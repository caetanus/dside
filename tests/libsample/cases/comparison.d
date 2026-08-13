// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import sample.comparisontester;
import std.stdio;
void main() {
    auto a = ComparisonTester(5), b = ComparisonTester(3), a2 = ComparisonTester(5);
    assert(a.compare(b) > 0 && b.compare(a) < 0 && a.compare(a2) == 0, "compare()");
    writeln("comparison OK");
}
