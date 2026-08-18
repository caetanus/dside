// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// `Connections`, the explicit form of a signal handler, on a target chosen by a property rather
// than written in place. Applications use it whenever the emitter is not a child of the handler.
import QtQuick
Item {
    id: root
    width: 160; height: 50
    property int hits: 0
    property int lastW: 0
    Rectangle { id: probe; width: 20; height: 20; color: "salmon" }
    Connections {
        target: probe
        function onWidthChanged() { root.hits += 1; root.lastW = probe.width }
    }
    Component.onCompleted: { probe.width = 55; probe.width = 65 }
    Text { y: 25; text: "hits=" + root.hits + " w=" + root.lastW }
}
