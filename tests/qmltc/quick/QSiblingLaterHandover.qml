// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A DELEGATED BINDING THAT NAMES A SIBLING DECLARED FURTHER DOWN THE DOCUMENT.
//
// An expression the compiler cannot compile is handed to the engine, together with the objects the
// ids in it name. Those objects are FIELDS of an enclosing object, assigned as that object builds
// its children IN ORDER — so an id declared below is still null where the handover is installed,
// and the expression threw `Cannot read property 'open' of null` at wire time and never ran again.
// The property kept its DEFAULT, which for a Rectangle's colour is pure white.
//
// The rule that defers such a handover to the late phase existed and listed two shapes — a read
// through `propObj(`, and a `scopePromise(` — and not this one. Measured on a real reader's header:
// `color: fontMenu.open ? … : "transparent"` painted a 38x24 block of white where the page's paper
// should have shown through, while `border.color` on the SAME element was alive, because it also
// reads a promised name and so happened to match the other clause. Two bindings on one object, one
// live and one dead, and the difference was which clause fired.
//
// `panel` is declared AFTER the rectangle that reads it, which is the whole point.
import QtQuick 2.15
Item {
    id: root
    width: 40; height: 20

    readonly property string got: swatch.color
    readonly property bool seen: panel.open

    Rectangle {
        id: swatch
        width: 20; height: 10
        // Not compilable (a `var` read through a sibling), so it is handed to the engine — with
        // `panel`, which does not exist yet at this point in the build.
        color: panel.open ? "#112233" : "#445566"
    }

    Item {
        id: panel
        property bool open: false
    }
}
