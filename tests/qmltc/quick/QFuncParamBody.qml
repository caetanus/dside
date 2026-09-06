// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A FUNCTION WITH PARAMETERS WHOSE BODY THIS COMPILER CANNOT TAKE.
//
// The delegation was offered only to a parameterless one, because the body "would have to see the
// parameters". It can: the engine takes the whole FUNCTION and is called with the arguments, each
// boxed as a QVariant on the way — the channel an untyped parameter already travels. The D
// signature stays the document's, so a compiled call site still compiles; only the body moved.
//
// Refusing here does not fail alone, which is why it was the blocker rather than a line in a
// census: a real reader's `adopt(newContent)` is both the first page load AND the handler for every
// page change, so one skipped function left the whole reading surface blank.
//
// `apply` has a parameter and a body with an early return and a local — the shape that does not
// compile — and `seen` is written from it, so the fixture reads the RESULT of the call rather than
// the fact that a method was emitted.
import QtQuick 2.15
Item {
    id: root
    width: 30; height: 10
    property string seen: "-"
    function apply(v) {
        if (v <= 0) return
        var doubled = v * 2
        root.seen = "got " + doubled
    }
    Component.onCompleted: root.apply(21)
}
