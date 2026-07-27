import sample.color, sample.invalue;
import std.stdio;
void main() {
    auto c = Color(InValue.OneIn);         // idiomatic ctor (enum)
    auto c2 = Color(0xff00ffu);            // idiomatic ctor (uint)
    writeln("color OK");
}
