// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
// A visual child needs an ITEM parent, not just a QObject one. QQuickItem tracks visual parentage
// through parentItem; setQtParent alone leaves it null, and an item with no parentItem is not in a
// scene — so writing `visible = true` on it silently does not take. Probed directly: set false,
// then true, and it stays false. That is why a binding on `visible` used to end false where the
// engine said true; the binding was fine, the parentage was not.
Item {
    id: control
    width: 100
    property bool shown: false
    Rectangle {
        objectName: "kid"
        width: 10
        visible: control.shown          // starts false, flipped by the .set
    }
}
