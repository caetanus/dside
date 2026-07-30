// moc/CTFE: a QObject DEFINED IN D emits its OWN signal, connected to the REAL
// display(int) slot of a built-in QLCDNumber. This is the key trick of PySide's t6
// (LCDRange emits valueChanged) without moc: the Thermostat meta-object is built
// at runtime (QMetaObjectBuilder) and connectMeta wires custom-signal -> Qt-slot.
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qlcdnumber;
import qt.widgets.qvboxlayout, qt.widgets.qtimer;
import qtmoc;
import cxxrt, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(QApplication, ref int, char**, int);

@QObject class Thermostat {
    Signal!int temperatureChanged;
    private int _t;
    @Slot void setTemperature(int t) {
        if (t != _t) { _t = t; temperatureChanged.emit(t); }   // emit the custom signal
    }
}

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "t6\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);

    auto widget = new QWidget();
    auto lcd = new QLCDNumber(3u, null);
    auto layout = new QVBoxLayout(widget);
    layout.addWidget(lcd);
    widget.show();

    auto thermo = newQObject!Thermostat();     // build the meta-object at runtime
    // custom signal (D) -> built-in slot (Qt): the receiver is the raw QObject of the lcd.
    connectMeta(thermo, "temperatureChanged(int)", lcd, "display(int)");

    thermo.setTemperature(42);                  // fires temperatureChanged(42) -> lcd.display(42)
    assert(lcd.intValue() == 42, "custom signal -> Qt slot did not update the LCD");

    auto t = new QTimer();
    t.connectTimeout(() { QApplication.quit(); }); t.start(50);
    QApplication.exec();
    writefln("cannon/t6 OK: @QObject D custom signal -> QLCDNumber.display, lcd=%d", lcd.intValue());
}
