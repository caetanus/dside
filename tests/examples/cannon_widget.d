// merge moc+trampolim: um QWidget subclassado EM D que sobrescreve paintEvent E
// tem sinais/slots próprios (o padrão CannonField do tutorial). `mixin QtdWidget!
// QWidget` liga os dois: overrides de virtual -> métodos D (via o trampolim qtvirt)
// e Signal/@Slot -> um meta-objeto runtime anexado. `new` cria tudo.
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qpaintevent, qt.widgets.qtvirt;
import qtmoc;
import cxxrt, std.stdio;
pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(QApplication, ref int, char**, int);
extern(C) void qtd_force_paint(void*);   // render síncrono (grab) — emitido no qtvirt

@QObject class CannonField {
    mixin QtdWidget!QWidget;                 // subclasse QWidget + moc, num objeto só
    Signal!int angleChanged;                 // sinal próprio
    private int _angle;
    int paints = 0, lastAngle = -1;
    @Slot void setAngle(int a) { if (a != _angle) { _angle = a; angleChanged.emit(a); } }
    @Slot void onAngle(int a)  { lastAngle = a; }
    void paintEvent(QPaintEvent e) { paints++; }   // override do virtual do QWidget
}

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "cw\0".ptr, null];
    auto app = cast(QApplication) __cpp_new(__traits(classInstanceSize, QApplication));
    __qapp_ctor(app, argc, argv.ptr, 0);

    auto cf = new CannonField();             // o mixin cria o trampolim + anexa o moc
    connectMeta(cf, "angleChanged(int)", cf, "onAngle(int)");
    cf.setAngle(30);                         // -> angleChanged(30) -> onAngle
    assert(cf.lastAngle == 30, "sinal próprio da subclasse não chegou ao slot");

    qtd_force_paint(cf.__qtdObj());          // dispara paintEvent -> override D
    assert(cf.paints > 0, "paintEvent override não disparou");

    writefln("cannon_widget OK: CannonField : QWidget @QObject — setAngle->angleChanged->onAngle=%d, paintEvent=%d",
        cf.lastAngle, cf.paints);
}
