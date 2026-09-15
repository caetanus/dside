// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A MEMBER READ THROUGH A NAME THE APPLICATION PUBLISHED, which is the shape that refuses most of a
// real application.
//
// `theme` is a context property: an object the program owns, handed to QML by name (apptypes.d
// publishes it, and the same list reaches the oracle's engine, so both sides of the differential
// read the same object). Nothing in this document names its type, and no registry can answer for it
// — which is exactly why the compiler refused every read through it and sent the expression to the
// engine.
//
// Measured on a real reader's Main.qml: 339 expressions delegated, and the single commonest shape is
// this one — 75 expressions whose head is `theme`, 91 mentions of `theme.<member>` (paper 22, ink 21,
// accent 20, muted 16, border 6). The compiler was adding machinery to a document that stayed
// interpreted, and the startup cost showed it: 118 ms interpreted against 226 ms compiled.
//
// The type is not what was missing. Three mechanisms already answer this, each already used
// elsewhere: the scope PROMISE resolves the object the way the engine does (QQmlContext::
// contextProperty), the meta-object reads a member by name in the TARGET's own terms, and a notify
// is connected by name (`<prop>Changed()`, or the object's own `changed()`). What was missing is the
// branch that puts them together when the BASE of the read is a name with no type.
//
// So this document must compile with NO delegation — `qmltc-pedantic-DCtxTheme` says so, and it
// failed before the branch existed — and the values must match the engine, which is what says the
// meta read and the engine's own read agree.
// Rooted in an app-defined D type because this corpus is built against the QtQml binding, which has
// no QtQuick in it: the shape being measured is the READ, and it needs no visual type at all.
import AppTypes 1.0

Backend {
    // 3, so that `same` below is TRUE: false is what a bool property holds when nothing wrote it,
    // and a comparison that is false either way cannot tell a correct read from a read that threw.
    value: 3

    // A string member, under a per-property notify (`paperChanged`).
    property string p: theme.paper
    // ...the same read with the object's own `changed()` as its notify, which is the other spelling
    // a real application uses.
    property string ink: theme.ink
    // ...and an int, so the reader is chosen by the TARGET's declared type and not by a guess.
    property int steps: theme.steps
    // ...and inside a larger expression, which is where a refusal costs the whole binding.
    property string both: "p=" + theme.paper + " n=" + theme.steps
    // ...and COMPARED, which is the caller that offers no type at all. A comparison compiles its
    // operands untyped first and infers from the other side only when that fails, so a read which
    // answers an untyped request with a guess breaks it: `propAny!string(...) == value` against an
    // int is a D compile error, and it was a real document that found it (a `landed` that is an int,
    // where every theme member so far had been a colour).
    property bool same: theme.steps === value
    property bool via: theme.steps > 2 && theme.paper !== ""
}
