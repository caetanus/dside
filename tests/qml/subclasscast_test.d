// Does Qt recognise a D subclass of a BOUND type as that type? qobject_cast walks the META-OBJECT
// chain (qt_metacast), not C++ RTTI, so a CTFE-built meta-object whose superClass does not reach the
// C++ base would make every `qobject_cast<QQuickX*>` Qt performs on our objects fail — and Qt uses
// that constantly to decide policy. QQuickMenu, for instance, configures its contentItem only if it
// recognises it, and a compiled Menu came out with an interactive/key-navigable inner list where the
// engine's is neither.
//
// The existing metacast test covers a pure D @QObject resolving "QObject". This covers the case the
// generator actually produces for QML: `@QObject class X { mixin QtdWidget!QQuickRectangle; }`.
import qt.quick.qquickrectangle;
import qt.quick.qtvirt;               // __<Class>_vnames for the trampoline mixin
import qtmoc;
import std.stdio;

@QObject class MyRect { mixin QtdWidget!QQuickRectangle; }

void main() {
    // A QtdWidget class is constructed with `new` — the mixin ctor builds the trampoline and attaches
    // the meta-object with the BOUND base as super. `newQObject!T` is the path for a PLAIN @QObject and
    // passes QObject as super, so using it on a QtdWidget class measures the wrong thing (it looks
    // like Qt cannot resolve the base, which is what this test exists to keep honest).
    auto r = new MyRect();

    // The class it announces is OURS — that part is expected and is not the question.
    writefln("className=%s", mocClassName(r));

    // The question: does the chain reach the C++ base, and its base?
    assert(r.metaCast("QQuickRectangle") !is null,
           "qt_metacast must resolve the BOUND base of a QtdWidget subclass — without it every "
           ~ "qobject_cast Qt performs on our objects fails and its internal policies silently "
           ~ "do not apply");
    assert(r.metaCast("QQuickItem") !is null, "...and the base's base");
    assert(r.metaCast("QObject") !is null, "...up to QObject");
    assert(r.metaCast("QQuickText") is null, "an unrelated Quick type must NOT resolve");

    writeln("subclasscast OK: Qt resolves a QtdWidget subclass as its bound C++ base");
}
