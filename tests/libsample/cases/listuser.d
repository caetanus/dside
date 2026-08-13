// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import sample.listuser; import std.stdio;
import cxxrt : make;   // make!T(...) — the one factory spelling (cxxrt dispatches to T.__make)
void main() {
    auto lu = make!ListUser();
    assert(lu !is null);
    writeln("listuser OK");
}
