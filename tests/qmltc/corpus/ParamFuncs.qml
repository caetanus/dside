// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQml 2.15
// Phase-8: functions WITH parameters (numeric -> double, string param inferred from concat).
QtObject {
    property int base: 4
    function times2(n) { return n * 2 }
    function addTag(s) { return s + "!" }
    property int r: times2(base)
    property string t: addTag("hi")
}
