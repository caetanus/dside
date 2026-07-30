import qt.widgets.qapplication, qt.widgets.qmainwindow;
import cxxrt, uiform, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern (C++) void __qapp_ctor(QApplication, ref int, char**, int);
mixin(uiForm(import("hello.ui")));
void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "uic\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);
    auto root = new QMainWindow();
    Ui_MainWindow ui; ui.setupUi(root);
    writeln("uic OK: real corpus hello_speak/mainwindow.ui (", __traits(allMembers, Ui_MainWindow).length, " members) built + ran");
}
