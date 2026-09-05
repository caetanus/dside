// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A DOCUMENT THAT READS A NAME IT DOES NOT DECLARE. `paper` is declared by whichever document
// instantiates this one, and QML resolves it up the COMPONENT scope chain — the creation context,
// not the parent object. That is the one shape behind 88% of this compiler's refusals
// (docs/qmltc-d-gaps.md), and a compiler that sees one document at a time cannot name its owner.
//
// Standalone — which is how this file's own target compiles it — the name resolves nowhere and
// both sides must agree on that: the engine reports a ReferenceError and leaves the property at
// its default, and the promise handed over here stays empty and does the same. The pairing with
// QScopeOuter.qml is where it has to RESOLVE.
import QtQuick
Rectangle {
    objectName: "leaf"
    width: 30; height: 12
    color: paper
}
