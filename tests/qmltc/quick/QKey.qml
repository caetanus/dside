// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
// KEYBOARD is its own axis, and the machinery under test is the FOCUS CHAIN plus the bound type's own
// C++ key handling — not a QML handler (`Keys.onPressed` with an arrow function is not compiled yet, so
// a fixture built on it would measure nothing). A TextInput consumes keys in C++: if the compiled object
// is focused and in a live scene, typing must change `text` exactly as it does under the engine. A
// document can be pixel-identical and click-correct and still never receive a key.
TextInput {
    width: 80; height: 24
    focus: true
    // A DECLARED property that mirrors the effect: `text` itself must not be bound (in the engine that
    // binding fights the key insertion), and the dump only carries what the document mentions — so the
    // observable is this one, reactive on text.
    property int len: text.length
    // NO `text:` binding on purpose: in the engine that is a BINDING, and it fights the key insertion
    // (the compiled side assigns once, so typing sticks and the two would differ for a reason that is
    // the fixture's, not the compiler's)
}
