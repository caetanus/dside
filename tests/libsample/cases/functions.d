import sample.functions, sample.invalue, sample.outvalue, sample.point, sample.complex;
import std.stdio;
void main() {
    assert(enumInEnumOut(InValue.OneIn) == OutValue.OneOut);
    assert(countCharacters("hello\0".ptr) == 5, "countCharacters(const char*)");
    // value types TRIVIALMENTE copiáveis (Point/Complex = 2 doubles) -> seguros por valor
    auto pt = Point(3.0, 4.0);
    auto cx = transmutePointIntoComplex(pt);       // const Point& -> Complex(x,y)
    assert(cx.real_() == 3.0 && cx.imag() == 4.0, "transmutePointIntoComplex");
    auto bk = transmuteComplexIntoPoint(cx);
    assert(bk.x() == 3.0 && bk.y() == 4.0, "transmuteComplexIntoPoint");
    // GAP: changePStr(Str*) faria append num std::string copiado bitwise (SSO
    // dangling) -> SEGV. Value type com membro std::string é inseguro por valor
    // (D não chama o copy ctor do C++). Precisa postblit this(this) -> copy ctor.
    writeln("functions OK");
}
