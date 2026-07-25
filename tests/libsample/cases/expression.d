import sample.expression;
import std.stdio;
void main() {
    auto a = Expression(5), b = Expression(3);
    auto sum = a + b;                      // opBinary!"+"
    auto dif = a - b;                      // opBinary!"-"
    writeln("expression OK");
}
