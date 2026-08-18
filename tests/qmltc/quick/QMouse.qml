// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
// (b) MouseArea -> QQuickMouseArea (private API). It REDECLARES QQuickItem's `enabled`, which used
// to make the generated connectEnabledChanged collide with the base's final one (generator bug,
// now fixed: an inherited signal name is not re-emitted).
MouseArea {
    enabled: false
    property bool e: !enabled
}
