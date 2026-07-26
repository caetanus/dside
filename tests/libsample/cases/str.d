import cxxrt : make;
import sample.str; import std.stdio; import std.string : fromStringz;
void main() {
    auto s = make!Str("hello\0".ptr);
    assert(s.cstring().fromStringz == "hello");
    assert(s.get_char(0)=='h' && s.get_char(4)=='o');
    auto c = Str('X'); assert(c.get_char(0)=='X');

    // GAP 2 (fixed): value type with std::string by value. The D copy calls the C++
    // copy-ctor (deep) via the qtdctor shim, NOT bitwise. Before, a bitwise copy of a
    // short SSO left the internal pointer aimed at the ORIGINAL's buffer (self-pointer)
    // -> mutating/appending the copy corrupted it or segfaulted.
    auto orig = make!Str("hi\0".ptr);
    auto dup = orig;                       // C++ copy-ctor (deep)
    auto suf = make!Str("!!\0".ptr);
    dup.append(suf);                       // mutate the copy only
    assert(dup.cstring().fromStringz == "hi!!", "append on the copy");
    assert(orig.cstring().fromStringz == "hi", "original intact after copy+mutate");
    writeln("str OK");
}
