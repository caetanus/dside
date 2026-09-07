// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A `var` PROPERTY BOUND TO A BLOCK, which was dropped in silence.
//
// The `var` branch asked for an ExpressionStatement, and a block is not one — so a `var` bound to
// a block reached none of its paths and produced no write, no refusal and no line in the census.
// The property was declared, never written, and every view over it was empty while the document
// said it was bound and nothing anywhere disagreed.
//
// Measured on a real reader, whose book list is exactly this shape:
//
//     readonly property var visibleBooks: { … for (…) out.push(…) ; return out }
//
// The card and the filter field painted; the list was empty.
//
// `n` and `first` are on the ROOT because that is what the differential compares, and they read
// the value back THROUGH the property — a fixture that only checked the property was declared
// would have passed the whole time it was broken.
import QtQuick 2.15
Item {
    id: root
    width: 40; height: 10
    property int seed: 3
    readonly property var rows: {
        var out = []
        for (var i = 0; i < seed; ++i) out.push({ k: "r" + i })
        return out
    }
    readonly property int n: rows.length
    readonly property string first: rows.length ? rows[0].k : "-"
}
