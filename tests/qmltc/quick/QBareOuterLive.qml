// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A BARE OUTER NAME AFTER THE VALUE BEHIND IT CHANGES.
//
// The compiled document resolves a name it does not declare with a PROMISE, which finds the object
// that owns the name and reads it — ONCE. That read is a snapshot, and for a plain value (a list, a
// number, a string) nothing brought a later change back: measured with the list replaced 60 ms in,
// the qualified read followed the engine to 3 while the bare one stayed at the 1 it resolved to.
//
// A read that is right at startup and wrong ever after is worse than one that is always wrong,
// because nothing about it looks broken — which is why this fixture is in the TIMED table rather
// than the property dump. At t=0 both spellings say 1 and a dump would call that agreement.
//
// Keeping it current means hearing the owner's NOTIFY, and hearing a signal means being a receiver
// with a SLOT — which this runtime has no moc to declare. It does not need one: a meta-object is
// data, QMetaObjectBuilder builds it, qt_metacall dispatches it, and that is the same channel the
// runtime already puts D slots on. See QtdScopeWatch in runtime/qtmoc/qtdmoc_qml.cpp.
import QtQuick 2.15
Item {
    id: root
    width: 40; height: 10

    property var entry: JSON.parse('{"items":[{"t":"a"}]}')
    readonly property var items: entry.items || []

    // The value the harness compares, on the root, taken from the BARE read two levels down.
    property int n: probe.nb

    // DECLARED FIRST on purpose, and this is about the harness rather than the behaviour.
    // QQuickItem hands back its non-visual children through `data` BEFORE its visual ones,
    // whatever the source order, so declaring the Item first gave the compiled side and the engine
    // different INDEXES for the same object: the oracle walked `data[0]` into a QQmlTimer, refused
    // the path and printed nothing at all for the document — which reads as a total mismatch.
    Timer {
        interval: 60; running: true
        onTriggered: root.entry = JSON.parse('{"items":[{"t":"a"},{"t":"b"},{"t":"c"}]}')
    }

    Item {
        Item { id: probe; property int nb: items.length }
    }
}
