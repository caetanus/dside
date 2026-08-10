// holder.d — the D wrapper lifetime layer.
//
// Design (parenting-pins):
//   - Every generated object wrapper extends QtdObject, which holds the C++ pointer
//     `_cpp` (nullable) and checks it on every call — a destroyed object throws
//     instead of segfaulting.
//   - Identity: `wrap(cptr, factory)` returns the SAME wrapper for a C++ pointer
//     (the map is C++-side, so it does not pin — see qtd_holder.cpp).
//   - Parenting pins: a parented child is held in `_pinned` (a GC root) so it lives
//     as long as its parent, even with no D-side reference. Unparenting / destruction
//     unpins it.
//   - A dropped, UNparented wrapper is collected by the GC; its finalizer calls
//     deleteLater (you own it). A parented one's finalizer does nothing (Qt owns it).
//   - destroyed() (C++ deleted the object) nulls `_cpp` and drops the entries.
//
// Single-threaded by design (Qt main thread; stop-the-world GC).
module holder;

import core.memory : GC;

alias QtdDestroyedFn = extern (C) void function(void *) nothrow;

extern (C) nothrow @nogc {
    void  qtd_holder_set_destroyed_hook(QtdDestroyedFn);
    void  qtd_holder_track(void *);
    int   qtd_holder_has_parent(void *);
    void  qtd_holder_delete_later(void *);
    int   qtd_holder_is_app(void *);
    void  qtd_holder_reg(void *, void *);
    void *qtd_holder_find(void *);
    void  qtd_holder_unreg(void *);
}

/// Base of every generated object wrapper. Holds the C++ pointer and its lifetime.
class QtdObject {
    package void *_cpp;
    package bool _isQObj;   // has destroyed()/parent() -> lifetime is tracked; else dispose-only
    // WHO CREATED THIS OBJECT — not "who has it now", which is what parenting answers.
    //
    // The finalizer used to decide ownership from parenting alone: unparented and not the app
    // singleton meant "ours, delete it". That is right for `new QWidget()` and WRONG for every
    // pointer Qt hands back. `QThread.currentThread()` compiles to `QThread.wrap(__QThread_1())`
    // and the current thread has no parent — so dropping the D reference scheduled a deleteLater
    // on the running thread, from what looks like a getter. Qt documents that deleting a running
    // QThread crashes.
    //
    // The distinction was already present at the two call sites and simply not recorded: a
    // generated CONSTRUCTOR allocated the object (`__cpp_new` then `_register()`), while `wrap()`
    // was GIVEN a pointer. So the default is BORROWED and only the paths that created the object
    // say otherwise. Nothing in the 385 generated `_register()` call sites has to change.
    //
    // This is deliberately not a full ownership model: an API that TRANSFERS ownership either way
    // (`QLayout::addItem`, a factory return) still needs the typesystem to say so. What it removes
    // is the failure mode where the binding deletes something it never owned — a leak is the
    // conservative error here, a use-after-free is not.
    package bool _ownedByD;

    this(void *c, bool isQObj) @nogc nothrow { _cpp = c; _isQObj = isQObj; }

    /// C++ deleted the object -> mark dead; a later call throws via checkAlive.
    final void _invalidate() @nogc nothrow { _cpp = null; }

    /// Register a freshly-constructed wrapper (built by a `new X(args)` ctor, whose _cpp is
    /// already set via super) for identity + lifetime: the same step wrap() runs after make() —
    /// map the C++ pointer to this wrapper, track destroyed(), and pin if it was born parented.
    /// `owned`: this wrapper's object was allocated by the binding (a generated ctor). `wrap()`
    /// passes false — see the note on `_ownedByD`. Defaulted so the 385 generated call sites,
    /// which are all constructors, keep meaning exactly what they meant.
    final void _register(bool owned = true) nothrow {
        _ownedByD = owned;
        qtd_holder_reg(_cpp, cast(void *) this);
        if (_isQObj) {
            qtd_holder_track(_cpp);
            if (qtd_holder_has_parent(_cpp) != 0) _pinned[_cpp] = this;
        }
    }

    /// A D subclass / @QObject object adopts its C++ trampoline pointer: set _cpp, register
    /// for identity, PIN (C++ holds a raw dself back-ref, so the GC must not collect this),
    /// and track destroyed(). Called by the moc mixin/newQObject (wrapper mode only).
    final void _adopt(void *c) nothrow {
        _cpp = c;
        _ownedByD = true;   // the C++ trampoline was created for THIS D object, by us

        qtd_holder_reg(c, cast(void *) this);
        qtd_holder_track(c);
        _pinned[c] = this;
    }

    final void checkAlive() {
        if (_cpp is null)
            throw new Error("use of a destroyed C++ object");
    }
    /// The live C++ pointer (throws if already destroyed).
    final void *ptr() { checkAlive(); return _cpp; }

    /// GC finalizer: if still alive and WE own it (no Qt parent), deleteLater it.
    /// A parented object is Qt-owned -> do nothing. Only C calls here (finalizer-safe).
    ~this() @nogc nothrow {
        if (!_live) return;   // runtime shutting down -> don't touch Qt/GC
        if (_ownedByD && _isQObj && _cpp !is null
                && qtd_holder_has_parent(_cpp) == 0 && qtd_holder_is_app(_cpp) == 0)
            qtd_holder_delete_later(_cpp);   // QObject WE created and Qt has not adopted
        if (_cpp !is null)
            qtd_holder_unreg(_cpp);
    }
}

// Parented children pinned here (a GC root) so they outlive any dropped D reference.
private __gshared QtdObject[void *] _pinned;

// True between module init and teardown. destroyed() fires from Qt during exit() too
// (posted deleteLater events), when the D runtime is going down — touching the GC then
// crashes, so guard on this (mirrors Shiboken bailing on !Py_IsInitialized).
private __gshared bool _live = false;

shared static this() { qtd_holder_set_destroyed_hook(&onDestroyed); _live = true; }
shared static ~this() { _live = false; }

/// The existing wrapper for a C++ pointer, or null.
QtdObject find(void *cptr) @nogc nothrow {
    return cast(QtdObject) qtd_holder_find(cptr);
}

/// Retrieve-or-wrap: identity for a C++ pointer. `make` builds the correct wrapper
/// type when none exists yet (the orphan path). A newly-wrapped, already-parented
/// object is pinned immediately. `isQObj` gates the destroyed() hook + the parent
/// query — a non-QObject has neither (touching them would misuse a non-QObject as one).
QtdObject wrap(void *cptr, scope QtdObject delegate(void *) make) {
    if (cptr is null) return null;
    if (auto w = find(cptr)) return w;
    auto w = make(cptr);           // make() sets w._cpp = cptr via the adopt ctor
    w._register(false);            // BORROWED: Qt handed us this pointer, we did not allocate it
    return w;
}

/// Parenting pins the child; call when a parent is established (ctor-with-parent / setParent).
void pin(void *cptr, QtdObject w) nothrow { _pinned[cptr] = w; }
void unpin(void *cptr) nothrow { _pinned.remove(cptr); }

/// Re-evaluate a wrapper's pin against its CURRENT Qt parent. Called after any non-const
/// method (which may have re-parented `this` or an object argument via setParent / a layout
/// add-remove / etc.): gained a parent -> pin (survives with the parent even with no D ref);
/// lost its parent -> unpin (now D-owned again -> the GC may collect + deleteLater it).
void reparented(QtdObject w) nothrow {
    if (w is null || w._cpp is null || !w._isQObj) return;
    auto c = w._cpp;
    bool nowParented = qtd_holder_has_parent(c) != 0;
    bool pinned = (c in _pinned) !is null;
    if (nowParented && !pinned) _pinned[c] = w;
    else if (!nowParented && pinned) _pinned.remove(c);
}

/// destroyed() hook: C++ deleted the object -> invalidate any live wrapper + drop it.
extern (C) void onDestroyed(void *cptr) nothrow {
    if (!_live) return;   // runtime shutting down -> don't touch the GC
    if (auto w = find(cptr)) w._invalidate();
    qtd_holder_unreg(cptr);
    _pinned.remove(cptr);
}
