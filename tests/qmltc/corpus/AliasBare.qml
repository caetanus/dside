// `property alias` onto a BARE (default) child's property. The child is addressable by its id
// exactly like one bound to a property is — this is the dominant alias shape in real QML.
import QtQml 2.15
QtObject {
    id: root
    property alias inner: kid.value
    property alias innerTag: kid.tag
    default property QtObject content: QtObject {
        id: kid
        property int value: 5
        property string tag: "bare"
    }
    property int doubled: kid.value * 2
}
