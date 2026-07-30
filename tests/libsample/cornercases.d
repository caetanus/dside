import cxxrt : make;
// Corner-case regression tests for the extern(C++) generator, run against
// shiboken's libsample (a C++ library purpose-built to stress bindings).
// Driven by run.sh, which builds libsample.a, generates the D bindings, and
// links this on BOTH ldc and dmd. Each block is a binding mechanism we've fixed
// or want to keep working. See memory: shiboken-cornercase-tests.
import sample.point, sample.complex, sample.size, sample.event, sample.brush;
import sample.derived, sample.objecttype;
import sample.functions;                       // namespace/global free functions
import sample.invalue, sample.outvalue;        // enums used by those functions
import sample.str, sample.rect;                // std::string member; public fields + literal
import std.stdio;
import std.string : fromStringz;

void main() {
    // --- value type: struct literal, inline accessors, mutation ---------------
    {
        auto p = Point(3.0, 4.0);
        assert(p.x() == 3.0 && p.y() == 4.0);
        p.setX(10.0); p.setY(20.0);
        assert(p.x() == 10.0 && p.y() == 20.0);
    }
    // --- pointer-to-value-type return (Point* copy(), was read by value) ------
    {
        auto p = Point(0.0, 0.0); p.setX(10.0); p.setY(20.0);
        Point* q = p.copy();
        assert(q.x() == 10.0 && q.y() == 20.0, "Point* copy()");
    }
    // --- const& value param + Point* out-param --------------------------------
    {
        auto a = Point(0.0, 0.0), b = Point(10.0, 20.0);
        Point mid;
        a.midpoint(b, &mid);
        assert(mid.x() == 5.0 && mid.y() == 10.0, "midpoint out-param");
    }
    // --- value type inline field math -----------------------------------------
    {
        auto s = Size(3.0, 4.0);
        assert(s.calculateArea() == 12.0);
        s.setWidth(5.0);
        assert(s.calculateArea() == 20.0);
    }
    // --- Complex value type ---------------------------------------------------
    {
        auto c = Complex(5.0, 2.3);
        assert(c.real_() == 5.0 && c.imag() == 2.3);
        c.setImaginary(9.9);
        assert(c.imag() == 9.9);
    }
    // --- nested enums (ABI-identical) -----------------------------------------
    assert(Event.EventType.SOME_EVENT == 2);
    assert(Event.EventTypeClass.Value2 == 1);
    assert(Brush.Style.Cross == 1);

    // --- inheritance + overload resolution + enum return ----------------------
    {
        auto d = make!Derived(0);
        assert(d.singleArgument(true) == false && d.singleArgument(false) == true);
        assert(d.defaultValue(5) == 5.1);
        assert(cast(int) d.overloaded(1, 2) == 0);   // OverloadedFunc_ii
        assert(cast(int) d.overloaded(3.0) == 1);    // OverloadedFunc_d
    }
    // --- object factories return live object pointers (no abstract _new) ------
    {
        auto o = make!ObjectType();
        assert(o !is null);
        assert(o.createChild(o) !is null);
        assert(ObjectType.createWithChild() !is null);
    }
    // --- value-type operators (opBinary / opEquals) --------------------------
    {
        auto a = Point(10.0, 20.0), b = Point(1.0, 2.0);
        auto s = a + b; assert(s.x() == 11.0 && s.y() == 22.0, "operator+");
        auto d = a - b; assert(d.x() == 9.0 && d.y() == 18.0, "operator-");
        assert(a == Point(10.0, 20.0), "operator== true");
        assert(!(a == b), "operator== false");
    }
    // --- namespace free functions with enum params + enum return -------------
    assert(enumInEnumOut(InValue.OneIn) == OutValue.OneOut);
    assert(enumInEnumOut(InValue.TwoIn) == OutValue.TwoOut);

    // --- value type with a std::string member (m_str = ubyte[32], not `char`!) --
    {
        auto s = make!Str("hello\0".ptr);        // ctor const char*
        assert(s.cstring().fromStringz == "hello", "Str.cstring() round-trip (m_str=ubyte[32])");
        assert(s.get_char(0) == 'h' && s.get_char(4) == 'o', "Str.get_char");
        auto c = Str('X');                       // ctor this(char)
        assert(c.get_char(0) == 'X' && c.cstring().fromStringz == "X", "Str(char)");
    }
    // --- value type: public int fields + struct-literal + inline accessors ------
    {
        auto r = Rect(1, 2, 3, 4);               // positional literal (ctor is inline)
        assert(r.left() == 1 && r.top() == 2 && r.right() == 3 && r.bottom() == 4, "Rect accessors");
        assert(r.m_left == 1 && r.m_bottom == 4, "Rect public fields");
        r.m_right = 30;
        assert(r.right() == 30, "Rect field mutation via inline accessor");
    }
    // --- more value-type operators (opBinary!"/", reverse operator) ----------
    {
        auto p = Point(10.0, 20.0);
        auto q = p / 2;                          // opBinary!"/"(int)
        assert(q.x() == 5.0 && q.y() == 10.0, "Point / int");
    }
    // (note: Overload is not constructible — the `= default` ctor is inline, no symbol;
    //  overload resolution is already covered by Derived.overloaded above.)
    // --- object identity + parent/child + Str-typed methods ---------------------
    {
        auto o = make!ObjectType();
        auto rootn = make!Str("root\0".ptr);      // const& param requires an lvalue (D does not bind an rvalue to ref)
        o.setObjectName(rootn);
        assert(o.objectName().cstring().fromStringz == "root", "objectName round-trip (Str)");
        auto ch = o.createChild(o);
        auto kidn = make!Str("kid\0".ptr);
        ch.setObjectName(kidn);
        auto found = o.findChild(kidn);
        assert(found !is null && found is ch, "findChild by name -> same wrapper (identity)");
    }

    writeln("libsample corner cases: ALL PASS");
}
