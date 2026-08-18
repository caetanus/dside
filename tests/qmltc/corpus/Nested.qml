// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQml 2.15
// Phase-5 fixture: a child object with its own literal + bound properties.
QtObject {
    property int x: 5
    property QtObject kid: QtObject {
        property int y: 10
        property int sum: y + 2
    }
}
