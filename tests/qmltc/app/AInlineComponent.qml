// An INLINE COMPONENT (`component Foo: ...`), Qt 5.15+ syntax that gives a document its own local
// type without a second file. Applications reach for it constantly; the styles corpus has none.
import QtQuick
Item {
    id: root
    width: 180; height: 60
    property color tint: "#448844"
    component Chip: Rectangle {
        property string label: ""
        width: 40; height: 20; color: root.tint
        Text { anchors.centerIn: parent; text: parent.label }
    }
    Row {
        spacing: 4
        Chip { label: "x" }
        Chip { id: mid; label: "y" }
        Chip { label: "z" }
    }
    property int midW: mid.width
}
