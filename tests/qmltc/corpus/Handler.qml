import QtQml 2.15
// Phase-4 fixture: a property-change signal handler with a side effect.
QtObject {
    property int count: 0
    property int total: 0
    onCountChanged: total = total + 1
}
