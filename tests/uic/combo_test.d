import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qstring;
import cxxrt, uiform, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern (C++) void __qapp_ctor(QApplication, ref int, char**, int);
mixin(uiForm(import("combo.ui")));
void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "uic\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);
    auto root = new QWidget();
    Ui_ComboForm ui; ui.setupUi(root);
    assert(ui.modeCombo !is null);
    assert(ui.modeCombo.count() == 3, "combo should have 3 items");
    assert(ui.modeCombo.itemText(0).toString() == "Serial");
    assert(ui.modeCombo.itemText(2).toString() == "UDP");
    writeln("uic OK: QComboBox items via addItem -> count=", ui.modeCombo.count(), " [Serial/TCP/UDP]");
}
