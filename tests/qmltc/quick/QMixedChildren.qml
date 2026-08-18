// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
// (b): an Item root with two BOUND-type children (Rectangle, Text). Verifies each bound child type
// gets its own D import (QQuickRectangle, QQuickText), not just the root's.
Item {
    width: 10
    Rectangle {
        width: 3
        color: "red"
    }
    Text {
        text: "x"
    }
}
