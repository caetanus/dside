// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
// (b): a QtQuick Item root -> a D subclass of the bound QQuickItem. Base props (width/height)
// set via the meta-object; a custom property + a reactive binding on top.
Item {
    width: 120
    height: 60
    property int pad: 4
    property int inner: width - pad
}
