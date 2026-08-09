// THE LEAF TABLE MUST COME BACK TO ITS BASELINE. `qtd_bind_leaf` keeps the dynamic connection in a
// side table keyed on owner|receiver|slot|property|signal. Qt invalidates the QMetaObject::Connection
// when either end dies, but the ENTRY is the runtime's own and nothing in Qt removes it: it used to
// survive until that exact key came back — and with a recycled address it could be FOUND by a later
// object, which is a stale connection handed to something that never asked for one.
//
// The count is not observable from the outside, so the runtime exports it. Build a tree, subscribe
// through it, destroy it, and require the table exactly where it started.
import qtmoc;
import qt.controls.qquickitem;
import std.stdio : writeln;

extern (C) int qtd_leaf_table_size();
extern (C) void qtd_qobject_delete(void* o) nothrow;

@QObject class Sink {
    int hits;
    @Slot void ping() { ++hits; }
}

void main() {   // no QGuiApplication: nothing here needs a scene, a window or an event loop
    immutable base = qtd_leaf_table_size();

    auto outer = new QQuickItem();
    auto inner = new QQuickItem(outer);
    auto sink  = newQObject!Sink();

    // `parent` is a QQuickItem*-valued meta property, so the leaf is whatever it holds — `outer`.
    bindLeaf(inner, "parent", "widthChanged()", sink, "ping()");
    assert(qtd_leaf_table_size() == base + 1,
           "one subscription did not produce one table entry");

    outer.setWidth(42);
    assert(sink.hits == 1, "the leaf signal did not reach the slot");

    // ...and a SECOND owner reading the same property name through a different object is a
    // DIFFERENT entry. It was not: the key omitted the owner, so this call used to evict the one
    // above and report success for both.
    auto other = new QQuickItem();
    auto kid   = new QQuickItem(other);
    bindLeaf(kid, "parent", "widthChanged()", sink, "ping()");
    assert(qtd_leaf_table_size() == base + 2,
           "two owners collapsed into one table entry");
    outer.setWidth(43);
    assert(sink.hits == 2, "the FIRST subscription was evicted by the second");

    qtd_qobject_delete(qobjOf(kid));
    qtd_qobject_delete(qobjOf(other));
    qtd_qobject_delete(qobjOf(inner));
    qtd_qobject_delete(qobjOf(outer));
    qtd_qobject_delete(qobjOf(sink));
    assert(qtd_leaf_table_size() == base,
           "the leaf table did not return to its baseline after the tree was destroyed");

    writeln("leaf lifetime OK: two owners are two entries, and destroying both ends empties the table");
}
