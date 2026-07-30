// PySide widgets/tutorials/cannon/t3.py — a QWidget window with a child QPushButton.
import qt.widgets.qapplication, qt.widgets.qpushbutton, qt.widgets.qwidget, qt.widgets.qfont;
import qt.widgets.qsize, qt.widgets.qrect, qt.widgets.qtimer, qt.widgets.qstring;
import cxxrt, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(QApplication, ref int, char**, int);

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "t3\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);

    auto window = new QWidget();
    auto wsz = QSize(200, 120); window.resize(wsz);

    auto lbl = qstr("Quit");
    auto quit = new QPushButton(lbl, window);          // child of window
    auto font = QFont("Times", 18, cast(int) QFont.Weight.Bold, false);
    quit.setFont(font);
    // setGeometry(x,y,w,h) is inline (builds a QRect); construct the QRect directly
    // (fields x1,y1,x2,y2) — QRect(10,40, w=180,h=40) => x2=10+180-1, y2=40+40-1.
    auto geo = QRect(10, 40, 10 + 180 - 1, 40 + 40 - 1);
    quit.setGeometry(geo);
    quit.connectClicked((bool) { QApplication.quit(); });

    window.show();
    auto t = new QTimer();
    t.connectTimeout(() { QApplication.quit(); }); t.start(50);
    QApplication.exec();
    writeln("cannon/t3 OK: QWidget window + parented QPushButton + setGeometry(int x4)");
}
