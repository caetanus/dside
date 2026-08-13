// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import cxxrt : make;
import sample.exceptiontest;
import std.stdio;
void main() {
    auto e = make!ExceptionTest();
    // no-throw path (false) -> returns 1. (a C++ throw crossing into D is a
    //  separate gap — different exception ABIs; not tested here.)
    assert(e.intThrowStdException(false) == 1, "exception no-throw path");
    writeln("exceptions OK");
}
