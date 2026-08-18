// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQml 2.15
// Phase-3 seed: comparisons (bool), ternary, modulo, and int/double division coercion.
QtObject {
    property int a: 6
    property int b: 7
    property bool lt: a < b
    property bool eq: a == b
    property int max: a > b ? a : b
    property int rem: b % a
    property real avg: (a + b) / 2.0
    property string tag: a < b ? "less" : "geq"
}
