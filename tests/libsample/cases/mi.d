import sample.mderived1, sample.base1, sample.base2;
import std.stdio;
void main() {
    auto d = MDerived1_new();
    assert(d !is null);
    auto b2 = d.asBase2();                 // upcast MI via static_cast shim (qtmi)
    assert(b2 !is null, "asBase2 upcast");
    writeln("mi OK");
}
