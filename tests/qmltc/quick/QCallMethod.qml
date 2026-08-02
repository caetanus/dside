// Calling a METHOD on an object the document names, and asking whether an object HAS a member —
// the two shapes Qt's own editing Actions are built from (`onTriggered: editor.undo()`,
// `editor.remove(a, b)`, `editor.hasOwnProperty("cut")`).
//
// The registry publishes methods per type now, so a call with the right parameter count is a row
// lookup rather than a guess; a method the DECLARED type does not have is still allowed, because
// QML is dynamically typed there and `invoke0` resolves by name at runtime — an `Item`-typed
// property holding a TextInput is exactly the case Qt relies on.
//
// The observable is the TEXT, which only changes if the calls actually reached the editor.
import QtQuick
Rectangle {
    id: root
    width: 120; height: 30

    TextInput {
        id: field
        text: "hello world"
    }

    // `field` is a TextInput, so the registry HAS these rows: the row-lookup path.
    property bool canAsk: field.hasOwnProperty("selectionStart")
    property bool cannotAsk: field.hasOwnProperty("thisIsNotAProperty")

    Component.onCompleted: {
        // A method WITH arguments — each crosses as text and QMetaType converts it.
        field.remove(0, 6)
        // ...and one with none.
        field.selectAll()
    }

    property string after: field.text
    property int selLen: field.selectedText.length
}
