// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// TypeWithSpecialProperties from the corpus: MEMBER properties (int/QString) and a
// READ/WRITE/NOTIFY one, feeding derived bindings.
import QmltcTests
TypeWithSpecialProperties {
    x: 3
    y: "why"
    xy: "pair"
    property int plusOne: x + 1
    property string joined: y + xy
}
