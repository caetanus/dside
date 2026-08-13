// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
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
// The REVERSE index, exported for this test alone (critics r13 #4). The main table returning to
// baseline says nothing about it: the cleanup used to drop a key from the vector of the object that
// died and leave it in the other endpoint's, so a long-lived receiver accumulated for ever while
// `qtd_leaf_table_size()` looked perfect.
extern (C) int qtd_leaf_index_size();
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

    assert(qtd_leaf_index_size() == 0,
           "the REVERSE index kept entries after every object died");

    // CHURN, which is the shape that made the one-sided cleanup matter: one receiver outliving
    // hundreds of owners. Each dead owner must take its key out of the receiver's vector too.
    auto keeper = newQObject!Sink();
    immutable b2 = qtd_leaf_table_size(), i2 = qtd_leaf_index_size();
    foreach (n; 0 .. 200) {
        auto own = new QQuickItem();
        auto sub = new QQuickItem(own);
        bindLeaf(sub, "parent", "widthChanged()", keeper, "ping()");
        qtd_qobject_delete(qobjOf(own));       // takes `sub` with it, as Qt does
    }
    assert(qtd_leaf_table_size() == b2,
           "200 dead owners left entries in the leaf table");
    assert(qtd_leaf_index_size() == i2,
           "200 dead owners left keys in the LIVE receiver's index — the one-sided cleanup is back");

    qtd_qobject_delete(qobjOf(keeper));
    assert(qtd_leaf_table_size() == base && qtd_leaf_index_size() == 0,
           "neither table came back to baseline");

    // NOT TESTED HERE, and said rather than implied: the connection's real sender is the object the
    // property HOLDS (`cur`), and it can die while owner and receiver live. The runtime watches it
    // — it is the third endpoint of QtdLeafEntry — but this shape cannot stage that death: `cur` is
    // the visual parent, so deleting it deletes the owner with it. Reaching it needs an item whose
    // QObject parent and visual parent are different objects, which is a fixture, not an assert.
    writeln("leaf lifetime OK: two owners are two entries; both tables empty after churn of 200 "
            ~ "owners against a LIVE receiver (critics r13 #4)");
}
