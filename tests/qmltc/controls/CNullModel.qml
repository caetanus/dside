// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQuick
import QtQuick.Templates as T
// A null OBJECT copied into a `QVariant` property is QML's `null`, not "a pointer of this class
// that happens to be null". Qt's ComboBox binds `model: control.delegateModel`, and delegateModel is
// null until a model is set: the engine leaves `std::nullptr_t` in the ListView's `model` and the
// straight QVariant copy left `QQmlInstanceModel*`. Same value, different type — which the dump
// reads back as `<null>` on one side and empty on the other, and which nothing else would show,
// because the write succeeds either way.
//
// Both styles' ComboBox and SearchField carried this; it is the whole of what was left in them.
T.ComboBox {
    id: control
    popup: T.Popup {
        contentItem: ListView {
            model: control.delegateModel
            currentIndex: control.highlightedIndex
        }
    }
}
