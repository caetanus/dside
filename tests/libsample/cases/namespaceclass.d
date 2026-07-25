import sample.ctparam;                              // SampleNamespace::CtParam
import std.stdio;
void main() {
    auto c = CtParam_new(42);                       // classe dentro de namespace
    assert(c.value() == 42, "namespace class CtParam.value()");
    writeln("namespaceclass OK");
}
