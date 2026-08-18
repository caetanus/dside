// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// GROUPED property: `group` is a QObject*-valued Q_PROPERTY on the C++ base, and QML addresses
// its members with dotted syntax. The group is a real child object reached through the parent's
// meta-object, so its members are ordinary properties on it — set here, and read in a binding.
import QmltcTests
QmlGroupPropertyTestType {
    group.count: 42
    group.str: "grouped"
    property int mirrored: group.count
    property string tagged: group.str + "!"
}
