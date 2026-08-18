// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick.Templates as T
// The same, for a VALUE group (QQuickIcon is a Q_GADGET, so the write is a read-modify-write of
// the whole value). `.set` mutates the dependency `k`, so a one-shot keeps icon.width at 10.
T.Button {
    text: "b"
    property int k: 9
    icon.width: k + 1
    icon.height: 8
}
