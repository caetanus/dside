// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import App 1.0
import QtQml 2.15   // for the Component.onCompleted attached signal
// Instantiates the D-registered type. Setting inValue writes a D @Property; onCompleted
// reads it back through the QML binding and calls the D @Slot fromQml.
Backend {
    inValue: 21
    Component.onCompleted: fromQml(inValue * 2)   // -> D @Slot receives 42
}
