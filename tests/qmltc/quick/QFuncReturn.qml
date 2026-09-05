// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A FUNCTION THAT RETURNS, CALLED FROM AN EXPRESSION THE ENGINE EVALUATES.
//
// A void QML function is emitted as a `@Slot` and the engine can call it. One that RETURNS was
// emitted as a plain D method, which the meta-object never saw — so a delegated binding calling it
// answered `Property 'X' of object … is not a function` about a function declared three lines
// above it. Measured on a real reader (bugs.md #9, criterion 4): `nav.visibleIndex(nav.browsedBook)`.
//
// The call is written through an id on purpose. That is the shape that goes through the meta
// channel: a compiled read of the same function would resolve in D and prove nothing about what
// the engine can see.
import QtQuick

Item {
    id: root
    width: 40; height: 20

    function twice(n: int): int { return n * 2 }
    function shout(s: string): string { return s + "!" }

    Text {
        objectName: "leaf"
        // Both halves, because a scalar return and a QString return cross differently.
        text: root.shout("v") + root.twice(21)
    }
}
