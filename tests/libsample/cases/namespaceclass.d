// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import sample.ctparam;                              // SampleNamespace::CtParam
import std.stdio;
import cxxrt : make;   // make!T(...) — the one factory spelling (cxxrt dispatches to T.__make)
void main() {
    auto c = make!CtParam(42);                       // classe dentro de namespace
    assert(c.value() == 42, "namespace class CtParam.value()");
    writeln("namespaceclass OK");
}
