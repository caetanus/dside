// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// CALLING A D METHOD THAT RETURNS SOMETHING. A Qt slot returns void, so until the meta-object
// could declare an invokable there was no way for QML to call one and read the answer — a QML
// function that returns a value was emitted as a plain D method the engine could not see, and
// answered `Property 'X' of object … is not a function` (bugs.md #9, criterion 4).
//
// Both a number and a string, because the return crosses differently: a scalar is written into
// the metacall's slot 0 directly and a QString has to be assigned into the one Qt already put
// there. A test that only returned an int would pass with the string half missing.
import App 1.0
import QtQml 2.15
Backend {
    Component.onCompleted: {
        report(twice(21), shout("ok"))
    }
}
