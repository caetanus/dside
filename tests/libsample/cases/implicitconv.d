import sample.implicitconv; import std.stdio;
void main() {
    // método estático que não precisa construir ImplicitConv por Null
    auto e = ImplicitConv.implicitConvOverloading(5);   // static (int)
    assert(cast(int) e >= 0);
    writeln("implicitconv OK");
}
