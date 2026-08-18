// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
import QtQuick.Templates as T
// An object's CHILDREN belong after the object is assigned to its parent's property, not inside its
// constructor. The engine defers `popup` on a ComboBox and `contentItem` on a Popup, so when
// QQuickComboBox::setPopup runs the ListView does not exist yet.
//
// It matters because setPopup RESETS it. Verified against the engine alone, with no compiler in the
// picture: build a `T.Popup { contentItem: ListView { highlightRangeMode: ListView.ApplyRange } }`,
// read ApplyRange, assign it to a `T.ComboBox`, read NoHighlightRange. Build the popup's contentItem
// first and the document's own value is silently thrown away — which is exactly what Qt's Fusion
// ComboBox showed, and what no diagnostic could say, because the write itself succeeds.
T.ComboBox {
    popup: T.Popup {
        contentItem: ListView {
            highlightRangeMode: ListView.ApplyRange
            highlightMoveDuration: 0
        }
    }
}
