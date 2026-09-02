// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A window, an animation and a model: enough that the engine has to resolve QtQuick, pull in
// QtQml.Models through it, and start the scene graph — which is where a bundle missing a plugin
// stops being a bundle.
import QtQuick
import QtQuick.Window

Window {
    width: 120; height: 60
    ListModel { id: m; ListElement { t: "a" } }
    Rectangle {
        anchors.fill: parent
        color: "steelblue"
        NumberAnimation on opacity { from: 0; to: 1; duration: 1 }
        Text { text: m.count }
    }
}
