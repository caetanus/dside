import QtQml 2.15
// Phase-9: a declared param-less signal, emitted from a function, observed by a handler.
QtObject {
    signal ping()
    property int hits: 0
    function fire() { ping() }
    onPing: { hits = hits + 1 }
    Component.onCompleted: { fire(); fire(); fire() }
}
