// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQml 2.15
// Phase-1 qmltc-d fixture: a root QtObject with only LITERAL scalar properties.
// qmltc-d compiles this to a D @QObject; the generated object's values must equal
// what QQmlComponent produces (the differential oracle).
QtObject {
    property int count: 42
    property string title: "hi there"
    property bool enabled: true
    property real ratio: 3.5
    property int offset: -7
}
