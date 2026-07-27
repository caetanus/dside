import QtQuick
// (b) TextEdit -> QQuickTextEdit (private API). text base prop (string) + a custom prop.
TextEdit {
    text: "hi"
    property int n: 3
}
