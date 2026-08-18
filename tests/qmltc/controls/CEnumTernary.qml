// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
import QtQuick.Templates as T
// A ternary between two ENUM MEMBERS (`alignment: cond ? Qt.AlignCenter : Qt.AlignLeft`, which is
// how Qt's Controls align an IconLabel). The direct form was accepted and this one was not — the
// same asymmetry that kept turning up, where one spelling compiles and the other does not. Each
// branch becomes a KEY STRING and the meta-object converts through QMetaEnum.
//
// `checked` is true, so the TRUE branch must win, and AlignRight is not the default (AlignLeft is).
T.Button {
    id: control
    checkable: true
    checked: true
    contentItem: T.Label {
        objectName: "lab"
        text: "x"
        horizontalAlignment: control.checked ? Qt.AlignRight : Qt.AlignLeft
    }
}
