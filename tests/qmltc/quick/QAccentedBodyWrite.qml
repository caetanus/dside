// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A DELEGATED BODY THAT CONTAINS AN ACCENT, AND THE WRITES AFTER IT.
//
// A body handed to the engine is wrapped in a function, and that costs the QML scope: inside a
// binding a bare name reads AND writes the scope object's property, inside a plain JS function the
// write is a global assignment that QML drops. So each own-property occurrence is qualified with
// the object, by AST offset.
//
// The parser counts UTF-16 units and the string being rewritten holds UTF-8 BYTES, which are the
// same number only while the source is ASCII. Every accented character is one unit and two bytes,
// so each offset ran further ahead of the byte it meant — measured on a real reader's map, 6 bytes
// early a third of the way into a function and 10 by its end, because the body says
// "o atlas não chegou" on the way past.
//
// Every qualification after the first accent then landed just before its own name, the verify
// declined — rightly; it must never write into the middle of an expression — and the name was left
// BARE. Nothing was raised anywhere: the function ran, the values were computed, and the writes
// went to globals. Four of six properties in one function were lost that way.
//
// `first` is written BEFORE the accent and `second`/`third` after it, which is the whole test: on
// the unfixed compiler the first lands and the rest do not.
import QtQuick 2.15
Item {
    id: root
    width: 40; height: 10

    property string first: "?"
    property string second: "?"
    property int third: -1   // 3 = 1 + 2, computed after the accent

    function load(a) {
        first = "um"
        // The accents are the point. They are ordinary application text — a Portuguese, French or
        // Spanish document has them in every other line.
        var msg = "não chegou · atenção · coração"
        // A loop over a parsed object is what sends this body to the engine, which is the only
        // route on which the qualification runs at all.
        var acc = 0
        for (var i = 0; i < a.rows.length; ++i) acc += a.rows[i].n
        if (msg.length < 0) return
        second = "dois"
        third = acc
    }

    Component.onCompleted: load(JSON.parse('{"rows":[{"n":1},{"n":2}]}'))
}
