// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
// (b) object-typed property: `property QtObject o: QtObject { ... }` — a child object bound to a
// declared QtObject property, with its own scalars read via the dotted path.
Item {
    width: 5
    property QtObject o: QtObject {
        property int x: 42
        property string s: "hi"
    }
}
