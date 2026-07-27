import QtQuick
// (b) TextInput -> QQuickTextInput (private API). text base prop (string) + a derived binding.
TextInput {
    text: "in"
    property string echo: text + "!"
}
