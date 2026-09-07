// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A BARE NAME AN ENCLOSING DOCUMENT DECLARES, READ INSIDE A DELEGATE, AFTER IT CHANGES.
//
// Inside a delegate an unqualified name is answered from the per-item context — `index`,
// `modelData`, a model role. But a name the enclosing DOCUMENT declares is not there: the read
// resolves it through the outer chain, and the DEPENDENCY wiring did not ask the same question. It
// connected to the context object, which has never heard of the name, so the binding held the value
// it computed while the delegate was being built and never moved again.
//
// It is invisible to a property dump, because at t=0 the two agree — which is why this is in the
// TIMED table. Measured on a real reader, and the pair is as sharp as this compiler has produced:
// the reading page came out BYTE-IDENTICAL to the engine in the light theme AND in sepia, and
// differed in dark. The line between them was `opacity: themeIndex === 2 ? 0.22 : 0.55` on a marked
// verse — compiled correctly, connected to the wrong object, so every highlight kept the light
// theme's 0.55 against the engine's 0.22.
import QtQuick 2.15
Item {
    id: root
    width: 40; height: 20

    property int mode: 1
    // Written from INSIDE the delegate: an id declared in one is not visible outside it.
    property real got: -1

    Timer { interval: 60; running: true; onTriggered: root.mode = 2 }

    Repeater {
        model: 1
        delegate: Item {
            width: 10; height: 10
            // `mode` is the enclosing document's, not a context name, and it CHANGES.
            property real v: mode === 2 ? 0.22 : 0.55
            onVChanged: root.got = v
            Component.onCompleted: root.got = v
        }
    }
}
