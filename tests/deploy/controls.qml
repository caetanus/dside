// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// Controls on purpose: the style is resolved at RUN TIME, so this is the document that catches a
// manifest built from what the `qmldir` calls its default. A Window with a Rectangle would load
// from a bundle missing every style.
import QtQuick
import QtQuick.Window
import QtQuick.Controls

Window {
    width: 200; height: 80
    Column {
        Button { text: "ok" }
        Slider { from: 0; to: 1 }
        CheckBox { text: "x" }
    }
}
