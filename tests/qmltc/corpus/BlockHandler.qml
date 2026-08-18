// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQml 2.15
// Phase-6: a multi-statement (brace block) signal handler body.
QtObject {
    property int count: 0
    property int a: 0
    property int b: 0
    onCountChanged: { a = count + 1; b = count * 2 }
}
