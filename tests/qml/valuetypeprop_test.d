// The meta-object records a property by its TYPE NAME and Qt resolves that through
// QMetaType::fromName, so a bound value type needs no per-type support in the runtime: cppSig
// falls back to the D struct's name, which matches the C++ one for every type the generator
// emits. This is what makes `@Property QColor` — and QSize, QRectF, … — work at all.
import qtmoc, qt.quick.qcolor, qt.quick.qsize, std.stdio;

@QObject class Painted {
    Signal!() tintChanged;
    @Property("tintChanged") QColor tint;
    @Property QSize extent;
}

void main() {
    auto p = newQObject!Painted();
    p.tint = QColor.fromString("tomato");
    p.extent = QSize(4, 7);
    assert(p.tint.isValid(), "QColor property did not hold a valid colour");
    assert(p.tint.rgba() == 0xffff6347, "QColor property lost its value");
    assert(p.extent.width() == 4 && p.extent.height() == 7, "QSize property lost its value");

    // A scalar alongside them still works — the fallback must not have captured everything.
    writefln("value-type @Property OK: QColor (rgba=%08x) and QSize (%dx%d) held in the "
             ~ "meta-object by type name", p.tint.rgba(), p.extent.width(), p.extent.height());
}
