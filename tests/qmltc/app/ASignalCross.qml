// A SIGNAL DECLARED IN ONE DOCUMENT AND HANDLED IN ANOTHER. `onPicked` on a locally-resolved type
// is a connection the compiler has to make across a document boundary, and the handler mutates
// state a third binding reads.
import QtQuick
Item {
    id: root
    width: 170; height: 60
    property int last: -1
    property string status: last < 0 ? "none" : "picked " + last
    Row {
        ATile { slot: 0; caption: "a"; onPicked: (which) => root.last = which }
        ATile { id: second; slot: 1; caption: "b"; onPicked: (which) => root.last = which * 10 }
    }
    Component.onCompleted: second.picked(4)
    Text { y: 30; text: root.status }
}
