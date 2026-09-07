// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A CHILD'S Component.onCompleted RUNS AFTER ITS BINDINGS, NOT BEFORE THEM.
//
// The completion body used to be emitted at the end of the object's own wire. For the ROOT that is
// after everything, so it was right there. For a CHILD the wire ends while the tree is still being
// built, and the cascade that installs its delegated bindings runs afterwards — including the one
// that gives a `var` property its INITIAL value. So the child's completion set the property and the
// initial binding emptied it a moment later, with nothing anywhere saying so.
//
// Measured on a real reader, which loads its first page from a child's completion handler: the page
// model was set and then reset to `[]`, and the reading surface stayed blank while every diagnostic
// said the document had compiled.
//
// `n` is on the ROOT because the differential compares the root's properties, and it is read from
// the ROOT's completion — which runs after the child's, since the cascade completes bottom-up. A
// fixture that asserted the child's own property would not have told the two orders apart.
import QtQuick 2.15
Item {
    id: root
    width: 40; height: 10
    property int n: -1
    Item {
        id: kid
        property var content: []
        Component.onCompleted: content = [1, 2, 3]
    }
    Component.onCompleted: root.n = kid.content.length
}
