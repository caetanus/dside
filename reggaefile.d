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
import std.file : getcwd, exists, dirEntries, SpanMode;
import std.path : buildPath, buildNormalizedPath, baseName, stripExtension;
import std.array : array, replace, join;
import std.algorithm : map, filter, sort;
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
            all ~= qtdTest("boom" ~ tag ~ "-" ~ dc, t("qml", "boom_test.d"), b, dc, qmlExtra);       // factory throw -> observable failure
            all ~= qtdTest("metathread" ~ tag ~ "-" ~ dc, t("qml", "metathread_test.d"), b, dc);     // single-thread affinity enforced
        }
        all ~= qmlTrTargets(root, b, tag);   // runtime tr() via lrelease .qm round-trip
    }
    auto qml = qtdBinding(root, "spec_cxx_qml.json", ["Qt6Qml", "Qt6Gui"]);
    qmlSuite(qml, "");
    all ~= qmlAotTargets(root, qml);   // qmlcachegen (Qt6 unit/loader format); Qt5 AOT is a follow-up
    all ~= qmlTypesCheckTargets(root, qml);   // CTFE .qmltypes (Qt-agnostic), validated by Qt's reader
    if (haveQt5())
        qmlSuite(qtdBinding(root, "spec_cxx_qml_qt5.json", ["Qt5Qml", "Qt5Gui"]), "-qt5");

    // --- lupdate-d extraction, in the build of record: run the D-aware extractor on a fixture
    //     and diff its .ts against the checked-in golden (module context + tr/UFCS/translate forms).
    all ~= lupdateCheckTargets(root);

    // --- coverage manifest gate: regenerate a binding and diff its per-symbol manifest against a
    //     checked-in baseline, failing on regression (disappeared/worsened/new-drop symbol).
    //     These are OPTIONAL top-level targets (critics r8 #1): the default `./build` full matrix
    //     must NOT run them, because their baselines are pinned to Qt 6.11 and a runner on a
    //     different Qt minor would measure SDK drift, not a generator regression. They stay
    //     reachable by name (`./build manifest-gate-qtwidgets`) so CI can run them ADVISORY.
    auto manifestGates = manifestGateTargets(root, [ex, qml], ["qtwidgets", "qml"],
                                             ["qtwidgets.manifest.tsv", "qml.manifest.tsv"]);

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

    // Mandatory targets are built by the default `./build`; the manifest gates are OPTIONAL —
    // in the graph (reachable by name) but excluded from defaultTargets() so the full matrix on a
    // mismatched Qt minor doesn't fail on baseline drift (critics r8 #1).
    import std.range : chain;
    return Build(chain(all.map!(t => createTopLevelTarget(t)),
                       manifestGates.map!(t => optional(t))));
}

// Differential oracle harness: our uic (uiForm) must build a tree identical to
// QUiLoader.load() for every .ui. The oracle load + the tree serializer live in a C++
// helper (links Qt6UiTools); the D side just diffs the two dumps. Built against the
// non-wrap widgets binding `ex`, per compiler.
Target[] uicheckTargets(string root, QtdBinding ex) {
    auto here = buildPath(root, "tests", "uic");
    auto cf = pkgCflags(["Qt6UiTools", "Qt6Widgets"]) ~ " -std=c++17 -fPIC -O2";
    auto libs = pkgLibs(["Qt6UiTools", "Qt6Widgets"]);
    auto uiformD = buildPath(root, "runtime", "uic", "uiform.d");
    auto qrcD = buildPath(root, "runtime", "qrc", "qrc.d");   // for the icon form's :/ resources
    auto checkD = buildPath(here, "uicheck.d");
    Target[] ts;
    foreach (dc; DCS) {
        auto uidumpO = buildPath(ex.bdir, "uidump-" ~ dc ~ ".o");   // absolute -> reggae keeps it here
        auto uidumpT = Target(uidumpO,
            "clang++ " ~ cf ~ " -c " ~ buildPath(here, "qtd_uidump.cpp") ~ " -o $out", []);
        auto lib = qtdBindLib(ex, dc);
        auto bin = Target("uicheck-" ~ dc ~ "-bin",
            dc ~ " -of=$out " ~ checkD ~ " " ~ uiformD ~ " " ~ qrcD ~ " " ~ uidumpO
            ~ " -I" ~ ex.genDir ~ " -I" ~ buildPath(root, "runtime", "qrc")
            ~ " -J=" ~ here ~ " -L--start-group -L=" ~ buildPath(ex.bdir, "libbinding_" ~ dc ~ ".a")
            ~ " -L=" ~ buildPath(ex.bdir, "libshims.a") ~ " -L--end-group " ~ libs,
            [Target(checkD), uidumpT, lib, ex.shims]);
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
        auto uidumpT = Target(uidumpO,
            "clang++ " ~ cf ~ " -c " ~ buildPath(here, "qtd_uidump.cpp") ~ " -o $out", []);
        auto lib = qtdBindLib(ex, dc);
        auto bin = Target("corpus-check-" ~ dc ~ "-bin",
            dc ~ " -of=$out " ~ checkD ~ " " ~ uiformD ~ " " ~ qrcD ~ " " ~ uidumpO
            ~ " -I" ~ ex.genDir ~ " -I" ~ buildPath(root, "runtime", "qrc")
            ~ " -J=" ~ here ~ " -L--start-group -L=" ~ buildPath(ex.bdir, "libbinding_" ~ dc ~ ".a")
            ~ " -L=" ~ buildPath(ex.bdir, "libshims.a") ~ " -L--end-group " ~ libs,
            [Target(checkD), uidumpT, lib, ex.shims]);
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
