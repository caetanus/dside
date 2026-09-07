// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// `a > 1` WHERE `a` IS A PROPERTY THE REGISTRY CANNOT TYPE.
//
// A comparison hands its operands no type — what two values are compared as is their own business —
// and a read that NEEDS one then settles for the neutral hint, which is `bool`. So a document
// property read across objects compiled to `propBool(box, "n") > 1`, and neither `true > 1` nor
// `false > 1` is ever true.
//
// In JS `<`, `>`, `<=`, `>=` convert both operands to NUMBERS, so `bool` is never what one of them
// wants. Measured on a real reader: `visible: stage.sheetCount > 1` hid the scroll indicator for
// the life of the process, while the same property read two lines away for a `width` came out
// `propDouble` — because there the TARGET lent it a type and a comparison has none to lend.
import QtQuick 2.15
Item {
    id: root
    width: 40; height: 10

    readonly property bool many: probe.many
    readonly property bool few: probe.few
    readonly property int n: box.n

    Item {
        id: box
        property int n: 3
    }
    Item {
        id: probe
        property bool many: box.n > 1     // true
        property bool few: box.n < 1      // false
    }
}
