// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A role whose NAME is only known at run time -- `model[control.textRole]`, which is how Qt's own
// ComboBox and SearchField write their delegate label. The key is computed here too (`root.key`),
// read through the enclosing document exactly as those do.
//
// The delegate here declares nothing required, which is what makes `model` readable from the
// context at all. QDelegateReqNoModel.qml is the other side of that boundary, in its own file --
// two Repeaters in ONE document does not work here, because only the first one's items are on a
// path both sides dump, so the second could never fail.
//
// Strings, again: "q0" against a bare "q".
import QtQml 2.15
import QtQuick 2.15
Item {
    id: root
    width: 100; height: 40
    property string key: "index"
    Repeater {
        model: 2
        delegate: Item {
            objectName: "q" + model[root.key]
            property string mine: "m" + model["index"]
        }
    }
}
