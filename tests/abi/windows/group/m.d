// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import std.stdio;
extern(C) int a_fn();
void main() {
    auto r = a_fn();
    writefln("a_fn() = %d (expect 21)", r);
    writeln(r == 21 ? "GROUP-PROBE: PASS" : "GROUP-PROBE: FAIL");
}
