import sample.pen, sample.color, sample.invalue;
import std.stdio;
void main() {
    auto p = Pen();                        // ctor default
    auto col = Color(InValue.OneIn);
    auto p2 = Pen(col);                    // ctor de const Color&
    writeln("pen OK");
}
