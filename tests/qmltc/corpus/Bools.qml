import QtQml
// Phase-3: logical &&, ||, ! over comparisons and bool properties.
QtObject {
    property int a: 6
    property int b: 7
    property bool p: true
    property bool q: false
    property bool both: p && q
    property bool either: p || q
    property bool notp: !p
    property bool range: a < b && b < 10
    property bool tri: (a > b) || (a == 6)
}
