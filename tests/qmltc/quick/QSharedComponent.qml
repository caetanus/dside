// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// TWO REPEATERS SHARING ONE NAMED `Component`, which is the shape an application writes when the
// same row is drawn in more than one place.
//
// A `Component` is SKIPPED as a child — it is a template, and compiling it would instantiate its
// contents eagerly, which the compiler says out loud. But the id still names it, and resolving
// `delegate: shared` through the ordinary child path produced a field for the child that was never
// emitted:
//
//     setPropObj(this, "delegate", instOf(__outer.__outer._dc0._dc2));
//     Error: no property `_dc2` for type `L_dc0`      (only _dc0 exists)
//
// Reported from a real application (Lectio's Settings.qml, two Repeaters on one Component) and
// reduced to eight lines. It disappears with an inline delegate, because then no child is skipped —
// which is why a corpus of inline delegates never showed it.
//
// What the document means is what an inline `delegate: Rectangle {}` means, so it is handed over the
// same way: the template's body with this document's imports.
//
// WHAT THIS ASSERTS, AND WHAT IT DELIBERATELY DOES NOT. The claim is that the document BUILDS and
// that the shared Component reaches both Repeaters — a regression puts `_dc2` back and the target
// goes red on a compile error, which is the whole of the reported bug.
//
// It does NOT assert the column's height, though that is the value a reader reaches for first. A
// Column holding Repeaters reports 0 here against the engine's 40, and the INLINE delegate of the
// same shape reports 0 too — measured, by putting the inline form through this same harness. So the
// height would make this fixture red for a defect it was not written for, which is how two fixtures
// of mine shipped red. That difference has a probe of its own: `repeater-in-positioner-height` in
// expected-fails.json.
import QtQuick

Item {
    id: root
    width: 40; height: 60

    // AN EMPTY MODEL, deliberately. The subject is that `delegate: shared` COMPILES and resolves to
    // the template; creating items would drag in where a view PUTS them, and Qt's Repeater inserts
    // its items before itself, so every `data[N]` after that is a guess on both the label and the
    // object-path side. Measured with a two-row model: ours reports QQuickRectangle at
    // data[0].data[0] where the engine reports the QQmlComponent. With no items there is nothing to
    // number and the fixture fails only for its own reason.
    property int firstCount: r1.count        // 0 on both sides
    property int secondCount: r2.count

    // The Component is the ROOT'S LAST child, not the Column's, and that placement is the fixture
    // working around a gap rather than hiding one. A skipped child shifts every `data[N]` after it,
    // so with the Component inside the Column our `data[0].data[0]` is the delegate's Rectangle
    // while the engine's is the QQmlComponent — measured, and it is the documented index-shift gap,
    // not this fix. Last at the root, nothing of ours is numbered behind it.
    Column {
        Repeater { id: r1; model: 0; delegate: shared }
        Repeater { id: r2; model: 0; delegate: shared }
    }
    Component { id: shared; Rectangle { width: 10; height: 10 } }
}
