// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A Connections element attaches handlers to a target's signals from OUTSIDE the target's own
// declaration — the handlers live in a separate element, but the wiring must behave exactly like
// an inline `onPing:`. A QtObject root has no default property, so Connections is held by a
// property (the only spelling QML accepts here). Target is the root, isolating Connections itself.
//
// Structural difference, on purpose: the engine really does build a Connections OBJECT and holds
// it in `conn`, while the compiled D side builds no object at all — the element is desugared into
// connections. That does not weaken the comparison: an object-valued property carries no scalar of
// its own (--verify-props recurses into it), and Connections declares nothing in this document.
import QtQml 2.15
QtObject {
    id: root
    signal ping(int n)
    signal named(string who)
    property int received: 0
    property string tag: ""
    function fire() { ping(5); named("Ada") }
    property QtObject conn: Connections {
        target: root
        function onPing(n) { root.received = n + 1 }
        function onNamed(who) { root.tag = "from " + who }
    }
    Component.onCompleted: fire()
}
