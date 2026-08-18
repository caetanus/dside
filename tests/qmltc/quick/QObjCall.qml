// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A METHOD CALL whose result is an OBJECT. Text cannot carry one -- the invoke channel's usual
// return is a string that QMetaType converts, and no string stands for an item -- so such a call
// could not be a value at all and the whole property was refused, declaration included.
//
// Qt's Basic ComboBox reads exactly this for its highlight rectangle:
// `property Item highlightedItem: parent ? parent.itemAtIndex(control.highlightedIndex) : null`.
//
// `childAt` is used here rather than `itemAtIndex` because it answers from the object tree alone: a
// view has not created its items yet when the dump runs, so `itemAtIndex` is null on both sides and
// could not tell a working call from a refused one.
import QtQuick
Item {
    id: root
    width: 100; height: 40
    Item { id: kid; x: 0; y: 0; width: 50; height: 20; objectName: "the-kid" }
    property Item hi: root.childAt(10, 10)
}
