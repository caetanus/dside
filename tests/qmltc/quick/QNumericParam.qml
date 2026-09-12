// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// TWO KINDS OF EVIDENCE ABOUT ONE PARAMETER, and only one of them is evidence.
//
//     function pad(n) { return n < 10 ? "0" + n : String(n) }
//
// `"0" + n` was read as proof that `n` is a string. It is not: JavaScript coerces the OTHER operand
// there, so a number concatenates just as happily — while `n < 10` compares numerically and is
// proof. Typed `string` from the concatenation, the generated D then compared a string with a
// double:
//
//     Error: incompatible types for `(n) < (10.0)`: `string` and `double`
//
// With the two readings in conflict the type is not knowable here, which is the case the compiler
// already has an answer for: leave the parameter untyped and let the engine run the body. That is
// the same outcome Qt reaches for the same shape.
//
// Both results are compared against the engine, so a wrong inference in either direction shows: a
// numeric `pad` would give "07" and "12" too, but `String(n)` on a string parameter is where they
// part company, and neither spelling builds today unless the type is left open.
import QtQuick

Item {
    id: root
    width: 10; height: 10

    function pad(n) { return n < 10 ? "0" + n : String(n) }

    property string lo: pad(7)
    property string hi: pad(12)
    property string qualified: root.pad(3)      // ...and through the object's own id
}
