import QtQml
// Phase-6: a multi-statement (brace block) signal handler body.
QtObject {
    property int count: 0
    property int a: 0
    property int b: 0
    onCountChanged: { a = count + 1; b = count * 2 }
}
