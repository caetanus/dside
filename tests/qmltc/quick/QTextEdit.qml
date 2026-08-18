// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
// (b) TextEdit -> QQuickTextEdit (private API). text base prop (string) + a custom prop.
TextEdit {
    text: "hi"
    property int n: 3
}
