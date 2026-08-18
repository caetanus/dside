// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
// (b) TextInput -> QQuickTextInput (private API). text base prop (string) + a derived binding.
TextInput {
    text: "in"
    property string echo: text + "!"
}
