// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
// (b) bool base prop: set QQuickItem.clip (a bool base prop) and read it in a derived bool binding.
Item {
    clip: true
    property bool inv: !clip
}
