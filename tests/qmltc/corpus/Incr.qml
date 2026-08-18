// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQml 2.15
// Phase-10: increment/decrement operators in functions and handlers.
QtObject {
    property int count: 0
    property int down: 10
    function bump() { ++count; count++; }
    function dec() { --down; down--; }
    Component.onCompleted: { bump(); bump(); dec(); }
}
