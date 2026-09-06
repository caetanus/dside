// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A DELEGATE'S LATE PHASE, which nothing used to call.
//
// A delegate is the root of its own instantiation — the view builds it — so no enclosing class
// calls its `__qmltcLate()` the way a parent calls its children's. Nothing did, so every connect
// and every delegated binding a delegate's late phase carried was emitted and never run.
//
// Each cell's width follows its label's, and the label's text arrives from the model through the
// engine. Without the late phase the connect is never made and each cell keeps the width it had
// before its label had any text — 10 — so the row comes out 24 wide instead of the engine's ~76.
// In the application this was found in, six footer labels came out piled at the same x.
//
// `rowW` is on the ROOT on purpose: the differential compares the root's properties, and a fixture
// that asserted only `width` and `height` here would have passed in both directions.
//
// ...and the bare child of a Repeater IS its delegate: written this way it used to be built as an
// OBJECT and assigned where Qt wants a factory, which produced one item and no per-item context.
import QtQuick 2.15
Item {
    id: root
    width: 200; height: 40
    readonly property real rowW: row.width
    Row {
        id: row
        objectName: "row"
        spacing: 4
        Repeater {
            model: [ { r: "aaa" }, { r: "bbbbbb" } ]
            Item {
                objectName: "cell"
                width: lbl.width + 10; height: 20
                Text { id: lbl; objectName: "lbl"; text: modelData.r }
            }
        }
    }
}
