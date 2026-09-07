// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A BLOCK BOUND TO A BASE PROPERTY — `x: { … return … }`.
//
// A script binding on a base property reached no branch of the member loop at all and fell to the
// generic refusal, so the property kept its default. It is a binding like any other and the engine
// evaluates blocks; handed over, it gets its value.
//
// This was the largest remaining cluster in a real application — 44 of 61 hard refusals, every one
// of them this shape — and it is what positions an overlay: a tooltip whose `x` is computed from
// its own width and its anchor's position sat at zero instead.
import QtQuick 2.15
Item {
    id: root
    width: 200; height: 40
    property int slot: 2
    // On the ROOT because the differential compares the root's properties: the first version
    // asserted nothing about `x` at all — the dump does not carry a base property of a child — and
    // passed while the binding was refused.
    readonly property real boxX: box.x
    Item {
        id: box
        objectName: "box"
        width: 30; height: 10
        x: {
            var step = root.width / 5
            if (root.slot < 0) return 0
            return step * root.slot + 4
        }
    }
}
