// dialog_test.d — the CTFE uic against a REAL corpus .ui (PySide's shared-memory
// dialog.ui, a QGridLayout form). Proves grid layout + typed access end to end. Headless.
import qt.widgets.qapplication, qt.widgets.qdialog, qt.widgets.qstring;
import cxxrt, uiform, std.stdio;

pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern (C++) void __qapp_ctor(QApplication, ref int, char**, int);

mixin(uiForm(import("dialog.ui")));   // -> imports + struct Ui_Dialog { setupUi(QDialog); retranslateUi(QDialog); }

void main() {
    __gshared int argc = 1;
    __gshared char*[2] argv = [cast(char*) "uic\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);

    auto root = QDialog_new();
    Ui_Dialog ui;
    ui.setupUi(root);                    // builds the QGridLayout tree

    assert(ui.loadFromFileButton !is null && ui.label !is null
        && ui.loadFromSharedMemoryButton !is null);
    assert(ui.loadFromFileButton.text().toString() == "Load Image From File...");
    assert(ui.loadFromSharedMemoryButton.text().toString() == "Display Image From Shared Memory");

    writeln("uic OK: real corpus dialog.ui (QGridLayout) -> typed Ui_Dialog, 3 widgets, text roundtrip");
}
