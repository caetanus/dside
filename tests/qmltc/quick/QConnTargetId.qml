// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A DELEGATED Connections THAT NAMES A SIBLING AS ITS TARGET.
//
// This compiler takes a Connections only when it targets the object itself; any other target — a
// sibling's id, a context property — is handed to the engine, which builds the whole element from
// the document's own text. But `target: t` names an ID OF OURS: a D field, with no name the engine
// could look up. Handed nothing, the Connections had no target at all and its handlers never fired,
// silently — a real reader's search results were computed by the backend and never collected, and
// the screen said "nothing found".
//
// The objects the body names are handed over with it now. They are resolved in the PARENT's scope
// and used in the child's wire, where the parent's fields have no names of their own, so each is
// rewritten against the enclosing object — `instOf(_dc0)` there is `undefined identifier _dc0`, and
// that is a compile error rather than a wrong value only by luck.
//
// `seen` is a BINDING on the property the handler writes, not a handler of its own: read from a
// second handler it depended on which of the two ran first, and the two sides connect in different
// orders — a difference about ordering, not about whether the Connections fired at all. A
// Connections that exists and does nothing looks exactly like one that works until a value is
// compared, and this compares one that cannot be confused with the order.
import QtQuick 2.15
Item {
    id: root
    width: 40; height: 10
    property var v: ({ a: 0 })
    readonly property int seen: v.a
    Timer {
        id: t
        interval: 10; running: true; repeat: false
    }
    Connections {
        target: t
        function onTriggered() { root.v = { a: 7 } }
    }
}
