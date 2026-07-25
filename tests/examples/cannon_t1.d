// PySide example widgets/tutorials/cannon/t1.py — "smuggled" to D against the
// generated Qt bindings. A real QApplication + QPushButton, run headless
// (QT_QPA_PLATFORM=offscreen) with a single-shot QTimer to quit the loop.
import qt.widgets.qapplication, qt.widgets.qpushbutton;
import qt.widgets.qsize, qt.widgets.qtimer, qt.widgets.qstring;
import cxxrt, std.stdio;

// QApplication(int&, char**, int) — the char** ctor isn't auto-bound; call it directly.
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(QApplication, ref int, char**, int);

void main() {
    __gshared int argc = 1;
    __gshared char*[2] argv = [cast(char*) "t1\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);

    auto title = qstr("Hello world!");
    auto hello = QPushButton_new(title, null);
    auto sz = QSize(100, 30);
    hello.resize(sz);
    hello.show();

    // quit the (offscreen) event loop shortly after it starts
    auto timer = QTimer_new();

    timer.connectTimeout(() { writeln("  event loop running -> quit"); QApplication.quit(); });
    timer.start(50);

    auto rc = QApplication.exec();
    writeln("cannon/t1 OK: real Qt widget app ran headless and exited, rc=", rc);
}
