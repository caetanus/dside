import sample.color, sample.invalue;
import std.stdio;
void main() {
    auto c = Color(InValue.OneIn);         // ctor idiomático (enum)
    auto c2 = Color(0xff00ffu);            // ctor idiomático (uint)
    writeln("color OK");
}
