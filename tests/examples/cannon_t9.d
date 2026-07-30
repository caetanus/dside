// Q_PROPERTY in the runtime meta-object: a D @QObject exposes @Property int value with
// a notify signal. Writing the property (via QVariant/setProperty) sets the D field
// AND emits the notify, which here is connected to the REAL display(int) slot of a QLCDNumber.
// This is the basis for property bindings / QML / QDataWidgetMapper over D objects.
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qlcdnumber;
import qt.widgets.qvboxlayout, qt.widgets.qtimer;
import qtmoc;
import cxxrt, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(QApplication, ref int, char**, int);

@QObject class Dial {
    Signal!int valueChanged;
    @Property("valueChanged") int value = 0;   // Q_PROPERTY(int value NOTIFY valueChanged)
}

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "t9\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);

    auto w = new QWidget();
    auto lcd = new QLCDNumber(3u, null);
    auto lay = new QVBoxLayout(w); lay.addWidget(lcd); w.show();

    auto dial = newQObject!Dial();
    connectMeta(dial, "valueChanged(int)", lcd, "display(int)");  // notify -> Qt slot

    dial.setProp("value", 88);                  // WriteProperty -> D field + emits valueChanged
    assert(dial.value == 88, "property did not set the D field");
    assert(dial.propInt("value") == 88, "ReadProperty did not read the D field");
    assert(lcd.intValue() == 88, "property notify did not reach the LCD slot");

    auto t = new QTimer();
    t.connectTimeout(() { QApplication.quit(); }); t.start(50);
    QApplication.exec();
    writefln("cannon/t9 OK: @Property int value (NOTIFY) -> QLCDNumber.display, lcd=%d", lcd.intValue());
}
