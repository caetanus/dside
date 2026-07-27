import QtQml
// Phase-2 fixture: numeric bindings over property refs + literals, and a string concat.
QtObject {
    property int a: 6
    property int b: 7
    property int sum: a + b
    property int scaled: (a + b) * 2
    property real half: 3.0
    property real quarter: half / 2
    property string label: "n=" + "x"
}
