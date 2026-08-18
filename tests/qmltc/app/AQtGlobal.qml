// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// O objecto global `Qt` — formatação, cores e enums, que aplicações usam a toda a hora e os
// estilos do Qt quase não tocam. Nada aqui depende do relógio: uma data fixa, para o valor ser o
// mesmo em qualquer corrida.
import QtQuick
Item {
    width: 260; height: 40
    property date when: new Date(2026, 0, 15, 9, 30, 0)
    property string stamp: Qt.formatDateTime(when, "yyyy-MM-dd hh:mm")
    property color mixed: Qt.rgba(0.2, 0.4, 0.6, 1.0)
    property int align: Qt.AlignHCenter
    Text { text: stamp + " " + align }
}
