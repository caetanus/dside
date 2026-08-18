// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
// The DEFINITION half of a spliced local type, and it names itself `control` — which is what Qt's
// own style files do (`Menu.qml`, `Button.qml`, every one of them writes `id: control`).
Rectangle {
    id: control
    implicitWidth: 20
    implicitHeight: 20
    property string who: "inner"
    // Resolved in THIS document's scope: `control` is this Rectangle, whatever the document that
    // uses it calls itself.
    property string fromDefn: control.who
    property string fromUse: "unset"
}
