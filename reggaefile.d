// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
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
import std.path : buildNormalizedPath, baseName, stripExtension;   // buildPath comes from qtd_build, normalised
import std.array : array, replace, join, split;
import std.algorithm : map, filter, sort, any, startsWith, canFind, all;
import std.process : execute;
import std.string : strip;

enum DCS = ["ldc2", "dmd"];

// WHERE Qt actually put its QML modules. `/usr/lib/qt6/qml` is this distribution's layout, not
// Qt's API: on a multiarch or prefix install the directory is somewhere else entirely, and every
// gate keyed on the literal path emits no targets there — a gate that DISAPPEARS rather than one
// that fails. Ask Qt, and keep the literal only as the last resort.
private __gshared string _qtQmlDir;
private __gshared bool _qtQmlAsked;
string qtInstallQml() {
    if (_qtQmlAsked) return _qtQmlDir;
    _qtQmlAsked = true;
    // THE EXPLICITLY-6 TOOLS FIRST. This asked `qtpaths` — which carries no version in its name —
    // before `qmake6`, and on this machine the unsuffixed family is Qt 5: `qmake -query QT_VERSION`
    // answers 5.15.19 while `qmake6` answers 6.11.1. Where `qtpaths` exists and belongs to Qt5, a
    // Qt6 build would have taken Qt5's QML directory and judged Qt6 bindings against Qt5's Controls
    // corpus — a wrong answer that looks like a working build. Measured 2026-08-14; here neither
    // `qtpaths` nor `qtpaths6` is installed at all, so the literal fallback below is what actually
    // answers, which is worth knowing about a line described as a last resort.
    foreach (probe; [["qtpaths6", "--query"], ["qmake6", "-query"], ["qtpaths", "--query"],
                     ["qmake", "-query"]]) {
        // ...and a probe that is not INSTALLED must not abort the build graph: `execute` throws
        // rather than returning non-zero when the executable is missing, which is how the first
        // version of this helper turned "qtpaths6 is not on this machine" into no build at all.
        try {
            auto r = execute(probe ~ ["QT_INSTALL_QML"]);
            if (r.status == 0) {
                auto p = r.output.strip;
                if (p.length && exists(p)) { _qtQmlDir = p; return p; }
            }
        } catch (Exception) { }
    }
    _qtQmlDir = "/usr/lib/qt6/qml";
    return _qtQmlDir;
}

Build reggaeBuild() {
    immutable root = getcwd();
    // Where the PowerShell halves of the build's steps live (tools/win/*.ps1). Set once, so a
    // step's two dialects can sit at the same call site without threading the root through
    // every signature that composes a command.
    setPsRoot(root);
    Target[] all;
    // Targets that must FAIL while a documented gap is open (critics r13 #6). They are OPTIONAL:
    // expected-fails-run names them and expects the failure, and a failing target in the default
    // build would report the gap as a regression — right fact, wrong channel.
    Target[] gapProbes;
    Target[] docsNumberSources;   // the o3/optlevels targets, for the documentation gate
    string docsNumberBdir;

    string t(string dir, string f) { return buildPath(root, "tests", dir, f); }
    bool haveQt5() { return qtHasModule("Qt5Widgets"); }

    // --- WRAPPER mode QtCore: identity + parenting-pins + orphan collection ---
    auto wrap = qtdBinding(root, "spec_cxx_wraptest.json", ["Qt6Core"]);
    foreach (dc; DCS) {
        all ~= qtdTest("wraptest-" ~ dc, t("wrapper", "wraptest.d"), wrap, dc);
        all ~= qtdTest("ownership-" ~ dc, t("wrapper", "ownership.d"), wrap, dc);   // destruction invariants
    }

    // The bindings the ctor-guard gate reads. Collected as they are created so the gate depends on
    // their gen targets rather than on whatever happens to be on disk.
    QtdBinding[] ctorGuardBindings;

    // --- WRAPPER mode QtWidgets (Qt6 + Qt5): widget app + moc/trampoline ---
    void widgets(string spec, string[] mods, string tag) {
        auto b = qtdBinding(root, spec, mods);
        ctorGuardBindings ~= b;
        foreach (dc; DCS) {
            all ~= qtdTest("widget_test-" ~ dc ~ "-" ~ tag, t("wrapper", "widget_test.d"), b, dc);
            all ~= qtdTest("moc_test-" ~ dc ~ "-" ~ tag, t("wrapper", "moc_test.d"), b, dc);
            all ~= qtdTest("moclife_widget-" ~ dc ~ "-" ~ tag, t("wrapper", "moclife_widget.d"), b, dc);
            // The transpiler's QML helpers live in the shared moc runtime that THIS (QtQml-free)
            // binding also compiles: prove they link and no-op here, not just that the C++ unit
            // compiles (qtmoc-probe-noqml covers that half).
            all ~= qtdTest("noqml_helpers-" ~ dc ~ "-" ~ tag, t("wrapper", "noqml_helpers.d"), b, dc);
            // `new QThread` is a QThread: one object, a trampoline, and run() landing in D. The
            // piece that makes it real is generic rather than QThread's — every virtual callback
            // attaches a thread druntime has not seen, because Qt is free to call one from a
            // thread it created and D code there otherwise has no registered stack.
            all ~= qtdTest("thread_test-" ~ dc ~ "-" ~ tag, t("wrapper", "thread_test.d"), b, dc);
            // ...and the door that opens with it stays locked. The meta-object runtime's side
            // tables are owner-thread only and abort loudly off it; until QThread was subclassable
            // there was no ordinary way for a user to reach that guard, because D never ran on a
            // thread Qt made. Now run() does, and creating a QObject in there is the first thing
            // anyone will try. A SAFETY test: the right outcome is the abort, not a worker QObject.
            all ~= qtdTest("threadguard-" ~ dc ~ "-" ~ tag, t("wrapper", "threadguard.d"), b, dc);
        }
    }
    widgets("spec_cxx_qtwidgets_wrap.json", ["Qt6Widgets"], "qt6");
    if (haveQt5())
        widgets("spec_cxx_qtwidgets_wrap_qt5.json", ["Qt5Widgets"], "qt5");

    // --- smuggled example apps against the non-wrap QtWidgets binding (Qt6) ---
    auto ex = qtdBinding(root, "spec_cxx_qtwidgets.json", ["Qt6Widgets"]);
    ctorGuardBindings ~= ex;
    foreach (app; dirEntries(buildPath(root, "tests", "examples"), "*.d", SpanMode.shallow).map!(e => e.name).array.sort)
        foreach (dc; DCS)
            all ~= qtdTest(baseName(app).stripExtension ~ "-" ~ dc, app, ex, dc);

    // A POINTER QT RETURNED IS NOT OURS. The finalizer decided ownership from parenting alone, so
    // `QThread.currentThread()` — unparented, not the app singleton — got a deleteLater when the D
    // reference was dropped, and ~QThread deadlocked at exit waiting for the thread running it.
    // Needs a REAL GC collection, which needs the reference gone from a conservatively scanned
    // stack; the first version of this test passed because nothing was ever collected.
    foreach (dc; DCS)
        all ~= qtdTest("borrowed-" ~ dc, t("wrapper", "borrowed.d"), ex, dc);
    // ...and a probe that asserts a documented GAP is still real, so the day it is closed the
    // inventory says so instead of quietly describing something that no longer happens. Read
    // tests/wrapper/dangle.d before "fixing" it: its failure is good news with instructions.
    foreach (dc; DCS)
        all ~= qtdTest("dangle-" ~ dc, t("wrapper", "dangle.d"), ex, dc);

    // A non-QObject the binding OWNS, in the three states ownership can be in: nobody took it (we
    // free it), Qt took it (we must not), Qt took it and died (we never touch it). Needs a C++
    // half because a freed block is not observable from D — and the two cheaper substitutes both
    // passed against a deliberately broken binding, which is why it watches ONE address.
    {
        auto wf = buildPath(root, "tests", "wrapper", "qtd_watchfree.cpp");
        auto wfo = buildPath(ex.bdir, "qtd_watchfree.o");
        auto wfObj = Target(wfo, guarded(wfo ~ ".lock",
            "clang++ " ~ pkgCflags(ex.mods) ~ " -std=c++17 " ~ cxxPic() ~ " -O0 -c " ~ wf ~ " -o " ~ wfo, null, wfo, [wf]),
            [Target(wf)]);
        foreach (dc; DCS)
            all ~= qtdTest("nonqobject-" ~ dc, t("wrapper", "nonqobject.d"), ex, dc,
                           wfo, [wfObj]);
    }

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
    if (qtHasModule("Qt6Quick")) {
        auto quick = qtdBinding(root, "spec_cxx_quick.json", ["Qt6Quick", "Qt6QmlModels", "Qt6Qml", "Qt6Gui"]);
        all ~= qmltcTargets(root, quick, buildPath(root, "tests", "qmltc", "quick"), "q");
        all ~= registryGateTarget(root, quick, "quick");
        all ~= shadowAotTargets(root, quick);   // phase 2: a refused expression as BYTECODE
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
    if (qtHasModule("Qt6QuickTemplates2")) {
        // Qt6QuickControls2Impl carries IconLabel/CheckLabel/ColorImage — the types every
        // Basic contentItem is built from. Binding their headers without linking the library
        // gets you a clean compile and undefined references at link time.
        auto ctrl = qtdBinding(root, "spec_cxx_controls.json",
                               ["Qt6QuickControls2Impl", "Qt6QuickTemplates2", "Qt6Quick",
                                "Qt6QmlModels", "Qt6Qml", "Qt6Gui"]);
        all ~= qmltcTargets(root, ctrl, buildPath(root, "tests", "qmltc", "controls"), "c");
        // AGREEING WITH THE ENGINE IS NOT THE SAME AS COMPILING IT. An expression the compiler
        // refuses is handed to the engine, which then produces the right value — so the corpus
        // check above stays green while the document quietly stops being a translation. `--pedantic`
        // is the only thing that can tell those apart: it makes a delegation an error. Named
        // documents only, because most of the corpus is not delegation-free and pretending
        // otherwise would turn this into a list of exceptions.
        {
            auto cdir = buildPath(root, "tests", "qmltc", "controls");
            foreach (doc; ["CDynLeaf"]) {
                auto qmlFile = buildPath(cdir, doc ~ ".qml");
                if (!exists(qmlFile)) continue;
                all ~= Target.phony("qmltc-pedantic-" ~ doc,
                    buildPath(ctrl.bdir, "qmltc-d") ~ " --pedantic --dump " ~ qmlFile ~ " " ~ doc
                    ~ " --qmlmap " ~ buildPath(ctrl.genDir, "qmlmap.tsv") ~ " -I " ~ cdir
                    ~ " > /dev/null",
                    [Target(qmlFile), qmltcTool(root, ctrl), ctrl.gen]);
            }
        }
        // ...and a GAP PROBE (critics r13 #6): a target that must FAIL while a documented gap is
        // open. Qt's Imagine Label delegates `states: [ {...} ]` on a NinePatchImageSelector — a type
        // of the style's impl module, absent from our registry — so `--pedantic` exits 4. When that
        // type is generated, this passes, and expected-fails-run reports the entry as describing a
        // world that no longer exists. Until now the inventory could only notice bad news.
        {
            auto imagineDir = buildPath(qtInstallQml(), "QtQuick", "Controls", "Imagine");
            auto lbl = buildPath(imagineDir, "Label.qml");
            // OPTIONAL: a gap probe MUST fail while the gap is open, so it cannot be part of the
            // default build — it is run by expected-fails-run, which expects the failure. Putting
            // it in `all` turned `./build` red, which is the gate reporting the gap as a
            // regression: right fact, wrong channel.
            if (exists(lbl))
                gapProbes ~= Target.phony("qmltc-pedantic-imagine-label",
                    buildPath(ctrl.bdir, "qmltc-d") ~ " --pedantic --dump " ~ lbl ~ " ILabel"
                    ~ " --qmlmap " ~ buildPath(ctrl.genDir, "qmlmap.tsv") ~ " -I " ~ imagineDir
                    ~ " > /dev/null", [qmltcTool(root, ctrl), ctrl.gen]);
        }

        // ...and the same compiler pointed at QML NOBODY HERE WROTE: Qt's own Basic style files,
        // generated, linked and CONSTRUCTED. Six defects lived where compile-clean cannot see —
        // they all build and then die (or silently build the wrong object) at construction.
        all ~= qmltcControlsRuntimeTargets(root, ctrl);
        // captured, because `docs-numbers` compares the documentation against what THESE targets
        // counted and must therefore depend on them
        auto o3T = o3GateTargets(root, ctrl);       // every judgeable document renders like the engine
        auto olT = optLevelTargets(root, ctrl);     // ...and the levels agree with it and each other
        docsNumberSources = o3T ~ olT;
        docsNumberBdir = ctrl.bdir;
        all ~= o3T;
        all ~= olT;
        // ...and over QT'S OWN corpus, where the certainty levels had only a COUNT. The README said
        // -O1 compiles 111 of 329 and that nothing crosses untyped there; the first half was
        // measured and the second was not, because the o3 gate judges -Ox — DIFFERENT CODE — and
        // qmltc-optlevels only walked the application corpus.
        //
        // FOUR STYLES, not one. It started as Basic alone, on the argument that each document is a
        // full generate/link/run/compare on two levels and one style keeps the scope honest. Then
        // the other four were measured by hand once, and three of them held defects Basic could
        // not: a binding that dereferences null, the default of an unset `color`, and a resource
        // that lives in an imported module. With those fixed the four styles judge 38, 36, 27 and 7
        // documents — 108 in all — and the rest of each style is handed to the engine and skipped.
        // Imagine is absent for the opposite reason: -O1 compiles NOTHING there, so the run is
        // vacuous and the script says so rather than reporting a green it did not earn.
        {
            auto od = buildPath(root, "tests", "qmltc", "optlevels-dir.sh");
            foreach (style; ["Basic", "Fusion", "Universal", "Material"]) {
                auto styleDir = buildPath(qtInstallQml(), "QtQuick", "Controls", style);
                if (!exists(od) || !exists(styleDir)) continue;
                // captured for `docs-numbers`: the -O1 column comes from THESE targets, and the
                // deletion test proved the point — with only the o3 edges declared, the counts
                // regenerated and the optlevels files did not, so the gate read 0 for every style
                // and accused the documentation of saying 39. A dependency that covers half of what
                // a gate reads is how a check comes to describe a mixture of two builds.
                auto olStyle = Target.phony("qmltc-optlevels-controls-" ~ style,
                    "sh " ~ od ~ " " ~ buildPath(ctrl.bdir, "qmltc-d") ~ " "
                    ~ buildPath(ctrl.genDir, "qmlmap.tsv") ~ " " ~ styleDir ~ " "
                    ~ buildPath(ctrl.bdir, "optlevels-" ~ style) ~ " " ~ ctrl.bdir ~ " "
                    ~ ctrl.genDir ~ " ldc2 " ~ pkgLibs(ctrl.mods),
                    [Target(od), Target(buildPath(root, "tests", "qmltc", "optlevels.sh")),
                     Target(buildPath(root, "tests", "qmltc", "optlevels-known.txt")),
                     qmltcTool(root, ctrl), ctrl.gen, qtdBindLib(ctrl, "ldc2"), ctrl.shims]);
                all ~= olStyle;
                docsNumberSources ~= olStyle;
            }
        }
        // ...and the LEAF TABLE's identity and lifetime, which no document can observe: the count
        // of live leaf connections is not a value the differential can dump. Two owners must be
        // two entries, and destroying the tree must empty the table.
        foreach (dc; DCS)
            all ~= qtdTest("leaf-lifetime-" ~ dc,
                           buildPath(root, "tests", "qmltc", "leaf_lifetime.d"), ctrl, dc);
        // ...and this binding gets a manifest gate like the other two. It had none, so changing its
        // spec tripped nothing — which is how binding the QtQuick animations (a real and intended
        // coverage change) landed without the manifest ever being consulted. A binding nobody holds
        // to a symbol contract is a binding whose fates can rot unnoticed.
        all ~= manifestGateTargets(root, [ctrl], ["controls"], ["controls.manifest.tsv"]);
        // ...and the registry's own floor: every QML type it can NAME must be TYPEABLE. `Text` was
        // named and had no property rows for as long as nobody compared the two tables, and the
        // refusals that caused ("declared type '?'") read like a compiler gap rather than a
        // registry one. Depends on both bindings' gen so it runs against freshly written tables.
        all ~= registryGateTarget(root, ctrl, "controls");
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

    // --- RUNTIME BOUNDARY RATCHET (critics r9 #2 / r11 #5): the audit has asked since round 9 for
    //     the QML compiler's runtime to leave the shared meta-object unit, and it is the one
    //     long-lived finding with no target behind it — which is why it RECEDED twice in one day
    //     while gated findings closed. This does not draw the boundary; it stops it receding.
    {
        auto rbD = buildPath(root, "tests", "runtime_boundary.d");
        auto rbBin = buildPath(root, ".build", "runtime-boundary-bin");
        auto rbBase = buildPath(root, "tests", "runtime-boundary.baseline");
        auto rbb = Target(rbBin, "dmd -of=$out " ~ rbD, [Target(rbD)]);
        all ~= Target.phony("runtime-boundary",
            "$in " ~ buildPath(root, "runtime", "qtmoc", "qtdmoc.cpp") ~ " "
            ~ buildPath(root, "runtime", "qtmoc", "qtmoc.d") ~ " " ~ rbBase, [rbb]);
    }

    // --- ABI LAYOUT PROBE (critics r4 #9, the oldest finding untouched until 2026-08-12): the
    //     container bridge reads QList's FIELDS at offsets the generator hard-codes, and those got
    //     in as "verified empirically". This asserts the same layout against the installed Qt
    //     headers and reads it BOTH ways — through our offsets and through Qt's own API — so a
    //     layout change fails here with the numbers instead of downstream with a bad pointer.
    //     Runtime, not sizeof-only: reordering two fields keeps the size and breaks the values.
    {
        auto abiSrc = buildPath(root, "tests", "abi", "qlist_layout.cpp");
        foreach (mod; ["Qt6Core", "Qt5Core"])
        {
            if (!qtHasModule(mod)) continue;
            auto tag = mod == "Qt5Core" ? "-qt5" : "";
            auto bin = buildPath(root, ".build", "abi-layout" ~ (tag.length ? "5" : "6"));
            // NOT pkgCflags/pkgLibs: those speak ldc's `-L-l…` dialect and this one is compiled
            // by a C++ compiler — the mismatch showed up as an undefined QArrayData::allocate,
            // which is a linker saying "you gave me no -lQt6Core" in the least obvious way. The
            // raw answers are what a C++ command line wants.
            //
            // And they are resolved HERE rather than by a `$(pkg-config …)` in the command: this
            // gate ran g++ and pkg-config by name and neither exists on Windows, so it failed with
            // `sh: g++: command not found` — a gate reporting on the machine, not on the layout.
            // clang++ is already required by every other C++ step in this build.
            auto b = Target(bin, posixCmdArgv("clang++ -std=c++17 " ~ cxxPic() ~ " " ~ qtCflags([mod])
                            ~ ` -o "$0" "$1" ` ~ qtLibsOf([mod]), ["$out", "$in"]), [Target(abiSrc)]);
            // Through the same runner as everything else: on Windows `$in` is an absolute native
            // path, and running it as bare command text got `'C:\Users\…\abi-layout6' is not
            // recognised as an internal or external command`.
            all ~= Target.phony("abi-layout" ~ tag, runExe(root, "$in", "", "", [mod]), [b]);
        }
    }

    // --- COMPILER CONTEXT RATCHET (critics r4 #3 / r9 #4 / r10 #6 / r11 #6): the twin of the one
    //     above, for the other five-round finding with no target behind it. It does not introduce
    //     the CompilationContext; it stops the implicit one from spreading.
    {
        auto ccD = buildPath(root, "tests", "compiler_context.d");
        auto ccBin = buildPath(root, ".build", "compiler-context-bin");
        auto ccBase = buildPath(root, "tests", "compiler-context.baseline");
        auto ccb = Target(ccBin, "dmd -of=$out " ~ ccD, [Target(ccD)]);
        all ~= Target.phony("compiler-context",
            "$in " ~ buildPath(root, "tools", "qmltc", "qmltc_d.cpp") ~ " " ~ ccBase, [ccb]);
    }

    // --- expected-fails registry consumer: validate schema/kind and that every `risk` probe names
    //     a real build target (so the inventory is enforcement, not just prose).
    {
        auto efD = buildPath(root, "tests", "expected_fails_check.d");
        auto efBin = buildPath(root, ".build", "expected-fails-lint-bin");
        auto efJson = buildPath(root, "tests", "expected-fails.json");
        auto efList = buildPath(root, ".build", "build-list.txt");
        auto efb = Target(efBin, "dmd -of=$out " ~ efD, [Target(efD)]);
        // deps=[efb] -> $in is the checker; capture ./build --list, then validate against it.
        // ...and the GAP PROBES with it. They are optional targets, so `--list` does not show them
        // — the linter called the first one dangling, which is the linter being right about the
        // list it was given and the list being incomplete. The reggaefile knows them, so it says so.
        auto gpList = buildPath(root, ".build", "gap-probes.txt");
        all ~= Target.phony("expected-fails-lint",
            "sh -c \"" ~ buildPath(root, "build") ~ " --list > " ~ efList ~ " 2>/dev/null; "
            ~ "cat " ~ gpList ~ " >> " ~ efList ~ " 2>/dev/null; "
            ~ "$in " ~ efJson ~ " " ~ efList ~ "\"", [efb]);
    }

    // --- CAN SOMEBODY ELSE USE THIS? An application built OUTSIDE the checkout, from the import
    //     path and the two archives alone. Every other target builds from inside, with paths
    //     reggae knows, which proves the binding compiles and nothing about consuming it — and
    //     writing this found three things in fifteen minutes that the whole matrix never saw:
    //     `new QWidget(null)` was ambiguous with the adopt ctor, `w.width()` lives on the second
    //     base, and QString had no `==` against a D string.
    {
        auto cs = buildPath(root, "tests", "consumer", "consumer.sh");
        if (exists(cs))
            foreach (dc; DCS)
                all ~= Target.phony("consumer-smoke-" ~ dc,
                    "sh " ~ cs ~ " " ~ ex.genDir ~ " " ~ ex.bdir ~ " " ~ dc ~ " "
                    ~ pkgLibs(ex.mods ~ ["Qt6Core"]),
                    [Target(cs), Target(buildPath(root, "tests", "consumer", "hello.d")),
                     ex.gen, qtdBindLib(ex, dc), ex.shims]);
    }

    // --- INSTALL IT, then DEPEND on it. `consumer-smoke` builds an application outside the
    //     checkout but still points -I and -L at a build directory, which is a path that happens
    //     to exist rather than a dependency. This lays the artifacts out as a dub package and lets
    //     dub resolve it — the half of round 12 #6 that was actually missing. It turned out to be
    //     an import path, two archives and eleven lines of dub.json: there was no machinery to
    //     build, only nobody had tried.
    {
        auto ins = buildPath(root, "tests", "install.sh");
        auto dcs = buildPath(root, "tests", "consumer", "dub-consumer.sh");
        auto prefix = buildPath(ex.bdir, "pkg");
        if (exists(ins) && exists(dcs)) {
            auto stamp = buildPath(ex.bdir, "pkg.stamp");
            // GUARDED, because both consumers reach this node and this backend runs it once per
            // reaching target: two installs raced, and the one that got to `rm -rf $PREFIX` first
            // deleted what the other was copying. The failure looked like a packaging bug and was
            // a build-graph one — the same shape the uidump object memoisation exists for.
            auto instCmd = "sh " ~ ins ~ " " ~ ex.genDir ~ " " ~ ex.bdir ~ " " ~ prefix
                ~ " qtd-qtwidgets " ~ pkgLibs(ex.mods).replace("-L-l", "-l") ~ " && touch " ~ stamp;
            // `ins` belongs in the guard's newerThan list, not only in the dependency list. Reggae
            // reruns the command when the script changes, but the guard's own `-nt` test then
            // decides whether to do anything — and with gen.stamp as its only reference, an edit to
            // install.sh alone exits 0 and leaves the package as it was. Measured: install.sh grew
            // the LICENSE/NOTICE copies at 17:36, a build ran at 19:32, and the package on disk was
            // still the one from two days before. A guard that can't see the script it runs is a
            // guard for a different question.
            // The ARCHIVES belong in that same list, for the same reason and one step further.
            // The dependency list below already names them, so reggae reruns the command when they
            // change — but the guard then answers a question about gen.stamp and install.sh only,
            // sees nothing newer, and exits 0 with the old package still on disk. Measured on
            // 2026-08-18: libbinding_ldc2.a rebuilt at 20:54 while pkg/lib/ still held the copy
            // from 08-13, five days stale, and license-package's byte comparison (round 18 #5) is
            // what caught it — the name check it replaced would have passed. A guard that cannot
            // see the archives it copies is, again, a guard for a different question.
            auto archivePaths = DCS.map!(dc => buildPath(ex.bdir, "libbinding_" ~ dc ~ ".a")).array
                                ~ [buildPath(ex.bdir, "libshims.a")];
            auto inst = Target(stamp,
                guarded(prefix ~ ".lock", instCmd, null, stamp,
                        [ex.genDir ~ "/gen.stamp", ins] ~ archivePaths),
                [Target(ins), ex.gen] ~ DCS.map!(dc => qtdBindLib(ex, dc)).array ~ [ex.shims]);
            // THE PACKAGE, not the tree. Every other licensing gate reads what is committed; this
            // one reads what a consumer receives, because a spotless repository can still ship a
            // package with no licence in it — which is precisely what this found on first run.
            auto lpk = buildPath(root, "tests", "license-package.sh");
            if (exists(lpk)) {
                // The archives the install actually copies, named by the graph. Without this the
                // package's own manifest is the only authority on what belongs in lib/, and a
                // regenerated manifest makes any addition consistent — measured: an opaque .a plus
                // a rebuilt MANIFEST.sha256 passed.
                auto arch = (DCS.map!(dc => "libbinding_" ~ dc ~ ".a").array ~ "libshims.a").join(",");
                all ~= Target.phony("license-package", "sh " ~ lpk ~ " " ~ prefix ~ " " ~ arch
                                    ~ " " ~ ex.bdir, [Target(lpk), inst]);
                // ...and a package that IS defective, so the gate's bite is a build step rather
                // than something I remember doing once. Nine violations were planted by hand to
                // prove this gate and then deleted; the proof lived in a transcript. This one
                // copies the real package, removes its LICENSE, and must be refused.
                // ...and the TABLE OF MUTATIONS that replaces the single probe (round 15 #4). The
                // probe deleted LICENSE, which proved a branch that already worked, while the same
                // gate accepted a renamed dub.json and a GPL-licensed source. Twenty defective
                // packages are now built and each must be refused FOR ITS OWN REASON — a refusal
                // with somebody else's message counts as a failure, because that is exactly how a
                // broken provenance check hid behind an unrelated one here two hours ago.
                auto lpm = buildPath(root, "tests", "license-package-mutations.sh");
                if (exists(lpm))
                    all ~= Target.phony("license-package-mutations", "sh " ~ lpm ~ " " ~ prefix ~ " " ~ arch
                                        ~ " " ~ ex.bdir, [Target(lpm), Target(lpk), inst]);
            }
            foreach (dc; DCS)
                all ~= Target.phony("dub-consumer-" ~ dc,
                    "sh " ~ dcs ~ " " ~ prefix ~ " qtd-qtwidgets " ~ dc,
                    [Target(dcs), Target(buildPath(root, "tests", "consumer", "hello.d")), inst]);
        }
    }

    // --- the audited transfer surface has to STAY audited ---
    // A class in `disposable` is one the binding will DELETE while it still owns it, which is safe
    // exactly as long as every API that could take ownership of it is declared. The list was walked
    // by hand against Qt's documentation once; this makes the walk a build step, so binding one
    // more method that takes such a type cannot widen the surface in silence. It found nineteen
    // unclassified methods the moment it was written.
    {
        auto og = buildPath(root, "tests", "ownership-gate.sh");
        if (exists(og))
            foreach (b; ctorGuardBindings)
                all ~= Target.phony("ownership-gate-" ~ b.specName.stripExtension.replace("spec_cxx_", ""),
                    "sh " ~ og ~ " " ~ buildPath(root, "generator", b.specName) ~ " " ~ b.genDir,
                    [Target(og), b.gen]);
    }

    // --- every allocating wrapper ctor frees its block if construction throws ---
    // Depends on the bindings' gen targets so it reads FRESHLY generated output: run against a
    // stale directory it reports 253 files missing a guard the emitter does emit, which is a red
    // that says nothing about the code.
    {
        auto cg = buildPath(root, "tests", "ctorguard.sh");
        if (exists(cg)) {
            Target[] deps = [Target(cg)];
            string dirs;
            foreach (b; ctorGuardBindings) { deps ~= b.gen; dirs ~= " " ~ b.genDir; }
            if (dirs.length)
                all ~= Target.phony("ctor-guard", "sh " ~ cg ~ dirs, deps);
        }
    }

    // --- the inventory is EXECUTED, not just well-formed (critics r7, open since) ---
    // The linter checks that every named probe target exists; it has never run one, and the cost of
    // that showed: `virtual-container-return` stayed listed after the shim that closed it landed,
    // because "the entry is well-formed" and "the entry is still true" are different questions.
    {
        auto efr = buildPath(root, "tests", "expected-fails-run.sh");
        auto efj = buildPath(root, "tests", "expected-fails.json");
        if (exists(efr))
            all ~= Target.phony("expected-fails-run",
                "sh " ~ efr ~ " " ~ efj ~ " " ~ buildPath(root, "build"),
                [Target(efr), Target(efj)]);
    }

    // --- holder lifetime layer, unit-tested in isolation (no generated binding) ---
    all ~= holderTests(root);

    // --- shiboken libsample corner cases (skipped if the pyside-setup clone is absent) ---
    all ~= libsampleTargets(root, buildNormalizedPath(root, "..", "pyside-setup"));

    // --- ANSWERS, not just targets. 893 of the 1101 default targets belong to the qmltc families,
    //     so "./build" is operationally the QML compiler's corpus and there was no shorter way to
    //     ask whether the GENERATOR is healthy. These name the questions people actually have.
    //     Every aggregate is a subset of `all` and none of them is a default target, so the full
    //     build is unchanged: this adds names, not work.
    // NOTE: the aggregates are BUILT AT THE END of this function, not here. They are a snapshot of
    // `all`, and taking that snapshot at this point is what round 15 #9 caught: every licensing
    // gate, `runtime-provenance` and `archive-composition` are appended AFTER, so `binding-core`
    // answered "is the binding healthy, gates included?" without depending on five of the gates it
    // named. Same ordering family as the registries rounds 13/14 fixed, reintroduced in the entry
    // point that answers the broadest question.
    Target[] aggregates;

    void buildAggregates() {
        bool isQmltc(string n) {
            return n.startsWith("qmltc") || n.startsWith("shadowaot-") || n.startsWith("leaf-lifetime");
        }
        Target[] pick(bool delegate(string) want) {
            return all.filter!(t => want(t.rawOutputs.length ? t.rawOutputs[0] : "")).array;
        }
        // libsample IS binding conformance, not an extra. It is the corpus designed OUTSIDE this
        // repository for exactly the corner cases the generator gets wrong — multiple inheritance,
        // overloads, references, function pointers, move-only types, operators, exceptions — and
        // excluding it meant a green "is the generator healthy?" could coexist with a regression
        // that libsample is the only thing here that catches.
        auto core   = pick(n => !isQmltc(n));
        auto qmlAll = pick(n => isQmltc(n));
        auto smoke  = pick(n => n.startsWith("qmltc-") && !n.canFind("-o3-gate-")
                             && !n.startsWith("qmltc-controls-runtime"));
        // THE DOCUMENTED NUMBERS AGAINST THE MEASURED ONES. Four coverage figures in README.md and
    // docs/qmltc-d.md were wrong on 2026-08-14 — the `-O3` column counted documents HANDLED under a
    // heading that says "compiles", one table was three documents stale, a paragraph disagreed with
    // the table beside it, and `-O1` had drifted by one. All four were typed by hand from a run that
    // later changed, so the o3 and optlevels gates now record what they counted and this compares
    // the documents against those files.
    {
        // ...and it DEPENDS on the gates whose output it reads, instead of hoping the files are
        // there. Without the edges it would pass by reading counts left by an earlier run — a green
        // that describes the previous build, which is precisely what runtime-provenance and
        // archive-composition were corrected for in rounds 13 and 14.
        //
        // The build directory is DERIVED, not typed. It read `.build/qt-6.11-cxx-controls`, a fact
        // about this machine wearing the clothes of a fact about the project: on a Qt 6.9 checkout
        // the directory is named differently, the gate would find no counts, and it would report
        // "fewer than five styles" — accusing the o3 gate of not having run. Third instance of a
        // hardcoded path in this audit, after `/usr/lib/qt6/moc` (182 targets silently gone) and the
        // absolute `generated-from` inside the shipped package.
        auto dn = buildPath(root, "tests", "docs-numbers.sh");
        if (exists(dn) && docsNumberSources.length)
            all ~= Target.phony("docs-numbers", "sh " ~ dn ~ " " ~ docsNumberBdir,
                                Target(dn) ~ docsNumberSources);
    }

    // THE MANUAL, BUILT AND CHECKED. `docs-sphinx` builds docs/manual with warnings as errors, so
    // an unreachable page or a broken cross-reference is a build failure rather than a site that
    // looks finished; `docs-spec-keys` compares the spec reference against the keys the generator
    // actually reads, in BOTH directions. The second direction is the one that already paid: before
    // the gate existed the reference listed `no_transfer` beside transfer_in/transfer_out as though
    // xiboca read it, and it does not — the ownership gate does. A reader would have written it into
    // a spec and got nothing.
    {
        auto dsx = buildPath(root, "tests", "docs-sphinx.sh");
        auto manual = buildPath(root, "docs", "manual");
        // Whichever binding was asked to emit an API reference is the one the manual assembles.
        Target[] docsApiDep;
        foreach (b; ctorGuardBindings) if (b.specName == "spec_cxx_qtwidgets.json") docsApiDep ~= b.gen;
        if (exists(dsx) && exists(buildPath(manual, "conf.py"))) {
            auto pages = dirEntries(manual, "*.rst", SpanMode.depth).map!(e => Target(e.name)).array;
            // The generated API reference is passed in, not built in place: it comes out of the
            // qtwidgets generation (spec key `docs_dir`), so the gate depends on that gen step. A
            // fresh checkout with nothing generated still builds the committed manual — the script
            // says so in its second message — which is why the api dir is an argument rather than a
            // requirement.
            all ~= Target.phony("docs-sphinx",
                                "sh " ~ dsx ~ " " ~ buildPath(root, ".build", "manual")
                                       ~ " " ~ buildPath(root, ".build", "api", "qtwidgets"),
                                [Target(dsx), Target(buildPath(manual, "conf.py"))] ~ pages ~ docsApiDep);
        }
        auto dsk = buildPath(root, "tests", "docs-spec-keys.sh");
        if (exists(dsk) && exists(buildPath(manual, "xiboca", "spec.rst")))
            all ~= Target.phony("docs-spec-keys", "sh " ~ dsk,
                                [Target(dsk), Target(buildPath(manual, "xiboca", "spec.rst")),
                                 Target(buildPath(manual, "xiboca", "ownership.rst")),
                                 Target(buildPath(root, "xiboca", "emit.d"))]);
    }

    // THE QUICKSTART THE DOCUMENTATION SHOWS, actually run. docs/manual/xiboca/
    // walks a reader through binding a C++ library that is neither Qt nor part of this repository's
    // bindings; this generates it, compiles it, links it and compares its output to a golden file.
    //
    // It exists because on 2026-08-18 the example both READMEs pointed at was broken and had been
    // for as long as the C-ABI emitter had been gone: generator/spec_userlib.json carried no
    // "abi": "cxx", so xiboca discovered 2 classes, emitted 0, and exited 0. Nothing ran it, so
    // nothing said so. It also covers ground the other gates cannot: the whole Qt matrix uses ONE
    // discovery mode (a Qt module plus qt_marker), and this is the only target exercising the other
    // one — headers plus source_filter, the mode every outside user starts from.
    {
        auto qs = buildPath(root, "tests", "xiboca-quickstart.sh");
        auto ulib = buildPath(root, "examples", "userlib");
        auto uspec = buildPath(root, "generator", "spec_userlib.json");
        if (exists(qs) && exists(uspec) && exists(buildPath(ulib, "shape.cpp")))
            all ~= Target.phony("xiboca-quickstart",
                                "sh " ~ qs ~ " " ~ buildPath(root, "xiboca", "xiboca") ~ " "
                                       ~ buildPath(root, ".build", "xiboca-quickstart"),
                                [Target(qs), Target(uspec), gendTarget(root),
                                 Target(buildPath(ulib, "shape.h")),
                                 Target(buildPath(ulib, "shape.cpp")),
                                 Target(buildPath(ulib, "app.d")),
                                 Target(buildPath(ulib, "expected.txt"))]);
    }

    // ...and OPTIONAL, not part of the default build. A node reached by two top-level targets
        // is executed once per reaching target in this backend, so adding these to `all` made the
        // full build run every member TWICE (visible as .reggae/objs/binding-core.objs/…). They are
        // entry points for asking a narrower question, which is the opposite of extra work.
        // ...and the aggregate CHECKS ITS OWN COMPOSITION. `binding-core` says "and their gates";
        // round 15 #9 measured that it contained none of the five product gates, because it was a
        // snapshot taken before they existed. A message is not a dependency, so the required list
        // is named here and a missing one is a build error rather than a weaker promise silently
        // kept. Adding a product gate means adding it here — that is the point.
        // `license-no-gpl-product` is NOT in this list any more, and the reason is worth the line:
        // it is a gap probe while the Qt5 parity archives are built with an unrecorded release
        // (see `qt5-parity-release-not-audited`), and a probe that must FAIL cannot be a member of
        // an aggregate that must pass. The composition check caught the contradiction the moment it
        // was created, which is what it is for — but the answer is to state the new shape here, not
        // to soften the check. When 5.15.19 is recorded the gate becomes mandatory again and this
        // list gets it back.
        static immutable string[] mustContain = [
            "license-coverage", "license-package",
            "runtime-provenance", "archive-composition",
        ];
        auto haveNames = core.map!(t => t.rawOutputs.length ? t.rawOutputs[0] : "").array;
        auto missing = mustContain.filter!(g => !haveNames.canFind(g)).array;
        if (core.length && missing.length)
            throw new Exception("binding-core claims to include the product gates and is missing: "
                                ~ missing.join(", ") ~ ". Either the gate was not registered before "
                                ~ "the aggregates are built, or it no longer exists.");
        if (core.length)   aggregates ~= Target.phony("binding-core",
            "echo 'binding-core OK: generator, runtime, uic, qrc, moc, webengine and their gates ("
            ~ mustContain.join(", ") ~ ")'", core);
        if (smoke.length)  aggregates ~= Target.phony("qmltc-smoke",
            "echo 'qmltc-smoke OK: the compiler over its own corpora, without Qt Controls'", smoke);
        if (qmlAll.length) aggregates ~= Target.phony("qmltc-corpus",
            "echo 'qmltc-corpus OK: every qmltc target, Qt Controls included'", qmlAll);
    }

    // On the Qt the baselines were recorded against, the gates run with everything else; on any
    // other minor they stay reachable by name but out of defaultTargets(), so the full matrix
    // never fails on SDK drift.
    // --- LICENSING GATES (docs/licensing-plan.md). The plan's own words: a release manager must be
    //     able to answer yes to every question in its checklist, and prose cannot answer any of
    //     them. These two answer the ones that are mechanical today; the rest of the plan's gates
    //     need artefacts this build does not yet produce (a Windows bundle, an SBOM) and are named
    //     in the plan rather than stubbed here.
    {
        auto lc = buildPath(root, "tests", "license-coverage.sh");
        if (exists(lc)) {
            all ~= Target.phony("license-coverage", "sh " ~ lc, [Target(lc)]);
            // INVENTORY AND PUBLICATION ARE DIFFERENT QUESTIONS (round 15 #8). The inventory may
            // pass with files whose terms are not established; a source archive may not. This
            // target answers the second one and is EXPECTED TO FAIL — 61 files carry NOASSERTION
            // today (the 60-file .ui corpus and one three-line .cpp), and Phase 1 of the licensing
            // plan is the work that empties it. Recorded as a gap probe so the state is a build
            // fact rather than a sentence in a document nobody runs.
            // NO LONGER A GAP PROBE. It was one while 61 files carried NOASSERTION — the honest
            // state, recorded as a build fact. On 2026-08-14 that list reached zero: 60 `.ui` files
            // by provenance established against qt/qt@0a2f238254, and `singletontype.cpp` by being
            // written here against Qt's declaration. A probe that must FAIL cannot stay pointed at
            // a target that now passes, so it is an ordinary gate and the expected-fails entry that
            // documented the gap is gone.
            all ~= Target.phony("license-publishable", "sh " ~ lc ~ " --publish", [Target(lc)]);
            // ...and the tree gate is attacked the way the package gate is. It decides the terms of
            // 551 files and it produced two defects in one afternoon — a quoted expression read as
            // a declaration (this project's own plan came out GPL-3.0-only) and a sidecar that
            // existed only on the author's machine. Both were found by asking what the gate ANSWERS
            // for a specific file, which is what a table of synthetic trees does every build.
            auto lcm = buildPath(root, "tests", "license-coverage-mutations.sh");
            if (exists(lcm))
                all ~= Target.phony("license-coverage-mutations", "sh " ~ lcm, [Target(lcm), Target(lc)]);
            // ...and the same gates run against WHAT WOULD BE PUBLISHED, not against this working
            // tree. `license-coverage` asks git which files exist, so it answers about one machine's
            // index: measured on 2026-08-14 the tree was green while five untracked files carried no
            // terms at all — the GPL, LGPL-2.1, LGPL-3.0 and Qt-Commercial records and the licence
            // matrix, every one of them load-bearing for the policy. This unpacks tracked plus
            // untracked-not-ignored files into a fresh repository and re-runs the gates there.
            auto lsnap = buildPath(root, "tests", "license-snapshot.sh");
            if (exists(lsnap))
                all ~= Target.phony("license-snapshot", "sh " ~ lsnap,
                                    [Target(lsnap), Target(lc), Target(lcm)]);
            // ...and the battery for the gate that checks the other gates. Its three rows are the
            // three ways "here" and "what would be published" come apart, and none of them is
            // visible to license-coverage run in a working tree — which is the whole reason the
            // snapshot gate exists, and the reason its own proof could not live in a transcript.
            auto lsm = buildPath(root, "tests", "license-snapshot-mutations.sh");
            if (exists(lsm) && exists(lsnap))
                all ~= Target.phony("license-snapshot-mutations", "sh " ~ lsm,
                                    [Target(lsm), Target(lsnap), Target(lc), Target(lcm)]);
        }
        auto lg = buildPath(root, "tests", "license-no-gpl-product.sh");
        auto reg2 = qtdShimsRegistry();
        // MANDATORY ONLY WHERE IT CAN ANSWER (round 17 #2). The matrix is keyed by exact Qt release
        // and REFUSES to judge one it does not record — correct, and it makes this gate red by
        // construction on a runner whose distro Qt is 6.4.2. The two honest ways out are to install
        // a Qt the matrix covers or to audit that release and record it; loosening the comparison
        // back to a minor would reopen the defect round 16 #6 was raised to close.
        //
        // Until one of those happens the gate follows the SAME rule the manifest gates already
        // follow here: mandatory when the installed release is one the matrix speaks about,
        // reachable by name and advisory otherwise. What that costs is stated rather than hidden —
        // on such a runner NO licensing verification of Qt modules is performed, and the workflow's
        // advisory step is where it runs and where its failure is visible.
        auto qtRel = () {
            return qtModVersion("Qt6Core");
        }();
        auto matrixPath = buildPath(root, "docs", "qt-license-matrix.tsv");
        bool relRecorded = qtRel.length && exists(matrixPath)
            && readText(matrixPath).split("\n").any!(l => l.startsWith("verified-for\t" ~ qtRel));
        if (exists(lg) && reg2.length) {
            // THE LINK MANIFEST, from the graph (round 15 #3). The gate used to identify a module by
            // grepping an archive for a namespace — the signature of one incident, blind to every
            // other module and to anything inline or templated. What actually determines the
            // dependency is which pkg-config modules were on the compile line, and the graph is
            // where that is known. Written here so the gate reads a recorded fact rather than
            // inferring one from symbols.
            auto lm = buildPath(root, ".build", "link-manifest.tsv");
            // THREE columns now: artifact, the RELEASE that produced it, and the EXPANDED link
            // line. Round 18 #1/#2: one name on the compile line is nine libraries on the link
            // line, and a single global release certified artifacts from two different Qt versions.
            writeIfChanged(lm, reg2.map!(e => e.archive ~ "\t" ~ (e.qtRel.length ? e.qtRel : "unknown")
                                              ~ "\t" ~ e.linkMods.join(",")).join("\n") ~ "\n");
            auto gpl = Target.phony("license-no-gpl-product", "sh " ~ lg ~ " " ~ lm,
                                    [Target(lg), Target(matrixPath)] ~ reg2.map!(e => e.target).array);
            // A GAP PROBE while an artifact's release is unrecorded (round 18 #2/#3). The gate
            // refuses the Qt5 parity archives because they are built with 5.15.19 and the matrix
            // records 5.15.17 — the correct answer, and one that must be VISIBLE rather than
            // absorbed. Round 18 #3 was right that making it non-blocking on an unknown release was
            // a third answer to a two-answer question; a probe that must fail, with its signature
            // in expected-fails.json, is the project's own way of keeping an honest red.
            if (relRecorded) gapProbes ~= gpl; else manifestGates ~= gpl;
            // ...and the battery that proves it refuses. Unlike the gate itself this is NOT
            // release-dependent: it builds its own matrix, its own specs and its own link manifest,
            // so it answers the same on every machine — including the question "what happens when
            // the installed release is not recorded?", which cannot be asked of the real matrix
            // without lying in it.
            auto lgm2 = buildPath(root, "tests", "license-no-gpl-product-mutations.sh");
            if (exists(lgm2))
                all ~= Target.phony("license-no-gpl-product-mutations", "sh " ~ lgm2,
                                    [Target(lgm2), Target(lg)]);
        }
    }

    // THE GATES THAT NEED THE WHOLE GRAPH come last, after every binding has registered itself
    // (critics r14 #4/#5). Declared earlier they saw a partial registry — libsample is created
    // further down — and a gate that promises the matrix while holding a subset is the shape this
    // audit has caught three times.
    // --- RUNTIME PROVENANCE (critics r13 #1): the generator copies runtime sources verbatim into
    //     every binding, which makes them build INPUTS. A missing edge does not fail — it goes
    //     green against the copy from before, and that is exactly what libsample did. The edge is
    //     the fix; this notices when the fix is undone, which a functional test cannot: it runs the
    //     wrong revision perfectly.
    //
    //     It runs AFTER the things that write the copies, and that edge is not decoration: on its
    //     first full build it failed against libsample's copies simply because it got there first.
    //     A gate that can be scheduled before the thing it inspects reports the previous state.
    {
        auto pv = buildPath(root, "tests", "runtime-provenance.sh");
        auto gens = qtdGenRegistry();
        if (exists(pv) && gens.length)
            all ~= Target.phony("runtime-provenance", "sh " ~ pv, Target(pv) ~ gens);
    }

    // --- ARCHIVE COMPOSITION CANARY (critics r13 #3): runtime-boundary counts QML types in a
    //     SOURCE FILE, which the audit correctly called lexical location — it can reach zero with
    //     the QML object still in every archive. This looks at the artefact, in both directions.
    {
        // The list comes from the GRAPH and the target depends on EVERY archive in it (critics
        // r14 #4). The first version globbed `.build/*/libshims.a`, skipped anything without a
        // marker, and depended on two archives while printing a conclusion about eleven — so on a
        // clean build it could run after two, say OK, and never look at Qt5, wraptest, webengine,
        // controls or libsample.
        auto ac = buildPath(root, "tests", "archive-composition.sh");
        auto reg = qtdShimsRegistry();
        if (exists(ac) && reg.length) {
            auto specFile = buildPath(root, ".build", "archive-composition.tsv");
            writeIfChanged(specFile,
                reg.map!(e => e.archive ~ "\t" ~ (e.hasQml ? "yes" : "no")).join("\n") ~ "\n");
            all ~= Target.phony("archive-composition", "sh " ~ ac ~ " " ~ specFile,
                                [Target(ac)] ~ reg.map!(e => e.target).array);
        }
    }

    import std.range : chain;
    // HERE — after every target, gate and registry is closed. See the note where `aggregates` is
    // declared: this is the fix for round 15 #9.
    buildAggregates();
    // The optional gap probes, written where the linter can read them (see expected-fails-lint).
    writeIfChanged(buildPath(root, ".build", "gap-probes.txt"),
                   gapProbes.map!(t => "- " ~ t.rawOutputs[0]).join("\n") ~ "\n");
    if (gatesEnforceable)
        return Build(chain(all.map!(t => createTopLevelTarget(t)),
                           manifestGates.map!(t => createTopLevelTarget(t)),
                           gapProbes.map!(t => optional(t)),
                           aggregates.map!(t => optional(t))));
    return Build(chain(all.map!(t => createTopLevelTarget(t)),
                       manifestGates.map!(t => optional(t)),
                       gapProbes.map!(t => optional(t)),
                       aggregates.map!(t => optional(t))));
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
    auto cf = pkgCflags(["Qt6UiTools", "Qt6Widgets"]) ~ " -std=c++17 " ~ cxxPic() ~ " -O2";
    auto t = Target(o, guarded(o ~ ".lock", "clang++ " ~ cf ~ " -c " ~ src ~ " -o " ~ o, null, o, [src]),
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
    auto cf = pkgCflags(["Qt6UiTools", "Qt6Widgets"]) ~ " -std=c++17 " ~ cxxPic() ~ " -O2";
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
            dc ~ " -of=$out" ~ dSupport(root) ~ " " ~ checkD ~ " " ~ uiformD ~ " " ~ qrcD ~ " " ~ uidumpO
            ~ " -I" ~ ex.genDir ~ " -I" ~ buildPath(root, "runtime", "qrc")
            ~ " -J=" ~ here ~ " -L--start-group -L=" ~ buildPath(ex.bdir, "libbinding_" ~ dc ~ ".a")
            ~ " -L=" ~ buildPath(ex.bdir, "libshims.a") ~ " -L--end-group " ~ libs,
            [Target(checkD), uidumpT, lib, ex.shims] ~ uiInputs(root, here));
        ts ~= Target.phony("uicheck-" ~ dc, runOffscreen(root, "$in", "", ex.mods), [bin]);
    }
    return ts;
}

// The whole Qt baseline .ui corpus (tests/uic/corpus/*.ui) run through the same differential
// oracle as uicheck. Reuses the uidump.o harness; each form is diffed against QUiLoader.
Target[] corpusCheckTargets(string root, QtdBinding ex) {
    auto here = buildPath(root, "tests", "uic");
    auto cf = pkgCflags(["Qt6UiTools", "Qt6Widgets"]) ~ " -std=c++17 " ~ cxxPic() ~ " -O2";
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
            dc ~ " -of=$out" ~ dSupport(root) ~ " " ~ checkD ~ " " ~ uiformD ~ " " ~ qrcD ~ " " ~ uidumpO
            ~ " -I" ~ ex.genDir ~ " -I" ~ buildPath(root, "runtime", "qrc")
            ~ " -J=" ~ here ~ " -L--start-group -L=" ~ buildPath(ex.bdir, "libbinding_" ~ dc ~ ".a")
            ~ " -L=" ~ buildPath(ex.bdir, "libshims.a") ~ " -L--end-group " ~ libs,
            [Target(checkD), uidumpT, lib, ex.shims]
            ~ uiInputs(root, here) ~ uiInputs(root, buildPath(here, "corpus")));
        ts ~= Target.phony("corpus-check-" ~ dc, runOffscreen(root, "$in", "", ex.mods), [bin]);
    }
    return ts;
}

// Coverage manifest gate: the per-symbol manifest becomes a CONTRACT. For each binding, the gen
// step rewrites coverage-manifest.tsv; the gate diffs it against tests/coverage/<b>.manifest.tsv
// and fails on a disappeared symbol, a fate that worsened (e.g. bound -> unmapped), or a new
// unmapped/inline-failed drop. Accept intended changes by regenerating the baseline. The gate
// program is compiler-independent (built once with dmd).
// Every QML type the registry can NAME must be TYPEABLE: a name in qmlmap.tsv with no rows in
// qmlprops.tsv is a type the compiler recognises and then cannot compile one binding on. `Text` was
// exactly that in the Controls binding for as long as nobody compared the two tables, and what it
// produced -- "declared type '?'" -- reads like a compiler gap rather than a registry one.
Target[] registryGateTarget(string root, QtdBinding bind, string label) {
    auto script = buildPath(root, "tests", "qmltc", "registry_gate.sh");
    return [Target.phony("registry-gate-" ~ label,
                         "sh " ~ script ~ " " ~ buildPath(bind.genDir, "qmlmap.tsv"),
                         [Target(script), bind.gen])];
}

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
            ts ~= Target.phony("tr" ~ tag ~ "-" ~ dc, runOffscreen(root, "$in", "", qml.mods), [bin, qmT]);
        } else {
            ts ~= Target.phony("tr" ~ tag ~ "-" ~ dc, runOffscreen(root, "$in", "", qml.mods), [bin]);
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
    if (!qtHasModule("Qt6QmlCompiler")) return [];
    auto here = buildPath(root, "tests", "qml");
    auto genD = buildPath(here, "qmltypes_gen.d");
    auto checkCpp = buildPath(here, "qtd_qmltypes_check.cpp");
    auto ccflags = pkgCflags(["Qt6QmlCompiler", "Qt6Qml", "Qt6Core"]) ~ " -std=c++17 " ~ cxxPic() ~ " -O2 "
        ~ (modulePrivateFlags(pkgCflags(["Qt6QmlCompiler"]), "QtQmlCompiler")
           ~ modulePrivateFlags(pkgCflags(["Qt6Qml"]), "QtQml")
           ~ modulePrivateFlags(pkgCflags(["Qt6Core"]), "QtCore")).join(" ");
    // raw pkg-config libs (this is a clang++ link, not the D linker's -L= form).
    auto clibs = qtLibsOf(["Qt6QmlCompiler", "Qt6Qml", "Qt6Core"]);
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
// THE SHARED HELPER OBJECTS, memoised. `qtd_qmltc_app.o` and `qtd_render.o` live in the binding's
// build dir and are linked by BOTH the qmltc differentials and the optlevels gate — but only the
// former declared them. The latter tested for the file with `[ -f ]` and linked against whatever it
// found, so while another target rewrote the object it linked against a partial file and reported
// `-O1 does not link`, a message that names nothing about concurrency. Measured 2026-08-14: ATile
// failed inside the matrix and passed 3/3 in isolation, which is the third time this session that a
// file expected-to-be-there rather than declared produced a phantom failure.
private Target[string] _qmltcAppObjs, _qmltcRenderObjs;
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
    auto toolFlags = pkgCflags([qml, core]) ~ " -std=c++17 " ~ cxxPic() ~ " -O2 "
        ~ (modulePrivateFlags(pkgCflags([qml]), "QtQml")
           ~ modulePrivateFlags(pkgCflags([core]), "QtCore")).join(" ");
    auto toolLibs = qtLibsOf([qml, core]);
    // Shared by every qmltc differential target -> guard it (see `guarded`): a concurrent
    // re-schedule of this one node otherwise links over a binary another target is executing.
    auto toolBin = buildPath(bind.bdir, "qmltc-d");
    // THE REVISION COMES FROM THE BUILD, in its own translation unit (round 16 #4). The tool used to
    // run `git rev-parse` in the CURRENT DIRECTORY at emission time, which is right only when it is
    // run from this checkout: measured, the same binary with the same input wrote
    // `generator=a0b3b94-dirty` here and `generator=unknown` from /tmp — and inside somebody else's
    // repository it would have written THEIR revision as if it were ours.
    //
    // It is a separate 3-line file rather than a -D on the tool's own compile line because the tool
    // is 11k lines: with writeIfChanged, a dirty-state flip recompiles three lines and relinks,
    // instead of rebuilding the compiler on every edit.
    auto revCpp = buildPath(bind.bdir, "qtd_gen_rev.cpp");
    auto revObj = buildPath(bind.bdir, "qtd_gen_rev.o");
    auto rv = () {
        auto r = execute(["git", "-C", root, "rev-parse", "--short", "HEAD"]);
        if (r.status != 0) return "unknown";
        auto d = execute(["git", "-C", root, "status", "--porcelain", "--untracked-files=no"]);
        return r.output.strip ~ (d.status == 0 && d.output.strip.length ? "-dirty" : "");
    }();
    writeIfChanged(revCpp, "// GENERATED by the build: the revision that produced this binary.\n"
        ~ "extern \"C\" const char *qtd_gen_rev(void) { return \"" ~ rv ~ "\"; }\n");
    auto revO = Target(revObj, "clang++ -std=c++17 " ~ cxxPic() ~ " -O2 -c " ~ revCpp ~ " -o " ~ revObj,
                       [Target(revCpp)]);
    auto t = Target(toolBin, guarded(toolBin ~ ".lock",
        "clang++ " ~ toolFlags ~ " " ~ toolCpp ~ " " ~ revObj ~ " -o " ~ toolBin ~ " " ~ toolLibs, null,
        toolBin, [toolCpp, revObj]),
        [Target(toolCpp), revO]);
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
    // EVERY unit of the boundary, not just the one that was there first (critics r13 #2). After the
    // QML half moved to qtdmoc_qml.cpp these probes kept compiling qtdmoc.cpp alone and kept
    // passing — a green that says nothing about whether the NEW unit builds in each configuration,
    // which is the contract the comment below claims. Each unit gets its own object file so a
    // failure names the file.
    auto units = ["qtmoc/qtdmoc.cpp", "qtmoc/qtdmoc_qml.cpp"]
        .map!(f => buildPath(root, "runtime", f)).filter!(f => exists(f)).array;
    if (units.length == 0) return [];
    Target[] ts;
    auto mk = (string name, string[] mods, bool qml, string qmlMod) {
        if (!mods.all!(m => qtHasModule(m))) return;
        auto cf = pkgCflags(mods);
        auto flags = cf ~ " -std=c++17 " ~ cxxPic() ~ " " ~ mocPrivateFlags(cf).join(" ")
                   ~ (qml ? " " ~ modulePrivateFlags(pkgCflags([qmlMod]), "QtQml").join(" ")
                            ~ " -DQTD_ENABLE_QML" : "");
        string cmd; Target[] deps;
        foreach (u; units) {
            auto obj = buildPath(root, ".build", "probe-" ~ name ~ "-" ~ baseName(u, ".cpp") ~ ".o");
            cmd ~= (cmd.length ? " && " : "") ~ "clang++ " ~ flags ~ " -c " ~ u ~ " -o " ~ obj;
            deps ~= Target(u);
        }
        // A compile-only probe prints nothing when it works, and "it compiled" then looks exactly
        // like "it never ran". Say what was built and in which configuration.
        import std.conv : to;
        cmd ~= " && echo 'qtmoc-probe-" ~ name ~ " OK: " ~ units.length.to!string
             ~ " runtime unit(s) compile with " ~ (qml ? "QtQml" : "no QtQml") ~ "'";
        ts ~= Target.phony("qtmoc-probe-" ~ name, cmd, deps);
    };
    // No QtQml in sight: the configuration that broke.
    mk("noqml", ["Qt6Core"], false, "");
    mk("qml6", ["Qt6Qml", "Qt6Core"], true, "Qt6Qml");
    mk("qml5", ["Qt5Qml", "Qt5Core"], true, "Qt5Qml");
    return ts;
}

// THE PROMISE, as a gate rather than a photograph: every judgeable document in a style renders
// exactly like the engine, at SOME level. Each is compiled greedily, rendered and compared; what
// differs is demoted to -O0, where Qt builds the document itself. A document counts as a failure
// only when NO level reproduces the engine's frame.
//
// It runs on ALL FIVE styles, and the reason is a hole this gate had on its first day: it watched
// Imagine alone, Material came out with three documents no level could place, and the build stayed
// green. A gate over a sample answers a question nobody asked — the promise is about every
// document, so the gate has to be about every document.
Target[] o3GateTargets(string root, QtdBinding bind) {
    auto script = buildPath(root, "tests", "qmltc", "o3.sh");
    if (!exists(script)) return [];
    auto tool = qmltcTool(root, bind);
    Target[] ts;
    auto outDir = buildPath(bind.bdir, "o3gate");
    // THE APPLICATION-SHAPED CORPUS, first, because it is the one that answers the question the
    // styles cannot. Qt's own QML is a narrow dialect written for a style engine; these are list
    // models, Loaders, real JS, states, inline components, signals crossing documents and one
    // document instantiating another from its own directory. Judged by exactly the same two axes.
    auto appDir = buildPath(root, "tests", "qmltc", "app");
    // GUARDED, one lock per state file. o3.sh truncates `o3gate/o3_<name>.txt` at the top and then
    // appends a line per document, so two concurrent instances of the SAME gate interleave into one
    // file: measured, 114 lines for a 70-document style, `compiled=86` on those 70, and UNPLACED=2
    // where the clean run says 0 — a red that reads exactly like a compiler regression. The binary
    // backend re-schedules a node when the build description is regenerated mid-run, which is how
    // it happened; this is the same shape already fixed for the qmltc tool binary and the install
    // node. No freshness test (empty `newerThan`): a gate must always run, only never twice at once.
    if (exists(appDir))
        ts ~= Target.phony("qmltc-o3-gate-app",
            guarded(buildPath(outDir, "o3_app.lock"),
                "sh -c 'sh " ~ script ~ " " ~ outDir ~ " " ~ appDir ~ " " ~ bind.bdir ~ " "
                ~ bind.genDir ~ " | tee /dev/stderr | grep -q \"UNPLACED=0\"'", null, "", []),
            [tool, Target(script), bind.gen, qtdBindLib(bind, "ldc2"), bind.shims]);
    auto ctlDir = buildPath(qtInstallQml(), "QtQuick", "Controls");
    // A MISSING STYLE IS A RED GATE, not a missing one. Controls absent altogether is a genuine
    // capability skip and says so out loud; Controls present with a style missing is the shape
    // that would quietly delete four fifths of this check on another machine.
    if (!exists(ctlDir))
        return ts ~ Target.phony("qmltc-o3-gate-skipped",
                                 "echo 'qmltc-o3-gate: skipped — no QtQuick.Controls under "
                                 ~ qtInstallQml() ~ "'", []);
    foreach (style; ["Basic", "Fusion", "Universal", "Imagine", "Material"]) {
        auto styleDir = buildPath(ctlDir, style);
        if (!exists(styleDir)) {
            ts ~= Target.phony("qmltc-o3-gate-" ~ style,
                               "sh -c 'echo \"qmltc-o3-gate: " ~ styleDir
                               ~ " is missing while Controls is installed\" >&2; exit 1'", []);
            continue;
        }
        // One compiler only: the levels are a property of the GENERATED code, not of who compiles
        // it, and the ldc2/dmd split is already covered everywhere else.
        auto cmd = guarded(buildPath(outDir, "o3_" ~ style ~ ".lock"),
                 "sh -c 'sh " ~ script ~ " " ~ outDir ~ " " ~ style ~ " " ~ bind.bdir ~ " "
                 ~ bind.genDir ~ " | tee /dev/stderr | grep -q \"UNPLACED=0\"'", null, "", []);
        ts ~= Target.phony("qmltc-o3-gate-" ~ style, cmd,
                           [tool, Target(script), bind.gen, qtdBindLib(bind, "ldc2"), bind.shims]);
    }
    return ts;
}

// THE LEVELS MUST AGREE — with the engine and with each other. `-O` is a degree of CERTAINTY, so a
// HIGHER level that disagrees with a lower one is a false positive by definition, and a level that
// hands the document over must still produce the engine's values. The script existed and nothing
// ran it: a check nobody executes is a comment.
//
// Over the APPLICATION corpus rather than the styles, because that is where the levels actually
// diverge — at -O1 and -O2 twelve of those fourteen documents go to the engine whole, which is the
// behaviour under test.
Target[] optLevelTargets(string root, QtdBinding bind) {
    auto script = buildPath(root, "tests", "qmltc", "optlevels.sh");
    auto dir = buildPath(root, "tests", "qmltc", "app");
    if (!exists(script) || !exists(dir)) return [];
    auto tool = qmltcTool(root, bind);
    auto toolBin = buildPath(bind.bdir, "qmltc-d");
    Target[] ts;
    foreach (e; dirEntries(dir, "*.qml", SpanMode.shallow).map!(x => x.name).array.sort) {
        auto name = baseName(e).stripExtension;
        auto outDir = buildPath(bind.bdir, "optlevels", name);
        auto cmd = "sh " ~ script ~ " " ~ toolBin ~ " " ~ buildPath(bind.genDir, "qmlmap.tsv")
                 ~ " " ~ e ~ " I" ~ name ~ " " ~ outDir ~ " " ~ bind.bdir ~ " " ~ bind.genDir
                 ~ " ldc2 " ~ pkgLibs(bind.mods);
        // ...AND the two helper objects this script links against. It tested for them with `[ -f ]`
        // and linked whatever was on disk: while another target rewrote `qtd_render.o`, this link
        // consumed a partial file and failed with `-O1 does not link`, a message that names nothing
        // about concurrency. ATile failed that way inside the matrix on 2026-08-14 and passed 3/3
        // in isolation. A file a gate expects to find is not a dependency; this makes it one.
        Target[] helpers;
        if (auto p = bind.bdir in _qmltcAppObjs) helpers ~= *p;
        if (auto p = bind.bdir in _qmltcRenderObjs) helpers ~= *p;
        ts ~= Target.phony("qmltc-optlevels-" ~ name, cmd,
                           [tool, Target(script), Target(e), bind.gen,
                            qtdBindLib(bind, "ldc2"), bind.shims] ~ helpers);
    }
    return ts;
}

Target[] qmltcControlsRuntimeTargets(string root, QtdBinding bind) {
    auto dir = buildPath(qtInstallQml(), "QtQuick", "Controls", "Basic");
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
    if (!qtHasModule("Qt6Qml")) return [];
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
    auto oracleFlags = pkgCflags(oracleMods) ~ " -std=c++17 " ~ cxxPic() ~ " -O2";
    auto oracleLibs = qtLibsOf(oracleMods);
    auto oracleBin = buildPath(bind.bdir, "qmlvalues");
    auto rndBin = buildPath(bind.bdir, "qmlrender");
    Target[] rndDep;
    if (bind.mods.any!(m => m.canFind("Quick"))) {
        auto rCpp = buildPath(here, "qtd_qmlrender.cpp");
        auto rFl = pkgCflags(bind.mods ~ ["Qt6Core"]) ~ " -std=c++17 " ~ cxxPic() ~ " -O2";
        auto rLb = qtLibsOf(bind.mods ~ ["Qt6Core"]);
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
    auto appHelper = () {
        if (auto p = bind.bdir in _qmltcAppObjs) return *p;
        auto t = Target(appObj, guarded(appObj ~ ".lock",
            "clang++ " ~ oracleFlags ~ " -c " ~ appCpp ~ " -o " ~ appObj, null, appObj, [appCpp]),
            [Target(appCpp)]);
        _qmltcAppObjs[bind.bdir] = t;
        return t;
    }();
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

// QJsDelegatedFrame is here for a reason no other entry has: its binding is DELEGATED to the
// engine, on an item a VIEW creates, and a view-created item has no static object path -- so the
// property differential beside it compares nothing about the very thing under test. The frame is
// the only axis that can see it.
static immutable string[] renderable = ["QEnumCmp", "QEnumProp", "QGroupReactive", "QObjGroup",
                                            "QJsDelegatedFrame",
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
        auto rFlags = pkgCflags(bind.mods ~ ["Qt6Core"]) ~ " -std=c++17 " ~ cxxPic() ~ " -O2";
        // memoised for the same reason as the app helper: the optlevels gate links against this
        // object and must depend on the SAME node, not on a second definition of it.
        if (bind.bdir !in _qmltcRenderObjs)
            _qmltcRenderObjs[bind.bdir] = Target(renderObj, guarded(renderObj ~ ".lock",
                "clang++ " ~ rFlags ~ " -c " ~ renderCpp ~ " -o " ~ renderObj, null, renderObj, [renderCpp]),
                [Target(renderCpp)]);
        renderDep ~= Target(renderObj, guarded(renderObj ~ ".lock",
            "clang++ " ~ rFlags ~ " -c " ~ renderCpp ~ " -o " ~ renderObj, null, renderObj, [renderCpp]),
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
            // qmlmap.tsv (QML-name -> bound C++ class) is a build output of the binding's xiboca run;
            // the tool reads it so its bound-type vocabulary is DATA, not hard-coded. Absent (e.g.
            // the QtObject binding) -> the tool just loads nothing.
            // ...and the CORPUS DIRECTORY on the import path, so a fixture can use a sibling
            // local type the way an application does. Without it a fixture that instantiates one
            // fails at type resolution, which reads like a compiler gap and is a missing -I.
            auto qmlmapArgs = ["--qmlmap", buildPath(bind.genDir, "qmlmap.tsv"), "-I", corpusDir];
            auto qmlmapArg = " " ~ qmlmapArgs.join(" ");
            // 1) qmltc-d --dump <qml> <Name> -> generated D (class + a value-dumping main).
            auto genD = buildPath(bind.bdir, "qmltc_" ~ name ~ "_" ~ dc ~ ".d");
            // Exit 3 is "partial": members were skipped and reported. The fixture suite treats it
            // as failure ON PURPOSE -- a fixture that quietly went partial is a regression nobody
            // would see -- except for the files whose REFUSAL is the thing under test. There the
            // diagnostic is the expected output, and the differential beside it is what proves the
            // refusal is the right one (both sides read empty). Any other exit code still fails.
            static immutable string[] partialOk = ["QDelegateReqNoModel", "QDelegateReqFill"];
            string genCmd;
            version (Windows)
                // bind.mods: the tool needs its own Qt on PATH to LOAD, not just to link. Without
                // it qmltc-d dies with `error while loading shared libraries: Qt6Core.dll` before
                // printing a line, the capture writes an empty file, and the failure surfaces much
                // later and elsewhere — at the link of the app built from it.
                genCmd = psCapture(root, toolBin, ["--dump", qmlFile, name] ~ qmlmapArgs,
                                   "$out", partialOk.canFind(name) ? "0,3" : "0", false, bind.mods);
            else
                genCmd = partialOk.canFind(name)
                    ? "sh -c '" ~ toolBin ~ " --dump " ~ qmlFile ~ " " ~ name ~ qmlmapArg
                        ~ " > $out; rc=$?; [ $rc -eq 0 ] || [ $rc -eq 3 ]'"
                    : toolBin ~ " --dump " ~ qmlFile ~ " " ~ name ~ qmlmapArg ~ " > $out";
            auto gen = Target(genD, genCmd, [tool, Target(qmlFile), bind.gen]);
            // 2) link the generated D against the binding (same shape as qtdApp).
            auto appBin = buildPath(bind.bdir, "qmltc_" ~ name ~ "_" ~ dc ~ "_check");
            auto link = dc ~ " -of=$out" ~ dSupport(root) ~ " " ~ genD ~ " " ~ appObj ~ renderLink ~ " -I" ~ bind.genDir
                ~ " -L--gc-sections -L--as-needed -L--start-group -L=" ~ buildPath(bind.bdir, "libbinding_" ~ dc ~ ".a")
                ~ " -L=" ~ buildPath(bind.bdir, "libshims.a") ~ " -L--end-group " ~ pkgLibs(bind.mods) ~ cxxRuntimeFlag();
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
            // ...except where the label protocol cannot name the objects at all. An item a VIEW
            // creates has no static path: `--labels` deliberately drops labels whose index a view
            // decides, so a delegate that declares properties makes --verify-props report engine
            // members no label mentions -- not "both sides shrank", but a protocol that was never
            // able to name them. The strong `-all-` target beside this one DOES compare those
            // items (both sides enumerate the same object), and it is green for all four; this
            // list exists so the weaker gate does not claim a gap the stronger one covers.
            static immutable string[] labelsGap = [
                "QDelegateKidCtx", "QDelegateRole", "QDelegateRoleReq", "QDelegateReqNoModel",
                "QDelegateReqFill", "QJsDelegatedFrame",
            ];
            auto verifyStep = labelsGap.canFind(name) ? ""
                : " && QT_QPA_PLATFORM=offscreen " ~ oracleBin ~ " " ~ qmlFile ~ " --verify-props " ~ props;
            string cmd;
            version (Windows) {
                // The same sequence in PowerShell. `Run` is the `&&`: PowerShell carries on after a
                // native program fails, so each step is checked. The label list is allowed to fail
                // (`2>/dev/null` on the sh side) — the diff is what judges.
                string[] ls = [
                    psRedirect(toolBin, [qmlFile, name] ~ qmlmapArgs, props, false, true),
                    psRedirect(appBin, [], a),
                    psRedirect(oracleBin, [qmlFile, "--props", props], b),
                ];
                if (verifyStep.length)
                    ls ~= "Run " ~ psQ(oracleBin) ~ " " ~ psQ(qmlFile) ~ " '--verify-props' " ~ psQ(props);
                ls ~= psDiff(a, b, "qmltc " ~ name ~ " (" ~ dc ~ ")");
                cmd = psInline(root, "qmltc" ~ tag ~ "-" ~ name ~ "-" ~ dc, ls, bind.mods);
            } else
                cmd = "sh -c '" ~ mkProps ~ "QT_QPA_PLATFORM=offscreen " ~ appBin ~ " > " ~ a
                    ~ " && QT_QPA_PLATFORM=offscreen " ~ oracleBin ~ " " ~ qmlFile ~ " --props " ~ props ~ " > " ~ b
                    ~ verifyStep
                    ~ " && diff " ~ a ~ " " ~ b
                    ~ " && echo \"qmltc " ~ name ~ " (" ~ dc ~ "): $(wc -l < " ~ a ~ ") value lines match the engine\"'";
            ts ~= Target.phony("qmltc" ~ tag ~ "-" ~ name ~ "-" ~ dc, cmd, [app, oracle, tool]);
            // ...and the STRONGER protocol beside it, which until now lived only in the corpus
            // scripts: `--objpaths` lists the objects and BOTH sides then enumerate every property
            // each one declares. The `--props` diff above can only prove that what the compiler
            // CHOSE to record matches; this one compares what the objects actually are, and it is
            // what found the deferred transitions, the gradients, the QJSValue slots and every
            // ordering defect this file records. Measured before adding it: 23 of the 23 controls
            // fixtures pass.
            // ...for every fixture EXCEPT the `Connections` pair, which is a DELIBERATE structural
            // difference: the element is desugared into connects and no object is built, while the
            // engine holds one in `conn`. Both fixtures say so in their own headers, and the entry
            // `qml-declared-members-not-in-metaobject` in tests/expected-fails.json carries it. Measured: controls 23 of 23, quick 46 of 46, corpus 44 of 46.
            // QJsDelegatedFrame is here for a DECLARED gap, not a value one: its delegate declares
            // `required property var modelData`, and a `var` has no D type, so we emit no property
            // at all while the engine's dump carries `modelData 0`. That absence is the whole
            // reason the binding above it is DELEGATED rather than compiled; the axis that judges
            // this fixture is the FRAME, which is registered for it.
            static immutable string[] dumpallGap = [
                "Connect", "CrossCall", "QJsDelegatedFrame",
            ];
            if (!dumpallGap.canFind(name)) {
            auto objs = genD ~ ".objs", da = genD ~ ".dall", qa = genD ~ ".qall";
            auto mkObjs = toolBin ~ " --objpaths " ~ qmlFile ~ " " ~ name ~ qmlmapArg ~ " > " ~ objs ~ " 2>/dev/null; ";
            string allCmd;
            version (Windows)
                allCmd = psInline(root, "qmltc" ~ tag ~ "-" ~ name ~ "-all-" ~ dc, [
                    psRedirect(toolBin, ["--objpaths", qmlFile, name] ~ qmlmapArgs, objs, false, true),
                    psRedirect(appBin, ["--dumpall"], da, true),
                    psRedirect(oracleBin, [qmlFile, "--dumpall", objs], qa, true),
                    psDiff(da, qa, "qmltc " ~ name ~ " (" ~ dc ~ ", objpaths)"),
                ], bind.mods);
            else
                allCmd = "sh -c '" ~ mkObjs ~ "QT_QPA_PLATFORM=offscreen " ~ appBin ~ " --dumpall | sort > " ~ da
                    ~ " && QT_QPA_PLATFORM=offscreen " ~ oracleBin ~ " " ~ qmlFile ~ " --dumpall " ~ objs ~ " | sort > " ~ qa
                    ~ " && diff " ~ da ~ " " ~ qa
                    ~ " && echo \"qmltc " ~ name ~ " (" ~ dc ~ ", objpaths): $(wc -l < " ~ da ~ ") lines match\"'";
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
                          ~ " && ! diff -q " ~ oT ~ " " ~ zT ~ " > /dev/null"
                          ~ " && echo \"qmltc" ~ tag ~ " " ~ name ~ " (" ~ dc ~ ", " ~ tm.ms.to!string
                          ~ "ms): " ~ tm.prop ~ " matches the engine and differs from t=0\"";
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
                          ~ " && ! diff -q " ~ ourOut ~ " " ~ ourOut ~ ".noclick > /dev/null"
                          ~ " && echo \"qmltc" ~ tag ~ " " ~ name ~ " (" ~ dc ~ ", click): " ~ ck.prop
                          ~ " matches the engine and differs from no-click\"";
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
                // COMMENT LINES ARE DROPPED FIRST: every token in this file becomes an argument to
                // the fixture, so until now the format could not carry its own licence header — and
                // a format that cannot answer for itself is exactly what forces a path map to
                // exist. The map produced four of this audit's licensing defects.
                auto setArgs = readText(setFile).split("\n")
                    .filter!(l => !l.strip.startsWith("#")).join(" ")
                    .strip.split.map!(a => "\"" ~ a ~ "\"").join(" ");
                // The mutation tokens as a LIST — the sh side quotes each because `method()` is
                // shell syntax there; through Invoke-Proc they are arguments and need no quoting.
                auto setList = readText(setFile).split("\n")
                    .filter!(l => !l.strip.startsWith("#")).join(" ").strip.split.array;
                string cmd2;
                version (Windows)
                    cmd2 = psInline(root, "qmltc" ~ tag ~ "-" ~ name ~ "-set-" ~ dc, [
                        psRedirect(toolBin, ["--labels", qmlFile, name] ~ qmlmapArgs, props, false, true),
                        psRedirect(appBin, setList, a ~ ".set"),
                        psRedirect(oracleBin, [qmlFile] ~ setList ~ ["--props", props], b ~ ".set"),
                        psDiff(a ~ ".set", b ~ ".set", "qmltc " ~ name ~ " (" ~ dc ~ ", setters)"),
                    ], bind.mods);
                else
                    cmd2 = "sh -c '" ~ mkProps ~ "QT_QPA_PLATFORM=offscreen " ~ appBin ~ " " ~ setArgs ~ " > " ~ a ~ ".set"
                        ~ " && QT_QPA_PLATFORM=offscreen " ~ oracleBin ~ " " ~ qmlFile ~ " " ~ setArgs ~ " --props " ~ props ~ " > " ~ b ~ ".set"
                        ~ " && diff " ~ a ~ ".set " ~ b ~ ".set"
                        ~ " && echo \"qmltc " ~ name ~ " (" ~ dc ~ ", setters): $(wc -l < " ~ a ~ ".set) lines match\"'";
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
    auto qmlCxx = pkgCflags(qml.mods) ~ " -std=c++17 " ~ cxxPic() ~ " -O2";
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
        auto link = dc ~ " -of=$out" ~ dSupport(root) ~ " " ~ aotMain ~ " " ~ unitO ~ " " ~ loaderO ~ " -I" ~ qml.genDir
            ~ " -L--gc-sections -L--as-needed -L--start-group -L=" ~ libPathOf(dc) ~ " -L=" ~ shimsPath
            ~ " -L--end-group " ~ pkgLibs(qml.mods);
        auto bin = Target("qmlaot-" ~ dc ~ "-bin", link, [Target(aotMain), unitOT, loaderOT, lib, qml.shims]);
        ts ~= Target.phony("qmlaot-" ~ dc, runOffscreen(root, "$in", "", qml.mods), [bin]);
    }
    return ts;
}

// PHASE 2 of the ladder: an expression qmltc-d cannot turn into D is handed to the engine, and
// with --shadow-dir it is handed over as a document compiled to BYTECODE rather than a source
// string compiled at run time. The script does the whole pipeline and judges it the ordinary way —
// the value dump must equal the engine's — after MOVING the shadow .qml files away, so a run that
// would also pass by reading the source cannot pass here.
// QJsDelegated is the fixture because it exists to delegate: its expression reads a member by a
// name known only at run time, which has no D translation at all.
Target[] shadowAotTargets(string root, QtdBinding quick) {
    auto gen = qmlcachegenPath();
    if (!gen.length) return [];   // no qmlcachegen here -> the AOT path is not testable
    auto script = buildPath(root, "tests", "qmltc", "shadow_aot.sh");
    if (!exists(script)) return [];
    auto qmlFile = buildPath(root, "tests", "qmltc", "quick", "QJsDelegated.qml");
    auto qmlmap = buildPath(quick.genDir, "qmlmap.tsv");
    auto tool = buildPath(quick.bdir, "qmltc-d");
    auto cflags = pkgCflags(quick.mods);
    Target[] ts;
    foreach (dc; DCS) {
        auto outDir = buildPath(quick.bdir, "shadowaot-" ~ dc);
        auto cmd = "sh " ~ script ~ " " ~ tool ~ " " ~ qmlmap ~ " " ~ qmlFile ~ " QJsDelegated "
                 ~ outDir ~ " " ~ quick.bdir ~ " " ~ quick.genDir ~ " " ~ dc ~ " " ~ gen ~ " " ~ cflags;
        ts ~= Target.phony("shadowaot-" ~ dc, cmd,
                           [Target(script), Target(qmlFile), qtdBindLib(quick, dc), quick.shims]);
    }
    // ...and the OUTPUT NOTICE, on the same fixture and for the same reason it was chosen here:
    // QJsDelegated is the one document that exercises every mode the compiler can write source in —
    // a compiled document AND shadows. Round 15 #5 found the notice implemented in xiboca only,
    // and a gate that ran one mode would have missed the shadows, which are written by a different
    // call in a different function and were the last to be fixed.
    auto lgo = buildPath(root, "tests", "license-generated-output.sh");
    // A GENERATED file, not a copied one. This passed `qtmoc.d`, which the generator COPIES from
    // runtime/ verbatim: it carries its own hand-written header and no output-grant block at all.
    // So the drift check between the two generators had an EMPTY reference, and the old one-sided
    // comparison ("require in qmltc-d every chosen line that appears in the sample") was therefore
    // vacuously true — it compared nothing. Round 16 #7 called the comparison weak; with this
    // reference it was absent.
    auto sampleGen = buildPath(quick.genDir, "qt", "quick", "qquickitem.d");
    // ...and the battery that proves that gate bites (its three known-good answers were measured by
    // hand and then existed only in a transcript — the mistake this audit has charged twice).
    auto lgm = buildPath(root, "tests", "license-generated-output-mutations.sh");
    if (exists(lgm) && exists(lgo))
        ts ~= Target.phony("license-generated-output-mutations",
            "sh " ~ lgm ~ " " ~ tool ~ " " ~ qmlFile ~ " " ~ qmlmap ~ " "
            ~ buildPath(root, "tests", "qmltc", "quick") ~ " " ~ sampleGen,
            [Target(lgm), Target(lgo), Target(qmlFile), quick.gen, qmltcTool(root, quick)]);
    if (exists(lgo))
        ts ~= Target.phony("license-generated-output",
            "sh " ~ lgo ~ " " ~ tool ~ " " ~ qmlFile ~ " " ~ qmlmap ~ " "
            ~ buildPath(root, "tests", "qmltc", "quick") ~ " " ~ sampleGen,
            [Target(lgo), Target(qmlFile), quick.gen, qmltcTool(root, quick)]);
    return ts;
}

// The holder unit test compiles the fixed runtime (holder.d + qtd_holder.cpp) with a
// small C++ helper — no xiboca, no binding. Kept as a bespoke target.
Target[] holderTests(string root) {
    auto H = buildPath(root, "runtime", "holder");
    auto here = buildPath(root, "tests", "holder");
    auto cflags = pkgCflags(["Qt6Core"]) ~ " -std=c++17 " ~ cxxPic() ~ " -O2";
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
            dc ~ " -of=$out" ~ dSupport(root) ~ " $in" ~ cxxRuntimeFlag() ~ " " ~ libs,
            [Target(buildPath(here, "holder_test.d")), Target(buildPath(H, "holder.d")), qtd, help]);
        ts ~= Target.phony("holder_test-" ~ dc, runOffscreen(root, "$in", "", ["Qt6Core"]), [app]);
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
    if (!qtHasModule("Qt6Qml")) return [];
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
        "clang++ " ~ pkgCflags(["Qt6Qml", "Qt6Gui", "Qt6Core"]) ~ " -std=c++17 " ~ cxxPic() ~ " -O2 "
        ~ "-DQTD_QMLVALUES_NO_MAIN -c " ~ oracleCpp ~ " -o $out", [Target(oracleCpp)]);

    Target[] ts;
    auto corpus = dirEntries(dir, "*.qml", SpanMode.shallow).map!(e => e.name).array;
    corpus.sort();
    foreach (dc; DCS) {
        auto dcLibs = pkgLibs(bind.mods) ~ cxxRuntimeFlag();
        auto dcLink = " -I" ~ bind.genDir ~ " -I" ~ dir
            ~ " -L--gc-sections -L--as-needed -L--start-group -L=" ~ buildPath(bind.bdir, "libbinding_" ~ dc ~ ".a")
            ~ " -L=" ~ buildPath(bind.bdir, "libshims.a") ~ " -L--end-group " ~ dcLibs;

        // 1) the type REGISTRY: a D driver writes the CTFE .qmltypes of the app's types.
        auto genBin = buildPath(bind.bdir, "dtypes-gen-" ~ dc);
        // Shared by every qmltcd- target -> guard it, like the oracle and qmltc-d itself.
        auto genCmd = dc ~ " -of=" ~ genBin ~ " " ~ buildPath(dir, "qmltypes_gen.d") ~ " " ~ appD ~ dcLink;
        auto gen = Target(genBin, guarded(genBin ~ ".lock", genCmd, null, genBin,
            [appD, buildPath(dir, "qmltypes_gen.d"), buildPath(bind.bdir, "libbinding_" ~ dc ~ ".a")]),
            [Target(buildPath(dir, "qmltypes_gen.d")), Target(appD), qtdBindLib(bind, dc), bind.shims]);
        auto typesFile = buildPath(bind.bdir, "AppTypes-" ~ dc ~ ".qmltypes");
        auto types = Target(typesFile, "$in $out", [gen]);

        // 2) the ORACLE: D main (registers the types) + the C++ engine half.
        auto oracleBin = buildPath(bind.bdir, "qmlvalues-d-" ~ dc);
        auto oracle = Target(oracleBin, guarded(oracleBin ~ ".lock",
            dc ~ " -of=" ~ oracleBin ~ " " ~ buildPath(here, "qtd_qmlvalues_d.d") ~ " " ~ appD ~ " " ~ oracleObj ~ dcLink, null,
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
            auto appCmd = dc ~ " -of=$out" ~ dSupport(root) ~ " " ~ genD ~ " " ~ appD ~ dcLink;
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
                ~ " && diff " ~ a ~ " " ~ b
                ~ " && echo \"qmltcd " ~ name ~ " (" ~ dc ~ "): $(wc -l < " ~ a ~ ") value lines match the engine\"'",
                [app, oracle, tool]);
            // 5) LIVE-binding differential: mutate both, re-diff. A binding that lost its
            //    connection to the BASE type's notify signal diverges here.
            auto setFile = buildPath(dir, name ~ ".set");
            if (exists(setFile)) {
                // Quote each token: a mutation may be `method()`, and bare parens are shell syntax.
                // COMMENT LINES ARE DROPPED FIRST: every token in this file becomes an argument to
                // the fixture, so until now the format could not carry its own licence header — and
                // a format that cannot answer for itself is exactly what forces a path map to
                // exist. The map produced four of this audit's licensing defects.
                auto setArgs = readText(setFile).split("\n")
                    .filter!(l => !l.strip.startsWith("#")).join(" ")
                    .strip.split.map!(a => "\"" ~ a ~ "\"").join(" ");
                ts ~= Target.phony("qmltcd-" ~ name ~ "-set-" ~ dc,
                    "sh -c '" ~ mkProps ~ "QT_QPA_PLATFORM=offscreen " ~ appBin ~ " " ~ setArgs ~ " > " ~ a ~ ".set"
                    ~ " && QT_QPA_PLATFORM=offscreen " ~ oracleBin ~ " " ~ qmlFile ~ " " ~ setArgs
                    ~ " --props " ~ props ~ " > " ~ b ~ ".set && diff " ~ a ~ ".set " ~ b ~ ".set"
                    ~ " && echo \"qmltcd " ~ name ~ " (" ~ dc ~ ", setters): $(wc -l < " ~ a ~ ".set) lines match\"'",
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
    if (!qtHasModule("Qt6Qml")) return [];
    auto dir = buildPath(root, "tests", "qmltc", "cpptypes");
    // ASK QT WHERE ITS TOOLS ARE, and refuse to disappear quietly if they are missing (round 17 #3).
    // These paths were hardcoded as `/usr/lib/qt6/<tool>`, which is this distribution's layout and
    // not Debian's: Ubuntu 24.04 installs both under `libexec/`. There the two `exists()` checks
    // failed, this function returned an empty list, and an entire family of targets — the ONLY one
    // that compiles Qt's own C++ QML types — simply did not exist. The CI floor counts `qmltc*`
    // targets and would have been satisfied by the other families, so absence of capability would
    // have read as green. That is the exact shape the libsample canaries were built to prevent.
    auto libexec = () {
        // try/catch per candidate: std.process.execute THROWS when the binary is absent rather than
        // returning non-zero, and `qtpaths6` is absent on this machine — the first probe aborted the
        // whole graph. A discovery loop has to survive not finding things.
        foreach (q; ["qtpaths6", "qmake6", "qtpaths", "qmake"]) {
            try {
                auto r = execute([q, q.startsWith("qtpaths") ? "--query" : "-query", "QT_INSTALL_LIBEXECS"]);
                if (r.status == 0 && r.output.strip.length) return r.output.strip;
            } catch (Exception) { /* not installed under this name; try the next */ }
        }
        // ...and the probe, which knows where Qt is even when none of those four is on PATH. On
        // Windows they are not: Qt's bin is not added to PATH by its installer, so every one of the
        // four probes above fails and libexec came back empty — reported as "QT_INSTALL_LIBEXECS=
        // unknown" while moc.exe sat in the directory the probe would have named.
        return qtLibexecDir("Qt6Qml");
    }();
    string findTool(string name) {
        // Qt puts its tools in libexec on Linux and in bin on Windows, where they also carry .exe —
        // and the two hardcoded paths below are a Linux distribution's layout, kept as a fallback
        // for when pkg-config does not report libexecdir.
        auto n = exeName(name);
        foreach (c; [buildPath(libexec, n), "/usr/lib/qt6/libexec/" ~ n, "/usr/lib/qt6/" ~ n])
            if (c.length > n.length && exists(c)) return c;
        return "";
    }
    auto moc = findTool("moc"), reg = findTool("qmltyperegistrar");
    if (!exists(dir)) return [];
    // Qt6Qml IS installed (checked above). If its tools cannot be found, that is a broken or
    // unexpected installation, and saying so beats building nothing and reporting success.
    if (!moc.length || !reg.length)
        throw new Exception("Qt6Qml is installed but its tools were not found (moc="
            ~ (moc.length ? moc : "MISSING") ~ ", qmltyperegistrar=" ~ (reg.length ? reg : "MISSING")
            ~ "; QT_INSTALL_LIBEXECS=" ~ (libexec.length ? libexec : "unknown") ~ "). The qmltc C++"
            ~ " corpus cannot be built, and skipping it silently is how absence of capability"
            ~ " becomes a green build.");
    auto bind = qtdBinding(root, "spec_cxx_corpustypes.json", ["Qt6Qml"]);
    auto here = buildPath(root, "tests", "qmltc");
    auto tool = qmltcTool(root, qmlBind);          // one qmltc-d, shared with the other suites
    auto toolBin = buildPath(qmlBind.bdir, "qmltc-d");
    // testprivateproperty.h includes <private/qobject_p.h>, so the vendored corpus needs Qt's
    // private include dirs — for moc, for qmltyperegistrar and for the C++ compile alike.
    auto privInc = (modulePrivateFlags(pkgCflags(["Qt6Core"]), "QtCore")
                    ~ modulePrivateFlags(pkgCflags(["Qt6Qml"]), "QtQml")).join(" ");
    auto cflags = pkgCflags(["Qt6Qml", "Qt6Gui", "Qt6Core"]) ~ " -std=c++17 " ~ cxxPic() ~ " -O2 " ~ privInc;
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
            moc ~ " " ~ pkgCflags(["Qt6Qml", "Qt6Core"]) ~ " " ~ privInc ~ " --output-json -o " ~ mocCpp ~ " " ~ hdr, null,
            mocCpp, [hdr]), [Target(hdr)]);
        mocObjs ~= Target(buildPath(bind.bdir, "moc_" ~ stem ~ ".o"),
            "clang++ " ~ cflags ~ " -I" ~ dir ~ " -c " ~ mocCpp ~ " -o $out", [m]);
    }
    // 2) qmltyperegistrar over the moc JSON -> the registration .cpp AND the .qmltypes registry.
    auto regCpp = buildPath(bind.bdir, "qmltyperegistrations.cpp");
    auto typesFile = buildPath(bind.bdir, "QmltcTests.qmltypes");
    auto regT = Target(regCpp, guarded(regCpp ~ ".lock",
        reg ~ " --generate-qmltypes=" ~ typesFile ~ " --import-name=QmltcTests"
        ~ " --major-version=1 --minor-version=0 -o " ~ regCpp ~ " " ~ jsons.join(" "), null,
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
    auto lib = Target(typesLib, arCmd("$out", "$in"), mocObjs ~ [regObj] ~ implObjs);

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
        ~ qtLibsOf(["Qt6Qml", "Qt6Gui", "Qt6Core"]),
        null, oracleBin, [oracleCpp, typesLib]), [Target(oracleCpp), lib]);

    // A bound root sets properties before any QGuiApplication exists; the helper provides one.
    auto appObj = buildPath(bind.bdir, "qtd_qmltc_app.o");
    auto appHelper = Target(appObj, guarded(appObj ~ ".lock",
        "clang++ " ~ cflags ~ " -c " ~ buildPath(here, "qtd_qmltc_app.cpp") ~ " -o " ~ appObj, null,
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
                dc ~ " -of=$out" ~ dSupport(root) ~ " " ~ genD ~ " " ~ appObj ~ " -I" ~ bind.genDir
                ~ " -L--gc-sections -L--as-needed -L--start-group -L=" ~ buildPath(bind.bdir, "libbinding_" ~ dc ~ ".a")
                ~ " -L=" ~ buildPath(bind.bdir, "libshims.a") ~ " -L--end-group"
                // --whole-archive on the types: their QQmlModuleRegistration is a static object
                // nothing references, and without it the module isn't registered in this process —
                // so an ATTACHED object (looked up through Qt's QML type registry) comes back null.
                ~ " -L--whole-archive -L=" ~ typesLib ~ " -L--no-whole-archive "
                ~ pkgLibs(["Qt6Qml", "Qt6Gui", "Qt6Core"]) ~ cxxRuntimeFlag();
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
                ~ " && diff " ~ a ~ " " ~ b
                ~ " && echo \"qmltcc " ~ name ~ " (" ~ dc ~ "): $(wc -l < " ~ a ~ ") lines match\"'", [app, oracle, tool]);
            auto setFile = buildPath(dir, name ~ ".set");
            if (exists(setFile)) {
                // Quote each token: a mutation may be `method()`, and bare parens are shell syntax.
                // COMMENT LINES ARE DROPPED FIRST: every token in this file becomes an argument to
                // the fixture, so until now the format could not carry its own licence header — and
                // a format that cannot answer for itself is exactly what forces a path map to
                // exist. The map produced four of this audit's licensing defects.
                auto setArgs = readText(setFile).split("\n")
                    .filter!(l => !l.strip.startsWith("#")).join(" ")
                    .strip.split.map!(a => "\"" ~ a ~ "\"").join(" ");
                ts ~= Target.phony("qmltcc-" ~ name ~ "-set-" ~ dc,
                    "sh -c '" ~ mkProps ~ "QT_QPA_PLATFORM=offscreen " ~ appBin ~ " " ~ setArgs ~ " > " ~ a ~ ".set"
                    ~ " && QT_QPA_PLATFORM=offscreen " ~ oracleBin ~ " " ~ qmlFile ~ " " ~ setArgs
                    ~ " --props " ~ props ~ " --attached-uri QmltcTests > " ~ b ~ ".set && diff "
                    ~ a ~ ".set " ~ b ~ ".set"
                    ~ " && echo \"qmltcc " ~ name ~ " (" ~ dc ~ ", setters): $(wc -l < " ~ a ~ ".set) lines match\"'",
                    [app, oracle, tool]);
            }
        }
    }
    return ts;
}
