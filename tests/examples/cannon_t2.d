// PySide widgets/tutorials/cannon/t2.py — QFont + the clicked(bool) signal (a
// signal WITH an argument, now marshaled to the D delegate).
import qt.widgets.qapplication, qt.widgets.qpushbutton, qt.widgets.qfont;
import qt.widgets.qsize, qt.widgets.qtimer, qt.widgets.qstring;
import cxxrt, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(QApplication, ref int, char**, int);

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "t2\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);

    auto lbl = qstr("Quit");
    auto quit = QPushButton_new(lbl, null);
    auto sz = QSize(75, 30);
    quit.resize(sz);
    auto font = QFont("Times", 18, cast(int) QFont.Weight.Bold, false);   // value-type ctor + string overload
    quit.setFont(font);
    quit.connectClicked((bool checked) { writeln("  clicked(", checked, ")"); QApplication.quit(); });
    quit.show();

    // headless (no real click): quit after a tick
    auto t = QTimer_new();
    t.connectTimeout(() { writeln("  (headless) tick -> quit"); QApplication.quit(); });
    t.start(50);
    QApplication.exec();
    writeln("cannon/t2 OK: QFont value-type ctor + clicked(bool) signal-with-arg");
}
