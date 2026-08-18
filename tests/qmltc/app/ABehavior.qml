// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// `Behavior on` mais uma animação declarada, e um estado que já assentou. A duração é zero para o
// resultado ser determinístico: o que se mede é ONDE a propriedade acaba, não a interpolação.
import QtQuick
Item {
    id: root
    width: 120; height: 60
    property real target: 80
    Rectangle {
        id: box
        width: root.target; height: 20; color: "teal"
        Behavior on width { NumberAnimation { duration: 0 } }
    }
    Component.onCompleted: root.target = 40
    property real settled: box.width
}
