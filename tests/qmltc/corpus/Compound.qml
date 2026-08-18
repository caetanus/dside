// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import QtQml 2.15
// Phase-10: compound assignment (+= etc.) and console.log (no-op).
QtObject {
    property int n: 5
    property string s: "a"
    function go() {
        n += 3;
        n *= 2;
        s += "b";
        console.log("tracing", n, s);
    }
    Component.onCompleted: go()
}
