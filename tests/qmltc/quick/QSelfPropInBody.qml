// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A DELEGATED BODY READING AND WRITING ITS OWN OBJECT'S PROPERTIES, by bare name.
//
// Inside a binding a bare name reads AND writes the scope object's property — that is how
// `onClicked: open = true` works. Inside a plain JS function it does not: the read still finds the
// scope object, and the write is a global assignment, which QML refuses outright with
//     Error: Invalid write to global property "out"
// A delegated body is wrapped in a function, so it lost exactly that. In the application this was
// found in, `content = newContent` left the property untouched and raised nothing on the way past:
// the page model stayed empty and the reading surface stayed blank, two calls away from the name.
//
// The occurrences are qualified by AST OFFSET rather than by matching text, which is what keeps a
// name inside a string or a parameter list out of it — the mistake that once produced
// `function (__sp_s.s)`.
//
// `out` is deliberately a D KEYWORD: the field cannot carry that name, so the property is published
// under one of its own, and this fixture is what caught two of the three places that still handed
// Qt the field's name instead.
//
// The argument crosses as a NUMBER, which is the other half: `v + base` is 7 and not "25". A
// numeric literal reaches an invoke already rendered as text, so its type has to travel with it.
import QtQuick 2.15
Item {
    id: root
    width: 40; height: 10
    property int base: 5
    property string out: "-"
    property string seen: "-"
    function poke(v) {
        if (v <= 0) return
        var k = v + base
        out = "o" + k
        root.seen = "s" + k
    }
    Component.onCompleted: root.poke(2)
}
