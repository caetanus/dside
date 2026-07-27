import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qpaintevent, qt.widgets.qtvirt;
import qtmoc, cxxrt, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(void* self, ref int, char**, int);
extern(C) void qtd_force_paint(void*);
@QObject class CannonField {
    mixin QtdWidget!QWidget;
    Signal!int angleChanged;
    private int _angle;
    int paints = 0, lastAngle = -1;
    @Slot void setAngle(int a) { if (a != _angle) { _angle = a; angleChanged.emit(a); } }
    @Slot void onAngle(int a)  { lastAngle = a; }
    void paintEvent(QPaintEvent e) { paints++; }
}
void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "cw\0".ptr, null];
    auto raw = __cpp_new(__QApplication_size); __qapp_ctor(raw, argc, argv.ptr, 0);
    auto app = QApplication.wrap(raw);
    auto cf = new CannonField();
    connectMeta(cf, "angleChanged(int)", cf, "onAngle(int)");
    cf.setAngle(30);
    assert(cf.lastAngle == 30, "own signal -> slot");
    qtd_force_paint(cf.__qtdObj());
    assert(cf.paints > 0, "paintEvent override");

    // critics r8 #2, SECOND carrier: the QtdWidget trampoline announces className "CannonField"
    // (its attached runtime metaobject). qt_metacast must honor its OWN name before delegating to
    // QWidget — the generated trampoline now checks qtd_moc_classmatch first.
    void* qw = cf.__qtdObj();
    assert(qtd_metacast(qw, "CannonField\0".ptr) is qw, "trampoline qt_metacast(self-name) must be this");
    assert(qtd_metacast(qw, "QWidget\0".ptr) !is null, "trampoline must still cast to base QWidget");
    assert(qtd_metacast(qw, "Bogus\0".ptr) is null, "trampoline unknown cast must be null");

    writefln("cannon_widget OK: setAngle->angleChanged->onAngle=%d, paintEvent=%d", cf.lastAngle, cf.paints);
}
