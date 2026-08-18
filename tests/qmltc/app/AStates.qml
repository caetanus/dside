// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// STATES AND A TRANSITION. A style declares states rarely and an application constantly. The
// document settles in a named state at startup, so the comparison is about WHERE the property
// changes land, not about animation timing.
import QtQuick
Item {
    id: root
    width: 120; height: 60
    property bool on: true
    Rectangle {
        id: box
        width: 40; height: 40; color: "grey"
        states: State {
            name: "lit"; when: root.on
            PropertyChanges { target: box; color: "gold"; width: 80 }
        }
        transitions: Transition { ColorAnimation { duration: 0 } }
    }
    Text { y: 45; text: box.state }
}
