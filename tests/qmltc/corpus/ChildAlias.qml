import QtQml 2.15
// Phase-6: alias to a CHILD object's property, via the child's id.
QtObject {
    id: root
    property int x: 5
    property QtObject kid: QtObject {
        id: kidObj
        property int y: 10
        property int sum: y + 2
    }
    property alias kidSum: kidObj.sum
    property alias selfX: root.x
}
