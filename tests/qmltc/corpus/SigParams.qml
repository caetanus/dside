// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQml 2.15
// Phase-10: a signal WITH parameters; the handler reads the argument.
QtObject {
    signal valueChanged(int v)
    signal named(string who)
    property int last: 0
    property string greeting: ""
    function fire() { valueChanged(42); named("Ada") }
    onValueChanged: { last = v }
    onNamed: { greeting = "hi " + who }
    Component.onCompleted: fire()
}
