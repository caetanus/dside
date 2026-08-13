// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// Pen records WHICH ctor built it (m_ctor / ctorType()), which is exactly what an overload-
// resolution test needs: previously both Pen() and Pen(Color) were constructed and neither was
// checked, so binding Pen(Color) to the default ctor would have passed.
import sample.pen, sample.color, sample.invalue;
import std.stdio;
enum EmptyCtor = 0, EnumCtor = 1, ColorCtor = 2, CopyCtor = 3;   // Pen's anonymous enum
void main() {
    auto p = Pen();                        // ctor default
    assert(p.ctorType() == EmptyCtor, "Pen() should record EmptyCtor");

    auto col = Color(InValue.OneIn);
    auto p2 = Pen(col);                    // ctor de const Color&
    assert(p2.ctorType() == ColorCtor,
        "Pen(Color) bound to the wrong overload: ctorType() is not ColorCtor");

    writeln("pen OK: Pen() -> EmptyCtor, Pen(Color) -> ColorCtor (overloads resolve distinctly)");
}
