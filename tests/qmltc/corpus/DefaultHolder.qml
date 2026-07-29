// A single-OBJECT `default property`: a bare child of a user of this type becomes THIS property's
// value, so the engine reaches it through the property — not through children()[0].
import QtQml 2.15
QtObject {
    property string tag: "holder"
    default property QtObject child
}
