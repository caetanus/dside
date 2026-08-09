// A local component another document in this directory instantiates. An application is made of
// these; Qt's styles resolve every type through a module instead.
import QtQuick
Rectangle {
    id: tile
    property string caption: ""
    property int slot: 0
    signal picked(int which)
    width: 50; height: 24
    color: slot % 2 === 0 ? "#dddddd" : "#bbbbbb"
    Text { anchors.centerIn: parent; text: tile.caption }
}
