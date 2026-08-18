// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
// A ternary BETWEEN two value-typed reads: `color: control.down ? control.palette.light : ...` is
// how Qt's Controls pick a colour. Neither branch can become a D expression — there is no D type
// for a QColor here — but each is a property copy, so the condition picks which copy runs. The
// .set flips the condition, so the branch has to switch reactively: a one-shot, or a wiring that
// only watched one branch, keeps the first colour.
Text {
    id: control
    text: "root"
    property bool hot: true
    property color warm: "tomato"
    property color cool: "steelblue"
    Text {
        objectName: "kid"
        text: "kid"
        color: control.hot ? control.warm : control.cool
    }
}
