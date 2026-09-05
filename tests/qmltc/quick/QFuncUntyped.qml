// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A FUNCTION WHOSE PARAMETER HAS NO TYPE ANNOTATION.
//
// Compiling one means picking a type, and picking is wrong: `pick(a, b)` below is called with
// numbers here and would be called with strings elsewhere, where JavaScript concatenates and a
// guessed `double` adds. Qt declines the same shape for the same reason.
//
// It used to be dropped instead, which is worse than either: callable from neither D nor the
// engine, so a delegated expression naming it answered `Property 'pick' of object … is not a
// function` about a function declared in the same file. A real reader lost `visibleIndex` that way
// (bugs.md #9, criterion 4).
//
// Now it is declared to the meta-object with QVariant arguments and run by the engine, so the
// types stay the document's. Both call shapes are here, because the point is that the SAME
// function answers differently — 3 for numbers, "12" for strings — which no single guessed
// parameter type can do.
import QtQuick

Item {
    id: root
    width: 40; height: 20

    function pick(a, b) { return a + b }

    Text {
        objectName: "leaf"
        text: root.pick(1, 2) + "/" + root.pick("1", "2")
    }
}
