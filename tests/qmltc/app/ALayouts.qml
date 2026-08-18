// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// QtQuick.Layouts — um MÓDULO diferente, e o que quase toda a aplicação usa para dispor coisas.
// Nenhum dos cinco estilos do Qt o importa; `anchors` é o que eles usam. As propriedades anexadas
// `Layout.*` são um segundo mecanismo por cima disso.
import QtQuick
import QtQuick.Layouts
Item {
    width: 240; height: 80
    RowLayout {
        anchors.fill: parent
        spacing: 6
        Rectangle { color: "#cc4444"; Layout.fillWidth: true; Layout.preferredHeight: 30 }
        Rectangle { color: "#44cc44"; Layout.preferredWidth: 60; Layout.fillHeight: true }
        ColumnLayout {
            Layout.fillWidth: true
            Rectangle { color: "#4444cc"; Layout.fillWidth: true; Layout.preferredHeight: 12 }
            Rectangle { color: "#cccc44"; Layout.fillWidth: true; Layout.preferredHeight: 12 }
        }
    }
}
