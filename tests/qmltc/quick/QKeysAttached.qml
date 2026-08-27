// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A HANDLER ON AN ATTACHED TYPE THE BINDING DOES NOT COVER. `Keys` is QQuickKeysAttached, which
// no spec binds, so the compiler has no signal table for it — and `Keys.pressed(QQuickKeyEvent*)`
// cannot be guessed from the name. It does not have to be: the attached object exists at run time
// and carries its own meta-object, so the handler is connected BY NAME.
//
// Two things went wrong here before, in order. The emission dereferenced a null and the tool
// died with SIGSEGV and zero output, so a build wiring it up got an empty file rather than an
// error. Then it stopped crashing and SKIPPED the handler instead: the document compiled and the
// keyboard did nothing — which is worse in an application than in a fixture, and this was found
// in one (bugs.md #1, on Main.qml and Config.qml of a real reader).
//
// So the fixture asserts the handler RUNS, not that the file compiles. The harness delivers a key
// with --key and `seen` has to move.
import QtQuick
Item {
    focus: true
    property int seen: 0
    Keys.onPressed: seen = seen + 1
}
