// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// `anchors.fill: parent` INSIDE A DELEGATE, where `parent` is the object's own, not a context name.
//
// A delegate's per-item context carries names the type does not declare — `index`, `modelData`, a
// model role — and a bare name inside one is answered from there. The test for "does the type
// declare it" asked g_baseProps, which holds only the base properties the DOCUMENT BINDS. `parent`
// is a property of every QQuickItem and is usually only read, so it was absent, and a bare `parent`
// inside a delegate was answered from the context AS TEXT:
//
//     setProp(propObj(this, "anchors"), "fill", contextStr(this, "parent"))
//
// — a QString written into a property that takes an ITEM. Measured on a real reader: 76 anchor
// writes in ONE document went that way, `fill` and `centerIn` both, every one inside a delegate.
// Nothing anchored and nothing said so. The same two lines OUTSIDE a delegate compiled correctly,
// which is why a corpus of Qt's own styles — which anchor in delegates rarely — never showed it.
//
// The width is asserted on the ROOT, because a value compared only where it is computed is a value
// the differential does not compare.
import QtQuick 2.15
Item {
    id: root
    width: 60; height: 20

    // Written from INSIDE the delegate: an id declared in one is not visible outside it, in QML or
    // here, so the delegate reports its own geometry rather than the root reaching in for it.
    property int fillW: -1
    property int fillH: -1
    property int centerX: -1

    Row {
        Repeater {
            model: 1
            delegate: Item {
                width: 30; height: 12
                Rectangle { id: inner; anchors.fill: parent; color: "#204080" }
                Rectangle { id: mid; width: 10; height: 4; anchors.centerIn: parent }
                Component.onCompleted: {
                    root.fillW = inner.width; root.fillH = inner.height; root.centerX = mid.x
                }
            }
        }
    }
}
