// A bound value type as a @Property. The meta-object records a property by TYPE NAME and Qt
// resolves it through QMetaType::fromName, so no per-type support is needed to REGISTER one.
//
// Reaching it is a separate question, and this test was wrong about it: it used to write and read
// the D field (p.extent = QSize(4,7); p.extent.width()) and assert on that, which passes even when
// the property is unreachable through the meta-object — the exact false-green this project keeps
// finding elsewhere. It now goes through the CHANNEL in both directions.
import qtmoc, qt.quick.qcolor, qt.quick.qsize, std.stdio;

@QObject class Painted {
    Signal!() tintChanged;
    @Property("tintChanged") QColor tint;
    @Property QSize extent;
    @Property int plain;
}

void main() {
    auto p = newQObject!Painted();

    // QColor has a registered QString conversion, so the string form reaches it and QMetaType
    // converts — this is what a compiled QML document does with `property color c: "tomato"`.
    setProp(p, "tint", "tomato");
    assert(p.tint.rgba() == 0xffff6347, "QColor property did not receive the converted value");
    assert(propStr(p, "tint") == "#ff6347", "QColor did not read back through the meta-object");

    // QSize has NO QString conversion, so the typed helpers cannot reach it. The generic pair,
    // keyed by the type NAME cppSig already computes, can — that is the point of it.
    assert(setPropVar(p, "extent", QSize(4, 7)), "generic setter refused a registered type");
    QSize got;
    assert(propVar(p, "extent", got), "generic getter could not read the property back");
    assert(got.width() == 4 && got.height() == 7, "QSize lost its value through the channel");
    assert(p.extent.width() == 4, "the meta-object write did not reach the D field");

    // The failure channel is real: an unknown name must be refused, not silently accepted.
    QSize ignored;
    assert(!propVar(p, "nosuchprop", ignored), "reading an unknown property must fail");

    // A scalar alongside them still takes its own path.
    setProp(p, "plain", 5);
    assert(propInt(p, "plain") == 5, "scalar property broke");

    writefln("value-type @Property OK: QColor via string conversion (%s), QSize via the generic "
             ~ "type-name pair (%dx%d), unknown name refused", propStr(p, "tint"),
             got.width(), got.height());
}
