// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// ANCHORS, which application layout is built from and the styles use sparingly. `anchors.fill`,
// centreing, margins and a sibling anchor all resolve to a different object than the one being
// assigned, which is the part a compiler can get wrong without the frame noticing.
import QtQuick
Item {
    id: root
    width: 200; height: 80
    Rectangle {
        id: left
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom; margins: 6 }
        width: 60; color: "#cccccc"
    }
    Rectangle {
        id: right
        anchors { left: left.right; right: parent.right; verticalCenter: parent.verticalCenter }
        height: 30; color: "#8888ff"
    }
    Text { anchors.centerIn: right; text: right.width + "x" + right.height }
}
