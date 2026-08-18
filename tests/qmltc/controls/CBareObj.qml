// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
import QtQuick.Templates as T
// The BARE spellings of two rules Qt's Controls use constantly: an object-valued property as a
// truth value (`background ? ...`) and a read THROUGH one (`background.implicitWidth`). The dotted
// forms (`control.background`) were already supported, and refusing the bare ones made the support
// look arbitrary. The numbers are chosen so a failure of either shows: if the null test answered
// false the result would be 10, and if the read came back 0 it would also be 10 — only both
// working gives 30.
T.Control {
    background: Rectangle { objectName: "bg"; implicitWidth: 30; implicitHeight: 12 }
    property real widest: Math.max(background ? background.implicitWidth : 0, 10)
}
