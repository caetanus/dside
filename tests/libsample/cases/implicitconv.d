// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import sample.implicitconv; import std.stdio;
void main() {
    // static method that doesn't need to construct ImplicitConv via Null
    auto e = ImplicitConv.implicitConvOverloading(5);   // static (int)
    assert(cast(int) e >= 0);
    writeln("implicitconv OK");
}
