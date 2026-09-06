// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// A `var` PROPERTY WRITTEN FROM JS AND READ BACK BY A BINDING.
//
// The reader keeps its translation list in one (`property var translations: []`), fills it from a
// function the engine runs, and titles its header from `translations[current].label`. If the write
// lands somewhere the read does not look, the subtitle is simply absent and nothing says why.
import QtQuick 2.15
Item {
    id: root
    width: 100; height: 30
    property var rows: []
    property int cur: 0
    readonly property string label: rows.length ? rows[cur].label : "-"
    readonly property int count: rows.length
    Component.onCompleted: { rows = [ { label: "um" }, { label: "dois" } ]; cur = 1 }
}
