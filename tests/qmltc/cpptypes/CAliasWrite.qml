// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// An alias is a REFERENCE: assigning it writes the TARGET, and reading it reads the target — no
// stored copy, so no NOTIFY is required on the target for the alias to stay faithful.
// `x` and `y` are MEMBER properties with no NOTIFY at all.
import QmltcTests
TypeWithSpecialProperties {
    id: root
    property alias xAlias: root.x
    property alias yAlias: root.y
    xAlias: 11
    yAlias: "via alias"
    property int fromAlias: xAlias + 1
}
