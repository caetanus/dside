// A declared object property whose value is the ABSENCE of an object. The property still exists --
// that is the whole point: the engine reports it as `<null>`, and whoever instantiates the type
// writes to it. Refused, the declaration went out with the value and the property was missing
// altogether, which is a structural difference from the engine, not a value one.
//
// Qt's Basic ComboBox needs this as the first half of
// `property Item highlightedItem: parent ? parent.itemAtIndex(control.highlightedIndex) : null`.
import QtQuick
Item {
    id: root
    width: 100; height: 40
    property Item hi: null
}
