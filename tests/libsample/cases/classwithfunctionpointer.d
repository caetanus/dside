import cxxrt : make;
// function pointer as a parameter (FIXED): void (*)(void*) now maps to `void*`, so
// callFunctionPointer(int, fp) binds and can be invoked with a real D callback passed
// as `cast(void*) &fn`. Also the static void*(...) method works.
import sample.classwithfunctionpointer;
import std.stdio;
__gshared int fpCalls;
extern(C) void myFp(void* p) { fpCalls++; }
void main() {
    auto c = make!ClassWithFunctionPointer();                 // value type, by value
    c.callFunctionPointer(0, cast(void*) &myFp);             // fn-ptr param -> invokes myFp
    assert(fpCalls == 1, "callFunctionPointer invoked the D callback");
    ClassWithFunctionPointer.doNothing(cast(void*) &myFp);   // static, void* param — OK
    writeln("classwithfunctionpointer OK (callFunctionPointer callback fired)");
}
