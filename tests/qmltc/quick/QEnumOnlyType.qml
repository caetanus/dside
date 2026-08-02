// `StandardKey.Copy` — an enum member of a type QML exports for its ENUM ALONE. `StandardKey` is
// QKeySequence: uncreatable, with no object to read a member from, and the key as TEXT is no use
// either (Qt would parse "Copy" as four letters, not as the standard key). The NUMBER is what QML
// assigns there, and QMetaEnum on the C++ type is where it lives — so no table of enum values is
// needed anywhere, and the lookup works for any such type without naming one.
//
// Qt's own editing Actions are all written this way (`shortcut: StandardKey.Undo`), which is why
// this is a prerequisite for compiling a context menu; `Shortcut.sequence` is the same shape in a
// document that needs nothing else.
import QtQuick
Rectangle {
    width: 20; height: 20
    Shortcut {
        id: sc
        sequence: StandardKey.Copy
    }
    // Read back through the meta channel: the engine renders a QKeySequence as its portable text,
    // so a wrong number would show up as a different shortcut rather than as a silent no-op.
    property string seq: sc.nativeText
}
