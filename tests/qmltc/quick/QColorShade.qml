// `Qt.darker` / `Qt.lighter`: the two QML globals with no QObject behind them, so nothing in the
// meta channel reaches them and the runtime has to implement what the engine implements. Qt's own
// Fusion style computes most of its palette this way, and every colour that feeds it — declared
// properties, `Color.transparent(...)` arguments — was refused for want of these two.
//
// The engine is the specification, so the fixture exercises the parts that could disagree with it:
// the DEFAULT factors (2.0 and 1.5, which QML supplies and the call site does not), a factor below
// 1 (which QColor documents as inverting the operation), the two argument shapes a colour arrives
// in here (a declared QColor field and a value read off a property through the meta channel), and
// a colour with ALPHA — where the string spelling changes from #rrggbb to #aarrggbb and a
// formatter of our own would have drifted from Qt's.
import QtQuick
Rectangle {
    width: 40; height: 40
    property color base: "steelblue"
    // A LITERAL, not `color: base`: reading a base property that the same document also BINDS is a
    // separate gap (it is refused whatever the expression around it), and binding it here would
    // have made this fixture measure that one instead.
    color: "steelblue"

    property color d12: Qt.darker(base, 1.2)
    property color l15: Qt.lighter(base, 1.5)
    property color dDef: Qt.darker(base)      // 2.0
    property color lDef: Qt.lighter(base)     // 1.5
    property color dSub: Qt.darker(base, 0.5) // < 1 lightens, per QColor
    property color alpha: Qt.darker("#80336699", 1.4)
    // ...and off the meta channel rather than the field: `color` is the bound type's own property,
    // so this read crosses as text where the ones above pass a QColor.
    property color viaMeta: Qt.lighter(color, 1.25)
    // Nested, to prove the result composes as a colour rather than as an opaque string.
    property color nested: Qt.darker(Qt.lighter(base, 1.4), 1.2)
}
