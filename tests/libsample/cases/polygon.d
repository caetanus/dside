// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// Polygon's ctors each seed m_points differently, and contains() reads that back — so the point
// actually stored is observable. Building two polygons and printing OK proved only that nothing
// crashed; a ctor that dropped its argument passed.
import sample.polygon, sample.point;
import std.stdio;
void main() {
    auto poly = Polygon(1.0, 2.0);         // ctor (double,double) -> one point at (1,2)
    assert(poly.contains(Point(1.0, 2.0)), "Polygon(double,double) did not store (1,2)");
    assert(!poly.contains(Point(9.0, 9.0)), "Polygon(double,double) contains a point it never got");

    auto poly2 = Polygon(Point(3.0, 4.0)); // ctor (Point)
    assert(poly2.contains(Point(3.0, 4.0)), "Polygon(Point) did not store its argument");
    assert(!poly2.contains(Point(1.0, 2.0)), "Polygon(Point) must not share the other's points");

    poly2.addPoint(Point(5.0, 6.0));       // a by-value Point argument crossing into C++
    assert(poly2.contains(Point(5.0, 6.0)), "addPoint(Point) did not reach the C++ vector");
    assert(poly2.contains(Point(3.0, 4.0)), "addPoint must append, not replace");

    writeln("polygon OK: both ctors store their point, addPoint appends (verified via contains)");
}
