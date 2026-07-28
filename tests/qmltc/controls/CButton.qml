// QtQuick.Templates is the C++ side of QtQuick.Controls: Controls' Button.qml derives from
// Templates' Button. Binding Templates is what makes the Controls vocabulary reachable at all.
import QtQuick.Templates
Button {
    text: "Go"
    enabled: false
    property string label: text + "!"
}
