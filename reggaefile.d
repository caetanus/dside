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
import std.array : array, replace;
import std.algorithm : map, filter, sort;
import std.process : execute;

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
    auto qml = qtdBinding(root, "spec_cxx_qml.json", ["Qt6Qml", "Qt6Gui"]);
    auto qmlExtra = buildPath(root, "runtime", "qrc", "qrc.d")
        ~ " -I" ~ buildPath(root, "runtime", "qrc") ~ " -J=" ~ buildPath(root, "tests", "qml");
    foreach (dc; DCS)
        all ~= qtdTest("qml-" ~ dc, t("qml", "backend_test.d"), qml, dc, qmlExtra);

    // --- holder lifetime layer, unit-tested in isolation (no generated binding) ---
    all ~= holderTests(root);

    // --- shiboken libsample corner cases (skipped if the pyside-setup clone is absent) ---
    all ~= libsampleTargets(root, buildNormalizedPath(root, "..", "pyside-setup"));

    return Build(all);
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
