// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
import QtQuick.Templates as T
// A local file that SHADOWS a registry type, rooted in the aliased import — which is how every Qt
// style is written (`Basic/MenuSeparator.qml` is a `T.MenuSeparator`). The shadowing is the point:
// `boundTypeFor("MenuSeparator")` must keep answering "not bound" for the whole compile, or the
// second child of this type is built as the bare Templates object instead of this file.
T.MenuSeparator {
    implicitHeight: 13
    implicitWidth: 40
}
