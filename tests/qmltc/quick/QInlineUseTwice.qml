// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// TWO USE SITES OF ONE INLINE COMPONENT, and the first one is inside a delegate.
//
// `loadLocalType` hands back the SAME UiObjectDefinition for every use of `component Head: …`, and
// the merge that folds a use site into it used to WRITE to that node: the use site's members were
// appended to the definition's own list and the definition's default values were stripped where the
// use site replaced them. So the first use stayed welded to the component, and every later use
// inherited its bindings and lost the defaults.
//
// It fails in both directions here, which is the point:
//
//   * `later.open` must be the DEFINITION's default, `true`. With the defaults stripped by the
//     first use site it came out `false` — the type default of a bool the declaration no longer
//     carried a value for.
//   * `later.mark` must be "after". It inherited `inner.mark`'s binding instead, which reads `sect`
//     — an id that exists only inside the delegate. Compiled from the document root that became
//     `__outer._dc0.delegate`, a FIELD naming a Component, so the generated D did not build at all
//     and the whole document was lost. The error named the `delegate` keyword and pointed nowhere
//     near the cause.
//
// The delegate half is what makes the second use's inherited binding unresolvable, so both uses are
// needed: neither alone reproduces it.
import QtQuick

Item {
    id: root
    width: 60; height: 40
    property var rows: [7, 8]

    // THE SECOND USE SITE'S VALUES, READ FROM THE ROOT — which is the only place the differential
    // can see them. A document that binds a Component (this one has a Repeater delegate) has every
    // `data[N]` path dropped as a guess, because the view decides where its items land; so without
    // these three the target would compare the root's width and height and nothing else, and a
    // subtler leak that still produced buildable D would pass. Measured: before them the comparison
    // was 3 lines, all of them the root's own.
    property string laterMark: later.mark          // "after", not the first use site's binding
    property bool laterOpen: later.open            // true — the DEFINITION's default
    property int laterSize: later.size             // 3, likewise

    component Head: Item {
        required property string mark
        property bool open: true            // the default the first use site used to strip
        property int size: 3
        width: 10; height: 10
    }

    // AN ITEM, NOT A POSITIONER. A Column here would also compare where it PUTS its children, and
    // two Repeater items followed by a static sibling land at the wrong y — a real difference, but
    // one this fixture was not written to catch and which would make it fail for a second reason.
    // It has a probe of its own (see the `repeater-sibling-position` entry in expected-fails.json).
    Item {
        Repeater {
            model: root.rows
            // The delegate declares NOTHING of its own: a property here would be a name the engine
            // puts on each per-item instance and the dump cannot label (the delegate is a Component,
            // so those paths are not ours to name), and the leak does not depend on one — what
            // matters is that the first use site's binding reads `sect`, which exists only inside.
            delegate: Column {
                id: sect
                Head { mark: "inner"; open: sect.height > 0 }
            }
        }
        Head { id: later; objectName: "later"; mark: "after" }
    }
}
