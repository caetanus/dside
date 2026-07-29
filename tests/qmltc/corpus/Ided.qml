import QtQml 2.15
// Phase-5 fixture: an id and self member-access in bindings (root.x), incl. a transitive chain.
QtObject {
    id: root
    property int x: 5
    property int y: root.x + 1
    property int z: root.y * 2
    property string label: root.tag + "!"
    property string tag: "hi"
}
