import QtQuick
import QtQuick.Window

Window {
    id: win
    width: 900; height: 560
    visible: true
    title: "qt-dlang-gen · Qt6 QML Dashboard"
    color: "#0f1020"

    // animated gradient backdrop
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#141634" }
            GradientStop { position: 1.0; color: "#0a0b18" }
        }
    }

    Column {
        anchors.fill: parent
        anchors.margins: 24
        spacing: 18

        // header
        Row {
            spacing: 14
            Rectangle {
                width: 44; height: 44; radius: 12
                gradient: Gradient {
                    GradientStop { position: 0; color: "#7c5cff" }
                    GradientStop { position: 1; color: "#4bd6ff" }
                }
            }
            Column {
                Text { text: "System Dashboard"; color: "white"; font.pixelSize: 26; font.bold: true }
                Text { text: "D backend ⇄ QML via native meta-object (no moc)"; color: "#8a8fb5"; font.pixelSize: 13 }
            }
        }

        // metric gauges
        Row {
            spacing: 18
            Repeater {
                model: [
                    { label: "CPU", val: dash.cpu, c1: "#ff6b9d", c2: "#ff9f6b" },
                    { label: "MEM", val: dash.mem, c1: "#7c5cff", c2: "#4bd6ff" },
                    { label: "NET", val: dash.net, c1: "#39e6a8", c2: "#4bd6ff" }
                ]
                delegate: Rectangle {
                    width: 260; height: 150; radius: 16
                    color: "#191b34"; border.color: "#2a2d52"; border.width: 1
                    Column {
                        anchors.centerIn: parent; spacing: 8
                        Text { anchors.horizontalCenter: parent.horizontalCenter
                               text: modelData.label; color: "#8a8fb5"; font.pixelSize: 14; font.bold: true }
                        Text { anchors.horizontalCenter: parent.horizontalCenter
                               text: modelData.val + "%"; color: "white"; font.pixelSize: 40; font.bold: true }
                        Rectangle {  // progress bar
                            width: 200; height: 10; radius: 5; color: "#0e1024"
                            Rectangle {
                                width: 200 * modelData.val / 100; height: 10; radius: 5
                                gradient: Gradient {
                                    orientation: Gradient.Horizontal
                                    GradientStop { position: 0; color: modelData.c1 }
                                    GradientStop { position: 1; color: modelData.c2 }
                                }
                                Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                            }
                        }
                    }
                }
            }
        }

        // interactive counter card
        Rectangle {
            width: parent.width; height: 150; radius: 16
            color: "#191b34"; border.color: "#2a2d52"; border.width: 1
            Row {
                anchors.centerIn: parent; spacing: 40
                Column {
                    Text { text: "Interactions"; color: "#8a8fb5"; font.pixelSize: 14 }
                    Text { text: dash.counter; color: "#4bd6ff"; font.pixelSize: 64; font.bold: true }
                }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 12
                    Rectangle {  // + button
                        width: 180; height: 46; radius: 10
                        gradient: Gradient {
                            GradientStop { position: 0; color: "#7c5cff" }
                            GradientStop { position: 1; color: "#4bd6ff" }
                        }
                        Text { anchors.centerIn: parent; text: "＋  increment()"; color: "white"; font.pixelSize: 16; font.bold: true }
                        MouseArea { anchors.fill: parent; onClicked: dash.increment() }
                    }
                    Rectangle {  // refresh button
                        width: 180; height: 46; radius: 10
                        color: "#232649"; border.color: "#3a3f70"; border.width: 1
                        Text { anchors.centerIn: parent; text: "⟳  refresh()"; color: "#c9cdf0"; font.pixelSize: 16 }
                        MouseArea { anchors.fill: parent; onClicked: dash.refresh() }
                    }
                }
            }
        }
    }
}
