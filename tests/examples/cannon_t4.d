// PySide cannon/t4.py — MyWidget(QWidget) container. MyWidget overrides nothing,
// so a QWidget with children is behaviorally identical (composition).
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qpushbutton, qt.widgets.qfont;
import qt.widgets.qrect, qt.widgets.qtimer, qt.widgets.qstring;
import cxxrt, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(QApplication, ref int, char**, int);

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "t4\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);

    auto widget = QWidget_new();
    widget.setFixedSize(200, 120);
    auto lbl = qstr("Quit");
    auto quit = QPushButton_new(lbl, widget);
    auto geo = QRect(62, 40, 62 + 75 - 1, 40 + 30 - 1); quit.setGeometry(geo);
    auto font = QFont_new("Times", 18, cast(int) QFont.Weight.Bold, false); quit.setFont(font);
    quit.connectClicked((bool) { QApplication.quit(); });
    widget.show();

    auto t = QTimer_new();
    t.connectTimeout(() { QApplication.quit(); }); t.start(50);
    QApplication.exec();
    writeln("cannon/t4 OK: QWidget container + child button");
}
