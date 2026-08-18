// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import App 1.0
import QtQml 2.15
// Both types are class `Dup` in D — if buildMo keyed by name only they'd share a metaobject and
// one slot would misfire. Distinct shapes must give distinct metaobjects.
QtObject {
    property var x: AlphaDup { av: 5; Component.onCompleted: alphaSlot(av) }
    property var y: BetaDup  { bv: 7; Component.onCompleted: betaSlot(bv) }
}
