// Q_PROPERTY no meta-objeto runtime: um @QObject D expõe @Property int value com
// sinal de notify. Escrever a propriedade (via QVariant/setProperty) seta o campo D
// E emite o notify, que aqui está conectado ao slot REAL display(int) de um QLCDNumber.
// É a base pra property bindings / QML / QDataWidgetMapper sobre objetos D.
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

    auto w = QWidget_new();
    auto lcd = QLCDNumber_new(3u, null);
    auto lay = QVBoxLayout_new(w); lay.addWidget(lcd); w.show();

    auto dial = newQObject!Dial();
    connectMeta(dial, "valueChanged(int)", cast(void*) lcd, "display(int)");  // notify -> Qt slot

    dial.setProp("value", 88);                  // WriteProperty -> campo D + emite valueChanged
    assert(dial.value == 88, "propriedade não setou o campo D");
    assert(dial.propInt("value") == 88, "ReadProperty não leu o campo D");
    assert(lcd.intValue() == 88, "notify da propriedade não chegou ao slot do LCD");

    auto t = QTimer_new();
    t.connectTimeout(() { QApplication.quit(); }); t.start(50);
    QApplication.exec();
    writefln("cannon/t9 OK: @Property int value (NOTIFY) -> QLCDNumber.display, lcd=%d", lcd.intValue());
}
