// The moc registry (_reg) is a permanent GC root: an entry keeps its D object alive until the
// C++ carrier is destroyed. A compiled QML document NESTS objects, so if those were parentless
// every document would leak one carrier + one pinned D object per nested object, for the life of
// the process — which also contradicts holder.d's "an unparented wrapper is collected".
//
// Nested objects are parented to their owner, so destroying the root closes the whole tree.
// Dropping the setQtParent calls below makes this fail with "moc registry leaked" — verified,
// and the reason this test exists.
import qtmoc, std.stdio, std.conv : to;

@QObject class Leaf { @Property int v = 1; }
@QObject class Root {
    @Property int v = 0;
    Leaf a, b;
    void build() { a = newQObject!Leaf(); b = newQObject!Leaf(); setQtParent(a, this); setQtParent(b, this); }
}

extern(C) void qtd_moc_delete(void*);   // deletes the C++ carrier (and, with it, its children)

void main() {
    auto base = mocRegisteredCount();
    {
        auto r = newQObject!Root();
        r.build();
        assert(mocRegisteredCount() == base + 3,
            "expected root + 2 children registered, got " ~ (mocRegisteredCount() - base).to!string);
        qtd_moc_delete(qobjOf(r));       // destroying the parent must take the children with it
    }
    auto after = mocRegisteredCount();
    assert(after == base,
        "moc registry leaked: baseline was " ~ base.to!string ~ ", now " ~ after.to!string);
    writeln("reglife OK: a nested tree registers 3 and releases all 3 on destruction");
}
