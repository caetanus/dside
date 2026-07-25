import sample.modelindex, sample.oddbool, sample.intwrapper;
import std.stdio;
void main() {
    // value types com campo público -> struct-literal + acessores inline + static
    auto mi = ModelIndex(5);
    assert(mi.value() == 5 && mi.m_value == 5, "ModelIndex field/accessor");
    mi.setValue(9); assert(mi.value() == 9, "ModelIndex.setValue inline");
    assert(ModelIndex.getValue(mi) == 9, "ModelIndex static getValue(const&)");
    auto ob = OddBool(true);
    assert(ob.value() == true && ob.m_value == true, "OddBool");
    auto iw = IntWrapper(42);
    assert(iw.m_number == 42 && iw.toInt() == 42, "IntWrapper field + non-inline method");
    writeln("fields OK");
}
