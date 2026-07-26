// PySide cannon/t5.py — QSlider.valueChanged -> QLCDNumber.display (built-in
// signal -> built-in slot, expressed as a typed D delegate).
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qpushbutton, qt.widgets.qfont;
import qt.widgets.qlcdnumber, qt.widgets.qslider, qt.widgets.qvboxlayout, qt.widgets.orientation;
import qt.widgets.qtimer, qt.widgets.qstring;
import cxxrt, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(QApplication, ref int, char**, int);

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "t5\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);

    auto widget = QWidget_new();
    auto lbl = qstr("Quit");
    auto quit = QPushButton_new(lbl, null);
    auto font = QFont("Times", 18, cast(int) QFont.Weight.Bold, false); quit.setFont(font);
    auto lcd = QLCDNumber_new(2u, null);
    auto slider = QSlider_new(Orientation.Horizontal, null);
    slider.setRange(0, 99);
    slider.setValue(0);

    quit.connectClicked((bool) { QApplication.quit(); });
    __gshared int lastLcd = -1;
    slider.connectValueChanged((int v) { lcd.display(v); lastLcd = v; });   // signal(int) -> slot

    auto layout = QVBoxLayout_new(widget);
    layout.addWidget(quit);
    layout.addWidget(lcd);
    layout.addWidget(slider);
    widget.show();

    slider.setValue(42);                       // fires valueChanged(42) -> delegate -> lcd.display
    assert(lastLcd == 42, "valueChanged(int) delegate did not receive the value");

    auto t = QTimer_new();
    t.connectTimeout(() { QApplication.quit(); }); t.start(50);
    QApplication.exec();
    writefln("cannon/t5 OK: slider.valueChanged(int) -> lcd.display, got %d", lastLcd);
}
