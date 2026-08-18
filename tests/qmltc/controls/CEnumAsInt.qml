// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// An ENUM (here a FLAGS) member read as a NUMBER, which QML does freely -- `Qt.AlignRight` IS 2.
// Two halves were missing and each hid the other:
//
//   the READ was refused at compile time, because the child-id resolver looks the member up in the
//   SCALAR rows of the registry and an enum-typed one is simply absent there. It bailed before the
//   generic member-read block could see it, so a branch written there did nothing at all.
//
//   and QVariant::toInt does not convert a QFlags, so even once it compiled the value came back 0.
//
// The refusal was quiet on the value axis: a declared int keeps its 0, and 0 is a plausible
// alignment. It only surfaced while writing a property whose whole job was to observe the alignment
// for another test -- the observer was the broken thing.
import QtQuick
import QtQuick.Templates as T
T.Control {
    id: root
    width: 100; height: 40
    contentItem: T.DialogButtonBox { id: bb; alignment: Qt.AlignRight }
    property int alignAsInt: bb.alignment
}
