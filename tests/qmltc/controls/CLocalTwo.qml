// O gémeo: mesmos NOMES (root, box, tag, origin, inner), valores e tipos diferentes.
import QtQuick
Rectangle {
    id: root
    property int tag: 2
    property string origin: "two"
    Rectangle { id: box; color: "#222222" }
    width: 100 + tag; height: 20
}
