import sample.abstract_; import std.stdio;
void main() {
    // Abstract is pure-virtual -> not instantiable (expected); tests the enums.
    assert(Abstract.Type.TpAbstract == 0 && Abstract.Type.TpDerived == 1);
    assert(Abstract.PrintFormat.Short == 0 && Abstract.PrintFormat.ClassNameAndId == 3);
    writeln("abstractenums OK");
}
