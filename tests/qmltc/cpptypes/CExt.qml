// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A type with QML_EXTENDED: the engine grafts another object's members onto it. We do not build
// that object, so the extension's OWN members are unusable — but the type itself is, and a .qml
// that never touches the extension compiles. Using one is an honest PARTIAL, not a refusal of
// every file rooted in such a type.
import QmltcTests
TypeWithExtension {
    property bool ownProperty: true
    property int derived: ownProperty ? 7 : 0
}
