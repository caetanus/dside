// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// QML is dynamically typed through a declared object property, and Qt's own Controls rely on it:
// Fusion's CheckIndicator declares `property T.AbstractButton control` and then reads
// `control.checkState` — a property AbstractButton does NOT have and the CheckBox actually put
// there does. The declaration is a lower bound on the object; the ASSIGNMENT names it. So the type
// used to resolve a path through such a property is the assigned one when the document assigns it.
//
// Here `probe` is declared as an `Item` (which has no `horizontalAlignment` and no `text`) and
// assigned a `Text`. Every read below would be refused against the declaration and is answered by
// the assignment — and the last one is the other half of the same idea: `=== undefined` asks
// whether the object has the property AT ALL, which is what the meta channel answers by reading a
// missing property as empty.
import QtQuick
Rectangle {
    id: root
    width: 60; height: 30

    property Item probe
    probe: label

    Text {
        id: label
        text: "hi"
        horizontalAlignment: Text.AlignRight
    }

    // Through the declared property, at depth: an enum compared by key, a plain scalar, and the
    // presence test. `Item` publishes none of these three names.
    property bool alignedRight: root.probe.horizontalAlignment === Text.AlignRight
    property bool alignedLeft: root.probe.horizontalAlignment === Text.AlignLeft
    property string probeText: root.probe.text
    // FALSE: the object really is a Text, so it HAS the property. The same expression against a
    // plain Item is the true case, and that is what Qt's CheckIndicator is guarding against.
    property bool noAlign: root.probe.horizontalAlignment === undefined
    property bool hasAlign: root.probe.horizontalAlignment !== undefined
}
