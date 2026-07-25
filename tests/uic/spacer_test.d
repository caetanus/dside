import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qstring;
import cxxrt, uiform, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern (C++) void __qapp_ctor(QApplication, ref int, char**, int);
mixin(uiForm(import("spacer.ui")));
void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "uic\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);
    auto root = QWidget_new();
    Ui_SpacerForm ui; ui.setupUi(root);
    assert(ui.leftBtn !is null && ui.rightBtn !is null && ui.hSpacer !is null);
    assert(ui.leftBtn.text().toString() == "Left" && ui.rightBtn.text().toString() == "Right");
    writeln("uic OK: QSpacerItem in a box layout -> QSpacerItem_new + addSpacerItem, buttons typed");
}
