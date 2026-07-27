import QtQuick
// (b) real base prop: set QQuickItem.opacity (a qreal base prop) to a real binding, and read it in
// another prop. Exercises propDouble/setProp(double) on a base property.
Item {
    opacity: 0.5
    property real vis: opacity * 2
}
