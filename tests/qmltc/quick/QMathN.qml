import QtQuick
// Math.max/min with THREE arguments (Qt's Controls use it) and with two. std.algorithm's max/min
// are variadic, imported under a private alias so a QML property named `max` cannot collide. The
// old two-argument form was `a > b ? a : b`, which evaluated each operand TWICE — and every
// operand here is a meta-object read.
Item {
    property real a: 3
    property real b: 9
    property real c: 5
    property real hi: Math.max(a, b, c)
    property real lo: Math.min(a, b, c)
    property real two: Math.max(a, b)
    width: Math.max(a, b, c) * 10
}
