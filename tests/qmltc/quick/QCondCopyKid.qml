// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A CONDITIONAL COPY WHOSE CONDITION READS A CHILD, which is what tore the statement in half.
//
// Both branches are value-type copies, so the binding compiles to a BLOCK rather than to an
// expression (see QCondCopyNull, which covers the null-dereference half of the same shape):
//
//     if (propBool(_dc0, "armed")) {
//         copyProp(__outer, "paper", this, "color");
//     } else { … }
//
// The wire body is then split into what runs BEFORE this object's children and what runs after,
// because an assignment naming a child cannot precede it. That split read one LINE at a time, and
// the only line here that names `_dc0` is the `if` head — so the head went into `__qmltcKids` and
// its body stayed in `__qmltcWire`:
//
//     __qmltcWire:  bindEval({ \n     copyProp(…); \n } else { … } \n });
//     __qmltcKids:  if (propBool(_dc0, "armed")) {
//
// which is not D in either place ("found `else` when expecting `)`"), so the document was lost
// whole. Three documents of a real application failed on exactly this.
//
// It fails both ways: unsplit but ordered wrongly the colour would read a child that does not exist
// yet and settle on the wrong branch, and the value is compared against the engine.
import QtQuick

Item {
    id: root
    width: 40; height: 20

    property color paper: "#ff0000"
    property color ink: "#0000ff"
    property string leafColor: leaf.color        // the value, where the differential can see it

    Rectangle {
        id: leaf
        width: 10; height: 10
        // `armed` is a property of a CHILD of this rectangle, so the condition names `_dc0` and the
        // branches are copies of the root's colours.
        color: probe.armed ? root.paper : root.ink
        Item { id: probe; property bool armed: true }
    }
}
