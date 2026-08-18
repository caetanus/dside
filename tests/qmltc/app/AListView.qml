// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A LIST VIEW over a model with a delegate that reads BOTH the row and the enclosing document.
// A Repeater builds everything at once; a ListView creates and recycles, which is a different
// lifetime for the same delegate and the one applications actually use.
import QtQuick
Item {
    id: root
    width: 140; height: 100
    property string tag: "row"
    ListModel {
        id: model
        ListElement { name: "alpha" }
        ListElement { name: "beta" }
        ListElement { name: "gamma" }
    }
    ListView {
        id: view
        anchors.fill: parent
        model: model
        delegate: Text { height: 22; text: root.tag + " " + index + " " + name }
    }
    property int shown: view.count
}
