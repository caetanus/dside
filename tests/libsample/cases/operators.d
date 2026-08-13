// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import sample.point;
import std.stdio;
void main() {
    auto a = Point(10.0,20.0), b = Point(1.0,2.0);
    assert((a+b).x()==11.0 && (a-b).y()==18.0);
    assert(a == Point(10.0,20.0) && !(a==b));
    assert((a/2).x()==5.0);
    writeln("operators OK");
}
