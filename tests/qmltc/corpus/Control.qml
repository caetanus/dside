// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQml 2.15
// Phase-10: if/else control flow in a function + a handler.
QtObject {
    property int x: 7
    property int cat: 0
    property int sign: 0
    function classify() {
        if (x > 10) cat = 3;
        else if (x > 5) cat = 2;
        else cat = 1;
    }
    onXChanged: { if (x < 0) sign = -1; else sign = 1; }
    Component.onCompleted: classify()
}
