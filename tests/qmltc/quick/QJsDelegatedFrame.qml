// The delegated binding on a VIEW-CREATED item, measured by the FRAME.
//
// This is the half no property differential can reach. An item a view creates has no static object
// path, so `--objpaths` names none of them and `--dumpall` compares nothing about them -- which is
// exactly the state Qt's own header/table/tumbler delegates are in, and why the value axis being
// clean over both style corpora says nothing about the twelve delegations there.
//
// The shape is Qt's Tumbler delegate, reproduced: `required property var modelData` has no D type,
// so the compiler refuses `text` and hands the expression to the engine. The engine injects
// `modelData` because the delegate declares it required; ours cannot be injected, and reads the
// same value from the per-item context one level up. If either half were wrong the column would
// draw the wrong text -- or none -- and the frames would differ.
import QtQuick 2.15
Item {
    width: 120; height: 60
    Row {
        spacing: 4
        Repeater {
            model: 3
            delegate: Text {
                required property var modelData
                required property int index
                text: "n" + modelData
                font.pixelSize: 16
            }
        }
    }
}
