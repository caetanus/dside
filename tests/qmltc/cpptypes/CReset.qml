// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// `prop: undefined` in QML RESETS the property — it calls the RESET method, it is not a value.
// It must go through QMetaProperty::reset: a Q_PROPERTY RESET method is an ordinary member, not
// a slot, so invoking it by name finds nothing and silently does nothing.
import QmltcTests
TypeWithSpecialProperties {
    id: root
    xy: "assigned"
    property alias xyAlias: root.xy
    xyAlias: undefined
}
