// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A handler on a BOUND BASE property's notify. `width` belongs to Item, not to this document, so
// the "is it a property we declared?" test said no and the handler was refused. The notify table
// knows it — and knows its real signature — which is what makes it connectable.
import QtQuick
Item {
    width: 100
    property int seen: 0
    property int lastWidth: 0
    onWidthChanged: { seen = seen + 1; lastWidth = width }
}
