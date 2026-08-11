// A PROBE THAT ASSERTS A GAP IS STILL THERE. Read the failure message before "fixing" this.
//
// `nonqobject-qt-owned-dangles` in tests/expected-fails.json: when Qt destroys an object it owns
// and that object is not a QObject, nothing invalidates the D wrapper. `QTreeWidgetItem` has no
// destroyed() signal, so `_cpp` stays non-null and `checkAlive()` — the guard that turns a use
// after destruction into a thrown Error instead of a segfault — never fires.
//
// This is what an inventory entry needs and did not have: something that says WHEN IT STOPS BEING
// TRUE. The linter checked the entry was well-formed; the runner checks its probes still pass; and
// a probe that asserts the CURRENT behaviour turns the day somebody closes the gap into a loud
// failure that names the entry to delete. That is the unexpected-pass detection the audit asks for,
// without inventing a direction field nothing would use.
//
// So: if this test fails because the wrapper IS now invalidated, the gap is closed. Delete the
// entry, delete this file, and keep the fix.
import qt.widgets.qapplication, qt.widgets.qtreewidget, qt.widgets.qtreewidgetitem;
import cxxrt;
import std.stdio : writeln;

pragma(mangle, "_ZN12QApplicationC1ERiPPci") extern(C++) void __qapp_ctor(void* self, ref int, char**, int);
extern (C) void qtd_qobject_delete(void* o) nothrow;
extern (C) void* qtd_holder_find(void*) nothrow @nogc;

void main() {
    __gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "dangle\0".ptr, null];
    auto raw = __cpp_new(__QApplication_size); __qapp_ctor(raw, argc, argv.ptr, 0);
    cast(void) QApplication.wrap(raw);

    auto tree = new QTreeWidget(null);
    auto item = new QTreeWidgetItem(0);
    tree.addTopLevelItem(item);          // declared transfer: the tree owns it from here
    auto p = item.ptr();
    assert(p !is null && qtd_holder_find(p) !is null, "the item was not registered");

    qtd_qobject_delete(tree.ptr());      // the tree deletes its items; no signal reaches us

    // THE GAP. `_cpp` should be null and checkAlive() should fire; it does not, because there is
    // nothing to hear. Asserting the defect is deliberate — see the header.
    assert(item.ptr() is p,
           "GOOD NEWS, AND THIS TEST IS NOW WRONG: the wrapper WAS invalidated when its owner died, "
           ~ "so `nonqobject-qt-owned-dangles` is closed. Remove that entry from "
           ~ "tests/expected-fails.json and delete this file.");

    writeln("dangle OK: the gap `nonqobject-qt-owned-dangles` is still real — a non-QObject whose ",
            "owner destroyed it leaves a wrapper that still believes it is alive");
}
