// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// `parent` INSIDE A DELEGATE IS NOT THE ENCLOSING OBJECT.
//
// A Repeater parents its items to its OWN parent, never to itself. The dependency collector did not
// know that: it recorded `parent.width` as `__outer.width` — true for an ordinary child, false here
// — so the wiring emitted a `findOuter(<Repeater class>)` for a frame that is not an ancestor of
// the delegate at run time. That returns null, and the delegate's whole ready step BAILS OUT before
// setting anything at all: not one property, not the children.
//
// So the cost is not one wrong binding, it is the entire object. Measured on a real reader's
// settings panel: twelve translation rows created and every one of them 0x0 and invisible, against
// the engine's twelve — `hasContext` true, `findOuter` null, twelve times, in silence. It closed
// two of the sixteen captured states at once (the settings panel at 17.8% of pixels and the font
// menu at 2.9%).
//
// The delegate's own `parent` was live the whole time — the late phase binds it — so recording it
// as the outer's bought nothing and cost everything. `height` is asserted beside `width` precisely
// because it is a CONSTANT: if it comes back 0, nothing in the object ran.
import QtQuick 2.15
Item {
    id: root
    width: 100; height: 60

    property int pick: 1
    // Written from inside the delegate: its own geometry, reported out.
    property int seenW: -1
    property int seenH: -1

    Column {
        id: col
        width: 80

        Repeater {
            model: 2
            Rectangle {
                required property int index
                width: parent.width          // the Column, NOT the Repeater
                height: 12                   // a constant: 0 here means the object never ran
                color: index === root.pick ? "#204080" : "#808080"
                Component.onCompleted: if (index === 0) { root.seenW = width; root.seenH = height }
            }
        }
    }
}
