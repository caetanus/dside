// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
// (b) a newly auto-discovered type: Column -> QQuickColumn (a positioner), reached purely by adding
// its header to discovery — no per-type code. spacing base prop read in a derived binding.
Column {
    spacing: 6
    property int gap2: spacing * 2
}
