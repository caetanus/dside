// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A VALUE SOURCE ON THE ROOT'S OWN PROPERTY. `Behavior on color` at the top level of a document is
// ordinary application QML — a real reader's Main.qml opens with one — and it is the only place a
// value source has to attach to the object that is still being constructed rather than to a child
// that is already there.
//
// Kept as a fixture because the root is the one object built by `newQObject` from outside the
// document, so its wire body runs on a different path from every child's.
import QtQuick

Rectangle {
    id: root
    width: 40; height: 20
    color: "#ff0000"
    Behavior on color { ColorAnimation { duration: 320 } }
}
