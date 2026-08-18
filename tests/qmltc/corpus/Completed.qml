// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQml 2.15
// Phase-6: Component.onCompleted runs an init block at construction.
QtObject {
    property int x: 3
    property int y: 0
    property string tag: ""
    Component.onCompleted: { y = x + 10; tag = "ready" }
}
