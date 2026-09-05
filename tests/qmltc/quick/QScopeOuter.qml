// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// THE OTHER HALF: the document that owns the name. It instantiates QScopeLeaf, which reads `paper`
// without declaring it, so the value asserted on the leaf is the proof that the cross-document
// scope name arrived — the case the compiler used to refuse outright.
import QtQuick
Item {
    id: root
    width: 40; height: 20
    property color paper: "#336699"
    QScopeLeaf { }
}
