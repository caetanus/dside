// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
// A child reading its ENCLOSING object by id — the shape Qt's own Controls are written in
// (`id: control` on the root, then `contentItem: Text { ... control.x ... }`). The child is a
// separate D class, so it reaches the root through a generated __outer back-reference. The .set
// mutates both a declared property and a base one: a one-shot would keep the first values.
Item {
    id: control
    width: 100
    property real gap: 3
    Rectangle {
        objectName: "kid"
        width: control.gap * 2
        height: control.width / 2
    }
}
