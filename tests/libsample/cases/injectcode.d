// overload resolution on methods returning const char*; private std::string member
// used only internally (never crosses the boundary by value).
import sample.injectcode;
import std.stdio; import std.string : fromStringz;
void main() {
    auto ic = InjectCode_new();
    assert(ic.simpleMethod1(2, 3).fromStringz == "5", "simpleMethod1 sum->str");
    assert(ic.simpleMethod2().fromStringz == "_", "simpleMethod2 const");
    assert(ic.overloadedMethod(10, 2.5).fromStringz == "12.5", "overloaded(int,double)");
    assert(ic.overloadedMethod(7, true).fromStringz == "7true", "overloaded(int,bool)");
    writeln("injectcode OK");
}
