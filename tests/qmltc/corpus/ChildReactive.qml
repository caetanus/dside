import QtQml 2.15
// Phase-6: mutate a CHILD property and see the child's binding AND a live child-alias update.
QtObject {
    id: root
    property QtObject kid: QtObject {
        id: k
        property int y: 10
        property int sum: y + 2
    }
    property alias kidSum: k.sum
}
