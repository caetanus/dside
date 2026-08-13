// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import sample.derived; import std.stdio;
import cxxrt : make;   // make!T(...) — the one factory spelling (cxxrt dispatches to T.__make)
void main() {
    auto d = make!Derived(0);
    assert(d.singleArgument(true)==false && d.defaultValue(5)==5.1);
    assert(cast(int) d.overloaded(1,2)==0 && cast(int) d.overloaded(3.0)==1);
    writeln("inheritance OK");
}
