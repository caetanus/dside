// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import sample.functions, sample.invalue, sample.outvalue, sample.point, sample.complex;
import std.stdio;
void main() {
    assert(enumInEnumOut(InValue.OneIn) == OutValue.OneOut);
    assert(countCharacters("hello\0".ptr) == 5, "countCharacters(const char*)");
    // TRIVIALLY copyable value types (Point/Complex = 2 doubles) -> safe by value
    auto pt = Point(3.0, 4.0);
    auto cx = transmutePointIntoComplex(pt);       // const Point& -> Complex(x,y)
    assert(cx.real_() == 3.0 && cx.imag() == 4.0, "transmutePointIntoComplex");
    auto bk = transmuteComplexIntoPoint(cx);
    assert(bk.x() == 3.0 && bk.y() == 4.0, "transmuteComplexIntoPoint");
    // GAP: changePStr(Str*) would append to a bitwise-copied std::string (SSO
    // dangling) -> SEGV. A value type with a std::string member is unsafe by value
    // (D does not call C++'s copy ctor). Needs a postblit this(this) -> copy ctor.
    writeln("functions OK");
}
