import QtQuick
// TIME as its own axis. `NumberAnimation on v` is a property VALUE SOURCE: the object is built and
// then handed the property it drives (QQmlPropertyValueSource — one generic Qt interface that
// covers every animation type and Behavior, so nothing in the compiler knows what a
// NumberAnimation is). Refusing it left compiled documents visually correct and frozen.
//
// Nothing else in this suite can see the difference: a property dump reads the initial value, a
// frame comparison sees one frame, a click test sends an event. Only letting time pass does.
Item {
    width: 100
    height: 40
    property int v: 0
    NumberAnimation on v { to: 50; duration: 120; running: true }
}
