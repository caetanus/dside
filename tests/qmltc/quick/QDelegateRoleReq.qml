// A role whose NAME is only known at run time -- `model[control.textRole]`, which is how Qt's own
// ComboBox and SearchField write their delegate label. The key is computed here too (`root.key`),
// read through the enclosing document exactly as those do.
//
// What this fixture does NOT carry is the `required property var model` those documents also write,
// and that is a MEASURED boundary rather than a convenience: declaring required properties turns
// the engine's context injection OFF. The same delegate with `required property int index` answers
// EMPTY for `model["index"]` in the engine, where without it it answers the role. So a delegate
// that declares them is reading the INJECTED property, not the context, and the compiler refuses it
// -- reading the context there would put a plausible value where the engine has none.
//
// Strings, again: "q0" against a bare "q".
import QtQml 2.15
import QtQuick 2.15
Item {
    id: root
    width: 100; height: 40
    property string key: "index"
    Repeater {
        model: 2
        delegate: Item {
            objectName: "q" + model[root.key]
            property string mine: "m" + model["index"]
        }
    }
}
