// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A TYPED FUNCTION CALLING AN UNTYPED ONE, which is two signatures that have to agree.
//
// `same(y)` has no evidence for what `y` is — `===` compares anything — so the compiler refuses to
// guess: the function is declared to the meta-object with QmlVarRef throughout and its body is
// handed to the engine. `tap(n)` is typed (the assignment pins `n` to int), so its call to `same`
// passes an int to a QVariant signature:
//
//     Error: function `same` is not callable using argument types `(int)`
//
// Two documents of a real application failed on that. The cause was that the call site typed each
// argument after the CALL's own target type instead of after the callee's parameters — which the
// signal-emit path beside it had always done correctly. The signature is now decided ONCE, in the
// prescan, so a call site compiled before the function's own body cannot disagree with it; the
// arguments are boxed with varOf and the result unboxed with varAs.
//
// It fails both ways: unboxed it does not build, and a wrong conversion would land a different
// number in `picked`, which is compared against the engine.
import QtQuick

Item {
    id: root
    width: 10; height: 10

    property int picked: 0
    property int also: 0

    function same(y) { return y === 2 }              // untyped: delegated, QmlVarRef in and out
    function tap(n) { root.picked = n; if (same(n)) root.picked = 10 }

    Component.onCompleted: { root.tap(2); root.also = same(3) ? 1 : 2 }
}
