// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A DECLARED `property color`: held as a real QColor, since the meta-object takes a property by
// type name. Assigning a base colour property already worked (Qt converts the string); declaring
// one did not.
import QtQuick
Rectangle {
    color: "steelblue"
    property color tint: "tomato"
    property color accent: "#5692c4"
}
