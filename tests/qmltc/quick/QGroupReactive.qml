// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
// A grouped write whose value READS something: `border.width: bw + 1` is a BINDING, not an
// assignment. It was emitted as a one-shot with no connect — the same bug this project keeps
// finding, reintroduced in the group paths because both were tested with LITERALS
// (`border.width: 3`), which have no dependency to go stale.
//
// The .set mutates the DEPENDENCY, not the target: that is the only way the difference shows.
Rectangle {
    width: 50
    height: 20
    property int bw: 2
    border.width: bw + 1
    border.color: "red"
}
