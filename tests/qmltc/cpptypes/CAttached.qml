// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// ATTACHED properties: `TestType.attachedCount` addresses the object TestType attaches to us.
// It is reached through Qt's QML type REGISTRY by name, so nothing about the type is hard-coded —
// and through qmlAttachedPropertiesObject, which CACHES per (object, type): the raw attach
// function constructs a fresh object on every call, so writing then reading would see nothing.
import QmltcTests
import QtQml
QtObject {
    id: root
    TestType.attachedCount: 42
    TestType.attachedFormula: 41 + 1
    TestType.attachedObject: QtObject { property string name: "attached child" }
    property int mirrored: root.TestType.attachedCount
    TestType.onAttachedCountChanged: { root.mirrored2 = root.mirrored2 + 1 }
    property int mirrored2: 0
}
