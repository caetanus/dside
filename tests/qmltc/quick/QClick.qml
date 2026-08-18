// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
// BEHAVIOUR, not appearance: a handler for a signal the BOUND TYPE declares (`clicked` on a
// MouseArea). This is the majority shape in real QML — 226 of the 373 handlers in the QML Qt
// ships are plain signals like this, against 147 notify handlers — and it was refused for want of
// a signature, so a compiled MouseArea rendered pixel-identically and did nothing when clicked.
// No property dump and no frame comparison can see that; only delivering an event can.
MouseArea {
    width: 60
    height: 40
    property int hits: 0
    property bool everPressed: false
    onClicked: { hits = hits + 1; everPressed = true }
}
