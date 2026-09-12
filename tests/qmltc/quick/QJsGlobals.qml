// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// THE JAVASCRIPT GLOBALS THAT ARE FUNCTIONS, not methods of a receiver.
//
// `Math.max(…)` parses as a member call and has been compiled for a long time; these have no
// receiver, so they parse as a bare identifier call and were emitted VERBATIM — `undefined
// identifier encodeURIComponent`, and with it the whole document. Five documents of a real
// application used one of these.
//
// Compiled rather than delegated because each one's semantics are exact and worth keeping compiled:
// RFC 3986's unreserved set is the one JS keeps, `parseInt` reads the longest numeric prefix (which
// `to!int` does not — it throws), and `String(x)` is nothing but the argument coerced to a string,
// so the call disappears into the coercion the compiler already does.
//
// Every expected value here is what the ENGINE answers for the same call, which is what the
// differential compares — including the two that are easy to get wrong: `parseInt("42px")` is 42
// rather than a refusal, and a bare `0x` prefix means radix 16 when no radix is given.
import QtQuick

Item {
    id: root
    width: 10; height: 10

    property real zero: 0

    property string enc: encodeURIComponent("a b/á?x=1")
    property string dec: decodeURIComponent("a%20b%2F%C3%A1")
    property int n1: parseInt("42px")
    property int n2: parseInt("0x1f")
    property int n3: parseInt("  -7 ")
    property int n4: parseInt("nope")
    property bool nan1: isNaN(root.zero / root.zero)
    property bool nan2: isNaN(root.zero)
    property string s1: String(7)
    property string s2: String(1.5)
    property string s3: String(true)
}
