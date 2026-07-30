// GAP 1 (fixed): Reference only has `explicit Reference(int=-1)` INLINE (no linkable
// symbol in the lib). An out-of-line C++ shim (qtdctor: placement-new) now provides the
// ctor, so make!Reference(...) constructs. Reference is polymorphic (virtual ~), so this
// exercises the OBJECT path of the shim (heap alloc + placement-new).
// Also: objId()/setObjId() are INLINE methods on an object type — now bound via an
// out-of-line trampoline shim (self->objId()), so getters/setters are callable.
import sample.reference; import std.stdio;
import cxxrt : make;   // make!T(...) — the one factory spelling (cxxrt dispatches to T.__make)
void main() {
    auto r = make!Reference(42);            // inline ctor via shim (heap + placement-new)
    assert(r.objId() == 42, "objId() after ctor(42) — inline getter via shim");
    auto d = make!Reference();              // default arg (int = -1)
    assert(d.objId() == -1, "objId() default = -1");
    r.setObjId(7);                         // inline setter via shim
    assert(r.objId() == 7, "setObjId()");
    writeln("reference OK");
}
