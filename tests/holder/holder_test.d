// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
import holder, core.memory, std.stdio;
extern(C) nothrow @nogc { void* ht_make(); void ht_setparent(void*,void*); void ht_delete(void*); void* ht_app(); void ht_process(); }
alias HookFn = extern(C) void function(void*) nothrow;
extern(C) nothrow @nogc { void qtd_holder_set_destroyed_hook(HookFn); void qtd_holder_unreg(void*); }
class QObj : QtdObject { this(void* c) @nogc nothrow { super(c, true); } }
QObj wrapObj(void* c) { return cast(QObj) holder.wrap(c, (void* p) => cast(QtdObject) new QObj(p)); }
void makeOrphans(void*[] os) { foreach (o; os) { auto w = wrapObj(o); } }  // wrap+drop, no lingering ref
void main() {
    ht_app();
    // identity
    auto p = ht_make(); auto wp = wrapObj(p);
    assert(wrapObj(p) is wp, "identity");
    // parenting pins: parented child survives GC with no D ref
    auto c = ht_make(); ht_setparent(c, p);
    { auto wc = wrapObj(c); }
    foreach (_; 0..5) GC.collect();
    assert(holder.find(c) !is null, "parented child survived GC (pinned)");
    // destruction invalidates
    auto wc2 = wrapObj(c);
    ht_delete(p); ht_process();
    bool threw = false; try wc2.checkAlive(); catch (Error) threw = true;
    assert(threw, "access after destroy throws");
    assert(holder.find(c) is null, "child unregistered after destroy");
    // orphans (no parent): dropped -> collected -> deleteLater'd (loose: GC timing)
    auto os = new void*[200]; foreach (i; 0..200) os[i] = ht_make();
    makeOrphans(os);
    int before = 0; foreach (o; os) if (holder.find(o) !is null) before++;
    foreach (_; 0..8) GC.collect();
    ht_process();
    int after = 0; foreach (o; os) if (holder.find(o) !is null) after++;
    writefln("orphans registered: before=%d after=%d", before, after);
    assert(after < before / 2, "most orphans collected+unregistered via finalizer");
    countersMove();
    trackedOnce();
    writeln("holder OK");
}

/// The two leak counters must move in BOTH directions. A counter that is flat because it is
/// broken reads exactly like a counter that is flat because nothing leaked, so asserting only
/// "returns to baseline" would pass against an instrument that never worked; the rise is
/// asserted first, on the pinned children, which is the deterministic half (a pinned wrapper
/// cannot be collected, so this does not depend on when the GC runs).
void countersMove() {
    auto w0 = holder.wrapperCount(), p0 = holder.pinnedCount();
    auto root = ht_make();
    auto kids = new void*[100];
    foreach (i; 0 .. 100) { kids[i] = ht_make(); ht_setparent(kids[i], root); wrapObj(kids[i]); }
    foreach (_; 0 .. 5) GC.collect();
    auto w1 = holder.wrapperCount(), p1 = holder.pinnedCount();
    writefln("counters: pinned %d -> %d, wrapped %d -> %d", p0, p1, w0, w1);
    assert(p1 - p0 == 100, "pinnedCount rises with parented children");
    assert(w1 - w0 >= 100, "wrapperCount rises with live wrappers");
    // Deleting the parent deletes the children: destroyed() must unregister AND unpin every one.
    ht_delete(root); ht_process();
    foreach (_; 0 .. 5) GC.collect();
    ht_process();
    assert(holder.pinnedCount() <= p0, "pinnedCount returns to baseline");
    assert(holder.wrapperCount() <= w0, "wrapperCount returns to baseline");
}

/// destroyed() is connected ONCE PER C++ OBJECT, not once per wrapper. The identity map cannot
/// answer this: it is erased when a WRAPPER dies, which for a borrowed pointer happens while the
/// C++ object is still alive and still connected — so re-wrapping used to add another connection
/// every time, and a long-lived object accumulated them without bound (measured: 20 for 20).
///
/// The re-wrap is forced by calling unreg directly rather than by dropping a reference and
/// collecting: the finalizer does exactly this and nothing else that matters here, and waiting
/// for a collection makes the test depend on which compiler's GC ran (dmd collected once where
/// ldc collected twenty times — the same probe then proves nothing on one of the two).
void trackedOnce() {
    qtd_holder_set_destroyed_hook(&countingHook);
    scope (exit) qtd_holder_set_destroyed_hook(&holder.onDestroyed);
    auto o = ht_make();
    foreach (_; 0 .. 20) { wrapObj(o); qtd_holder_unreg(o); }   // what the finalizer does
    hits = 0;
    ht_delete(o); ht_process();
    writefln("destroyed-hook calls after 20 re-wraps: %d", hits);
    assert(hits == 1, "one destroyed() connection per object, not per wrapper");
}

__gshared int hits;
extern (C) void countingHook(void* c) nothrow { hits++; holder.onDestroyed(c); }
