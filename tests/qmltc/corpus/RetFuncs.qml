// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQml 2.15
// Phase-8: no-arg functions with typed (inferred) return values, used in bindings.
QtObject {
    property int base: 5
    function ten() { return 10 }
    function scaled() { return base * ten() }
    function half() { return base / 2 }
    function tag() { return "hi" }
    property int a: ten()
    property int b: scaled()
    property real c: half()
    property int d: half()
    property string s: tag()
}
