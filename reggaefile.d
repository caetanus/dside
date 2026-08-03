// reggaefile.d — the qt-dlang-gen build graph (run with reggae).
//
//   reggae -b binary . --reggaefile-import-path reggae
//   ./build                 # build+run every target (the whole test matrix)
//   ./build <name>          # one target, e.g. widget_test-ldc2-qt6
//
// Bindings are generated on demand and compiled per-module into an archive; the linker
// selects what each app needs (no import-closure BFS). Everything is verified on ldc2
// AND dmd (parity); Qt5 and Qt6 where applicable. See reggae/qtd_build.d.
import reggae;
import qtd_build;
import std.conv : to;
import std.file : getcwd, exists, dirEntries, SpanMode, readText;
import std.path : buildPath, buildNormalizedPath, baseName, stripExtension;
import std.array : array, replace, join, split;
import std.algorithm : map, filter, sort, any, startsWith, canFind, all;
import std.process : execute;
import std.string : strip;

enum DCS = ["ldc2", "dmd"];

Build reggaeBuild() {
    immutable root = getcwd();
    Target[] all;

    string t(string dir, string f) { return buildPath(root, "tests", dir, f); }
    bool haveQt5() { return execute(["pkg-config", "--exists", "Qt5Widgets"]).status == 0; }

    // --- WRAPPER mode QtCore: identity + parenting-pins + orphan collection ---
    auto wrap = qtdBinding(root, "spec_cxx_wraptest.json", ["Qt6Core"]);
    foreach (dc; DCS) {
        all ~= qtdTest("wraptest-" ~ dc, t("wrapper", "wraptest.d"), wrap, dc);
        all ~= qtdTest("ownership-" ~ dc, t("wrapper", "ownership.d"), wrap, dc);   // destruction invariants
    }

    // --- WRAPPER mode QtWidgets (Qt6 + Qt5): widget app + moc/trampoline ---
    void widgets(string spec, string[] mods, string tag) {
        auto b = qtdBinding(root, spec, mods);
        foreach (dc; DCS) {
            all ~= qtdTest("widget_test-" ~ dc ~ "-" ~ tag, t("wrapper", "widget_test.d"), b, dc);
            all ~= qtdTest("moc_test-" ~ dc ~ "-" ~ tag, t("wrapper", "moc_test.d"), b, dc);
            all ~= qtdTest("moclife_widget-" ~ dc ~ "-" ~ tag, t("wrapper", "moclife_widget.d"), b, dc);
            // The transpiler's QML helpers live in the shared moc runtime that THIS (QtQml-free)
            // binding also compiles: prove they link and no-op here, not just that the C++ unit
            // compiles (qtmoc-probe-noqml covers that half).
            all ~= qtdTest("noqml_helpers-" ~ dc ~ "-" ~ tag, t("wrapper", "noqml_helpers.d"), b, dc);
        }
    }
    widgets("spec_cxx_qtwidgets_wrap.json", ["Qt6Widgets"], "qt6");
    if (haveQt5())
        widgets("spec_cxx_qtwidgets_wrap_qt5.json", ["Qt5Widgets"], "qt5");

    // --- smuggled example apps against the non-wrap QtWidgets binding (Qt6) ---
    auto ex = qtdBinding(root, "spec_cxx_qtwidgets.json", ["Qt6Widgets"]);
    foreach (app; dirEntries(buildPath(root, "tests", "examples"), "*.d", SpanMode.shallow).map!(e => e.name).array.sort)
        foreach (dc; DCS)
            all ~= qtdTest(baseName(app).stripExtension ~ "-" ~ dc, app, ex, dc);

    // --- CTFE uic: .ui -> typed Ui struct (mixin), built against the widgets binding ---
    auto uicExtra = buildPath(root, "runtime", "uic", "uiform.d") ~ " "
        ~ buildPath(root, "runtime", "qrc", "qrc.d")   // icon_test registers a CTFE .qrc
        ~ " -I" ~ buildPath(root, "runtime", "uic") ~ " -I" ~ buildPath(root, "runtime", "qrc")
        ~ " -J=" ~ buildPath(root, "tests", "uic");
    // box form, real corpus grid dialog, tabs, synthetic mainwindow chrome, real corpus mainwindow
    foreach (app; ["uic_test.d", "dialog_test.d", "tabs_test.d", "mainwin_test.d", "hello_test.d",
                   "egroup_test.d", "combo_test.d", "spacer_test.d", "icon_test.d"])
        foreach (dc; DCS)
            all ~= qtdTest(baseName(app).stripExtension.replace("_test", "") ~ "-" ~ dc,
                t("uic", app), ex, dc, uicExtra);
    all ~= uicheckTargets(root, ex);   // our uic == QUiLoader (differential oracle)
    all ~= corpusCheckTargets(root, ex);   // whole Qt baseline .ui corpus vs QUiLoader

    // --- CTFE qrc: a .qrc + import()ed files -> Qt .rcc blob, registered (no rcc tool) ---
    auto qrcExtra = buildPath(root, "runtime", "qrc", "qrc.d")
        ~ " -I" ~ buildPath(root, "runtime", "qrc") ~ " -J=" ~ buildPath(root, "tests", "qrc");
    foreach (dc; DCS)
        all ~= qtdTest("qrc-" ~ dc, t("qrc", "qrc_test.d"), ex, dc, qrcExtra);

    // --- QtWebEngineCore: link+run a smoke test against the real .so (whole-program) ---
    auto we = qtdBinding(root, "spec_cxx_webengine.json", ["Qt6WebEngineCore"]);
    foreach (dc; DCS)
        all ~= qtdTest("webengine-" ~ dc, t("webengine", "webengine_smoke.d"), we, dc);

    // --- QML: a D @QObject backend (runtime meta-object) driving a qrc-embedded .qml. No C++
    //     type registrar — the moc builds the QMetaObject, qrc bundles the .qml (:/), engine loads it.
    auto qmlExtra = buildPath(root, "runtime", "qrc", "qrc.d")
        ~ " -I" ~ buildPath(root, "runtime", "qrc") ~ " -J=" ~ buildPath(root, "tests", "qml");
    // The Qt5 and Qt6 QML bindings share d_package qt.qml, so ONE set of test sources runs on
    // both — the runtime features (setContextProperty, qmlRegisterType, moc lifetime, tr) are the
    // parity surface. Qt-version seams (e.g. QQmlPrivate::RegisterType layout) live in qtdmoc.cpp
    // behind a single QT_VERSION branch, so a future Qt7 is a small localized delta, not a rewrite.
    auto homoExtra = qmlExtra ~ " " ~ t("qml", "homonym_a.d") ~ " " ~ t("qml", "homonym_b.d");
    void qmlSuite(QtdBinding b, string tag) {
        foreach (dc; DCS) {
            all ~= qtdTest("qml" ~ tag ~ "-" ~ dc, t("qml", "backend_test.d"), b, dc, qmlExtra);   // setContextProperty
            all ~= qtdTest("qmlreg" ~ tag ~ "-" ~ dc, t("qml", "register_test.d"), b, dc, qmlExtra); // qmlRegisterType
            all ~= qtdTest("qmltwo" ~ tag ~ "-" ~ dc, t("qml", "register_two_test.d"), b, dc, qmlExtra); // 2 distinct types
            all ~= qtdTest("homonym" ~ tag ~ "-" ~ dc, t("qml", "homonym_test.d"), b, dc, homoExtra); // 2 same-named types
            all ~= qtdTest("homocollide" ~ tag ~ "-" ~ dc, t("qml", "homonym_collision_test.d"), b, dc, homoExtra); // same key -> conflict
            all ~= qtdTest("moclife" ~ tag ~ "-" ~ dc, t("qml", "moclife_test.d"), b, dc);           // side-table cleanup
            all ~= qtdTest("metacast" ~ tag ~ "-" ~ dc, t("qml", "metacast_test.d"), b, dc);         // qt_metacast identity
            all ~= qtdTest("metacontract" ~ tag ~ "-" ~ dc, t("qml", "metacontract_test.d"), b, dc); // @Slot/NOTIFY compile-time rules
            all ~= qtdTest("slotoverload" ~ tag ~ "-" ~ dc, t("qml", "slotoverload_test.d"), b, dc); // Qt-style overloaded slots
            all ~= qtdTest("boom" ~ tag ~ "-" ~ dc, t("qml", "boom_test.d"), b, dc, qmlExtra);       // factory throw -> observable failure
            all ~= qtdTest("metathread" ~ tag ~ "-" ~ dc, t("qml", "metathread_test.d"), b, dc);     // single-thread affinity enforced
            all ~= qtdTest("reglife" ~ tag ~ "-" ~ dc, t("qml", "reglife_test.d"), b, dc);           // nested tree releases its registry entries
        }
        all ~= qmlTrTargets(root, b, tag);   // runtime tr() via lrelease .qm round-trip
    }
    all ~= qtmocProbeTargets(root);   // the shared runtime must compile with AND without QtQml
    // The report derives category/compiler/Qt from target NAMES in a second system, so it can stop
    // describing what the build runs without anything failing: it called 472 of 667 targets
    // `other` and 122 Qt5 targets Qt6 while every one of them executed correctly. Its self-test is
    // a build target so that drift is a RED BUILD, not a wrong artifact.
    {
        auto rep = buildPath(root, "tools", "test-report.sh");
        if (exists(rep))
            all ~= Target.phony("report-selftest", "bash " ~ rep ~ " --self-test", [Target(rep)]);
    }
    auto qml = qtdBinding(root, "spec_cxx_qml.json", ["Qt6Qml", "Qt6Gui"]);
    qmlSuite(qml, "");
    all ~= qmlAotTargets(root, qml);   // qmlcachegen (Qt6 unit/loader format); Qt5 AOT is a follow-up
    all ~= qmlTypesCheckTargets(root, qml);   // CTFE .qmltypes (Qt-agnostic), validated by Qt's reader
    all ~= qmltcTargets(root, qml, buildPath(root, "tests", "qmltc", "corpus"), "");   // qmltc-d: .qml -> D vs oracle
    all ~= qmltcDTypeTargets(root, qml);   // .qml rooted in an APP-DEFINED type written in D
    all ~= qmltcCppTypeTargets(root, qml); // ... and in C++ (Qt's own corpus types, vendored)
    // (b) QtQuick: a bound-type root (Item -> QQuickItem) compiled to a D subclass, diffed vs the engine.
    if (execute(["pkg-config", "--exists", "Qt6Quick"]).status == 0) {
        auto quick = qtdBinding(root, "spec_cxx_quick.json", ["Qt6Quick", "Qt6QmlModels", "Qt6Qml", "Qt6Gui"]);
        all ~= qmltcTargets(root, quick, buildPath(root, "tests", "qmltc", "quick"), "q");
        // A bound VALUE TYPE as a @Property (QColor, QSize): needs the Quick binding, since that
        // is where those types live.
        foreach (dc; DCS) {
            all ~= qtdTest("valuetypeprop-" ~ dc, buildPath(root, "tests", "qml", "valuetypeprop_test.d"),
                           quick, dc);
            // Does Qt resolve a QtdWidget subclass as its BOUND C++ base? qobject_cast walks the
            // meta-object chain, and Qt uses it to decide policy on objects handed to it.
            all ~= qtdTest("subclasscast-" ~ dc, buildPath(root, "tests", "qml", "subclasscast_test.d"),
                           quick, dc);
        }
    }
    // QtQuick.Templates — the C++ side of QtQuick.Controls, and the vocabulary real QML documents
    // are written against (measured: Controls is what most of Qt's own .qml needs).
    if (execute(["pkg-config", "--exists", "Qt6QuickTemplates2"]).status == 0) {
        // Qt6QuickControls2Impl carries IconLabel/CheckLabel/ColorImage — the types every
        // Basic contentItem is built from. Binding their headers without linking the library
        // gets you a clean compile and undefined references at link time.
        auto ctrl = qtdBinding(root, "spec_cxx_controls.json",
                               ["Qt6QuickControls2Impl", "Qt6QuickTemplates2", "Qt6Quick",
                                "Qt6QmlModels", "Qt6Qml", "Qt6Gui"]);
        all ~= qmltcTargets(root, ctrl, buildPath(root, "tests", "qmltc", "controls"), "c");
        // ...and the same compiler pointed at QML NOBODY HERE WROTE: Qt's own Basic style files,
        // generated, linked and CONSTRUCTED. Six defects lived where compile-clean cannot see —
        // they all build and then die (or silently build the wrong object) at construction.
        all ~= qmltcControlsRuntimeTargets(root, ctrl);
        // ...and this binding gets a manifest gate like the other two. It had none, so changing its
        // spec tripped nothing — which is how binding the QtQuick animations (a real and intended
        // coverage change) landed without the manifest ever being consulted. A binding nobody holds
        // to a symbol contract is a binding whose fates can rot unnoticed.
        all ~= manifestGateTargets(root, [ctrl], ["controls"], ["controls.manifest.tsv"]);
    }
    if (haveQt5()) {
        // qmltc-d on Qt5: Qt ships no qmltc there at all, so this combination is ONLY covered by
        // us — and it was covered by nothing until the audit, which is how two Qt6-only APIs in
        // the oracle went unnoticed.
        auto qml5 = qtdBinding(root, "spec_cxx_qml_qt5.json", ["Qt5Qml", "Qt5Gui"]);
        qmlSuite(qml5, "-qt5");
        // qmltc-d on Qt5. Qt ships no qmltc there at all, so this combination is covered by
        // nothing else — and it was covered by nothing here either until the audit.
        // AliasBare uses `default property QtObject content: QtObject {}` — Qt6-only syntax that
        // Qt5's OWN engine rejects at 8:49, exactly where qmltc-d reports it. Nothing to compare.
        // The skip list is what Qt5's OWN ENGINE cannot load, established by running it over the
        // corpus rather than guessed: AliasBare uses `default property T x: T {}` and ListInt uses
        // `list<int>`, both Qt6-only syntax that Qt5 rejects at the same line and column qmltc-d
        // reports. SingletonFixture is a `pragma Singleton` FIXTURE (the UsesSingleton test imports it);
        // Qt5's QQmlComponent refuses to instantiate such a file directly, so there is nothing to
        // compare against — Qt6 tolerates it, which is why this only shows here.
        all ~= qmltcTargets(root, qml5, buildPath(root, "tests", "qmltc", "corpus"), "5",
                            ["AliasBare", "ListInt", "SingletonFixture"]);
    }

    // --- lupdate-d extraction, in the build of record: run the D-aware extractor on a fixture
    //     and diff its .ts against the checked-in golden (module context + tr/UFCS/translate forms).
    all ~= lupdateCheckTargets(root);

    // --- coverage manifest gate: regenerate a binding and diff its per-symbol manifest against a
    //     checked-in baseline, failing on regression (disappeared/worsened/new-drop symbol).
    //     The baselines are recorded against ONE Qt minor, and on a different minor the gate would
    //     measure SDK drift instead of a generator regression — which is why these used to be
    //     OPTIONAL. But "optional" meant the default ./build never ran them, so a real symbol
    //     regression could land unnoticed on the very machine whose Qt the baselines match. That
    //     is a version question, not a permanent exemption: the gate is MANDATORY when the
    //     installed Qt minor equals the one the binding (and therefore its baseline) was generated
    //     for, and advisory-by-name otherwise.
    auto manifestGates = manifestGateTargets(root, [ex, qml], ["qtwidgets", "qml"],
                                             ["qtwidgets.manifest.tsv", "qml.manifest.tsv"]);
    bool gatesEnforceable = bindingQtMinor(ex.genDir).length
        && bindingQtMinor(ex.genDir) == installedQtMinor("Qt6Widgets")
        && bindingQtMinor(qml.genDir) == installedQtMinor("Qt6Qml");

    // --- expected-fails registry consumer: validate schema/kind and that every `risk` probe names
    //     a real build target (so the inventory is enforcement, not just prose).
    {
        auto efD = buildPath(root, "tests", "expected_fails_check.d");
        auto efBin = buildPath(root, ".build", "expected-fails-lint-bin");
        auto efJson = buildPath(root, "tests", "expected-fails.json");
        auto efList = buildPath(root, ".build", "build-list.txt");
        auto efb = Target(efBin, "dmd -of=$out " ~ efD, [Target(efD)]);
        // deps=[efb] -> $in is the checker; capture ./build --list, then validate against it.
        all ~= Target.phony("expected-fails-lint",
            "sh -c \"" ~ buildPath(root, "build") ~ " --list > " ~ efList ~ " 2>/dev/null; "
            ~ "$in " ~ efJson ~ " " ~ efList ~ "\"", [efb]);
    }

    // --- holder lifetime layer, unit-tested in isolation (no generated binding) ---
    all ~= holderTests(root);

    // --- shiboken libsample corner cases (skipped if the pyside-setup clone is absent) ---
    all ~= libsampleTargets(root, buildNormalizedPath(root, "..", "pyside-setup"));

    // On the Qt the baselines were recorded against, the gates run with everything else; on any
    // other minor they stay reachable by name but out of defaultTargets(), so the full matrix
    // never fails on SDK drift.
    import std.range : chain;
    if (gatesEnforceable)
        return Build(chain(all.map!(t => createTopLevelTarget(t)),
                           manifestGates.map!(t => createTopLevelTarget(t))));
    return Build(chain(all.map!(t => createTopLevelTarget(t)),
                       manifestGates.map!(t => optional(t))));
}

// Differential oracle harness: our uic (uiForm) must build a tree identical to
// QUiLoader.load() for every .ui. The oracle load + the tree serializer live in a C++
// helper (links Qt6UiTools); the D side just diffs the two dumps. Built against the
// non-wrap widgets binding `ex`, per compiler.
// The QUiLoader dump helper is used by BOTH uic differentials. Declaring it twice with the same
// output and no dependencies made reggae execute it once per reaching top-level target — four
// concurrent `clang++ -o` on one path per build, while other targets linked against it. One
// memoised, guarded node instead.
private Target[string] _uidumpObjs;
Target uidumpObj(string root, QtdBinding ex, string dc) {
    auto o = buildPath(ex.bdir, "uidump-" ~ dc ~ ".o");
    if (auto p = o in _uidumpObjs) return *p;
    auto src = buildPath(root, "tests", "uic", "qtd_uidump.cpp");
    auto cf = pkgCflags(["Qt6UiTools", "Qt6Widgets"]) ~ " -std=c++17 -fPIC -O2";
    auto t = Target(o, guarded(o ~ ".lock", "clang++ " ~ cf ~ " -c " ~ src ~ " -o " ~ o, o, [src]),
                    [Target(src)]);
    _uidumpObjs[o] = t;
    return t;
}

// Every .ui the form tests string-import (-J). They are real inputs: without them a changed .ui
// (or a changed uiform.d / qrc.d, which were compiled but never listed) leaves the previous
// binary in place and the differential re-reports a stale verdict as if it were fresh.
Target[] uiInputs(string root, string dir) {
    Target[] ts = [Target(buildPath(root, "runtime", "uic", "uiform.d")),
                   Target(buildPath(root, "runtime", "qrc", "qrc.d"))];
    if (exists(dir))
        foreach (e; dirEntries(dir, "*.ui", SpanMode.shallow)) ts ~= Target(e.name);
    return ts;
}

Target[] uicheckTargets(string root, QtdBinding ex) {
    auto here = buildPath(root, "tests", "uic");
    auto cf = pkgCflags(["Qt6UiTools", "Qt6Widgets"]) ~ " -std=c++17 -fPIC -O2";
    auto libs = pkgLibs(["Qt6UiTools", "Qt6Widgets"]);
    auto uiformD = buildPath(root, "runtime", "uic", "uiform.d");
    auto qrcD = buildPath(root, "runtime", "qrc", "qrc.d");   // for the icon form's :/ resources
    auto checkD = buildPath(here, "uicheck.d");
    Target[] ts;
    foreach (dc; DCS) {
        auto uidumpO = buildPath(ex.bdir, "uidump-" ~ dc ~ ".o");
        auto uidumpT = uidumpObj(root, ex, dc);
        auto lib = qtdBindLib(ex, dc);
        auto bin = Target("uicheck-" ~ dc ~ "-bin",
            dc ~ " -of=$out " ~ checkD ~ " " ~ uiformD ~ " " ~ qrcD ~ " " ~ uidumpO
            ~ " -I" ~ ex.genDir ~ " -I" ~ buildPath(root, "runtime", "qrc")
            ~ " -J=" ~ here ~ " -L--start-group -L=" ~ buildPath(ex.bdir, "libbinding_" ~ dc ~ ".a")
            ~ " -L=" ~ buildPath(ex.bdir, "libshims.a") ~ " -L--end-group " ~ libs,
            [Target(checkD), uidumpT, lib, ex.shims] ~ uiInputs(root, here));
        ts ~= Target.phony("uicheck-" ~ dc, "QT_QPA_PLATFORM=offscreen $in", [bin]);
    }
    return ts;
}

// The whole Qt baseline .ui corpus (tests/uic/corpus/*.ui) run through the same differential
// oracle as uicheck. Reuses the uidump.o harness; each form is diffed against QUiLoader.
Target[] corpusCheckTargets(string root, QtdBinding ex) {
    auto here = buildPath(root, "tests", "uic");
    auto cf = pkgCflags(["Qt6UiTools", "Qt6Widgets"]) ~ " -std=c++17 -fPIC -O2";
    auto libs = pkgLibs(["Qt6UiTools", "Qt6Widgets"]);
    auto uiformD = buildPath(root, "runtime", "uic", "uiform.d");
    auto qrcD = buildPath(root, "runtime", "qrc", "qrc.d");
    auto checkD = buildPath(here, "corpus_check.d");
    Target[] ts;
    foreach (dc; DCS) {
        auto uidumpO = buildPath(ex.bdir, "uidump-" ~ dc ~ ".o");
        auto uidumpT = uidumpObj(root, ex, dc);
        auto lib = qtdBindLib(ex, dc);
        auto bin = Target("corpus-check-" ~ dc ~ "-bin",
            dc ~ " -of=$out " ~ checkD ~ " " ~ uiformD ~ " " ~ qrcD ~ " " ~ uidumpO
            ~ " -I" ~ ex.genDir ~ " -I" ~ buildPath(root, "runtime", "qrc")
            ~ " -J=" ~ here ~ " -L--start-group -L=" ~ buildPath(ex.bdir, "libbinding_" ~ dc ~ ".a")
            ~ " -L=" ~ buildPath(ex.bdir, "libshims.a") ~ " -L--end-group " ~ libs,
            [Target(checkD), uidumpT, lib, ex.shims]
            ~ uiInputs(root, here) ~ uiInputs(root, buildPath(here, "corpus")));
        ts ~= Target.phony("corpus-check-" ~ dc, "QT_QPA_PLATFORM=offscreen $in", [bin]);
    }
    return ts;
}

// Coverage manifest gate: the per-symbol manifest becomes a CONTRACT. For each binding, the gen
// step rewrites coverage-manifest.tsv; the gate diffs it against tests/coverage/<b>.manifest.tsv
// and fails on a disappeared symbol, a fate that worsened (e.g. bound -> unmapped), or a new
// unmapped/inline-failed drop. Accept intended changes by regenerating the baseline. The gate
// program is compiler-independent (built once with dmd).
Target[] manifestGateTargets(string root, QtdBinding[] bindings, string[] labels, string[] baselines) {
    auto gateD = buildPath(root, "tests", "manifest_gate.d");
    auto gateBin = buildPath(root, ".build", "manifest-gate-bin");
    // -unittest: the gate runs its own regression-detection unittests (dropped/regressed overload)
    // at startup before checking the real manifest — the gate proves it can't be fooled.
    auto gate = Target(gateBin, "dmd -unittest -of=$out " ~ gateD, [Target(gateD)]);
    Target[] ts;
    foreach (i, b; bindings) {
        auto baseline = buildPath(root, "tests", "coverage", baselines[i]);
        auto curMan = buildPath(b.genDir, "coverage-manifest.tsv");
        // deps: the gate binary + the binding's gen (so the manifest is freshly regenerated).
        // --DRT-testmode=run-main: run the gate's regression-detection unittests, THEN the real check.
        ts ~= Target.phony("manifest-gate-" ~ labels[i],
            gateBin ~ " --DRT-testmode=run-main " ~ baseline ~ " " ~ curMan ~ " " ~ labels[i], [gate, b.gen]);
    }
    return ts;
}

// lupdate-d in the build of record: build the extractor (its own dub package), run it on
// tests/lupdate/fixture.d, and diff the emitted .ts against the golden. Locks the extraction
// contract — tr("x"), tr("x",disambig), "x".tr, "x".tr(disambig), translate("Ctx","x"), and the
// MODULE-as-context rule that the runtime tr() mirrors. The runtime end of the loop (.ts -> .qm ->
// tr()) is covered by the tr-* targets. Skipped if dub isn't available.
Target[] lupdateCheckTargets(string root) {
    if (execute(["which", "dub"]).status != 0) return [];
    auto dir = buildPath(root, "tools", "lupdate");
    auto bin = buildPath(dir, "lupdate-d");
    auto fixt = buildPath(root, "tests", "lupdate", "fixture.d");
    auto golden = buildPath(root, "tests", "lupdate", "fixture.golden.ts");
    auto outTs = buildPath(root, ".build", "lupdate-fixture.ts");
    auto pres = buildPath(root, ".build", "lupdate-preserve.ts");
    // 1) extraction matches the golden; 2) an EXISTING translation SURVIVES a re-run (critics r6 #6
    // catalog preservation). Fill one translation, re-extract, and require it's still there.
    auto cmd = "dub build --root=" ~ dir ~ " -q && " ~ bin ~ " " ~ fixt ~ " -ts " ~ outTs
        ~ " >/dev/null && diff -u " ~ golden ~ " " ~ outTs
        ~ " && cp " ~ golden ~ " " ~ pres
        ~ " && sed -i '0,/type=.unfinished.><.translation>/s@<translation type=.unfinished.></translation>@<translation>KEEP_ME</translation>@' " ~ pres
        ~ " && " ~ bin ~ " " ~ fixt ~ " -ts " ~ pres ~ " >/dev/null"
        ~ " && grep -q KEEP_ME " ~ pres
        ~ " && echo 'lupdate-check OK: golden match + existing translation preserved across re-run'";
    return [Target.phony("lupdate-check", "sh -c \"" ~ cmd ~ "\"", [])];
}

// Runtime tr(): a class with `mixin Tr` gets a Qt-style bare tr("…") (context = class name).
// The test always checks the identity (no translator -> source), and when lrelease is present
// it compiles tr_test.ts -> .qm, loads it, and checks the translation — the runtime end of the
// lupdate-d -> .ts -> lrelease -> .qm -> tr() loop. Passing the .qm as argv[1] triggers the
// full round-trip; without lrelease the target still runs (identity only).
Target[] qmlTrTargets(string root, QtdBinding qml, string tag = "") {
    auto here = buildPath(root, "tests", "qml");
    auto tsFile = buildPath(here, "tr_test.ts");
    auto lrelease = lreleasePath();
    Target[] ts;
    foreach (dc; DCS) {
        auto bin = qtdApp("tr" ~ tag ~ "-" ~ dc ~ "-bin", buildPath(here, "tr_test.d"), qml, dc);
        if (lrelease.length) {
            auto qm = buildPath(qml.bdir, "tr" ~ tag ~ "-" ~ dc ~ ".qm");
            auto qmT = Target(qm, lrelease ~ " " ~ tsFile ~ " -qm $out", [Target(tsFile)]);
            // deps [bin, qmT] -> $in = "<test-bin> <qm>" -> the test loads the .qm (full check).
            ts ~= Target.phony("tr" ~ tag ~ "-" ~ dc, "QT_QPA_PLATFORM=offscreen $in", [bin, qmT]);
        } else {
            ts ~= Target.phony("tr" ~ tag ~ "-" ~ dc, "QT_QPA_PLATFORM=offscreen $in", [bin]);
        }
    }
    return ts;
}

// .qmltypes emission: a D driver (qmltypes_gen) writes App.qmltypes from the CTFE meta-object
// of a @QObject type (the qmltyperegistrar equivalent), then Qt's OWN parser
// (QQmlJSTypeDescriptionReader, what qmllint/qmltyperegistrar use) validates it — proving the
// generated type description is well-formed and has the right shape. Needs Qt6QmlCompiler
// (private API); skipped if absent. The C++ validator is dc-independent but named per-dc so
// reggae never double-schedules the shared node.
Target[] qmlTypesCheckTargets(string root, QtdBinding qml) {
    if (execute(["pkg-config", "--exists", "Qt6QmlCompiler"]).status != 0) return [];
    auto here = buildPath(root, "tests", "qml");
    auto genD = buildPath(here, "qmltypes_gen.d");
    auto checkCpp = buildPath(here, "qtd_qmltypes_check.cpp");
    auto ccflags = pkgCflags(["Qt6QmlCompiler", "Qt6Qml", "Qt6Core"]) ~ " -std=c++17 -fPIC -O2 "
        ~ (modulePrivateFlags(pkgCflags(["Qt6QmlCompiler"]), "QtQmlCompiler")
           ~ modulePrivateFlags(pkgCflags(["Qt6Qml"]), "QtQml")
           ~ modulePrivateFlags(pkgCflags(["Qt6Core"]), "QtCore")).join(" ");
    // raw pkg-config libs (this is a clang++ link, not the D linker's -L= form).
    auto clibs = execute(["pkg-config", "--libs", "Qt6QmlCompiler", "Qt6Qml", "Qt6Core"]).output.strip;
    Target[] ts;
    foreach (dc; DCS) {
        // the CTFE generator binary. Built against the qml binding so libshims resolves the
        // qtd_* symbols dmd emits for an (unused) Signal.emit; --gc-sections drops the rest.
        auto gen = qtdApp("qmltypes-gen-" ~ dc ~ "-bin", genD, qml, dc);
        // run the generator -> App.qmltypes (deps=[gen] so $in is the generator path).
        auto outTypes = buildPath(qml.bdir, "App-" ~ dc ~ ".qmltypes");
        auto types = Target(outTypes, "$in $out", [gen]);
        // Qt's authoritative .qmltypes reader.
        auto check = Target("qmltypes-check-" ~ dc ~ "-bin",
            "clang++ " ~ ccflags ~ " " ~ checkCpp ~ " -o $out " ~ clibs, [Target(checkCpp)]);
        // validate: deps=[check, types] -> $in = "<validator> <App.qmltypes>".
        ts ~= Target.phony("qmltypes-" ~ dc, "$in", [check, types]);
    }
    return ts;
}

// The qmltc-d binary, built ONCE per binding: both the corpus differential and the
// D-app-type differential depend on it, and two Targets writing the same output would be a
// duplicated (racing) build node.
private Target[string] _qmltcTools;
Target qmltcTool(string root, QtdBinding bind) {
    if (auto p = bind.bdir in _qmltcTools) return *p;
    auto toolCpp = buildPath(root, "tools", "qmltc", "qmltc_d.cpp");
    // qmltc-d frontend needs the QQmlJS PRIVATE headers (QtQml + QtCore private subdirs), from
    // the SAME Qt the binding was generated for: the parser lives in both, the tool compiles
    // against both (two spelling differences, see paramTypeName/isDefaultMem), and Qt5 has no
    // qmltc of its own — so building the tool there is the only way that combination is covered.
    auto q = bind.mods.any!(m => m.startsWith("Qt5")) ? "Qt5" : "Qt6";
    auto qml = q ~ "Qml", core = q ~ "Core";
    auto toolFlags = pkgCflags([qml, core]) ~ " -std=c++17 -fPIC -O2 "
        ~ (modulePrivateFlags(pkgCflags([qml]), "QtQml")
           ~ modulePrivateFlags(pkgCflags([core]), "QtCore")).join(" ");
    auto toolLibs = execute(["pkg-config", "--libs", qml, core]).output.strip;
    // Shared by every qmltc differential target -> guard it (see `guarded`): a concurrent
    // re-schedule of this one node otherwise links over a binary another target is executing.
    auto toolBin = buildPath(bind.bdir, "qmltc-d");
    auto t = Target(toolBin, guarded(toolBin ~ ".lock",
        "clang++ " ~ toolFlags ~ " " ~ toolCpp ~ " -o " ~ toolBin ~ " " ~ toolLibs, toolBin, [toolCpp]),
        [Target(toolCpp)]);
    _qmltcTools[bind.bdir] = t;
    return t;
}

// qmltc-d: compile each tests/qmltc/corpus/*.qml to D and DIFF the generated object's property
// values against the REAL QML engine (QQmlComponent) — the corpus-check-style differential for
// the QML->D compiler. Two C++ programs: qmltc-d itself (frontend = Qt's private QQmlJS parser,
// so QtQml+QtCore private flags) which emits D + a --dump checker main, and the oracle
// (qtd_qmlvalues, public QQmlComponent) that prints the engine's values. Per (corpus file x dc):
// generate <Name>.d, link it against the qml binding, run it and the oracle, diff. All artifact
// paths are absolute (under the qml binding's bdir) so reggae keeps them where we reference them.
// PHASE 1 corpus is literal-scalar roots; bindings/children come in later phases.
// `skip` names corpus files the ENGINE of that Qt cannot parse, so a differential against it is
// impossible by construction — not a gap in qmltc-d. Qt5 rejects `default property T x: T {}`
// (Qt6-only syntax) at the same line and column our compiler reports it.
// Qt's OWN shipped Controls QML, built and constructed. Not a differential: the bar here is that
// the object exists at all, which is the step every compile-time metric skips. Skipped silently
// when Qt's Basic style is not installed, so the suite still runs on a machine without it.
// The shared moc runtime is compiled into EVERY binding, including ones with no QtQml at all
// (QtWidgets, libsample). A QML-only helper that escaped its #ifdef broke the whole default build,
// and nothing in the matrix would have caught it: every qmltc target links QtQml by construction.
// These probes compile the unit in each configuration the project actually ships, so a
// feature-isolation slip fails HERE rather than in an unrelated binding.
Target[] qtmocProbeTargets(string root) {
    auto src = buildPath(root, "runtime", "qtmoc", "qtdmoc.cpp");
    if (!exists(src)) return [];
    Target[] ts;
    auto mk = (string name, string[] mods, bool qml, string qmlMod) {
        if (!mods.all!(m => execute(["pkg-config", "--exists", m]).status == 0)) return;
        auto cf = pkgCflags(mods);
        auto flags = cf ~ " -std=c++17 -fPIC " ~ mocPrivateFlags(cf).join(" ")
                   ~ (qml ? " " ~ modulePrivateFlags(pkgCflags([qmlMod]), "QtQml").join(" ")
                            ~ " -DQTD_ENABLE_QML" : "");
        auto obj = buildPath(root, ".build", "probe-" ~ name ~ ".o");
        ts ~= Target.phony("qtmoc-probe-" ~ name,
                           "clang++ " ~ flags ~ " -c " ~ src ~ " -o " ~ obj, [Target(src)]);
    };
    // No QtQml in sight: the configuration that broke.
    mk("noqml", ["Qt6Core"], false, "");
    mk("qml6", ["Qt6Qml", "Qt6Core"], true, "Qt6Qml");
    mk("qml5", ["Qt5Qml", "Qt5Core"], true, "Qt5Qml");
    return ts;
}

Target[] qmltcControlsRuntimeTargets(string root, QtdBinding bind) {
    auto dir = "/usr/lib/qt6/qml/QtQuick/Controls/Basic";
    if (!exists(dir)) return [];
    auto here = buildPath(root, "tests", "qmltc");
    auto script = buildPath(here, "qtd_controls_runtime.sh");
    auto tool = qmltcTool(root, bind);
    auto toolBin = buildPath(bind.bdir, "qmltc-d");
    auto appCpp = buildPath(here, "qtd_qmltc_app.cpp");
    auto renderCpp = buildPath(here, "qtd_render.cpp");
    Target[] ts;
    foreach (dc; DCS) {
        auto outDir = buildPath(bind.bdir, "ctlrt-" ~ dc);
        auto cmd = "sh " ~ script ~ " " ~ toolBin ~ " " ~ buildPath(bind.genDir, "qmlmap.tsv")
                 ~ " " ~ dir ~ " " ~ outDir ~ " " ~ dc ~ " " ~ bind.genDir ~ " " ~ appCpp
                 ~ " " ~ renderCpp ~ " " ~ buildPath(bind.bdir, "libbinding_" ~ dc ~ ".a")
                 ~ " " ~ buildPath(bind.bdir, "libshims.a")
                 ~ " '" ~ pkgCflags(bind.mods ~ ["Qt6Core"]) ~ "' " ~ pkgLibs(bind.mods);
        ts ~= Target.phony("qmltc-controls-runtime-" ~ dc, cmd,
                           [tool, Target(script), Target(appCpp), Target(renderCpp),
                            bind.gen, qtdBindLib(bind, dc), bind.shims]);
    }
    return ts;
}

Target[] qmltcTargets(string root, QtdBinding bind, string corpusDir, string tag,
                      string[] skip = []) {
    if (execute(["pkg-config", "--exists", "Qt6Qml"]).status != 0) return [];
    auto here = buildPath(root, "tests", "qmltc");
    if (!exists(corpusDir)) return [];
    auto oracleCpp = buildPath(here, "qtd_qmlvalues.cpp");
    auto tool = qmltcTool(root, bind);
    auto toolBin = buildPath(bind.bdir, "qmltc-d");

    // oracle uses only the PUBLIC QML API (QQmlComponent) + Gui (QGuiApplication); loads QtQuick at runtime.
    // From the SAME Qt the binding was generated for. Hardcoding Qt6 here built a Qt6 oracle into
    // the qt-5.15 build dir, which then loaded libQt6Core alongside a Qt5 binding and crashed in
    // QObject::property — diagnosed as "the oracle aborts on Qt5" until the backtrace named the
    // library. The tool had the same bug and was fixed one commit earlier; this is its twin.
    auto oq = bind.mods.any!(m => m.startsWith("Qt5")) ? "Qt5" : "Qt6";
    auto oracleMods = [oq ~ "Qml", oq ~ "Gui", oq ~ "Core"];
    auto oracleFlags = pkgCflags(oracleMods) ~ " -std=c++17 -fPIC -O2";
    auto oracleLibs = execute(["pkg-config", "--libs"] ~ oracleMods).output.strip;
    auto oracleBin = buildPath(bind.bdir, "qmlvalues");
    auto rndBin = buildPath(bind.bdir, "qmlrender");
    Target[] rndDep;
    if (bind.mods.any!(m => m.canFind("Quick"))) {
        auto rCpp = buildPath(here, "qtd_qmlrender.cpp");
        auto rFl = pkgCflags(bind.mods ~ ["Qt6Core"]) ~ " -std=c++17 -fPIC -O2";
        auto rLb = execute(["pkg-config", "--libs"] ~ bind.mods ~ ["Qt6Core"]).output.strip;
        rndDep ~= Target(rndBin, guardedLink(rndBin ~ ".lock",
            "clang++ " ~ rFl ~ " " ~ rCpp ~ " -o $out " ~ rLb, rndBin, [rCpp]), [Target(rCpp)]);
    }

    // guardedLink, not guarded: this binary is SHARED by every differential in the suite, so a
    // rebuild of it races with runs already using it — writing straight to the final path leaves a
    // window where the file exists and is not yet executable, and a concurrent run dies with
    // EACCES. guardedLink's own comment documents that exact failure; the oracle was the last
    // binary still linking the unsafe way, and it surfaced the moment its source changed.
    auto oracle = Target(oracleBin, guardedLink(oracleBin ~ ".lock",
        "clang++ " ~ oracleFlags ~ " " ~ oracleCpp ~ " -o $out " ~ oracleLibs,
        oracleBin, [oracleCpp]), [Target(oracleCpp)]);

    // A bound visual root (Text) touches the font DB on property-set and fatals without a
    // QGuiApplication; this helper .o (linked into every check, DCE-dropped where unreferenced)
    // provides qtd_qmltc_init_gui_app() the generated main calls for such roots.
    auto appCpp = buildPath(here, "qtd_qmltc_app.cpp");
    auto appObj = buildPath(bind.bdir, "qtd_qmltc_app.o");
    auto appHelper = Target(appObj, guarded(appObj ~ ".lock",
        "clang++ " ~ oracleFlags ~ " -c " ~ appCpp ~ " -o " ~ appObj, appObj, [appCpp]), [Target(appCpp)]);
    // Files whose render is MEANINGFUL — they have area and more than one colour, so the frame
    // comparison can actually fail. The list is explicit rather than "every file": most of this
    // corpus was written for a PROPERTY differential and its roots have no visual size, which
    // renders a 1-pixel window that would compare equal no matter what the compiler emitted. The
    // comparator enforces the same rule at runtime, so a file added here that turns out to be
    // blank fails loudly instead of quietly passing.
    // BEHAVIOUR cases: (file, x, y, property). A real click is delivered to both sides and the
    // resulting property compared. This is the half of the criterion no property dump and no frame
    // comparison can reach — a MouseArea whose handler never runs renders pixel-identically and
    // does nothing, which is exactly what happened before base-type signals were connectable.
    static struct Click { string name; int x, y; string prop; }
    static immutable Click[] clickable = [Click("QClick", 30, 20, "hits"),
                                         Click("CClick", 40, 15, "hits")];

    // TIME cases: (file, ms, property). Both sides run for the same wall time and the property is
    // compared. An animation only advances when something drives it, so a compiled object can hold
    // a correct NumberAnimation that never ticks — invisible to a property dump (reads the initial
    // value), to a frame comparison (one frame) and to a click test (an event, not time).
    static struct Timed { string name; int ms; string prop; }
    static immutable Timed[] timed = [Timed("QAnim", 400, "v")];

    // Documents whose KEYBOARD behaviour is compared: send this key to both sides and diff the property.
struct Keyed { string name; int key; string prop; }
// EMPTY on purpose, and the state is precise. Both halves are plumbed (qtd_key_item here, `--key` in
// the oracle, `--key` in the generated main), QKey.qml compiles clean, and the observable works: a
// declared `property int len: text.length`, because binding `text` itself makes the engine's binding
// fight the key insertion, and the dump only carries what the document mentions.
// With window activation + forceActiveFocus on BOTH sides, and the engine half rebuilt to construct
// exactly like ours (own QQuickWindow, root reparented into contentItem), the measurement is:
// OURS receives the key (len=1) and the ENGINE's object does not (len=0).
// That is NOT "we behave better" — it means the harness is still not equivalent: an item created by
// QQmlComponent needs something ours does not (activation timing, or being in a window before
// completion). Until the engine half receives the key, this axis cannot judge the compiler, so no
// target is registered. Next: find what makes the engine-created item accept the key (compare with
// QQuickView + QTest::keyClick, which is how Qt's own tests do it).
static immutable Keyed[] keyed = [];

static immutable string[] renderable = ["QEnumCmp", "QEnumProp", "QGroupReactive", "QObjGroup",
                                            "QText", "QTextEdit", "QTextInput", "QVarCopy",
                                            "QVarTernary"];

    // The RENDER helper, for suites whose binding has QtQuick: a generated Item root gains a
    // `--render <png>` mode, which is the only thing in this suite that draws. Built only where
    // Quick exists — the QtQml-only binding has no Item root to render and must not need it.
    auto hasQuick = bind.mods.any!(m => m.canFind("Quick"));
    auto renderCpp = buildPath(here, "qtd_render.cpp");
    auto renderObj = buildPath(bind.bdir, "qtd_render.o");
    Target[] renderDep;
    string renderLink;
    if (hasQuick) {
        auto rFlags = pkgCflags(bind.mods ~ ["Qt6Core"]) ~ " -std=c++17 -fPIC -O2";
        renderDep ~= Target(renderObj, guarded(renderObj ~ ".lock",
            "clang++ " ~ rFlags ~ " -c " ~ renderCpp ~ " -o " ~ renderObj, renderObj, [renderCpp]),
            [Target(renderCpp)]);
        renderLink = " " ~ renderObj;
    }

    Target[] ts;
    auto corpus = dirEntries(corpusDir, "*.qml", SpanMode.shallow).map!(e => e.name).array;
    corpus.sort();
    // Feature not implemented yet — see the gate below. `skip` is a different thing: a document the
    // ENGINE of this Qt cannot load, where there is no oracle to compare against at all.
    // EMPTY, and that is the point: CDelegate lived here while `Component` was refused, and moved
    // out the day the compiled document matched the engine. A file goes in only with its bar
    // written down (docs/qmltc-d.md) and comes out by measurement, not by decision.
    static immutable string[] pendingFeature = [];
    foreach (qmlFile; corpus) {
        auto name = baseName(qmlFile).stripExtension;
        if (skip.canFind(name)) continue;
        // ...and a document whose FEATURE is not compiled yet: the fixture is committed so the bar
        // is written down and the diff is measured the day it lands, but a differential cannot be
        // the gate while the compiler correctly REFUSES the file — that leaves the default build
        // red and hides every other regression behind it. The target asserts the REFUSAL instead.
        // The day the feature works the refusal stops, THIS target fails, and the file moves out.
        if (pendingFeature.canFind(name)) {
            foreach (dc; DCS) {
                auto diag = buildPath(bind.bdir, "qmltc_" ~ name ~ "_" ~ dc ~ ".pending");
                ts ~= Target.phony("qmltcc-" ~ name ~ "-" ~ dc,
                    "sh -c '" ~ toolBin ~ " --dump " ~ qmlFile ~ " " ~ name ~ " --qmlmap "
                    ~ buildPath(bind.genDir, "qmlmap.tsv") ~ " > /dev/null 2>" ~ diag
                    ~ "; test -s " ~ diag ~ "'", [tool]);
            }
            continue;
        }
        foreach (dc; DCS) {
            // qmlmap.tsv (QML-name -> bound C++ class) is a build output of the binding's gend run;
            // the tool reads it so its bound-type vocabulary is DATA, not hard-coded. Absent (e.g.
            // the QtObject binding) -> the tool just loads nothing.
            auto qmlmapArg = " --qmlmap " ~ buildPath(bind.genDir, "qmlmap.tsv");
            // 1) qmltc-d --dump <qml> <Name> -> generated D (class + a value-dumping main).
            auto genD = buildPath(bind.bdir, "qmltc_" ~ name ~ "_" ~ dc ~ ".d");
            auto gen = Target(genD, toolBin ~ " --dump " ~ qmlFile ~ " " ~ name ~ qmlmapArg ~ " > $out",
                [tool, Target(qmlFile), bind.gen]);
            // 2) link the generated D against the binding (same shape as qtdApp).
            auto appBin = buildPath(bind.bdir, "qmltc_" ~ name ~ "_" ~ dc ~ "_check");
            auto link = dc ~ " -of=$out " ~ genD ~ " " ~ appObj ~ renderLink ~ " -I" ~ bind.genDir
                ~ " -L--gc-sections -L--as-needed -L--start-group -L=" ~ buildPath(bind.bdir, "libbinding_" ~ dc ~ ".a")
                ~ " -L=" ~ buildPath(bind.bdir, "libshims.a") ~ " -L--end-group " ~ pkgLibs(bind.mods) ~ " -L-lstdc++";
            // Guarded: with a `<Name>.set` sidecar TWO phony targets depend on this binary, and a
            // concurrent re-schedule links over it while the other target is running it.
            // The link also consumes the helper object and BOTH binding archives; leaving them out
            // pins a stale binary whenever the binding or the runtime changes — a green target
            // proving something about code that is no longer in the tree.
            auto appIns = [genD, appObj] ~ (hasQuick ? [renderObj] : []) ~ [buildPath(bind.bdir, "libbinding_" ~ dc ~ ".a"),
                           buildPath(bind.bdir, "libshims.a")];
            auto app = Target(appBin, guardedLink(appBin ~ ".lock", link, appBin, appIns),
                              [gen, appHelper] ~ renderDep ~ [qtdBindLib(bind, dc), bind.shims]);
            // 3) run the generated D and the oracle over the SAME .qml; the value dumps must match.
            //    The oracle dumps the EXACT property paths qmltc-d emits (`--labels` -> a .props
            //    file, `--props` to the oracle), so base C++ properties the .qml set are compared too.
            auto a = genD ~ ".dvals";
            auto b = genD ~ ".qmlvals";
            auto props = genD ~ ".props";
            auto mkProps = toolBin ~ " --labels " ~ qmlFile ~ " " ~ name ~ qmlmapArg ~ " > " ~ props ~ " 2>/dev/null; ";
            // The diff alone can only prove that what the tool EMITTED matches. --verify-props
            // is the independent half: it fails if the engine built a QML-declared member the
            // label list never mentions, which is the "both sides shrank" false green.
            auto cmd = "sh -c '" ~ mkProps ~ "QT_QPA_PLATFORM=offscreen " ~ appBin ~ " > " ~ a
                ~ " && QT_QPA_PLATFORM=offscreen " ~ oracleBin ~ " " ~ qmlFile ~ " --props " ~ props ~ " > " ~ b
                ~ " && QT_QPA_PLATFORM=offscreen " ~ oracleBin ~ " " ~ qmlFile ~ " --verify-props " ~ props
                ~ " && diff " ~ a ~ " " ~ b ~ "'";
            ts ~= Target.phony("qmltc" ~ tag ~ "-" ~ name ~ "-" ~ dc, cmd, [app, oracle, tool]);
            // ...and the STRONGER protocol beside it, which until now lived only in the corpus
            // scripts: `--objpaths` lists the objects and BOTH sides then enumerate every property
            // each one declares. The `--props` diff above can only prove that what the compiler
            // CHOSE to record matches; this one compares what the objects actually are, and it is
            // what found the deferred transitions, the gradients, the QJSValue slots and every
            // ordering defect this file records. Measured before adding it: 23 of the 23 controls
            // fixtures pass.
            // ...for every fixture EXCEPT the ones a measured, named gap makes fail today: a QML
            // member that is not a plain scalar property — an alias, a default-property holder, a
            // list property, and the object-property paths the emitter does not mark — is a D
            // field and not a meta-object property, so the engine's dump has `conn <object>` (or
            // `inner`, `child`, `kids[0]`) and ours has no such key. Measured: controls 23 of 23
            // pass, quick 42 of 46, corpus 33 of 46. Listing them here rather than dropping the
            // gate keeps the 98 that DO hold, and the list is the backlog — see the
            // `qml-declared-members-not-in-metaobject` entry in tests/expected-fails.json.
            static immutable string[] dumpallGap = [
                "AliasBare", "Aliased", "AliasHolder", "AliasRebind", "ArrayBinding", "ChildAlias",
                "ChildReactive", "Connect", "CrossCall", "DefaultHolder", "UsesAliasDefault",
                "UsesDefault", "UsesList",
                "QNested", "QObjProp", "QUsesLocalExt", "QUsesLocal",
            ];
            if (!dumpallGap.canFind(name)) {
            auto objs = genD ~ ".objs", da = genD ~ ".dall", qa = genD ~ ".qall";
            auto mkObjs = toolBin ~ " --objpaths " ~ qmlFile ~ " " ~ name ~ qmlmapArg ~ " > " ~ objs ~ " 2>/dev/null; ";
            auto allCmd = "sh -c '" ~ mkObjs ~ "QT_QPA_PLATFORM=offscreen " ~ appBin ~ " --dumpall | sort > " ~ da
                ~ " && QT_QPA_PLATFORM=offscreen " ~ oracleBin ~ " " ~ qmlFile ~ " --dumpall " ~ objs ~ " | sort > " ~ qa
                ~ " && diff " ~ da ~ " " ~ qa ~ "'";
            ts ~= Target.phony("qmltc" ~ tag ~ "-" ~ name ~ "-all-" ~ dc, allCmd, [app, oracle, tool]);
            }
            // RENDER differential: draw the same document both ways and compare the FRAME. The
            // property dump can agree while the two paint differently — that is the bar the
            // project is actually held to ("renders and behaves like the interpreted version"),
            // and nothing here drew a pixel before this. Software backend so it is deterministic
            // and needs no GPU; the comparator refuses a frame with no area or a single colour,
            // so this cannot decay into a test that passes on emptiness.
            // Time: both sides run for the same wall time, then the property is compared — and
            // the value must differ from the t=0 one, or the test would pass on a frozen document.
            foreach (tm; timed) if (tm.name == name && rndDep.length) {
                auto renv3 = "QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software ";
                auto oT = genD ~ ".time.ours", eT = genD ~ ".time.eng", zT = genD ~ ".time.zero";
                auto tcmd = renv3 ~ appBin ~ " --run " ~ tm.ms.to!string
                          ~ " | grep '^" ~ tm.prop ~ "\t' > " ~ oT
                          ~ " && " ~ renv3 ~ rndBin ~ " --run " ~ qmlFile ~ " " ~ tm.ms.to!string
                          ~ " " ~ tm.prop ~ " > " ~ eT
                          ~ " && diff " ~ eT ~ " " ~ oT
                          ~ " && " ~ renv3 ~ appBin ~ " | grep '^" ~ tm.prop ~ "\t' > " ~ zT
                          ~ " && ! diff -q " ~ oT ~ " " ~ zT ~ " > /dev/null";
                ts ~= Target.phony("qmltc" ~ tag ~ "-" ~ name ~ "-time-" ~ dc, tcmd,
                                   [app] ~ rndDep ~ [tool]);
            }
            // KEYBOARD: same key to both sides, compare the property it should have changed. Focus and
            // the bound type's own C++ key handling are machinery nothing else in this suite touches —
            // a document can be pixel-identical and click-correct and never see a key.
            foreach (kk; keyed) if (kk.name == name && rndDep.length) {
                auto renv4 = "QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software ";
                auto oK = genD ~ ".key.ours", eK = genD ~ ".key.eng", zK = genD ~ ".key.zero";
                auto kcmd = renv4 ~ appBin ~ " --key " ~ kk.key.to!string
                          ~ " | grep '^" ~ kk.prop ~ "\t' > " ~ oK
                          ~ " && " ~ renv4 ~ rndBin ~ " --key " ~ qmlFile ~ " " ~ kk.key.to!string
                          ~ " " ~ kk.prop ~ " > " ~ eK
                          ~ " && diff " ~ eK ~ " " ~ oK
                          // ...and prove the key MATTERED: without it the value must differ, or the
                          // test would pass on a document that ignores the keyboard entirely.
                          ~ " && " ~ renv4 ~ appBin ~ " | grep '^" ~ kk.prop ~ "\t' > " ~ zK
                          ~ " && ! diff -q " ~ oK ~ " " ~ zK ~ " > /dev/null";
                ts ~= Target.phony("qmltc" ~ tag ~ "-" ~ name ~ "-key-" ~ dc, kcmd,
                                   [app] ~ rndDep ~ [tool]);
            }
            // Behaviour: same click to both sides, compare the property it should have changed.
            foreach (ck; clickable) if (ck.name == name && rndDep.length) {
                auto renv2 = "QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software ";
                auto ourOut = genD ~ ".click.ours", engOut = genD ~ ".click.eng";
                auto ccmd = renv2 ~ appBin ~ " --click " ~ ck.x.to!string ~ " " ~ ck.y.to!string
                          ~ " | grep '^" ~ ck.prop ~ "\t' > " ~ ourOut
                          ~ " && " ~ renv2 ~ rndBin ~ " --click " ~ qmlFile ~ " " ~ ck.x.to!string
                          ~ " " ~ ck.y.to!string ~ " " ~ ck.prop ~ " > " ~ engOut
                          ~ " && diff " ~ engOut ~ " " ~ ourOut
                          // ...and prove the click MATTERED: without it the value must differ, or
                          // the test would pass on a document that ignores input entirely.
                          ~ " && " ~ renv2 ~ appBin ~ " | grep '^" ~ ck.prop ~ "\t' > " ~ ourOut ~ ".noclick"
                          ~ " && ! diff -q " ~ ourOut ~ " " ~ ourOut ~ ".noclick > /dev/null";
                ts ~= Target.phony("qmltc" ~ tag ~ "-" ~ name ~ "-click-" ~ dc, ccmd,
                                   [app] ~ rndDep ~ [tool]);
            }
            if (renderable.canFind(name) && rndDep.length) {
                auto ourPng = genD ~ ".our.png", engPng = genD ~ ".eng.png";
                auto renv = "QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software ";
                auto rcmd = renv ~ appBin ~ " --render " ~ ourPng
                          ~ " && " ~ renv ~ rndBin ~ " " ~ qmlFile ~ " " ~ engPng
                          ~ " && " ~ renv ~ rndBin ~ " --compare " ~ engPng ~ " " ~ ourPng;
                ts ~= Target.phony("qmltc" ~ tag ~ "-" ~ name ~ "-render-" ~ dc, rcmd,
                                   [app] ~ rndDep ~ [tool]);
            }
            // 4) LIVE-BINDING differential: if a `<Name>.set` sidecar lists `name=value` mutations,
            //    apply them to BOTH the generated D and the engine, and diff the post-mutation dumps.
            //    A binding that isn't reactive would diverge here (dependent wouldn't update).
            auto setFile = buildPath(corpusDir, name ~ ".set");
            if (exists(setFile)) {
                // Quote each token: a mutation may be `method()`, and bare parens are shell syntax.
                auto setArgs = readText(setFile).strip.split.map!(a => "\"" ~ a ~ "\"").join(" ");
                auto cmd2 = "sh -c '" ~ mkProps ~ "QT_QPA_PLATFORM=offscreen " ~ appBin ~ " " ~ setArgs ~ " > " ~ a ~ ".set"
                    ~ " && QT_QPA_PLATFORM=offscreen " ~ oracleBin ~ " " ~ qmlFile ~ " " ~ setArgs ~ " --props " ~ props ~ " > " ~ b ~ ".set"
                    ~ " && diff " ~ a ~ ".set " ~ b ~ ".set'";
                ts ~= Target.phony("qmltc" ~ tag ~ "-" ~ name ~ "-set-" ~ dc, cmd2, [app, oracle, tool]);
            }
        }
    }
    return ts;
}

// qmlcachegen AOT: compile tests/qml/register.qml to a bytecode unit + a cache-loader hook
// (Qt's own tool), link both into an app that ships NO .qml source, and prove the engine
// serves qrc:/register.qml from the precompiled unit. Skipped when qmlcachegen isn't installed.
// The loader's output file name MUST end in `qmlcache_loader.cpp` — that's how qmlcachegen
// switches from unit to loader mode. The generated .cpp are pure C++ (compiled once per dc so
// reggae never double-schedules a shared node), so the unit/loader are regenerated per compiler.
Target[] qmlAotTargets(string root, QtdBinding qml) {
    auto gen = qmlcachegenPath();
    if (!gen.length) return [];   // no qmlcachegen on this system -> skip the AOT path
    auto here = buildPath(root, "tests", "qml");
    auto qmlFile = buildPath(here, "register.qml");
    auto qrcFile = buildPath(here, "register.qrc");
    auto aotMain = buildPath(here, "aot_test.d");
    auto qmlCxx = pkgCflags(qml.mods) ~ " -std=c++17 -fPIC -O2";
    auto libPathOf(string dc) { return buildPath(qml.bdir, "libbinding_" ~ dc ~ ".a"); }
    auto shimsPath = buildPath(qml.bdir, "libshims.a");
    Target[] ts;
    foreach (dc; DCS) {
        // .qml -> bytecode unit; and the cache loader that hooks it in for qrc:/register.qml.
        auto unitCpp = buildPath(qml.bdir, "aot_register_qml-" ~ dc ~ ".cpp");
        auto unitCppT = Target(unitCpp,
            gen ~ " --resource-path /register.qml -o $out " ~ qmlFile, []);
        auto loaderCpp = buildPath(qml.bdir, "aot-" ~ dc ~ "_qmlcache_loader.cpp");
        auto loaderCppT = Target(loaderCpp,
            gen ~ " --resource-name qmlcache_qmlreg -o $out --resource " ~ qrcFile ~ " /register.qml", []);
        auto unitO = buildPath(qml.bdir, "aot_register_qml-" ~ dc ~ ".o");
        auto unitOT = Target(unitO, "clang++ " ~ qmlCxx ~ " -c " ~ unitCpp ~ " -o $out", [unitCppT]);
        auto loaderO = buildPath(qml.bdir, "aot_qmlcache_loader-" ~ dc ~ ".o");
        auto loaderOT = Target(loaderO, "clang++ " ~ qmlCxx ~ " -c " ~ loaderCpp ~ " -o $out", [loaderCppT]);
        auto lib = qtdBindLib(qml, dc);
        auto link = dc ~ " -of=$out " ~ aotMain ~ " " ~ unitO ~ " " ~ loaderO ~ " -I" ~ qml.genDir
            ~ " -L--gc-sections -L--as-needed -L--start-group -L=" ~ libPathOf(dc) ~ " -L=" ~ shimsPath
            ~ " -L--end-group " ~ pkgLibs(qml.mods);
        auto bin = Target("qmlaot-" ~ dc ~ "-bin", link, [Target(aotMain), unitOT, loaderOT, lib, qml.shims]);
        ts ~= Target.phony("qmlaot-" ~ dc, "QT_QPA_PLATFORM=offscreen $in", [bin]);
    }
    return ts;
}

// The holder unit test compiles the fixed runtime (holder.d + qtd_holder.cpp) with a
// small C++ helper — no gend, no binding. Kept as a bespoke target.
Target[] holderTests(string root) {
    auto H = buildPath(root, "runtime", "holder");
    auto here = buildPath(root, "tests", "holder");
    auto cflags = pkgCflags(["Qt6Core"]) ~ " -std=c++17 -fPIC -O2";
    auto libs = pkgLibs(["Qt6Core"]);
    Target[] ts;
    foreach (dc; DCS) {
        // Objects are per-dc (not shared across the ldc2/dmd phonies) so reggae never
        // double-schedules one shared node concurrently (which would truncate the .o).
        auto qtd = Target("h_qtd-" ~ dc ~ ".o",
            "clang++ " ~ cflags ~ " -c " ~ buildPath(H, "qtd_holder.cpp") ~ " -o $out", []);
        auto help = Target("h_help-" ~ dc ~ ".o",
            "clang++ " ~ cflags ~ " -c " ~ buildPath(here, "helper.cpp") ~ " -o $out", []);
        // deps order -> $in = holder_test.d holder.d h_qtd.o h_help.o
        auto app = Target("holder_test-" ~ dc ~ "-bin",
            dc ~ " -of=$out $in -L-lstdc++ " ~ libs,
            [Target(buildPath(here, "holder_test.d")), Target(buildPath(H, "holder.d")), qtd, help]);
        ts ~= Target.phony("holder_test-" ~ dc, "QT_QPA_PLATFORM=offscreen $in", [app]);
    }
    return ts;
}

mixin BuildgenMain;

// qmltc-d against APP-DEFINED QML TYPES WRITTEN IN D. QML resolves a type through its
// meta-object, so the language that produced it is irrelevant — a `@QObject` D class exported by
// qmlRegisterType is a QML element exactly as a C++ Q_OBJECT/QML_ELEMENT type is. Both sides of
// the differential are driven from ONE list of D types (tests/qmltc/dtypes/apptypes.d):
//
//   ORACLE   = the REAL QML engine. qtd_qmlvalues_d.d registers the D types, then hands over to
//              qtd_qmlvalues.cpp's qtd_qmlvalues_main — the same walk/format/dump the C++ oracle
//              has always used, so the comparison protocol is unchanged.
//   COMPILED = qmltc-d reads the types' CTFE `.qmltypes` (Qt's own registry format, itself a QML
//              document, so it is parsed with the same QQmlJS frontend) and emits a D class that
//              plainly DERIVES from the D type — no C++ trampoline, no mixin: an inherited
//              @Property is a real field.
//
// Equal dumps prove the compiled-to-D object reproduces what the engine builds. A `<Name>.set`
// sidecar additionally mutates both and re-diffs, which is what proves the bindings stayed LIVE
// through the base type's own notify signal.
Target[] qmltcDTypeTargets(string root, QtdBinding bind) {
    if (execute(["pkg-config", "--exists", "Qt6Qml"]).status != 0) return [];
    auto here = buildPath(root, "tests", "qmltc");
    auto dir = buildPath(here, "dtypes");
    if (!exists(dir)) return [];
    auto appD = buildPath(dir, "apptypes.d");
    auto tool = qmltcTool(root, bind);
    auto toolBin = buildPath(bind.bdir, "qmltc-d");

    // The oracle's engine half, compiled without its `main` so the D driver can supply one.
    auto oracleCpp = buildPath(here, "qtd_qmlvalues.cpp");
    auto oracleObj = buildPath(bind.bdir, "qmlvalues_lib.o");
    auto oracleLib = Target(oracleObj,
        "clang++ " ~ pkgCflags(["Qt6Qml", "Qt6Gui", "Qt6Core"]) ~ " -std=c++17 -fPIC -O2 "
        ~ "-DQTD_QMLVALUES_NO_MAIN -c " ~ oracleCpp ~ " -o $out", [Target(oracleCpp)]);

    Target[] ts;
    auto corpus = dirEntries(dir, "*.qml", SpanMode.shallow).map!(e => e.name).array;
    corpus.sort();
    foreach (dc; DCS) {
        auto dcLibs = pkgLibs(bind.mods) ~ " -L-lstdc++";
        auto dcLink = " -I" ~ bind.genDir ~ " -I" ~ dir
            ~ " -L--gc-sections -L--as-needed -L--start-group -L=" ~ buildPath(bind.bdir, "libbinding_" ~ dc ~ ".a")
            ~ " -L=" ~ buildPath(bind.bdir, "libshims.a") ~ " -L--end-group " ~ dcLibs;

        // 1) the type REGISTRY: a D driver writes the CTFE .qmltypes of the app's types.
        auto genBin = buildPath(bind.bdir, "dtypes-gen-" ~ dc);
        // Shared by every qmltcd- target -> guard it, like the oracle and qmltc-d itself.
        auto genCmd = dc ~ " -of=" ~ genBin ~ " " ~ buildPath(dir, "qmltypes_gen.d") ~ " " ~ appD ~ dcLink;
        auto gen = Target(genBin, guarded(genBin ~ ".lock", genCmd, genBin,
            [appD, buildPath(dir, "qmltypes_gen.d"), buildPath(bind.bdir, "libbinding_" ~ dc ~ ".a")]),
            [Target(buildPath(dir, "qmltypes_gen.d")), Target(appD), qtdBindLib(bind, dc), bind.shims]);
        auto typesFile = buildPath(bind.bdir, "AppTypes-" ~ dc ~ ".qmltypes");
        auto types = Target(typesFile, "$in $out", [gen]);

        // 2) the ORACLE: D main (registers the types) + the C++ engine half.
        auto oracleBin = buildPath(bind.bdir, "qmlvalues-d-" ~ dc);
        auto oracle = Target(oracleBin, guarded(oracleBin ~ ".lock",
            dc ~ " -of=" ~ oracleBin ~ " " ~ buildPath(here, "qtd_qmlvalues_d.d") ~ " " ~ appD ~ " " ~ oracleObj ~ dcLink,
            oracleBin, [appD, buildPath(here, "qtd_qmlvalues_d.d"), oracleObj]),
            [Target(buildPath(here, "qtd_qmlvalues_d.d")), Target(appD), oracleLib, qtdBindLib(bind, dc), bind.shims]);

        foreach (qmlFile; corpus) {
            auto name = baseName(qmlFile).stripExtension;
            auto dtypesArg = " --dtypes " ~ typesFile ~ " apptypes";
            // 3) compile the .qml to D against the registry, and link it with the app's types.
            auto genD = buildPath(bind.bdir, "qmltcd_" ~ name ~ "_" ~ dc ~ ".d");
            auto gd = Target(genD, toolBin ~ " --dump " ~ qmlFile ~ " " ~ name ~ dtypesArg ~ " > $out",
                [tool, Target(qmlFile), types]);
            auto appBin = buildPath(bind.bdir, "qmltcd_" ~ name ~ "_" ~ dc ~ "_check");
            auto appCmd = dc ~ " -of=$out " ~ genD ~ " " ~ appD ~ dcLink;
            auto app = Target(appBin, guardedLink(appBin ~ ".lock", appCmd, appBin,
                [genD, appD, buildPath(bind.bdir, "libbinding_" ~ dc ~ ".a"), buildPath(bind.bdir, "libshims.a")]),
                [gd, Target(appD), qtdBindLib(bind, dc), bind.shims]);
            // 4) run both over the SAME .qml and diff (same --labels/--props protocol as the corpus).
            auto a = genD ~ ".dvals", b = genD ~ ".qmlvals", props = genD ~ ".props";
            auto mkProps = toolBin ~ " --labels " ~ qmlFile ~ " " ~ name ~ dtypesArg ~ " > " ~ props ~ " 2>/dev/null; ";
            ts ~= Target.phony("qmltcd-" ~ name ~ "-" ~ dc,
                "sh -c '" ~ mkProps ~ "QT_QPA_PLATFORM=offscreen " ~ appBin ~ " > " ~ a
                ~ " && QT_QPA_PLATFORM=offscreen " ~ oracleBin ~ " " ~ qmlFile ~ " --props " ~ props ~ " > " ~ b
                ~ " && QT_QPA_PLATFORM=offscreen " ~ oracleBin ~ " " ~ qmlFile ~ " --verify-props " ~ props
                ~ " && diff " ~ a ~ " " ~ b ~ "'", [app, oracle, tool]);
            // 5) LIVE-binding differential: mutate both, re-diff. A binding that lost its
            //    connection to the BASE type's notify signal diverges here.
            auto setFile = buildPath(dir, name ~ ".set");
            if (exists(setFile)) {
                // Quote each token: a mutation may be `method()`, and bare parens are shell syntax.
                auto setArgs = readText(setFile).strip.split.map!(a => "\"" ~ a ~ "\"").join(" ");
                ts ~= Target.phony("qmltcd-" ~ name ~ "-set-" ~ dc,
                    "sh -c '" ~ mkProps ~ "QT_QPA_PLATFORM=offscreen " ~ appBin ~ " " ~ setArgs ~ " > " ~ a ~ ".set"
                    ~ " && QT_QPA_PLATFORM=offscreen " ~ oracleBin ~ " " ~ qmlFile ~ " " ~ setArgs
                    ~ " --props " ~ props ~ " > " ~ b ~ ".set && diff " ~ a ~ ".set " ~ b ~ ".set'",
                    [app, oracle, tool]);
            }
        }
    }
    return ts;
}

// qmltc-d against APP-DEFINED QML TYPES WRITTEN IN C++ — the same thing the D-type backend does,
// with the type's language swapped, which is the whole point: QML resolves a type through its
// meta-object. The types in tests/qmltc/cpptypes/ are VERBATIM copies from Qt's own qmltc corpus
// (ordinary Q_OBJECT + QML_ELEMENT + Q_PROPERTY classes), vendored like tests/uic/corpus/.
//
// The pipeline over them is Qt's OWN, not something we reimplement:
//   moc --output-json  ->  qmltyperegistrar  ->  { registration .cpp , .qmltypes }
// The registration .cpp is linked into the ORACLE (so the engine can instantiate the types); the
// .qmltypes is the registry qmltc-d reads (`--cpptypes`), giving it the base property TYPES and
// NOTIFY names instead of inferring them from the assigned literal.
//
// The COMPILED side reuses the bound-subclass backend already proven on QtQuick: the generator
// binds these headers (spec_cxx_corpustypes.json, headers-mode — the generator's primary use case)
// and emits a trampoline per type, so the generated D class subclasses the C++ type and drives
// base properties through the meta-object.
Target[] qmltcCppTypeTargets(string root, QtdBinding qmlBind) {
    if (execute(["pkg-config", "--exists", "Qt6Qml"]).status != 0) return [];
    auto dir = buildPath(root, "tests", "qmltc", "cpptypes");
    auto moc = "/usr/lib/qt6/moc", reg = "/usr/lib/qt6/qmltyperegistrar";
    if (!exists(dir) || !exists(moc) || !exists(reg)) return [];
    auto bind = qtdBinding(root, "spec_cxx_corpustypes.json", ["Qt6Qml"]);
    auto here = buildPath(root, "tests", "qmltc");
    auto tool = qmltcTool(root, qmlBind);          // one qmltc-d, shared with the other suites
    auto toolBin = buildPath(qmlBind.bdir, "qmltc-d");
    // testprivateproperty.h includes <private/qobject_p.h>, so the vendored corpus needs Qt's
    // private include dirs — for moc, for qmltyperegistrar and for the C++ compile alike.
    auto privInc = (modulePrivateFlags(pkgCflags(["Qt6Core"]), "QtCore")
                    ~ modulePrivateFlags(pkgCflags(["Qt6Qml"]), "QtQml")).join(" ");
    auto cflags = pkgCflags(["Qt6Qml", "Qt6Gui", "Qt6Core"]) ~ " -std=c++17 -fPIC -O2 " ~ privInc;
    // Every vendored header that declares QML_ELEMENT types. Adding a corpus type is adding it
    // here and to the spec's `headers` — a build input, never per-type code.
    // Vendored headers that declare QML_ELEMENT types, with their extension: the corpus has a
    // .hpp among them, and dropping it left its type out of the registry entirely.
    auto headers = ["typewithmanyproperties.h", "typewithproperties.h", "typewithsignal.h",
                    "typewithspecialproperties.h", "testgroupedtype.h", "typewithnamespace.h",
                    "testprivateproperty.h", "extensiontypes.h", "singletontype.h", "hpp.hpp", "testattachedtype.h"];
    auto implCpps = ["typewithproperties", "testgroupedtype", "typewithnamespace",
                     "testprivateproperty", "extensiontypes", "singletontype", "testattachedtype"];

    // 1) Qt's moc over each vendored header -> moc_<h>.cpp + moc_<h>.cpp.json.
    Target[] mocObjs;
    string[] jsons;
    foreach (h; headers) {
        auto hdr = buildPath(dir, h);
        auto stem = h.stripExtension;
        auto mocCpp = buildPath(bind.bdir, "moc_" ~ stem ~ ".cpp");
        auto j = mocCpp ~ ".json";
        jsons ~= j;
        // moc writes the .json as a SIDE EFFECT of -o, so the .cpp is the tracked output.
        auto m = Target(mocCpp, guarded(mocCpp ~ ".lock",
            moc ~ " " ~ pkgCflags(["Qt6Qml", "Qt6Core"]) ~ " " ~ privInc ~ " --output-json -o " ~ mocCpp ~ " " ~ hdr,
            mocCpp, [hdr]), [Target(hdr)]);
        mocObjs ~= Target(buildPath(bind.bdir, "moc_" ~ stem ~ ".o"),
            "clang++ " ~ cflags ~ " -I" ~ dir ~ " -c " ~ mocCpp ~ " -o $out", [m]);
    }
    // 2) qmltyperegistrar over the moc JSON -> the registration .cpp AND the .qmltypes registry.
    auto regCpp = buildPath(bind.bdir, "qmltyperegistrations.cpp");
    auto typesFile = buildPath(bind.bdir, "QmltcTests.qmltypes");
    auto regT = Target(regCpp, guarded(regCpp ~ ".lock",
        reg ~ " --generate-qmltypes=" ~ typesFile ~ " --import-name=QmltcTests"
        ~ " --major-version=1 --minor-version=0 -o " ~ regCpp ~ " " ~ jsons.join(" "),
        regCpp, jsons), mocObjs);   // deps on the moc targets: the JSON must exist first
    auto regObj = Target(buildPath(bind.bdir, "qmltyperegistrations.o"),
        "clang++ " ~ cflags ~ " -I" ~ dir ~ " -c " ~ regCpp ~ " -o $out", [regT]);
    Target[] implObjs;
    foreach (c; implCpps) {
        auto src = buildPath(dir, c ~ ".cpp");
        if (!exists(src)) continue;
        implObjs ~= Target(buildPath(bind.bdir, c ~ ".o"),
            "clang++ " ~ cflags ~ " -I" ~ dir ~ " -c " ~ src ~ " -o $out", [Target(src)]);
    }
    auto typesLib = buildPath(bind.bdir, "libcorpustypes.a");
    auto lib = Target(typesLib, "ar rcs $out $in", mocObjs ~ [regObj] ~ implObjs);

    // 3) the ORACLE: the stock C++ oracle linked against the types. --whole-archive is REQUIRED —
    //    the module registration is a static QQmlModuleRegistration nothing references, so a
    //    normal archive link drops the object and the engine reports "module not installed".
    auto oracleBin = buildPath(bind.bdir, "qmlvalues-cpp");
    auto oracleCpp = buildPath(here, "qtd_qmlvalues.cpp");
    // typesLib is IN the link: without it here, changing a vendored C++ type rebuilds the archive
    // and the compiled side, but not the oracle — so the differential compares a new compiled side
    // against an oracle built from the old types, and passes. Demonstrated before this was fixed.
    auto oracle = Target(oracleBin, guarded(oracleBin ~ ".lock",
        "clang++ " ~ cflags ~ " -o " ~ oracleBin ~ " " ~ oracleCpp
        ~ " -Wl,--whole-archive " ~ typesLib ~ " -Wl,--no-whole-archive "
        ~ execute(["pkg-config", "--libs", "Qt6Qml", "Qt6Gui", "Qt6Core"]).output.strip,
        oracleBin, [oracleCpp, typesLib]), [Target(oracleCpp), lib]);

    // A bound root sets properties before any QGuiApplication exists; the helper provides one.
    auto appObj = buildPath(bind.bdir, "qtd_qmltc_app.o");
    auto appHelper = Target(appObj, guarded(appObj ~ ".lock",
        "clang++ " ~ cflags ~ " -c " ~ buildPath(here, "qtd_qmltc_app.cpp") ~ " -o " ~ appObj,
        appObj, [buildPath(here, "qtd_qmltc_app.cpp")]), [Target(buildPath(here, "qtd_qmltc_app.cpp"))]);

    Target[] ts;
    auto corpus = dirEntries(dir, "*.qml", SpanMode.shallow).map!(e => e.name).array;
    corpus.sort();
    // Documents whose FEATURE the compiler does not implement yet. The fixture is committed so the
    // bar is written down and the diff is measured the day it lands -- but a differential cannot be
    // the gate while the compiler correctly REFUSES the file: it would leave the default build red
    // and hide every other regression behind it. So the target asserts the refusal instead (a
    // diagnostic, on a file that does not compile clean). The day the feature works the refusal
    // stops and THIS target fails, which is the signal to move the file out of the list.
    static immutable string[] pending = [];   // same contract as pendingFeature above
    foreach (dc; DCS) {
        foreach (qmlFile; corpus) {
            auto name = baseName(qmlFile).stripExtension;
            auto arg = " --cpptypes " ~ typesFile ~ " qt.corpustypes";
            if (pending.canFind(name)) {
                auto diag = buildPath(bind.bdir, "qmltcc_" ~ name ~ "_" ~ dc ~ ".pending");
                ts ~= Target.phony("qmltcc-" ~ name ~ "-" ~ dc,
                    "sh -c '" ~ toolBin ~ " --dump " ~ qmlFile ~ " " ~ name ~ arg
                    ~ " > /dev/null 2>" ~ diag ~ "; test -s " ~ diag ~ "'", [tool]);
                continue;
            }
            auto genD = buildPath(bind.bdir, "qmltcc_" ~ name ~ "_" ~ dc ~ ".d");
            auto gd = Target(genD, toolBin ~ " --dump " ~ qmlFile ~ " " ~ name ~ arg ~ " > $out",
                [tool, Target(qmlFile), regT, bind.gen]);   // regenerating the binding must re-emit
            auto appBin = buildPath(bind.bdir, "qmltcc_" ~ name ~ "_" ~ dc ~ "_check");
            auto appCmd =
                dc ~ " -of=$out " ~ genD ~ " " ~ appObj ~ " -I" ~ bind.genDir
                ~ " -L--gc-sections -L--as-needed -L--start-group -L=" ~ buildPath(bind.bdir, "libbinding_" ~ dc ~ ".a")
                ~ " -L=" ~ buildPath(bind.bdir, "libshims.a") ~ " -L--end-group"
                // --whole-archive on the types: their QQmlModuleRegistration is a static object
                // nothing references, and without it the module isn't registered in this process —
                // so an ATTACHED object (looked up through Qt's QML type registry) comes back null.
                ~ " -L--whole-archive -L=" ~ typesLib ~ " -L--no-whole-archive "
                ~ pkgLibs(["Qt6Qml", "Qt6Gui", "Qt6Core"]) ~ " -L-lstdc++";
            auto app = Target(appBin, guardedLink(appBin ~ ".lock", appCmd, appBin,
                [genD, appObj, typesLib, buildPath(bind.bdir, "libbinding_" ~ dc ~ ".a"),
                 buildPath(bind.bdir, "libshims.a")]),
                [gd, appHelper, lib, qtdBindLib(bind, dc), bind.shims]);
            auto a = genD ~ ".dvals", b = genD ~ ".qmlvals", props = genD ~ ".props";
            auto mkProps = toolBin ~ " --labels " ~ qmlFile ~ " " ~ name ~ arg ~ " > " ~ props ~ " 2>/dev/null; ";
            ts ~= Target.phony("qmltcc-" ~ name ~ "-" ~ dc,
                "sh -c '" ~ mkProps ~ "QT_QPA_PLATFORM=offscreen " ~ appBin ~ " > " ~ a
                ~ " && QT_QPA_PLATFORM=offscreen " ~ oracleBin ~ " " ~ qmlFile ~ " --props " ~ props ~ " --attached-uri QmltcTests > " ~ b
                ~ " && QT_QPA_PLATFORM=offscreen " ~ oracleBin ~ " " ~ qmlFile ~ " --verify-props " ~ props ~ " --attached-uri QmltcTests"
                ~ " && diff " ~ a ~ " " ~ b ~ "'", [app, oracle, tool]);
            auto setFile = buildPath(dir, name ~ ".set");
            if (exists(setFile)) {
                // Quote each token: a mutation may be `method()`, and bare parens are shell syntax.
                auto setArgs = readText(setFile).strip.split.map!(a => "\"" ~ a ~ "\"").join(" ");
                ts ~= Target.phony("qmltcc-" ~ name ~ "-set-" ~ dc,
                    "sh -c '" ~ mkProps ~ "QT_QPA_PLATFORM=offscreen " ~ appBin ~ " " ~ setArgs ~ " > " ~ a ~ ".set"
                    ~ " && QT_QPA_PLATFORM=offscreen " ~ oracleBin ~ " " ~ qmlFile ~ " " ~ setArgs
                    ~ " --props " ~ props ~ " --attached-uri QmltcTests > " ~ b ~ ".set && diff "
                    ~ a ~ ".set " ~ b ~ ".set'",
                    [app, oracle, tool]);
            }
        }
    }
    return ts;
}
