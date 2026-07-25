// bindingmanager.d — the cptr -> D-wrapper registry, modelled on Shiboken's
// BindingManager (registerWrapper / retrieveWrapper / releaseWrapper).
//
// It does three jobs at once:
//   1. Identity      — a C++ pointer we already wrap yields the SAME D wrapper
//                      (so `a.parent() is b`, `sender()`, findChild, … work).
//   2. GC pin        — the registry is a module-global (a GC root), so a
//                      registered wrapper stays alive for exactly as long as its
//                      C++ object does. No __gshared, no permanent GC.addRoot.
//   3. Invalidation  — when C++ destroys the object, QObject::destroyed() fires
//                      the hook below, which invalidates the wrapper (Shiboken's
//                      validCppObject = 0) and releases it, making it collectable.
//
// Single-threaded by design: entries are touched from the Qt object's thread
// (the main event loop). A multi-threaded binding would guard g_wrappers.
module bindingmanager;

// Self-contained: declare the QtCore-only C support directly (implemented in
// qtd_binding.cpp) so any generated QObject binding can import this module
// without pulling in the QtQml-heavy meta-object runtime.
alias QtdDestroyedFn = extern (C) void function(void* cptr) nothrow;
extern (C) nothrow {
    void  qtd_set_destroyed_hook(QtdDestroyedFn fn);
    void  qtd_track_destroyed(void* obj);
    int   qtd_has_parent(void* obj);
    // plain-QObject helpers (exercise the general wrapper path in tests)
    void* qtd_make_qobject();
    void  qtd_qobject_delete(void* obj);
    void  qtd_qobject_set_parent(void* child, void* parent);
}

/// Per-entry record. `invalidate` is a type-erased thunk supplied at register
/// time — it knows how to mark this specific wrapper dead (null its handle etc.).
private struct Entry {
    Object wrapper;
    void function(Object) nothrow invalidate;
}

// The AA is __gshared → a GC root, so its `Object` values are pinned while
// registered. Keyed by the C++ object pointer.
private __gshared Entry[void*] g_wrappers;

shared static this() {
    qtd_set_destroyed_hook(&onDestroyed);   // install the destroyed() callback once
}

/// Register a wrapper for a C++ object. If it is a QObject, hook its destroyed()
/// so the wrapper is auto-invalidated when Qt deletes it. Returns cptr for chaining.
void* register(void* cptr, Object wrapper, void function(Object) nothrow invalidate,
               bool isQObject) nothrow {
    g_wrappers[cptr] = Entry(wrapper, invalidate);
    if (isQObject) qtd_track_destroyed(cptr);
    return cptr;
}

/// Return the existing wrapper for a C++ pointer, or null if none is registered.
Object retrieve(void* cptr) nothrow {
    if (auto e = cptr in g_wrappers) return e.wrapper;
    return null;
}

/// Drop the registry entry (releases the pin). Idempotent.
void release(void* cptr) nothrow {
    g_wrappers.remove(cptr);
}

/// True if the C++ QObject has a parent — i.e. C++ owns it and D must not delete it.
bool cppOwns(void* cptr) nothrow {
    return qtd_has_parent(cptr) != 0;
}

/// destroyed() hook: C++ deleted the object. Invalidate its wrapper and release.
/// Idempotent and safe if the meta-object dtor already released it.
extern (C) void onDestroyed(void* cptr) nothrow {
    if (auto e = cptr in g_wrappers) {
        if (e.invalidate) e.invalidate(e.wrapper);
        g_wrappers.remove(cptr);
    }
}
