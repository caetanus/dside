// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A SIBLING's id. QML resolves an id anywhere in its component, so a child reads the child next to
// it by name — Qt's Fusion SwitchIndicator sizes its groove from `handle.x + handle.width`, and its
// TabButton, ProgressBar and Slider all do the same thing. None of it compiled: a name that was not
// a property of this object, of an enclosing one, or a child of THIS one simply did not resolve.
//
// The fixture covers both directions on purpose. A BACKWARD reference is the easy case; a FORWARD
// one is the one that exposes the eager order — the sibling field is still null while this object's
// own wire runs, so the connect would connect to nothing and the first value would be wrong
// forever. Both must equal the engine, which evaluates the binding when the value is first needed.
import QtQuick
Rectangle {
    id: root
    width: 200; height: 40
    color: "white"

    // FORWARD: `handle` is declared after this one.
    Rectangle {
        id: groove
        height: 6
        width: handle.x + handle.width
        color: "steelblue"
    }

    Rectangle {
        id: handle
        x: 40; y: 10
        width: 24; height: 24
        color: "tomato"
    }

    // BACKWARD, and through a second hop: `groove` was built before this one.
    Rectangle {
        id: trail
        y: 30; height: 4
        width: groove.width / 2
        color: "seagreen"
    }

    // ...and from the ROOT, where the same names are its own children rather than siblings — the
    // rule that already worked, kept here so a change to the new one cannot silently replace it.
    property real handleRight: handle.x + handle.width
    property real grooveWidth: groove.width
}
