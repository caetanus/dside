import qt.widgets.qapplication, qt.widgets.qmainwindow, qt.widgets.qstring;
import cxxrt, uiform, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern (C++) void __qapp_ctor(QApplication, ref int, char**, int);
mixin(uiForm(import("mainwin.ui")));
void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "uic\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);
    auto root = new QMainWindow();
    Ui_MainWindow ui; ui.setupUi(root);
    assert(ui.centralwidget !is null && ui.menubar !is null && ui.statusbar !is null && ui.toolbar !is null);
    assert(ui.bodyLabel.text().toString() == "Hello");
    assert(ui.menuFile.title().toString() == "File");
    assert(ui.actionOpen.text().toString() == "Open");
    assert(ui.actionQuit.text().toString() == "Quit");
    writeln("uic OK: QMainWindow chrome -> menubar+menu+actions+toolbar+statusbar+central, typed");
}
