import QtQml 2.15
// Phase-6: string .length and Math.max/min/abs in bindings.
QtObject {
    property string title: "hello"
    property int len: title.length
    property int a: 3
    property int b: 8
    property int hi: Math.max(a, b)
    property int lo: Math.min(a, b)
    property int mag: Math.abs(a - b)
}
