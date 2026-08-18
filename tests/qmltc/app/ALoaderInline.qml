// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A LOADER WITH AN INLINE COMPONENT, and a binding that reads THROUGH `item` once it exists.
// `sourceComponent` is a template like a delegate, but the object arrives late and via a property
// the document also reads — the deep-read path and the Component path in one document.
import QtQuick
Item {
    id: root
    width: 160; height: 60
    property int seed: 7
    property int seen: loader.item ? loader.item.width : -1
    Loader {
        id: loader
        sourceComponent: Rectangle { width: root.seed * 10; height: 20; color: "steelblue" }
    }
    Text { y: 30; text: "seen=" + root.seen }
}
