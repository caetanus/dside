import QtQuick
// A grouped assignment where the GROUP IS AN OBJECT: `border` on a Rectangle is a QQuickPen*, not
// a value. The registry marks this with `isPointer`, which the property table now records as a
// trailing `*` — the distinction is not recoverable from the type NAME (QQuickScaleGrid and QFont
// look alike) and it decides how the write must be compiled: an object group is a plain property
// write on what the group holds. A VALUE group (font.pixelSize) stays refused; see the doc.
Rectangle {
    width: 60
    height: 40
    color: "white"
    border.width: 3
    border.color: "red"
}
