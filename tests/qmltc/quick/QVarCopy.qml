import QtQuick
// A value-typed property copied through the meta-object without the generator knowing the type:
// `color` is a QColor and `tint` is a declared `property color`. The QVariant carries the type and
// QMetaType converts on write. It is a BINDING, not a one-shot: children are constructed before
// the parent assigns its own properties, so the first copy reads a default and the notify corrects
// it — which is why `tint` is deliberately NOT the default colour. This is the dominant line in
// Qt's own Controls (`color: control.palette.text`, `font: control.font`).
Text {
    id: control
    text: "root"
    color: "steelblue"
    property color tint: "tomato"
    Text {
        objectName: "kid"
        text: "kid"
        color: control.tint
    }
}
