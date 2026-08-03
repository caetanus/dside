import QtQuick
// TWO children of the same local type, and that type's root arrived QUALIFIED (`T.MenuSeparator` in
// MenuSeparator.qml next to this file, which shadows the registry type exactly as every Qt style
// does). `g_qualifiedTypes` accumulates every bare name that came in that way, and the default-child
// site did not put the import state back after loading a local type — so the FIRST child's load made
// `boundTypeFor("MenuSeparator")` answer the Templates type from then on, and the SECOND child was
// compiled as a bare bound object with none of the file's body.
//
// The observable is the COLUMN's implicit height, not the children's own: a label the compiler
// records per child disappears with the child, and the engine is then asked for the same shorter
// list — so the comparison passes while the defect stands (checked: that is exactly what the first
// version of this fixture did). A Column sums what its children actually are, and 13 against 26 is
// the whole difference.
Column {
    MenuSeparator { }
    MenuSeparator { }
    property real total: implicitHeight
}
