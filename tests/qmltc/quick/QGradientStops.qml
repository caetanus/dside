// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A CHILD OF A TYPE THE ENGINE BUILDS GOES IN THAT TYPE'S DEFAULT PROPERTY.
//
// `Gradient` is not a bound type, so the engine builds it — and its stops belong in `stops`, which
// no table here carries a name for. Given a QObject parent and nothing else they are nowhere the
// type looks, the gradient has no stops, and a Rectangle whose gradient is empty paints its default
// colour. In the reader that was 46 pixels of WHITE down the left edge of the page where the engine
// draws the spine shadow: the last visible difference between the two frames, and the one that
// looked least like a missing list.
//
// The answer is on the object: Qt records it as Q_CLASSINFO("DefaultProperty"), which is what the
// engine itself reads. `n` is on the ROOT because the differential compares the root's properties.
import QtQuick 2.15
Item {
    id: root
    width: 60; height: 20
    readonly property int n: box.gradient ? box.gradient.stops.length : -1
    Rectangle {
        id: box
        objectName: "box"
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#ff0000" }
            GradientStop { position: 0.5; color: "#00ff00" }
            GradientStop { position: 1.0; color: "#0000ff" }
        }
    }
}
