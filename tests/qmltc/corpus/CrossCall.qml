// Calling a method on ANOTHER object through its id, and a Connections whose target is that
// object rather than the enclosing one — the real shape of Connections.
import QtQml 2.15
QtObject {
    id: root
    property int received: 0
    property string tag: ""
    property QtObject kid: QtObject {
        id: inner
        signal fired(int v)
        signal named(string who)
        function go() { fired(3); named("Ada") }
    }
    property QtObject conn: Connections {
        target: inner
        function onFired(v) { root.received = v * 2 }
        function onNamed(who) { root.tag = "via " + who }
    }
    // A SECOND target with a signal of the SAME name: the two handlers must stay distinct.
    property QtObject kid2: QtObject {
        id: other
        signal fired(int v)
        function go() { fired(50) }
    }
    property QtObject conn2: Connections {
        target: other
        function onFired(v) { root.otherGot = v + 1 }
    }
    property int otherGot: 0
    Component.onCompleted: { inner.go(); other.go() }
}
