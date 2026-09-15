// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A READ THROUGH `parent.parent`, WHICH IS TWO FRAMES OUT AND WAS ANSWERED BY NEITHER RULE.
//
// `parent` is compiled as the enclosing object rather than as a meta read, because Qt sets the
// visual parent AFTER construction and the wire runs inside the constructor — so a child reading
// `parent.<prop>` gets the back-reference, with the right hops and the right notify. That rule
// existed at ONE depth. `parent.parent.<prop>` matched no branch that knew about frames, and
// instead reached the branch for a member the TYPE does not declare: Item has no `rows`, so the
// read was answered "in the target's own terms", which for a string is empty.
//
// Nothing reported it. The document compiled, the binding existed, and `rows.length` was the
// length of that empty text: `n=0` where the engine says `n=3`. The `var` guard next to it has the
// same hole for the same reason — it recognised `<id>.<prop>.length` and a bare `<prop>.length`,
// both of which name an id, and a `parent` chain names none.
//
// So each shape is its own binding, because one refused operand delegates the whole expression and
// would hide the compiled ones: a declared string at depth two and at depth three (both COMPILED,
// from the enclosing object's field), and a `var` through its length (REFUSED to the engine, where
// a `var` is a JS value). Depth three is there to keep the depth from being hard-coded again —
// `parent.parent.parent` was refused outright before this.
import QtQuick

Item {
    id: root
    width: 40; height: 20

    property var rows: [ "a", "bb", "ccc" ]
    property string tag: "root"

    Item {
        id: mid
        anchors.fill: parent
        Item {
            id: inner
            anchors.fill: parent
            // THREE frames out, and COMPILED: the enclosing object declares `tag`, so the read is
            // its field. Depth was hard-coded at one, which is why this was answered by the branch
            // for a member the type does not declare — empty text, in silence.
            Text { objectName: "deep"; text: "t=" + parent.parent.parent.tag }
        }
        // TWO frames out, also compiled, for the depth the old rule reached only inside objPathExpr.
        Text { objectName: "near"; y: 20; text: "t=" + parent.parent.tag }
        // ...and the `var`, which must be REFUSED to the engine at any depth, because a `var` is a
        // JS value there and a string here. Delegating it is the right answer and the value proves
        // it: `n=3`, where reading it as text gave the length of the text an empty read renders as.
        Text { objectName: "rows"; y: 40; text: "n=" + parent.parent.rows.length }
    }
}
