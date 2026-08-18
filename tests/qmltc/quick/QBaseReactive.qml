// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
// The REVERSE of QItem: a BASE property bound to a declared one. QItem covers declared <- base
// (`inner: width - pad`), which was wired; base <- declared was emitted as a ONE-SHOT setProp with
// no connect and no diagnostic, so `width` never recomputed and nothing reported it. The .set
// mutates `pad`, which is the only way to tell a binding from an assignment.
Item {
    property real pad: 4
    width: pad * 10
    height: pad + 1
}
