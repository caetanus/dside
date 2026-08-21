// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// PySide cannon t8: the custom LCDRange widget (QSlider + QLCDNumber) that re-emits
// its OWN valueChanged(int). No subclass trampoline: LCDRange is a D @QObject class
// (for its signal) that COMPOSES a root QWidget with the children. Proves the chain:
// built-in slider.valueChanged -> D slot -> re-emit custom -> another D slot.
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qlcdnumber, qt.widgets.qslider;
import qt.widgets.qvboxlayout, qt.widgets.orientation, qt.widgets.qtimer;
import qtmoc;
import cxxrt, std.stdio;
import appctor : QAPP_CTOR;
pragma(mangle, QAPP_CTOR) extern(C++) void __qapp_ctor(QApplication, ref int, char**, int);

@QObject class LCDRange {
    QWidget root; QLCDNumber lcd; QSlider slider;
    Signal!int valueChanged;
    this() {
        root = new QWidget();
        lcd = new QLCDNumber(2u, null);
        slider = new QSlider(Orientation.Horizontal, null);
        slider.setRange(0, 99); slider.setValue(0);
        auto lay = new QVBoxLayout(root);
        lay.addWidget(lcd); lay.addWidget(slider);
    }
    @Slot void onSlider(int v) { lcd.display(v); valueChanged.emit(v); }  // slider -> lcd + re-emit
    @Slot void setValue(int v) { slider.setValue(v); }                    // public API (fires onSlider)
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
    // internal wiring (after newQObject: the LCDRange meta-object already exists)
    connectMeta(r.slider, "valueChanged(int)", r, "onSlider(int)");
    r.root.show();

    auto sink = newQObject!Sink();
    connectMeta(r, "valueChanged(int)", sink, "onValue(int)");   // custom D -> custom D

    r.setValue(37);   // -> slider.setValue -> slider.valueChanged -> onSlider -> lcd.display + valueChanged.emit -> sink
    assert(r.lcd.intValue() == 37, "built-in slider -> D slot did not update the LCD");
    assert(r.value() == 37, "value() does not reflect the slider");
    assert(sink.last == 37, "re-emit of the custom valueChanged did not reach the sink");

    auto t = new QTimer();
    t.connectTimeout(() { QApplication.quit(); }); t.start(50);
    QApplication.exec();
    writefln("cannon/t8 OK: LCDRange composed — slider(built-in) -> onSlider(D) -> re-emit -> sink(D)=%d", sink.last);
}
