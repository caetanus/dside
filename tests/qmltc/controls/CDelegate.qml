// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// The Component acceptance test. `delegate:` is a TEMPLATE the type instantiates itself, so the
// bar is not "delegate is non-null" — it is that the items EXIST, match the engine property for
// property, and that a binding INSIDE one which reads the enclosing document has the engine's
// value. Point 3 is what separates a real Component from a detached one.
import QtQuick
Item {
    id: root
    width: 200; height: 60
    property string tag: "outer"
    property int bump: 1
    Repeater {
        model: 3
        delegate: Text {
            // reads the ENCLOSING document — the whole point of the test
            text: root.tag + "-" + index
            x: index * 10 + root.bump
        }
    }
}
