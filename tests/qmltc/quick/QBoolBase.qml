import QtQuick
// (b) bool base prop: set QQuickItem.clip (a bool base prop) and read it in a derived bool binding.
Item {
    clip: true
    property bool inv: !clip
}
