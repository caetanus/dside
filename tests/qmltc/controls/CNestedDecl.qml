// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
import QtQuick.Templates as T
// A PROPERTY DECLARED INSIDE AN ASSIGNED OBJECT IS STILL A PROPERTY.
//
// Found by judging Qt's own Universal/BusyIndicator, which is one of exactly three documents in the
// whole Controls corpus that compile WITHOUT A SINGLE DIAGNOSTIC and still disagree with the engine.
// Its contentItem declares `readonly property real size: Math.min(...)` and uses it one line later
// (`count: size < 60 ? 5 : 6`); the engine reports `contentItem.size = 20` and we reported no such
// property at all. Not a wrong value — an absent one.
//
// That class is the worst of the three groups the 329-document corpus splits into: a document the
// compiler KNOWS it cannot handle is demoted, the engine builds it, and the user sees the right
// thing. This one compiled clean and lied, which is what reaches a consumer as `undefined` where the
// engine gives a number.
//
// The fixture separates the two hypotheses the BusyIndicator alone cannot:
//
//   * `readonly` is not the issue — `rootRO` is declared at the ROOT and IS emitted today
//     (measured: CNullBinding's `readonly property color c1` appears in both dumps);
//   * the issue is WHERE: `nestedRO` and `nestedRW` are declared inside the object assigned to
//     `contentItem`, which is built through the assigned/deferred path, and that path does not
//     emit the properties the document declares on it.
//
// Both a readonly and a read-write one, so a fix that only handles `readonly` is visible as a
// half-fix rather than as a pass.
T.Control {
    id: root
    width: 100
    height: 40

    readonly property real rootRO: width / 2
    property string rootRW: "root"

    contentItem: Item {
        id: inner
        readonly property real nestedRO: Math.min(root.width, root.height)
        property string nestedRW: "nested"
        // ...and USED one line later, exactly as Qt's document does: if the declaration is dropped
        // but the use still resolves, the value came from somewhere the document did not say.
        objectName: nestedRO < 60 ? "small" : "large"
    }
}
