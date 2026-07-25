import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qstring;
import cxxrt, uiform, qrc, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern (C++) void __qapp_ctor(QApplication, ref int, char**, int);
mixin(qrcRegister(import("icons.qrc")));
mixin(uiForm(import("icon.ui")));
void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "uic\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);
    auto root = QWidget_new();
    Ui_IconForm ui; ui.setupUi(root);
    assert(ui.iconBtn !is null);
    assert(ui.iconBtn.text().toString() == "Connect");
    writeln("uic OK: <iconset> resource icon set via CTFE qrc (setIcon ran clean)");
}
