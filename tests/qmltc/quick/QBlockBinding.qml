// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A PROPERTY BOUND TO A BLOCK, which is ordinary QML and is not an expression.
//
// `readonly property int step: { … return n }` is how a document writes a binding that needs a
// local or an early return. The delegation is handed an EXPRESSION, so a block was never offered to
// it: the property was declared, the refusal was printed, and it kept its type's default for ever
// (docs/qmltc-d-gaps.md, gap 3). A block is JavaScript and the engine runs JavaScript — called as a
// function it is an expression again, and the reads inside it are captured as the binding's
// dependencies exactly as they would be in one.
//
// `local` is the half that has to be watched: the promise rewrite is a whole-token substitution
// over the source, and a name DECLARED inside the block must be left alone. Rewritten it becomes
// `var __sp_local.local`, which the engine refuses — and then the whole body is lost, not just that
// name. The fixture reads a declared `var` back through the binding's result, so the rewrite
// breaking it is a wrong VALUE and not a silence.
import QtQuick 2.15
Item {
    id: root
    width: 40; height: 10
    property int seed: 7
    readonly property int step: {
        if (seed <= 0) return -1
        var local = seed * 3
        return local + 1
    }
    readonly property string label: {
        var parts = []
        for (var i = 0; i < 3; ++i) parts.push("v" + i)
        return parts.join("-")
    }
}
