import sample.point, sample.size, sample.complex, sample.rect;
import std.stdio;
void main() {
    auto p = Point(3.0, 4.0); assert(p.x()==3.0 && p.y()==4.0);
    p.setX(10.0); assert(p.x()==10.0);
    Point* q = p.copy(); assert(q.x()==10.0);
    auto s = Size(3.0, 4.0); assert(s.calculateArea()==12.0);
    auto c = Complex(5.0, 2.3); assert(c.real_()==5.0 && c.imag()==2.3);
    auto r = Rect(1,2,3,4); assert(r.left()==1 && r.bottom()==4 && r.m_right==3);
    writeln("valuetypes OK");
}
