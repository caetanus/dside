// qtmeta.d — CTFE layer: a class annotates members with @qtProperty/@qtSlot/
// @qtSignal and mixes in QtObject; the meta-object description and the Qt<->D
// dispatch are generated at compile time via __traits + static foreach. This is
// the "native moc": no external generator, no codegen step.
module qtmeta;

import metaobj;

struct qtProperty {}
struct qtSlot {}
struct qtSignal {}

template isTagged(alias sym, alias UDA) {
    static if (__traits(compiles, __traits(getAttributes, sym))) {
        enum isTagged = () {
            bool r = false;
            static foreach (a; __traits(getAttributes, sym))
                static if (is(a == UDA)) r = true;
            return r;
        }();
    } else enum isTagged = false;
}

template qtType(T) {
    static if (is(T == int))         enum qtType = "int";
    else static if (is(T == bool))   enum qtType = "bool";
    else static if (is(T == double)) enum qtType = "double";
    else static assert(false, "unsupported @qtProperty type: " ~ T.stringof);
}

mixin template QtObject() {
    import metaobj;
    private alias _T = typeof(this);

    void* obj;
    private bool _alive;         // Shiboken's validCppObject: false once Qt deletes us
    private int[string] _mIdx;   // signal/slot name -> method index
    private int[string] _pIdx;   // property name -> property index

    void setup() {
        auto b = qtd_mob_new((_T.stringof ~ "\0").ptr);
        // a notify signal per @qtProperty
        static foreach (m; __traits(allMembers, _T))
            static if (isTagged!(__traits(getMember, _T, m), qtProperty))
                _mIdx[m ~ "Changed"] = qtd_mob_add_signal(b, (m ~ "Changed()\0").ptr);
        // explicit @qtSignal methods
        static foreach (m; __traits(allMembers, _T))
            static if (isTagged!(__traits(getMember, _T, m), qtSignal))
                _mIdx[m] = qtd_mob_add_signal(b, (m ~ "()\0").ptr);
        // @qtSlot methods
        static foreach (m; __traits(allMembers, _T))
            static if (isTagged!(__traits(getMember, _T, m), qtSlot))
                _mIdx[m] = qtd_mob_add_slot(b, (m ~ "()\0").ptr);
        // properties (linked to their notify signal)
        static foreach (m; __traits(allMembers, _T))
            static if (isTagged!(__traits(getMember, _T, m), qtProperty))
                _pIdx[m] = qtd_mob_add_property(b, (m ~ "\0").ptr,
                    (qtType!(typeof(__traits(getMember, _T, m))) ~ "\0").ptr,
                    _mIdx[m ~ "Changed"]);
        obj = qtd_mob_create_object(b, cast(void*) this, &_slot, &_read, &_write, &_dtor);
        _alive = true;
        // Register in the BindingManager. Qt (C++) holds `this` as dself, a pointer
        // on the C++ heap the D GC never scans — but the registry is a module-global
        // (a GC root) that strong-refs the wrapper, so `this` stays alive for exactly
        // as long as its QObject does. No __gshared, no manual GC.addRoot. Registering
        // also hooks destroyed(), so deleteLater/parent-delete invalidate us too.
        import bindingmanager;
        bindingmanager.register(obj, this, &_invalidate, /*isQObject*/ true);
    }

    /// Type-erased invalidation thunk (Shiboken's validCppObject = 0): mark the
    /// wrapper dead so stale calls no-op instead of touching freed memory.
    static void _invalidate(Object o) nothrow {
        auto self = cast(_T) o;
        self._alive = false;
        self.obj = null;
    }

    /// ~QtdObject fired (synchronous teardown() path). Release + invalidate now;
    /// the later destroyed() signal hits the same key and no-ops (idempotent).
    extern (C) static void _dtor(void* dself) nothrow {
        import bindingmanager;
        auto self = cast(_T) dself;
        bindingmanager.onDestroyed(self.obj);
    }

    /// Explicitly destroy the backing QObject now (synchronous deleteLater). Runs
    /// _dtor via ~QtdObject, so the pin is released and the wrapper invalidated.
    void teardown() {
        if (obj) qtd_object_delete(obj);
    }

    /// True if C++ owns this object (it has a parent) — Qt will delete it, so D
    /// must not. Mirrors Shiboken's hasOwnership flip on setParent.
    bool cppOwns() nothrow {
        import bindingmanager;
        return obj !is null && bindingmanager.cppOwns(obj);
    }

    /// Emit a @qtProperty's change notification (call after mutating the field).
    void notify(string name)() {
        if (!_alive) return;   // wrapper invalidated by C++ destruction
        qtd_object_emit(obj, _mIdx[name ~ "Changed"], null);
    }
    /// Same, but deferred to the main event-loop stack. Use this when emitting
    /// from a vibe fiber — QML re-evaluates bindings as V4 JS, whose stack guard
    /// is calibrated to the main thread stack (a fiber stack silently fails).
    void notifyQueued(string name)() {
        if (!_alive) return;
        qtd_object_emit_queued(obj, _mIdx[name ~ "Changed"]);
    }
    /// Emit a @qtSignal.
    void signal(string name)() {
        if (!_alive) return;
        qtd_object_emit(obj, _mIdx[name], null);
    }

    extern (C) static void _slot(void* dself, int id, void** args) nothrow {
        auto self = cast(_T) dself;
        static foreach (m; __traits(allMembers, _T))
            static if (isTagged!(__traits(getMember, _T, m), qtSlot))
                if (id == self._mIdx[m]) {
                    try { __traits(getMember, self, m)(); } catch (Exception) {}
                    return;
                }
    }
    extern (C) static void _read(void* dself, int id, void* arg) nothrow {
        auto self = cast(_T) dself;
        static foreach (m; __traits(allMembers, _T))
            static if (isTagged!(__traits(getMember, _T, m), qtProperty))
                if (id == self._pIdx[m]) {
                    *cast(typeof(__traits(getMember, _T, m))*) arg = __traits(getMember, self, m);
                    return;
                }
    }
    extern (C) static void _write(void* dself, int id, void* arg) nothrow {
        auto self = cast(_T) dself;
        static foreach (m; __traits(allMembers, _T))
            static if (isTagged!(__traits(getMember, _T, m), qtProperty))
                if (id == self._pIdx[m]) {
                    __traits(getMember, self, m) =
                        *cast(typeof(__traits(getMember, _T, m))*) arg;
                    return;
                }
    }
}
