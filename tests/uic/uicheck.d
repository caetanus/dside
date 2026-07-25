// uicheck.d — differential oracle harness: for each .ui, the tree WE build (uiForm +
// setupUi) must serialize identically to the tree QUiLoader.load() builds (Qt's own uic).
// The dump + the oracle load live in qtd_uidump.cpp; we just diff the two strings.
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qdialog, qt.widgets.qmainwindow;
import cxxrt, uiform, qrc, std.stdio, std.string;

pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern (C++) void __qapp_ctor(QApplication, ref int, char**, int);
extern (C) const(char)* qtd_ui_dump(void*);
extern (C) const(char)* qtd_ui_load_and_dump(const(char)*);

// one struct per form (distinct <class> names)
mixin(uiForm(import("dialog.ui")));    // Ui_Dialog
mixin(uiForm(import("login.ui")));     // Ui_LoginForm
mixin(uiForm(import("mainwin.ui")));   // Ui_MainWindow
mixin(uiForm(import("tabs.ui")));      // Ui_TabForm
mixin(uiForm(import("egroup.ui")));    // Ui_ShapeForm
mixin(uiForm(import("spacer.ui")));    // Ui_SpacerForm
mixin(qrcRegister(import("icons.qrc")));  // register :/ui/* so both trees resolve icons
mixin(uiForm(import("icon.ui")));      // Ui_IconForm
mixin(uiForm(import("bookwindow.ui")));  // Ui_BookWindow

__gshared int fails;

void check(T, R)(string path, R root) {
    T ui;
    ui.setupUi(root);
    string ours = qtd_ui_dump(cast(void*) root).fromStringz.idup;
    string oracle = qtd_ui_load_and_dump(path.toStringz).fromStringz.idup;
    if (ours == oracle) {
        writefln("  MATCH     %s", path);
    } else {
        writefln("  MISMATCH  %s", path);
        writeln("--- ours ---\n", ours, "--- oracle ---\n", oracle);
        fails++;
    }
}

void main() {
    __gshared int argc = 1;
    __gshared char*[2] argv = [cast(char*) "uicheck\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);

    check!Ui_Dialog("tests/uic/dialog.ui", QDialog_new());
    check!Ui_LoginForm("tests/uic/login.ui", QWidget_new());
    check!Ui_MainWindow("tests/uic/mainwin.ui", QMainWindow_new());
    check!Ui_TabForm("tests/uic/tabs.ui", QWidget_new());
    check!Ui_ShapeForm("tests/uic/egroup.ui", QWidget_new());
    check!Ui_SpacerForm("tests/uic/spacer.ui", QWidget_new());
    check!Ui_IconForm("tests/uic/icon.ui", QWidget_new());
    check!Ui_BookWindow("tests/uic/bookwindow.ui", QMainWindow_new());

    if (fails) { writefln("uicheck: %d MISMATCH(es)", fails); assert(false); }
    writeln("uicheck OK: our uic == QUiLoader for every .ui");
}
