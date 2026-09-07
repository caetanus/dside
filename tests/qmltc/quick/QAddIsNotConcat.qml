// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// `+` BETWEEN TWO NUMBERS IS ADDITION, WHATEVER THE TARGET IS.
//
// JS concatenates when an OPERAND is a string; the property being written has no say in it. The
// compiler asked the TARGET instead, so `+` in anything feeding text became `~`.
//
// Measured on a real reader's book navigator: `text: index + 1` numbered the chapters
// 01, 11, 21, 31 … 101, 111 — `to!string(index) ~ to!string(1)` — where the engine numbered them
// 1 to 28. `2 + 3` came out "23". Nothing was refused and nothing was reported; the grid looked
// like a grid, with the wrong numbers in it.
//
// The three concatenating forms are asserted beside the two adding ones, because the fix has to
// leave them alone — and `e` because a numeric add NESTED in a concatenation was already right and
// must stay right.
import QtQuick 2.15
Item {
    id: root
    width: 40; height: 10

    property int n: 7

    readonly property string a: n + 1        // "8"
    readonly property string b: 2 + 3        // "5"
    readonly property string c: "x" + n      // "x7"
    readonly property string d: n + "x"      // "7x"
    readonly property string e: "s=" + (n + 1)   // "s=8"
}
