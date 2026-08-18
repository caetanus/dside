// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// An enum CONSTANT where a NUMBER is wanted. `loops` is a plain `int` on QQuickAbstractAnimation --
// `Animation.Infinite` names a constant of another enum entirely -- so the string-key channel a real
// enum-typed property uses cannot carry it: QMetaEnum would have nothing to convert against. The
// value is what the property takes, and the meta-object of the class the registry names is where it
// lives. Qt writes this in both style corpora.
//
// -1 against the default 1: the two cannot be confused.
import QtQuick
Item {
    width: 100; height: 40
    NumberAnimation { id: anim; loops: Animation.Infinite; duration: 100 }
}
