// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQml 2.15
// Phase-10: local var declarations + multi-statement return functions.
QtObject {
    id: root
    property int base: 5
    property int result: 0
    property int magic: 0
    function compute() {
        var doubled = base * 2;
        var plus = doubled + 1;
        return plus + base;
    }
    function getMagic() {
        var c = root.base;
        root.base++;
        return root.base + (c * 2);
    }
    Component.onCompleted: { result = compute(); magic = getMagic(); }
}
