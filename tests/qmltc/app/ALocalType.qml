// ONE DOCUMENT INSTANTIATING ANOTHER from the same directory, reading its declared properties back
// and binding one of its own to them. The type is resolved by DIRECTORY, not by a module import,
// which is how application code is written and how none of Qt's styles is.
import QtQuick
Item {
    id: root
    width: 170; height: 60
    property string prefix: "t"
    Row {
        ATile { id: a; slot: 0; caption: root.prefix + "0" }
        ATile { id: b; slot: 1; caption: root.prefix + "1" }
        ATile { id: c; slot: 2; caption: root.prefix + "2" }
    }
    property int widths: a.width + b.width + c.width
    Text { y: 30; text: "w=" + widths + " " + b.caption }
}
