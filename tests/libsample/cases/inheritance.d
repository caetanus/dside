import sample.derived; import std.stdio;
void main() {
    auto d = Derived_new(0);
    assert(d.singleArgument(true)==false && d.defaultValue(5)==5.1);
    assert(cast(int) d.overloaded(1,2)==0 && cast(int) d.overloaded(3.0)==1);
    writeln("inheritance OK");
}
