import sample.polygon, sample.point;
import std.stdio;
void main() {
    auto poly = Polygon(1.0, 2.0);         // ctor (double,double)
    auto poly2 = Polygon(Point(3.0, 4.0)); // ctor (Point)
    writeln("polygon OK");
}
