// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// QList<T> OF A VALUE RECORD, both directions — the shape of QDnsLookup::mailExchangeRecords().
//
// The values are the easy half. The half that decides whether this is safe is the COUNT: the record
// has a user-provided copy constructor and destructor (as every d-pointer Qt record does), and the
// fixture counts live instances. Right after each call the count must be exactly the copies D holds:
//   - a byte copy where the real copy constructor was needed leaves it LOW (copies not counted, and
//     later destroyed — a double release of the QString inside);
//   - a container the call leaked, or one destroyed on the wrong-sized struct, leaves it HIGH.
// A test that compared only the values would pass in both of those cases.
import qt.reclist.rechost, qt.reclist.recitem;
import std.stdio, std.conv : to;

void main() {
    immutable base = RecItem.live();

    // RETURN: a QList by value becomes a D array of copies; the QList itself is gone.
    auto a = RecHost.make(3);
    assert(a.length == 3, "three records expected, got " ~ a.length.to!string);
    assert(a[0].name().toString() == "item0" && a[1].name().toString() == "item1"
           && a[2].n() == 20, "the records' values did not survive the crossing");
    assert(RecItem.live() == base + 3,
           "live after make(3): expected base+3 (the D copies), got base+" ~ (RecItem.live() - base).to!string);

    // The QVector spelling (Qt6: the same type; Qt5: a different container) — same rule.
    auto v = RecHost.makeVec(2);
    assert(v.length == 2 && v[1].name().toString() == "v1", "QVector<RecItem> did not cross");
    assert(RecItem.live() == base + 5, "live after makeVec(2): expected base+5, got base+"
           ~ (RecItem.live() - base).to!string);

    // PARAMETER: a D array becomes a QList for the call (copies made, then released with it).
    assert(RecHost.total(a) == 30, "total over the D array was wrong");
    assert(RecHost.names(a).toString() == "item0,item1,item2", "the QList built from D lost order or values");
    assert(RecItem.live() == base + 5,
           "a parameter's temporary QList outlived the call: base+" ~ (RecItem.live() - base).to!string);

    // A D-side copy of the array copies each record through the REAL copy constructor.
    auto b = a.dup;
    assert(RecItem.live() == base + 8, "a.dup must copy-construct each record: base+"
           ~ (RecItem.live() - base).to!string);
    assert(b[2].name().toString() == "item2");

    // Empty: no records, nothing alive, nothing crashed.
    assert(RecHost.make(0).length == 0 && RecItem.live() == base + 8);

    writeln("reclist OK: QList/QVector<record> cross both ways with real copies (live count exact)");
}
