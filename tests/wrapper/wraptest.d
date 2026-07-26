import qt.core.qobject, qt.core.qtimer;
import holder, core.memory, std.stdio, std.conv;
static void makeOrphans(void*[] ocs) { foreach (i; 0 .. ocs.length) { auto o = new QObject(); ocs[i] = o.ptr(); } }
// fire-and-forget children of `parent` (no D ref kept) — pinned by parenting.
static void makeChildren(QObject parent, void*[] cs) { foreach (i; 0 .. cs.length) { auto b = new QObject(parent); cs[i] = b.ptr(); } }
static void unparentAll(void*[] cs) { foreach (c; cs) { if (auto w = cast(QObject) holder.find(c)) w.setParent(null); } }
void main() {
    auto p = new QObject();
    auto t = new QTimer(p);                 // parented to p -> pinned at wrap time
    // identity: the holder returns the same wrapper for the same cptr
    assert(holder.find(t.ptr()) is t, "identity");
    // parenting pins: drop the D ref, GC, the wrapper survives (held by the parent pin)
    auto tc = t.ptr(); t = null;
    foreach (_; 0..5) GC.collect();
    assert(holder.find(tc) !is null, "parented child survived GC (pinned)");
    // orphans (no parent): dropped -> collected -> unregistered by the finalizer. GC
    // collection isn't guaranteed for a single object (conservative false pointers), so
    // use many and assert most were reclaimed.
    auto ocs = new void*[200];
    makeOrphans(ocs);
    foreach (_; 0..8) GC.collect();
    int alive = 0; foreach (oc; ocs) if (holder.find(oc) !is null) alive++;
    assert(alive < 20, "most orphans collected + unregistered (alive=" ~ alive.to!string ~ ")");
    // your test: new child of p (no ref kept) -> pinned; unparent -> unpin -> GC collects it.
    auto pp = new QObject();
    auto cs = new void*[200];
    makeChildren(pp, cs);
    foreach (_; 0..3) GC.collect();
    int pinned = 0; foreach (c; cs) if (holder.find(c) !is null) pinned++;
    assert(pinned == 200, "all children pinned by parenting (survive GC, pinned=" ~ pinned.to!string ~ ")");
    unparentAll(cs);                        // setParent(null) -> reparented() unpins
    foreach (_; 0..8) GC.collect();
    int stillPinned = 0; foreach (c; cs) if (holder.find(c) !is null) stillPinned++;
    assert(stillPinned < 20, "unparented children unpinned + collected (stillPinned=" ~ stillPinned.to!string ~ ")");
    writeln("wraptest OK");
}
