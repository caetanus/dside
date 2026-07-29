import QtQuick
import QtQuick.Templates as T
// BEHAVIOUR on a real Control, not a synthetic MouseArea: a Button has to emit `clicked` and
// update `pressed` when a real mouse event reaches it. Both handlers here are for signals the
// BOUND TYPE declares — the shape that was refused until the signal table existed, and the reason
// a compiled Button rendered correctly and was inert.
T.Button {
    width: 80; height: 30
    property int hits: 0
    property bool wasDown: false
    onClicked: hits = hits + 1
    onPressedChanged: if (pressed) wasDown = true
}
