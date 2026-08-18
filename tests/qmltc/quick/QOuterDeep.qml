// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
// The root's id read from TWO levels down, through an ANONYMOUS intermediate. `__outer` is always
// the IMMEDIATE parent, so a farther id is reached by hopping (`__outer.__outer.gap`) and the
// intermediate has to carry its own back-reference. Declaring the field as the id-bearing
// ancestor's class instead would compile and then reinterpret the parent as that class — a cast
// from void* in D is unchecked, so it reads another object's fields rather than failing. Qt's own
// Controls nest this deep routinely.
Item {
    id: control
    property real gap: 5
    Item {
        Rectangle {
            objectName: "deep"
            width: control.gap * 2
        }
    }
}
