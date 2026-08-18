// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
import QtQuick.Templates as T
// A ternary BETWEEN two value reads written into an OBJECT-GROUP member. A base property already
// supported this shape; doing it here too keeps the two positions consistent — the same expression
// should not compile in one and be refused in the other. The condition picks which copy runs.
//
// `enabled` is false, so the FALSE branch must win: navy, not seagreen. Both palette roles are
// non-default, so taking the wrong branch (or neither) is visible.
T.Control {
    id: control
    enabled: false
    palette.mid: "seagreen"
    palette.dark: "navy"
    contentItem: Rectangle {
        objectName: "bg"
        border.width: 2
        border.color: control.enabled ? control.palette.mid : control.palette.dark
    }
}
