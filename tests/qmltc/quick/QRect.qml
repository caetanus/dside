import QtQuick
// (b): a QtQuick Rectangle root -> a D subclass of the bound QQuickRectangle (a PRIVATE Qt type).
// Base props (width/height, on QQuickItem) set via the meta-object; a custom reactive binding.
Rectangle {
    width: 80
    height: 40
    property int area: width * height
}
