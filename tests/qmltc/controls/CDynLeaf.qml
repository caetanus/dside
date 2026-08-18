// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
import QtQuick.Templates as T
// A READ THROUGH A PROPERTY WHOSE DECLARED TYPE DOES NOT HAVE THE MEMBER.
//
// Qt's whole Imagine style is written this way — `topPadding: background ? background.topPadding : 0`
// on every control, where `background` is declared `Item` and `topPadding` belongs to the
// NinePatchImage actually assigned. Measured over the five styles: 516 such reads in 71 documents.
//
// The compiler used to refuse the read (no static table can say what the member is) and hand the
// expression to the engine, so the VALUE was right and the CERTAINTY was not — an -O1 document
// cannot contain a delegation. This pins both halves of the replacement: the read resolves through
// the object's own meta-object, and the re-evaluation subscribes to the notify that meta-object
// names. Neither is available from `Item`, which is all the declared type says.
T.Control {
    id: control
    width: 120
    height: 60

    property real rad: 6

    background: Rectangle {
        implicitWidth: 40
        implicitHeight: 20
        radius: control.rad
        antialiasing: true
    }

    // `background` is an Item. `radius` and `antialiasing` are the Rectangle's.
    property real r: background ? background.radius : -1
    property bool aa: background ? background.antialiasing : false
    // The Imagine spelling exactly: negated, with JS `||` as the zero guard.
    property real neg: background ? -background.radius || 0 : 0

    // ...and the leaf must be LIVE. Writing `rad` fires the Rectangle's radiusChanged, which no
    // table of Item's properties knows about; wire only the initial value and `r` stays 6.
    Component.onCompleted: control.rad = 9
}
