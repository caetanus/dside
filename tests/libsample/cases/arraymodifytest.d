import cxxrt : make;
// raw array marshaling: pass a D int[] as int* to C++.
import sample.arraymodifytest;
import std.stdio;
void main() {
    auto a = make!ArrayModifyTest();
    int[] xs = [1, 2, 3, 4, 5];
    assert(a.sumIntArray(cast(int) xs.length, xs.ptr) == 15, "sumIntArray via .ptr");
    writeln("arraymodifytest OK");
}
