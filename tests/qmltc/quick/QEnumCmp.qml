// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
// Comparing an ENUM property to an enum member (`control.checkState === Qt.Checked` in Qt's own
// Controls). The numeric value is not knowable here, but an enum property read as a STRING gives
// its KEY (QVariant::toString goes through QMetaEnum) and the member's key is its own name — so
// the comparison is done on keys, needing no table of enum values. The .set changes the enum, so
// both branches are exercised.
//
// `clip` rather than `visible` deliberately: `visible` did NOT reproduce here (we end at false
// where the engine says true, with an identical binding that works on clip). QQuickItem's visible
// is effective-visibility with completion-time recalculation, and our one-shot-then-notify order
// is not the engine's evaluate-at-completion order. Recorded in docs/qmltc-d.md as a real gap
// rather than hidden by choosing a property that happens to pass.
Text {
    id: control
    text: "root"
    horizontalAlignment: Text.AlignHCenter
    Text {
        objectName: "kid"
        text: control.horizontalAlignment === Text.AlignHCenter ? "centred" : "not-centred"
        clip: control.horizontalAlignment !== Text.AlignLeft
    }
}
