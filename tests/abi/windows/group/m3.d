// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import std.stdio;
extern(C) int uses_nothing();
void main() { auto v = uses_nothing(); writefln("uses_nothing() = %d (expect 7)", v); writeln(v == 7 ? "INLINE-PROBE: PASS" : "INLINE-PROBE: FAIL"); }
