// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A .qml rooted in an APP-DEFINED type written in C++ — TypeWithManyProperties, taken verbatim
// from Qt's own qmltc corpus. `hasAllAttributes` is REQUIRED, so it must be initialized.
import QmltcTests
TypeWithManyProperties {
    hasAllAttributes: "req"
    readAndWrite: "abc"
    property string echo: readAndWrite + "!"
}
