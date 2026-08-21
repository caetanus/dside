// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import std.stdio;
extern(C) void* mkba(const(char)* s);
// The xiboca pattern, against real Qt: explicit self, mangled straight to the C++ symbol.
pragma(mangle, "?length@QByteArray@@QEBA_JXZ") extern(C++) long ba_length(void* self);
void main() {
    auto b = mkba("hello from D".ptr);
    auto n = ba_length(b);
    writefln("QByteArray::length() -> %d (expect 12)", n);
    writeln(n == 12 ? "QT-CALL: PASS" : "QT-CALL: FAIL");
}
