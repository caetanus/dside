import sample.modifiedconstructor;
import std.stdio;
void main() {
    auto m = ModifiedConstructor(5);
    assert(m.retrieveValue() == 5, "ModifiedConstructor stores arg");
    writeln("modifiedctor OK");
}
