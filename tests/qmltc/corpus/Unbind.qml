// The other half of Rebind.qml: assigning a value drops the declarative binding, so a later
// change to its dependency must NOT revive it.
import QtQml
QtObject {
    property int p1: 1
    property int p2: p1 + 1
    function unbind() { p2 = 42; }
}
