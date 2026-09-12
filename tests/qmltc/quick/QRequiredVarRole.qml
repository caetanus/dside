// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A `required property var` ROLE, WHICH WAS DECLARED BY NOBODY AND FILLED BY NOBODY.
//
// A required property inside a delegate is a value the VIEW hands in. The fill table types one as
// string, int, bool or double — a `var` is none of those — and the declaration path excluded a
// required `var` outright. So the property became nothing at all: no field on the class, so an
// id-qualified read of it from a child had nothing to find, and no fill, so there would have been
// nothing in it anyway. One role type missing from two per-type tables at once.
//
// Measured on a real reader's search panel, whose delegate declares `required property string
// label` beside `required property var refs`: the section heading painted from `label` and the
// verses under it never appeared, because the inner Repeater's model is `refs`. Closing it made
// that whole panel byte-identical to the engine's.
//
// The two roles are declared side by side here for exactly that reason: the typed one worked and
// the `var` one did not, which is the pair that says where to look.
import QtQuick 2.15
Item {
    id: root
    width: 60; height: 30

    property var groups: JSON.parse('[{"label":"um","refs":[{"t":"a"},{"t":"b"},{"t":"c"}]}]')

    // Reported out of the delegate: an id declared in one is not visible outside it.
    property string seenLabel: "?"
    property int seenRefs: -1
    property string seenFirst: "?"

    Column {
        Repeater {
            model: root.groups
            // AN ITEM, NOT A COLUMN, and only because of what the object-path variant compares: the
            // two sides disagree on the `__class` of a delegate whose root is a type that declares no
            // properties of its own (QQuickColumn), which is a real difference in the class walk and
            // has a probe of its own (`delegate-class-walk` in expected-fails.json). Nothing in this
            // fixture's subject — a required property filled by the VIEW — depends on the type.
            delegate: Item {
                required property string label
                required property var refs
                Component.onCompleted: {
                    root.seenLabel = label
                    root.seenRefs = refs ? refs.length : -1
                    root.seenFirst = (refs && refs.length) ? refs[0].t : "-"
                }
            }
        }
    }
}
