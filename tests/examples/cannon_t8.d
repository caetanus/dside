// PySide cannon t8: o widget custom LCDRange (QSlider + QLCDNumber) que re-emite
// seu PRÓPRIO valueChanged(int). Sem trampolim de subclasse: LCDRange é uma classe
// D @QObject (pro seu sinal) que COMPÕE um QWidget root com os filhos. Prova a
// cadeia: slider built-in.valueChanged -> slot D -> re-emit custom -> outro slot D.
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qlcdnumber, qt.widgets.qslider;
import qt.widgets.qvboxlayout, qt.widgets.orientation, qt.widgets.qtimer;
import qtmoc;
import cxxrt, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(QApplication, ref int, char**, int);

@QObject class LCDRange {
    QWidget root; QLCDNumber lcd; QSlider slider;
    Signal!int valueChanged;
    this() {
        root = QWidget_new();
        lcd = QLCDNumber_new(2u, null);
        slider = QSlider_new(Orientation.Horizontal, null);
        slider.setRange(0, 99); slider.setValue(0);
        auto lay = QVBoxLayout_new(root);
        lay.addWidget(lcd); lay.addWidget(slider);
    }
    @Slot void onSlider(int v) { lcd.display(v); valueChanged.emit(v); }  // slider -> lcd + re-emit
    @Slot void setValue(int v) { slider.setValue(v); }                    // API pública (dispara onSlider)
    int value() { return slider.value(); }
}

@QObject class Sink {
    int last = -1;
    @Slot void onValue(int v) { last = v; }
}

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "t8\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);

    auto r = newQObject!LCDRange();
    // wiring interno (depois de newQObject: o meta-objeto do LCDRange já existe)
    connectMeta(cast(void*) r.slider, "valueChanged(int)", r, "onSlider(int)");
    r.root.show();

    auto sink = newQObject!Sink();
    connectMeta(r, "valueChanged(int)", sink, "onValue(int)");   // custom D -> custom D

    r.setValue(37);   // -> slider.setValue -> slider.valueChanged -> onSlider -> lcd.display + valueChanged.emit -> sink
    assert(r.lcd.intValue() == 37, "slider built-in -> slot D não atualizou o LCD");
    assert(r.value() == 37, "value() não reflete o slider");
    assert(sink.last == 37, "re-emit do custom valueChanged não chegou ao sink");

    auto t = QTimer_new();
    t.connectTimeout(() { QApplication.quit(); }); t.start(50);
    QApplication.exec();
    writefln("cannon/t8 OK: LCDRange composto — slider(built-in) -> onSlider(D) -> re-emit -> sink(D)=%d", sink.last);
}
