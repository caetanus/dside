// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// An object-or-NULL ternary on a DECLARED property, which is the shape Qt's Basic ComboBox writes
// for its highlight rectangle:
//   property Item highlightedItem: parent ? parent.itemAtIndex(control.highlightedIndex) : null
// The BASE-property path has had object-or-null since the Fusion gradients needed it; the declared
// one did not, so the property was refused and with it its declaration.
//
// Two halves are compared here, because two different things were missing. `present` asks a bare
// object NAME as a truth test -- `control.background ? …` compiled and `parent ? …` did not, the
// same question in two spellings -- and takes the CALL branch. `absent` takes the null branch, and
// is what proves the condition is really being evaluated rather than assumed true.
import QtQuick
Item {
    id: root
    width: 100; height: 40
    Item { id: kid; x: 0; y: 0; width: 50; height: 20; objectName: "the-kid" }
    property Item present: kid ? root.childAt(10, 10) : null
    property Item absent: gone ? root.childAt(10, 10) : null
    property Item gone: null
}
