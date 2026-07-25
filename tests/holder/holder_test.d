import holder, core.memory, std.stdio;
extern(C) nothrow @nogc { void* ht_make(); void ht_setparent(void*,void*); void ht_delete(void*); void* ht_app(); void ht_process(); }
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
    writeln("holder OK");
}
