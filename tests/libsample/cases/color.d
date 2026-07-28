// Constructing a Color used to be the whole test: it never observed the result, so a ctor that
// bound to the wrong overload — or did nothing at all — still printed OK. Color::m_null starts
// true and BOTH real ctors clear it, which makes isNull() the observable that distinguishes a
// ctor that ran from one that did not.
import sample.color, sample.invalue;
import std.stdio;
void main() {
    Color def;                             // default-constructed: m_null stays true
    assert(def.isNull(), "a default Color must be null");

    auto c = Color(InValue.OneIn);         // idiomatic ctor (enum)
    assert(!c.isNull(), "Color(InValue) did not run the C++ ctor (still null)");

    auto c2 = Color(0xff00ffu);            // idiomatic ctor (uint)
    assert(!c2.isNull(), "Color(uint) did not run the C++ ctor (still null)");

    writeln("color OK: default Color is null; Color(InValue) and Color(uint) both clear it");
}
