import sample.modifications, sample.point;
import cxxrt : make;   // make!T(...) — the one factory spelling (cxxrt dispatches to T.__make)
import std.stdio;
void main() {
    auto m = make!Modifications(); auto pt = Point(1.0, 2.0);
    alias E = Modifications.OverloadedModFunc;
    assert(m.overloaded(1, true, 2, 3.0)   == E.Overloaded_ibid, "...int,double");
    assert(m.overloaded(1, true, 2, false) == E.Overloaded_ibib, "...int,bool");
    assert(m.overloaded(1, true, 2, pt)    == E.Overloaded_ibiP, "...int,Point");
    assert(m.overloaded(1, true, 2, 3)     == E.Overloaded_ibii, "...int,int");
    assert(m.overloaded(1, true, pt, pt)   == E.Overloaded_ibPP, "...Point,Point");
    writeln("overloaddepth OK");
}
