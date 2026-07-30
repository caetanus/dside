import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qstring;
import cxxrt, uiform, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern (C++) void __qapp_ctor(QApplication, ref int, char**, int);
mixin(uiForm(import("tabs.ui")));
void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "uic\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);
    auto root = new QWidget();
    Ui_TabForm ui; ui.setupUi(root);
    assert(ui.tabs !is null && ui.genLabel !is null && ui.advLabel !is null);
    assert(ui.genLabel.text().toString() == "General settings");
    assert(ui.advLabel.text().toString() == "Advanced settings");
    assert(ui.tabs.tabText(0).toString() == "General");
    assert(ui.tabs.tabText(1).toString() == "Advanced");
    writeln("uic OK: QTabWidget (2 pages w/ layouts + margins) -> typed Ui_TabForm, tab titles + labels");
}
