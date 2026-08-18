// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
import QtQuick.Templates as T
// A VALUE-typed source written into an OBJECT group: `border.color: control.palette.dark` is how
// Qt's Controls colour a border. The group is an object, so this is the same QVariant copy a base
// property uses, with the group object as the destination — the type is carried by the variant,
// not known by the generator. This also finally gives copyGroupProp a test with teeth: `mid` is a
// palette role, so the compared value is not a default.
T.Control {
    id: control
    palette.mid: "seagreen"
    contentItem: Rectangle {
        objectName: "bg"
        border.width: 2
        border.color: control.palette.mid
    }
}
