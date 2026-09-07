// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A DELEGATE WHOSE TYPE THIS COMPILER DOES NOT BIND BUT THE ENGINE KNOWS.
//
// A `Shape` written as a DIRECT CHILD is built by createQmlObjectAny with the document's own
// imports and renders. The same `Shape` written as a Repeater's `delegate` was refused outright —
// "not a bound Qt type — skipped" — because the Component branch never asked the question the
// child branch already answers.
//
// Measured on a real reader's map: the journey route (one Shape, a direct child) drew, and every
// coastline and border (Shapes, all of them delegates) was absent. That is the bulk of a 42.6%
// frame difference, and it is neither a missing plugin nor a renderer difference — QtQuick.Shapes
// was installed and loaded the whole time.
//
// The delegate is handed over as TEXT with the document's imports, which is what the engine would
// have read. ALL of them, not the first: a Shape's body names `ShapePath` and `PathLine` from
// QtQuick.Shapes while everything around it is QtQuick, and given one import the engine answered
// `Shape is not a type`.
//
// Both spellings are in the document on purpose: the one that already worked has to keep working.
import QtQuick 2.15
import QtQuick.Shapes 1.15
Item {
    id: root
    width: 60; height: 40

    // The route that already worked: a direct child.
    Shape {
        ShapePath { strokeColor: "#204080"; strokeWidth: 2; startX: 2; startY: 2
                    PathLine { x: 20; y: 20 } }
    }

    // The one that was skipped.
    Item {
        Repeater {
            model: 2
            delegate: Shape {
                ShapePath { strokeColor: "#804020"; strokeWidth: 2; startX: 2; startY: 2
                            PathLine { x: 10; y: 10 } }
            }
        }
    }
}
