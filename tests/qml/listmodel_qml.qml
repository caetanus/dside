// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// The same checks as listmodel.qml, with no QtQuick: the view is an Instantiator (QtQml.Models),
// which applies inserts, removes and moves incrementally too, and needs only a QCoreApplication —
// so it runs on the Qt5 and Qt6 QML bindings alike. Versioned imports and `model.<role>` keep one
// document valid on both.
import QtQml 2.15
import QtQml.Models 2.15

QtObject {
    id: root
    property int created: 0
    property int resets: 0

    property Instantiator inst: Instantiator {
        model: driver.rows
        delegate: QtObject {
            property string title: model.title
            property int n: model.n
            property bool starred: model.starred
            property int uid: 0
            Component.onCompleted: uid = ++root.created
        }
    }
    property Connections resetWatch: Connections {
        target: driver.rows
        function onModelReset() { root.resets++ }
    }
    property Connections stepWatch: Connections {
        target: driver
        function onStep() {
            let s = []
            for (let i = 0; i < inst.count; i++) {
                const o = inst.objectAt(i)
                s.push(o ? ("d" + o.uid + ":" + o.title + ":" + o.n + ":" + o.starred) : "?")
            }
            driver.report(s.join(","), root.created, root.resets)
        }
    }
}
