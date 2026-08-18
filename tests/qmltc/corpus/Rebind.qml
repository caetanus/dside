// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// `Qt.binding(...)` INSTALLS a new binding at runtime; assigning a plain value REMOVES the
// binding altogether. Both are compiled as a selector on the property: every recompute is
// connected up front and only the active one acts, so nothing has to be disconnected at runtime.
import QtQml 2.15
QtObject {
    property int p1: 1
    property int p2: p1 + 1
    function rebind() { p2 = Qt.binding(function() { return p1 * 2 }); }
    function unbind() { p2 = 42; }
}
