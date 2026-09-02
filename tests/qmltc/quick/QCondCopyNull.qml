// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A CONDITIONAL COPY WHOSE TEST READS THROUGH `parent`, WHICH IS NULL WHILE THE OBJECT IS WIRED.
//
// Both branches are VALUE-TYPE copies, and a copy is a STATEMENT rather than an expression, so
// the whole binding compiles to a BLOCK:
//
//     if (propAny!bool(propObj(this, "parent"), "current")) {
//         copyProp(__outer.__outer, "paper", this, "color");
//     } else { … }
//
// The re-evaluation slot for that expression is wrapped in `bindEval`, which is what makes a
// binding that dereferences null abort and write nothing — the engine's own behaviour. The INITIAL
// evaluation was not: `guardWire` decides what to wrap by looking at one LINE at a time, and a
// block matches none of its tests.
//
// `current` is deliberately a property the parent's TYPE does not declare, because that is what
// picks `propAny`, and `propAny` throws QmlNullDeref for a property that is not there whether or
// not a binding is running. So the throw left `__qmltcWire`, unwound through every `__qmltcKids`
// above it, and ended the program. It killed a real application at startup rather than costing it
// one property — the reader's window never opened, and the exception's own text ("null has no
// property 'current'") named a delegate eight levels down. Measured rather than reasoned: gdb on
// the built binary, breakpoint on `_d_throw_exception`, frame #2
// `Main_dc9_dc1_dc3_dc2_dc0_dc0_dc0_dc0.__qmltcWire()`.
//
// The fixture asserts the VALUE against the engine, so it fails both ways: unguarded the process
// dies, and a guard that swallowed the re-evaluation too would leave the colour at its default
// instead of the branch the engine takes.
import QtQuick

Item {
    id: root
    width: 40; height: 20

    property color paper: "#ff0000"
    property color ink: "#0000ff"

    Item {
        anchors.fill: parent
        property bool current: true
        Text {
            objectName: "leaf"
            text: "x"
            color: parent.current ? root.paper : root.ink
        }
    }
}
