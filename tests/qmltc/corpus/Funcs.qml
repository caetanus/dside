import QtQml 2.15
// Phase-7: QML functions called from Component.onCompleted (and each other).
QtObject {
    property int count: 0
    property int total: 0
    function bump() { count = count + 1 }
    function reset() { total = count * 10 }
    Component.onCompleted: { bump(); bump(); bump(); reset() }
}
