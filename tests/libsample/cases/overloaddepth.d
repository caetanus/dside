import sample.modifications, sample.point;
import std.stdio;
void main() {
    auto m = Modifications_new(); auto pt = Point(1.0, 2.0);
    alias E = Modifications.OverloadedModFunc;
    assert(m.overloaded(1, true, 2, 3.0)   == E.Overloaded_ibid, "...int,double");
    assert(m.overloaded(1, true, 2, false) == E.Overloaded_ibib, "...int,bool");
    assert(m.overloaded(1, true, 2, pt)    == E.Overloaded_ibiP, "...int,Point");
    assert(m.overloaded(1, true, 2, 3)     == E.Overloaded_ibii, "...int,int");
    assert(m.overloaded(1, true, pt, pt)   == E.Overloaded_ibPP, "...Point,Point");
    writeln("overloaddepth OK");
}
