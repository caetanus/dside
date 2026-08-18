// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// The bare child lands on the base type's single-object `default property`, and is dumped under
// that property's name.
import QtQml 2.15
DefaultHolder {
    property string hello: "parent"
    QtObject {
        property string hello: "the default child"
        property int n: 5
    }
}
