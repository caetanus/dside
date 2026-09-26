// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick

Window {
    id: root
    visible: true
    width: 200; height: 400
    property int created: 0      // delegates ever instantiated
    property int resets: 0       // modelReset signals seen

    ListView {
        id: view
        anchors.fill: parent
        model: driver.rows
        delegate: Item {
            required property string title
            required property int n
            required property bool starred
            width: 200; height: 20
            // A creation stamp: the SAME delegate after a move keeps it, a rebuilt one does not.
            // Assigned once, not bound: a binding that increments what it reads is a loop.
            property int uid: 0
            Component.onCompleted: uid = ++root.created
        }
    }
    Connections { target: driver.rows; function onModelReset() { root.resets++ } }

    // D mutates the model, then asks for a snapshot: layout forced so the view has caught up.
    Connections {
        target: driver
        function onStep() {
            view.forceLayout()
            let s = []
            for (let i = 0; i < view.count; i++) {
                const it = view.itemAtIndex(i)
                s.push(it ? ("d" + it.uid + ":" + it.title + ":" + it.n + ":" + it.starred) : "?")
            }
            driver.report(s.join(","), root.created, root.resets)
        }
    }
}
