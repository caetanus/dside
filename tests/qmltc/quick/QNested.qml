// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
// (b): a QtQuick Item with a default-property child Item -> nested D subclasses of QQuickItem.
Item {
    width: 100
    property int pad: 3
    Item {
        width: 50
        property int mine: 9
        property int sum: mine + width
    }
}
