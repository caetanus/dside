// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import App 1.0
import QtQml 2.15
// Two distinct registered D types instantiated together — distinct runtime metaobjects, distinct
// slots. `property var` (not `property Alpha`) sidesteps the shared-typeId limitation on Qt6
// (all D types share QtdMocObject* as C++ typeId, so a TYPED cross-property assignment is rejected
// there — tracked as a known gap; distinct per-type QMetaType is the fix).
QtObject {
    property var a: Alpha { av: 10; Component.onCompleted: report(av * 2) }   // -> g_alpha=20
    property var b: Beta  { bv: 3;  Component.onCompleted: note(bv * 2) }     // -> g_beta=6
}
