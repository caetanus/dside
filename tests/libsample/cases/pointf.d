import cxxrt : make;
import sample.pointf, sample.point;
import std.stdio;
void main() {
    auto p = make!PointF(3.0, 4.0);       // this(const Point&) disables the literal; the (double,double) ctor is all-default -> _new only
    assert(p.x() == 3.0 && p.y() == 4.0, "PointF x/y");
    auto b = make!PointF(1.0, 2.0);
    assert((p + b).x() == 4.0 && (p - b).y() == 2.0, "PointF +/-");
    PointF mid; p.midpoint(b, &mid);
    assert(mid.x() == 2.0 && mid.y() == 3.0, "PointF midpoint out-param");
    writeln("pointf OK");
}
