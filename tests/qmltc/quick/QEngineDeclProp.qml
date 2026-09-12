// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A PROPERTY THE DOCUMENT DECLARES ON AN OBJECT THE ENGINE BUILDS, reached from every direction.
//
// `Shape` exports no symbol to subclass, so the generated class is a shell around an instance
// createQmlObject made — and the properties declared here are handed to it as `decls`, which puts
// them ON THAT INSTANCE. Both sides then reach them through the meta-object. Six places assumed a D
// field instead, and each fix uncovered the next:
//
//   * a CHILD reading the enclosing object's declared property (`sh.faceId` from the ShapePath)
//     compiled to `__outer.faceId` — "no property `faceId` for `this.__outer`";
//   * the object reading its OWN (a bare `currentName` in its handler) — "undefined identifier";
//   * writing one (`tag = …`), which a meta read is not an lvalue for;
//   * incrementing one (`faceId++`), same reason, and with the reader picked by an empty target type
//     so an int came out read with propBool;
//   * reading one from OUTSIDE (`sh.tag` on the root), which took the child-id path and gave
//     "no property `tag` for … `void*`";
//   * and a bare call to a method of the Qt BASE (`forceActiveFocus()` on the Rectangle below),
//     which lives on the object Qt built and is not a member of the generated class either.
//
// Three documents of a real application failed on the first; the last two this fixture found on its
// own. They are one fixture because they are one fact in six places — and because a regression in
// any of them stops this document building, which the target reports whatever the values say.
//
// `tag` is computed AFTER the increment, so the order and the int-to-string conversion are pinned
// too, and every value is compared against the engine's own answer.
import QtQuick
import QtQuick.Shapes

Item {
    id: root
    width: 60; height: 40

    property string seenTag: ""
    property int seenId: 0
    property string seenName: ""

    Shape {
        id: sh
        width: 20; height: 20

        property int faceId: 3
        property string currentName: "ada"
        property string tag: ""

        // A child reading the enclosing engine-built object's declared property. Numeric on both
        // sides on purpose: a comparison against a string would be delegated to the engine and the
        // compiled path — the one that used to emit `__outer.faceId` — would never run.
        ShapePath { strokeWidth: sh.faceId; strokeColor: "red" }

        Component.onCompleted: {
            faceId++                              // read-modify-write through the meta-object
            tag = currentName + "/" + faceId      // bare self reads, and a write
        }
    }

    Rectangle {
        id: box
        width: 10; height: 10
        // A method of the BOUND base, called bare. Base PROPERTIES have gone through the
        // meta-object here all along; base METHODS were emitted as D calls on a class that has none.
        Component.onCompleted: forceActiveFocus()
    }

    Component.onCompleted: {
        root.seenTag = sh.tag
        root.seenId = sh.faceId
        root.seenName = sh.currentName
    }
}
