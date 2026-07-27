import QtQml
// Phase-5 fixture: self property aliases via the root id (reactive: mirror updates on change).
QtObject {
    id: root
    property int x: 5
    property alias mirror: root.x
    property string s: "hi"
    property alias sAlias: root.s
}
