// moc/CTFE: um QObject DEFINIDO EM D emite seu PRÓPRIO sinal, conectado ao slot
// REAL display(int) de um QLCDNumber built-in. É o pulo do gato do t6 do PySide
// (LCDRange emite valueChanged) sem moc: o meta-objeto do Thermostat é construído
// em runtime (QMetaObjectBuilder) e connectMeta liga custom-signal -> Qt-slot.
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qlcdnumber;
import qt.widgets.qvboxlayout, qt.widgets.qtimer;
import qtmoc;
import cxxrt, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(QApplication, ref int, char**, int);

@QObject class Thermostat {
    Signal!int temperatureChanged;
    private int _t;
    @Slot void setTemperature(int t) {
        if (t != _t) { _t = t; temperatureChanged.emit(t); }   // emite o custom signal
    }
}

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "t6\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);

    auto widget = QWidget_new();
    auto lcd = QLCDNumber_new(3u, null);
    auto layout = QVBoxLayout_new(widget);
    layout.addWidget(lcd);
    widget.show();

    auto thermo = newQObject!Thermostat();     // constrói o meta-objeto em runtime
    // custom signal (D) -> slot built-in (Qt): o receiver é o QObject cru do lcd.
    connectMeta(thermo, "temperatureChanged(int)", cast(void*) lcd, "display(int)");

    thermo.setTemperature(42);                  // dispara temperatureChanged(42) -> lcd.display(42)
    assert(lcd.intValue() == 42, "custom signal -> Qt slot não atualizou o LCD");

    auto t = QTimer_new();
    t.connectTimeout(() { QApplication.quit(); }); t.start(50);
    QApplication.exec();
    writefln("cannon/t6 OK: @QObject D custom signal -> QLCDNumber.display, lcd=%d", lcd.intValue());
}
