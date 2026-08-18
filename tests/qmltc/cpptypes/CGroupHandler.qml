// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A handler ON a grouped property: the signal belongs to the group object, the slot to this one.
// The body also WRITES a group member, the counterpart of reading one. Mutating group.count in
// the `.set` run fires the handler, so the diff proves the connection is real.
import QmltcTests
QmlGroupPropertyTestType {
    property int seen: 0
    group.count: 1
    group.str: "start"
    group.onCountChanged: {
        seen = seen + 1;
        group.str = "changed";
    }
}
