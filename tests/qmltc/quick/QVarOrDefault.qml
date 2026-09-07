// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// `readonly property var xs: obj.xs || []` — a `var` WHOSE TYPE WAS INFERRED FROM A `||`.
//
// A `var` whose initialiser has a known type is compiled as that type, which is right and is what
// lets most of them be real D fields. But `||` and `&&` are NOT boolean in JavaScript: they yield
// one of the OPERANDS. Typed `bool`, the property became a D `bool` field, every read through it
// stopped compiling, and the list it holds was never there.
//
// Measured on a real reader's commentary panel: the header — the same parsed object, read without a
// `||` — printed its reference and its lemma, and the body under it was empty. Neither the entries
// nor the "no commentary" fallback appeared, because the property was neither a list nor an empty
// one; it was `true`.
//
// `n` and `first` read back THROUGH the property, so a type that compiles and holds the wrong thing
// fails here rather than passing quietly.
import QtQuick 2.15
Item {
    id: root
    width: 40; height: 10
    property var entry: JSON.parse('{"lemma":"a","items":[{"t":"x"},{"t":"y"},{"t":"z"}]}')
    readonly property var items: entry.items || []
    readonly property int n: items.length
    readonly property string first: items.length ? items[0].t : "-"
}
