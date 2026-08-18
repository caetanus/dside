// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
import QtQuick.Templates as T
// A bare child goes into the type's OWN default property, and that is NOT always `data`: a
// Pane/Popup/Control declares `contentData` (the child is held by its contentItem), a Flickable
// `flickableData`. Placing it by hand as an item child of the Pane put it where the ENGINE never
// has it — and labelling it `data[0]` named a different object entirely: on the engine side
// `data[0]` here is the Pane's own background, while `contentData[0]` is this Rectangle.
// The property name comes from the registry (5th qmlmap column, resolved up the prototype chain),
// and the append goes through QQmlListReference, so each type applies its own rule.
T.Pane {
    padding: 4

    Rectangle {
        objectName: "kid"
        width: 30
        height: 12
        color: "#336699"
    }
}
