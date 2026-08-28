// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A FUNCTION ON AN ENCLOSING OBJECT, CALLED WITH VALUES — and the values have to arrive.
//
// A call from a child to a function of the object that encloses it goes through the meta channel
// (`invokeMixed`), because the child has no D-level handle on the enclosing class's method. Every
// argument that was neither a string nor a colour used to fall through to `qobjOf`, which is for
// QObjects, so a `double` instantiated `qobjOf!double` and the unit stopped having an object file:
//
//     qtmoc.d(286): Error: invalid cast from `double` to `void*`
//
// It compiled. `ldc2 -c -o-` reports zero errors on the same file — the cast only fails when code
// is actually generated — which is why this document exists rather than a compile check.
//
// BOTH SPELLINGS, on purpose. A literal argument never hit the bug: the compiler wraps one in
// `numText()` before the call, so the two paths disagreed about whose job the conversion is. They
// are compared here against each other and against the engine, so neither can drift alone.
//
// Typed parameters because an untyped one is a separate gap (`a parameter whose type cannot be
// determined from its use`) and this document is about the crossing, not about inference.
import QtQuick
Item {
    id: outer

    property string fromVars: ""
    property string fromLits: ""

    // Each stores its own result rather than returning it: assigning the RESULT of a call to a
    // property of the ENCLOSING object is a separate gap, and a fixture that trips over it would
    // measure that instead of this.
    function takeVars(a: real, b: int, c: bool, d: string) {
        fromVars = a + "|" + b + "|" + c + "|" + d
    }
    function takeLits(a: real, b: int, c: bool, d: string) {
        fromLits = a + "|" + b + "|" + c + "|" + d
    }

    Item {
        Component.onCompleted: {
            var a = 1.5
            var b = -3
            var c = true
            var d = "x"
            outer.takeVars(a, b, c, d)
            outer.takeLits(1.5, -3, true, "x")
        }
    }
}
