// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A CHILD OBJECT bound into a grouped property's member: the child is built in D and attached
// THROUGH the group object. Its D field can't be named after the dotted path, so the field and
// the QML path the oracle walks are tracked separately.
import QmltcTests
import QtQml
QmlGroupPropertyTestType {
    group.count: 3
    group.object: QtObject {
        property string name: "in.the.group"
        property int n: 9
    }
    property int mirrored: group.count
}
