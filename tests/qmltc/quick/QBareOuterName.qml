// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A NAME THIS OBJECT DOES NOT DECLARE, READ WITHOUT AN ID TO QUALIFY IT.
//
// `items` is declared on the root and read two levels down as a bare name. The engine resolves it
// by walking the scope chain; a compiled document resolves it with a PROMISE, which looks for the
// object that owns the name and, until this fixture existed, walked `QObject::parent()` to do it.
//
// A compiled document attaches a child by writing its `parent` PROPERTY — which is what the QML
// source says. For a QQuickItem that is the VISUAL parent, and `setParentItem` does not set the
// QObject parent, so a fully-built compiled tree has `QObject::parent() == nullptr` at every level.
// The walk stood still: `0 ancestors` after all 32 retries, on an object whose visual grandparent
// declared the very name being asked for.
//
// It never surfaced as a refusal. The promise stayed unresolved, its property map kept no key, and
// JS read `undefined` — so `nBare` (an `int`) took `undefined.length` as 0 while `emptyBare` took
// `undefined.length === 0` as FALSE, at the same instant, on the same object, in the same pass.
// That is how it was reported from a real reader: a Repeater over the same property ITERATED while
// the "nothing here" fallback beside it was also visible. The qualified read went to the object and
// the bare one to an empty map.
//
// Both routes are asserted, and the point of the fixture is that they AGREE.
import QtQuick 2.15
Item {
    id: root
    width: 40; height: 10

    property var entry: JSON.parse('{"items":[{"t":"x"},{"t":"y"}]}')
    readonly property var items: entry.items || []

    // Published on the root, because a value asserted only where it is computed is a value the
    // differential does not compare.
    readonly property int nBare: probe.nb
    readonly property int nQual: probe.nq
    readonly property bool emptyBare: probe.eb
    readonly property string firstBare: probe.fb

    Item {
        Item {
            id: probe
            property int nb: items.length              // bare: the scope chain answers
            property int nq: root.items.length         // qualified: the object answers
            property bool eb: items.length === 0
            property string fb: items.length ? items[0].t : "-"
        }
    }
}
