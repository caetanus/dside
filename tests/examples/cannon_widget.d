// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// merge moc+trampoline: a QWidget subclassed IN D that overrides paintEvent AND
// has its own signals/slots (the CannonField pattern from the tutorial). `mixin QtdWidget!
// QWidget` wires both: virtual overrides -> D methods (via the qtvirt trampoline)
// and Signal/@Slot -> an attached runtime meta-object. `new` creates everything.
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qpaintevent, qt.widgets.qtvirt;
import qtmoc;
import cxxrt, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(QApplication, ref int, char**, int);
extern(C) void qtd_force_paint(void*);   // synchronous render (grab) — emitted in qtvirt

@QObject class CannonField {
    mixin QtdWidget!QWidget;                 // subclass QWidget + moc, in a single object
    Signal!int angleChanged;                 // own signal
    private int _angle;
    int paints = 0, lastAngle = -1;
    @Slot void setAngle(int a) { if (a != _angle) { _angle = a; angleChanged.emit(a); } }
    @Slot void onAngle(int a)  { lastAngle = a; }
    void paintEvent(QPaintEvent e) { paints++; }   // override of the QWidget virtual
}

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "cw\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);

    auto cf = new CannonField();             // the mixin creates the trampoline + attaches the moc
    connectMeta(cf, "angleChanged(int)", cf, "onAngle(int)");
    cf.setAngle(30);                         // -> angleChanged(30) -> onAngle
    assert(cf.lastAngle == 30, "the subclass's own signal did not reach the slot");

    qtd_force_paint(cf.__qtdObj());          // fires paintEvent -> D override
    assert(cf.paints > 0, "paintEvent override did not fire");

    writefln("cannon_widget OK: CannonField : QWidget @QObject — setAngle->angleChanged->onAngle=%d, paintEvent=%d",
        cf.lastAngle, cf.paints);
}
