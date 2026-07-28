// qtmoc — signals/slots for QObjects defined in D, WITHOUT moc: the meta-object is
// built at runtime (QMetaObjectBuilder, see qtdmoc.cpp) and, via
// CTFE + __traits, we generate the signatures, the signal emit and the slot
// dispatch. The user only marks the class with @QObject and the methods with @Slot:
//
//     @QObject class Counter {
//         Signal!int valueChanged;                                   // a signal
//         @Slot void setValue(int v) { ...; valueChanged.emit(v); }  // a slot
//     }
//
//     auto c = newQObject!Counter();                    // builds the meta-object
//     connectMeta(c, "valueChanged(int)", c, "onValue(int)");
//
// In D a UDA alone injects neither members nor a constructor — that's why the instance
// is born by the newQObject!T factory (which keeps the QObject's void* in an external
// registry, instead of a field inside the user's class).
//
// THREADING (critics r8 #6): this runtime is SINGLE-THREADED by design. The side-tables
// (_reg/_qmlFactories/_qmlRegistered here; g_moCache/g_moAttach in qtdmoc.cpp) are lock-free
// global mutable state. The restriction is not a silent assumption: the first
// construction/registration pins an "owner thread" into the C++ runtime, and creating/destroying/registering a
// @QObject from another thread ABORTS with a message (qtd_thread_guard) instead of corrupting a map.
// Create and destroy D @QObjects only on the thread that first used the runtime (typically the main one).
// Real support for worker QObjects (locking / per-thread tables) is a structural follow-up.
module qtmoc;

import std.traits : Parameters, hasUDA, getUDAs;

// ---- runtime C++ (qtdmoc.cpp) -----------------------------------------------
alias SlotCb = extern (C) void function(void*, int, void**) nothrow;
alias PropCb = extern (C) void function(void*, int, int, void**) nothrow;
extern (C) nothrow {
    void* qtd_moc_new(const(char)*, const(char)**, int, const(char)**, int,
                      const(char)**, const(char)**, const(int)*, int, void*, SlotCb, PropCb);
    // Register a D @QObject type as a QML element (only linked in for QtQml bindings).
    alias MakeCb = extern (C) void* function(void*, void*) nothrow;
    alias DestroyCb = extern (C) void function(void*, void*) nothrow;
    void* qtd_qml_register_type(const(char)*, int, int, const(char)*,
                      const(char)*, const(char)**, int, const(char)**, int,
                      const(char)**, const(char)**, const(int)*, int,
                      MakeCb, DestroyCb, SlotCb, PropCb);
    void  qtd_moc_activate(void*, int, void**);
    int qtd_connect_meta(void*, const(char)*, void*, const(char)*);
    void* qtd_metacast(void*, const(char)*);   // QObject::qt_metacast(n) on a qobj — for the identity test
    const(char)* qtd_moc_classname(void*);     // metaObject()->className() of the qobj
    int  qtd_moc_owner_check();                // 1=owner thread, 0=other thread, -1=no owner (r8 #6)
    // QString marshaling (implemented in qtdmoc.cpp, which links QtCore)
    void* qtd_str_to_qs(const(char)*, int);
    void  qtd_qs_free(void*);
    void* qtd_tr(const(char)*, const(char)*, const(char)*, int);   // QCoreApplication::translate
    bool  qtd_install_translator(const(char)*);                    // new QTranslator + install (C++)
    void  qtd_qs_set(void*, const(char)*, int);   // assign a D string into an existing QString
    int   qtd_qs_utf8len(void*);
    void  qtd_qs_utf8(void*, char*);
    // property access by name (via QVariant)
    int    qtd_prop_get_int(void*, const(char)*);
    void   qtd_prop_set_int(void*, const(char)*, int);
    double qtd_prop_get_double(void*, const(char)*);
    void   qtd_prop_set_double(void*, const(char)*, double);
    bool   qtd_prop_get_bool(void*, const(char)*);
    void   qtd_prop_set_bool(void*, const(char)*, bool);
    void* qtd_prop_get_qs(void*, const(char)*);
    void  qtd_prop_set_qs(void*, const(char)*, const(char)*, int);
}

// ---- callback error policy (round-4 #6: silence is not acceptable) ----------
// A slot/property/signal callback invoked BY Qt must be `nothrow` — a D exception can't
// unwind across the C++ frame. Instead of swallowing it, record it: a thread-local last
// error + count (inspectable/testable), an optional global hook, and a debug stderr note.
// (Errors — asserts, etc. — are bugs and are intentionally NOT caught here: they terminate.)
__gshared void function(Throwable) nothrow qtdCallbackErrorHook;   // opt-in global sink
size_t qtdCallbackErrors;          // thread-local (module scope) — count for asserts/tests
Throwable qtdLastCallbackError;    // thread-local — the most recent swallowed exception
void qtdOnCallbackError(Throwable e) nothrow {
    qtdCallbackErrors++;
    qtdLastCallbackError = e;
    if (qtdCallbackErrorHook !is null) qtdCallbackErrorHook(e);
    debug {
        import core.stdc.stdio : fprintf, stderr;
        fprintf(stderr, "qtd: callback threw (swallowed at C++ boundary): %.*s\n",
            cast(int) e.msg.length, e.msg.ptr);
    }
}

// converts a QString* (meta-call arg) into a D string.
string qsToD(void* qs) {
    int n = qtd_qs_utf8len(qs);
    auto buf = new char[n];
    if (n) qtd_qs_utf8(qs, buf.ptr);
    return cast(string) buf[0 .. n];
}

// ---- translation (tr / translate / install) ---------------------------------
private string trImpl(string context, string source, string disambig, int n) {
    auto qs = qtd_tr((context ~ "\0").ptr, (source ~ "\0").ptr,
                     disambig is null ? null : (disambig ~ "\0").ptr, n);
    auto s = qsToD(qs); qtd_qs_free(qs); return s;
}

/// `tr` FREE and UFCS — `"foo".tr`, `"foo".tr("disambiguation")`. The CONTEXT is the NAME of the
/// caller's module (via `__MODULE__`, which is resolved at the call site) — matching exactly what
/// lupdate-d extracts, so the same `.qm` covers extraction and runtime. With no translator/`.qm` covering the
/// string, Qt returns `source`, so it is always safe. For an explicit context use `translate`.
string tr(string source, string disambiguation = null, int n = -1, string context = __MODULE__) {
    return trImpl(context, source, disambiguation, n);
}

/// `translate` Qt-style: EXPLICIT context. `translate("Context", "foo")` — same as what
/// lupdate-d recognizes as `[QCoreApplication.]translate("Ctx","src")`.
string translate(string context, string source, string disambiguation = null, int n = -1) {
    return trImpl(context, source, disambiguation, n);
}

/// Installs a translator WITHOUT `_new`: `QTranslator.install("app_pt")`. The QTranslator (and a
/// QCoreApplication, if there isn't one yet) are built on the C++ side — the user never
/// builds anything by hand. Empty `.qm` -> empty translator (identity). Returns whether the `.qm` loaded.
struct QTranslator {
    static bool install(string qm = "") { return qtd_install_translator((qm ~ "\0").ptr); }
}

/// Class UDA: marks a D QObject with a runtime meta-object (signals/slots).
struct QObject {}
/// Method UDA: slot (invokable by Qt / connectable to a signal).
struct Slot {}
/// Field UDA: exposes the field as a Q_PROPERTY. `notify` = name of the change
/// signal (optional), e.g. @Property("valueChanged") int value;
struct Property { string notify = ""; }

/// A signal with the given argument types. Emitting calls QMetaObject::activate.
struct Signal(Args...) {
    private void* _owner;   // the owning QObject (qtd)
    private int   _idx;     // the signal's local index in the meta-object
    void _bind(void* owner, int idx) { _owner = owner; _idx = idx; }
    void emit(Args args) {
        void*[Args.length + 1] argv;
        void*[Args.length + 1] tofree = null;             // QStrings to free afterwards
        argv[0] = null;                                   // return slot (void)
        static foreach (i; 0 .. Args.length) {
            static if (is(Args[i] == string)) {
                argv[i + 1] = qtd_str_to_qs(args[i].ptr, cast(int) args[i].length);
                tofree[i + 1] = argv[i + 1];
            } else argv[i + 1] = cast(void*) &args[i];
        }
        qtd_moc_activate(_owner, _idx, argv.ptr);
        static foreach (i; 1 .. Args.length + 1)
            if (tofree[i]) qtd_qs_free(tofree[i]);
    }
    void opCall(Args args) { emit(args); }
}

// ---- per-object registry (avoids injecting members into the user class) -----
struct MocReg {
    void* qobj;                                    // the underlying QObject
    void delegate(int, void**) nothrow disp;       // slot dispatch (captures the object)
    void delegate(int, int, void**) nothrow prop;  // property read/write
}
__gshared MocReg[void*] _reg;              // key = the D object's pointer

extern (C) void __mocGlobalDispatch(void* dobj, int idx, void** args) nothrow {
    if (auto p = dobj in _reg) p.disp(idx, args);
}
extern (C) void __mocGlobalProp(void* dobj, int idx, int write, void** args) nothrow {
    if (auto p = dobj in _reg) p.prop(idx, write, args);
}
// Called by the QtdMocObject destructor (C++) -> drops the `_reg` entry, closing the
// side-table when the object dies (not only on the QML path). Registered once at init.
// `destroyed` also fires during process shutdown, from posted deleteLater events, when the D
// runtime may already be going down — touching the GC then crashes. holder.d guards exactly this
// case with `_live`; this callback is reached from the same window and needs the same guard.
private __gshared bool _regLive = true;
shared static ~this() { _regLive = false; }
extern (C) void __mocGlobalDestroy(void* dobj) nothrow { if (_regLive) _reg.remove(dobj); }

/// How many D @QObjects are currently registered. A test can assert this returns to its baseline
/// after a compiled object tree is destroyed — i.e. that nesting does not leak.
size_t mocRegisteredCount() { return _reg.length; }
private alias MocDestroyCb = extern (C) void function(void*) nothrow;
extern (C) void qtd_moc_set_destroy_cb(MocDestroyCb) nothrow;
shared static this() { qtd_moc_set_destroy_cb(&__mocGlobalDestroy); }

// Side-table lifetime (_reg + g_moAttach): an object created by `newQObject!T` keeps its
// `_reg` entry as long as the C++ QtdMocObject exists. If it is destroyed (parented to a
// QObject whose parent dies, or created by the QML engine), the destructor clears BOTH side-tables via
// this callback. A parentless QtdMocObject is NOT auto-deleted (it lives until process end) — that is the
// expected lifetime of a top-level signals/slots hub, just like a parentless C++ QObject.

/// Pointer to the underlying QObject: a raw void* passes straight through; a D @QObject is
/// resolved via the registry (null if not registered).
void* qobjOf(T)(T o) {
    static if (is(T == void*)) return o;
    else {
        if (auto p = cast(void*) o in _reg) return p.qobj;
        return null;
    }
}

/// qt_metacast by name on the underlying QObject. Returns the QObject pointer if `n`
/// matches its own class (or a base), null otherwise — the same contract as
/// qobject_cast. Exists to prove the metaobject doesn't lie about the object (critics r8 #2).
void* metaCast(T)(T o, string n) {
    return qtd_metacast(qobjOf(o), (n ~ "\0").ptr);
}

/// metaObject()->className() of the underlying QObject (to test type identity).
string mocClassName(T)(T o) {
    import core.stdc.string : strlen;
    auto p = qtd_moc_classname(qobjOf(o));
    return p is null ? null : cast(string) p[0 .. strlen(p)].idup;
}

// ---- CTFE: D type -> C++ signature mapping ----------------------------------
template cppSig(T) {
         static if (is(T == int))    enum cppSig = "int";
    else static if (is(T == bool))   enum cppSig = "bool";
    else static if (is(T == double)) enum cppSig = "double";
    else static if (is(T == float))  enum cppSig = "float";
    else static if (is(T == uint))   enum cppSig = "uint";
    else static if (is(T == string)) enum cppSig = "QString";
    else static assert(0, "qtmoc: signal/slot type not yet supported: " ~ T.stringof);
}
string sigString(string name, Args...)() {
    string s = name ~ "(";
    static foreach (i, A; Args) s ~= (i ? "," : "") ~ cppSig!A;
    return s ~ ")";
}

// names of signals (Signal!... fields) and slots (@Slot), in allMembers order.
template signalMembers(T) {
    template isSig(string m) {
        static if (is(typeof(__traits(getMember, T, m)) == Signal!A, A...)) enum isSig = true;
        else enum isSig = false;
    }
    enum signalMembers = mocFilter!(T, isSig);
}
template slotMembers(T) {
    template isSlot(string m) {
        static if (is(typeof(__traits(getMember, T, m)) == function))
            enum isSlot = hasUDA!(__traits(getMember, T, m), Slot);
        else enum isSlot = false;
    }
    enum slotMembers = mocFilter!(T, isSlot);
}
string[] mocFilter(T, alias pred)() {
    string[] r;
    static foreach (m; __traits(allMembers, T))
        static if (m.length && pred!m) r ~= m;
    return r;
}

// signatures ("name(types)") of signals/slots.
string[] signalSigs(T)() {
    string[] r;
    static foreach (m; signalMembers!T) {{   // {{ }} => per-iteration scope (A...)
        static if (is(typeof(__traits(getMember, T, m)) == Signal!A, A...))
            r ~= sigString!(m, A);
    }}
    return r;
}
string[] slotSigs(T)() {
    string[] r;
    static foreach (m; slotMembers!T)
        r ~= sigString!(m, Parameters!(__traits(getMember, T, m)));
    return r;
}

// fields marked with @Property.
template propMembers(T) {
    template isProp(string m) {
        static if (is(typeof(__traits(getMember, T, m)) == function)) enum isProp = false;
        else enum isProp = hasUDA!(__traits(getMember, T, m), Property);
    }
    enum propMembers = mocFilter!(T, isProp);
}
string[] propTypes(T)() {
    string[] r;
    static foreach (m; propMembers!T) r ~= cppSig!(typeof(__traits(getMember, T, m)));
    return r;
}
// name of the notify signal of a @Property (tolerates @Property without parentheses).
template propNote(alias sym) {
    private alias U = getUDAs!(sym, Property);
    static if (is(U[0])) enum propNote = "";          // @Property (type) -> no notify
    else                 enum propNote = U[0].notify;  // @Property()/@Property("x")
}
// index (in signalMembers order) of each property's notify signal, or -1.
int[] propNotify(T)() {
    int[] r;
    static foreach (m; propMembers!T) {{
        enum note = propNote!(__traits(getMember, T, m));
        int idx = -1, i = 0;
        static foreach (s; signalMembers!T) { if (s == note) idx = i; i++; }
        r ~= idx;
    }}
    return r;
}

// ---- meta-method contract (critics r8 #4) -----------------------------------
// The metaobject cannot accept a declaration whose semantics it does not honor:
//   * a Qt @Slot returns void. A method that returns a value is an INVOKABLE — the
//     runtime does not marshal the return (it was silently discarded, and
//     QMetaObject::invokeMethod with Q_RETURN_ARG returned false). Reject it.
//   * a @Property("notifySig") whose NOTIFY does not name a Signal of this class
//     silently resolved to index -1 (no notification ever fires).
//     And if it names a Signal, the signature must match what callProp emits
//     (0 args, or 1 arg of the property's type) — otherwise the receiving slot reads garbage.
// All at compile time, with a message pointing to the fix. It is a function (statement
// scope) instantiated by a call at the top of each registration path — the
// instantiation fires the static asserts; at runtime it is a no-op (optimized away).
void validateMeta(T)() {
    import std.traits : ReturnType;
    static foreach (m; slotMembers!T)
        static assert(is(ReturnType!(__traits(getMember, T, m)) == void),
            "qtmoc: @Slot " ~ T.stringof ~ "." ~ m ~ " must return void. " ~
            "A method that returns a value is an invokable, not a slot, and the runtime " ~
            "would discard the return — emit the result through a Signal instead.");
    static foreach (m; propMembers!T) {{
        enum note = propNote!(__traits(getMember, T, m));
        static if (note.length) {
            alias PT = typeof(__traits(getMember, T, m));
            enum bool found = () {
                bool f = false;
                static foreach (s; signalMembers!T) if (s == note) f = true;
                return f;
            }();
            static assert(found,
                "qtmoc: @Property " ~ T.stringof ~ "." ~ m ~ " has NOTIFY \"" ~ note ~
                "\" which is not a Signal of this class.");
            static foreach (s; signalMembers!T)
                static if (s == note)
                    static if (is(typeof(__traits(getMember, T, s)) == Signal!A, A...))
                        static assert(A.length == 0 || (A.length == 1 && is(A[0] == PT)),
                            "qtmoc: NOTIFY \"" ~ note ~ "\" of " ~ T.stringof ~ "." ~ m ~
                            " must be parameterless or take a single " ~ PT.stringof ~
                            " (callProp emits the new value as the sole argument).");
        }
    }}
}

// reads/writes property `m` of `o` via the value slot a[0]. On write, if the
// value changes and there is a notify signal, emits it (so bindings/QML see the change).
void callProp(T, string m)(T o, void* qobj, int notifyIdx, int write, void** a) {
    alias X = typeof(__traits(getMember, T, m));
    if (write) {
        static if (is(X == string)) X nv = qsToD(a[0]);
        else                        X nv = *cast(X*) a[0];
        if (__traits(getMember, o, m) != nv) {
            __traits(getMember, o, m) = nv;
            if (notifyIdx >= 0) {
                void*[2] argv; argv[0] = null;
                static if (is(X == string)) {
                    auto qs = qtd_str_to_qs(nv.ptr, cast(int) nv.length);
                    argv[1] = qs; qtd_moc_activate(qobj, notifyIdx, argv.ptr); qtd_qs_free(qs);
                } else {
                    argv[1] = cast(void*) &nv; qtd_moc_activate(qobj, notifyIdx, argv.ptr);
                }
            }
        }
    } else {   // ReadProperty: assign the D value into the QVariant/typed slot at a[0]
        static if (is(X == string)) {
            auto s = __traits(getMember, o, m);
            qtd_qs_set(a[0], s.ptr, cast(int) s.length);   // *(QString*)a[0] = s
        }
        else *cast(X*) a[0] = __traits(getMember, o, m);
    }
}

// invokes slot `m` of `o` reading the args from the C array (args[0] is the return).
void callSlot(T, string m)(T o, void** args) {
    alias P = Parameters!(__traits(getMember, T, m));
    P vals;
    static foreach (j, X; P) {
        static if (is(X == string)) vals[j] = qsToD(args[j + 1]);
        else vals[j] = *cast(X*) args[j + 1];
    }
    __traits(getMember, o, m)(vals);
}

// ---- factory ----------------------------------------------------------------
/// Creates an instance of a D @QObject, builds its meta-object at runtime,
/// binds the Signal fields and registers the slot dispatch.
T newQObject(T, Args...)(Args ctorArgs) {
    static assert(hasUDA!(T, QObject),
        "qtmoc: " ~ T.stringof ~ " precisa da UDA @QObject");
    validateMeta!T();   // @Slot void + existing/compatible NOTIFY (compile time)
    T o = new T(ctorArgs);
    enum sigs  = signalSigs!T;
    enum slts  = slotSigs!T;
    enum pnames = propMembers!T;
    enum ptypes = propTypes!T;
    enum pnotif = propNotify!T;
    // arrays of C-strings (signatures with \0 -> .ptr is safe in C); +1 avoids [0]
    const(char)*[sigs.length + 1] sigp;
    const(char)*[slts.length + 1] sltp;
    const(char)*[pnames.length + 1] pnp;
    const(char)*[ptypes.length + 1] ptp;
    int[pnotif.length + 1] pnt;
    static foreach (i; 0 .. sigs.length)   sigp[i] = (sigs[i] ~ "\0").ptr;
    static foreach (i; 0 .. slts.length)   sltp[i] = (slts[i] ~ "\0").ptr;
    static foreach (i; 0 .. pnames.length) pnp[i]  = (pnames[i] ~ "\0").ptr;
    static foreach (i; 0 .. ptypes.length) ptp[i]  = (ptypes[i] ~ "\0").ptr;
    static foreach (i; 0 .. pnotif.length) pnt[i]  = pnotif[i];
    void* qobj = qtd_moc_new((T.stringof ~ "\0").ptr,
        sigp.ptr, cast(int) sigs.length, sltp.ptr, cast(int) slts.length,
        pnp.ptr, ptp.ptr, pnt.ptr, cast(int) pnames.length,
        cast(void*) o, &__mocGlobalDispatch, &__mocGlobalProp);
    static if (__traits(hasMember, T, "_adopt")) o._adopt(qobj);   // WRAPPER: _cpp + pin
    wireQObject(o, qobj);
    return o;
}

// Binds the Signal fields to (qobj, index) and registers the slot/prop dispatch of `o`.
// Shared by newQObject (qobj comes from qtd_moc_new) and by the QML factory
// (qobj = the QtdMocObject the engine allocated).
private void wireQObject(T)(T o, void* qobj) {
    enum pnotif = propNotify!T;
    int si = 0;
    static foreach (m; signalMembers!T) {
        __traits(getMember, o, m)._bind(qobj, si);
        si++;
    }
    void delegate(int, void**) nothrow disp = (int idx, void** a) nothrow {
        try {
            static foreach (i, m; slotMembers!T)
                if (idx == i) { callSlot!(T, m)(o, a); return; }
        } catch (Exception e) { qtdOnCallbackError(e); }
    };
    void delegate(int, int, void**) nothrow prop = (int idx, int write, void** a) nothrow {
        try {
            static foreach (i, m; propMembers!T)
                if (idx == i) { callProp!(T, m)(o, qobj, pnotif[i], write, a); return; }
        } catch (Exception e) { qtdOnCallbackError(e); }
    };
    _reg[cast(void*) o] = MocReg(qobj, disp, prop);
    // Post-wire hook: signals are now bound and the meta-object exists, so a generated type can
    // connect its binding dependencies and compute initial values here (it CANNOT in its own
    // ctor, which runs before wiring). qmltc-d emits `__qmltcWire`; a no-op for every hand-written
    // @QObject (none declare it), so this is inert for the existing suite.
    static if (__traits(hasMember, T, "__qmltcWire")) o.__qmltcWire();
}

// ---- QML type registration --------------------------------------------------
// Registers a D @QObject as a QML element: `import <uri> <maj>.<min>; <T> { ... }`.
// The engine instantiates the C++ carrier (QtdMocObject) and calls back into `create` (C++),
// which in turn calls the D factory below to create+bind the T that backs the object.
// All D instances share the same C++ typeId (QtdMocObject*), distinguished
// by the runtime QMetaObject — proven by a probe where N types coexist.
private __gshared void* delegate(void* qobj) nothrow[void*] _qmlFactories;   // key = QtdQmlType* (C++)

// SINGLE C callbacks (not per-T -> no extern(C) symbol collision); they dispatch
// via the QtdQmlType* that C++ passes back as `self`.
private extern (C) void* __qmlMake(void* self, void* qobj) nothrow {
    if (auto f = self in _qmlFactories) return (*f)(qobj);
    return null;
}
private extern (C) void __qmlDestroy(void* self, void* dobj) nothrow {
    _reg.remove(dobj);   // drops the T from the registry -> the GC can collect it
}

// publicKey ("uri/name maj.min", what the QML engine sees) -> D identity of the registered type.
// The identity is T.mangleof (fully-qualified mangled name): two homonymous D @QObjects
// (same T.stringof, different modules) have a DISTINCT mangleof. So the same (T, uri, name,
// version) is an idempotent no-op, but two DIFFERENT types under the same public key are an
// observable conflict — not a silent "already registered" (critics r8 #3).
private __gshared string[string] _qmlRegistered;

/// Registers the type `T` (D @QObject) as an instantiable QML element. Call before loading the
/// .qml. Error contract (critics r7 #2): **THROWS** if registration fails in the backend (Qt5 pool
/// exhausted or `qmlregister` refused) — the C++ failure does NOT become a silent success. Registering the
/// SAME (T, uri, name, version) again is idempotent (does not consume another Qt5 pool slot).
void qmlRegisterType(T)(string uri, int vmaj, int vmin, string qmlName) {
    static assert(hasUDA!(T, QObject),
        "qtmoc: " ~ T.stringof ~ " precisa da UDA @QObject");
    static assert(__traits(compiles, new T()),
        "qtmoc: " ~ T.stringof ~ " precisa de construtor sem argumentos (o QML instancia sem args)");
    validateMeta!T();   // @Slot void + existing/compatible NOTIFY (compile time)
    import std.conv : to;
    enum typeId = T.mangleof;   // unambiguous D identity (homonyms differ in the mangle)
    auto pubKey = uri ~ "/" ~ qmlName ~ " " ~ vmaj.to!string ~ "." ~ vmin.to!string;
    if (auto prev = pubKey in _qmlRegistered) {
        if (*prev == typeId) return;   // SAME type, same version -> no-op (doesn't re-consume the Qt5 pool)
        throw new Exception("qmlRegisterType conflict: " ~ pubKey ~ " is already registered to a "
            ~ "different D type (" ~ *prev ~ " != " ~ typeId ~ "). Use a distinct name/URI/version.");
    }
    enum sigs = signalSigs!T;
    enum slts = slotSigs!T;
    enum pnames = propMembers!T;
    enum ptypes = propTypes!T;
    enum pnotif = propNotify!T;
    const(char)*[sigs.length + 1] sigp;
    const(char)*[slts.length + 1] sltp;
    const(char)*[pnames.length + 1] pnp;
    const(char)*[ptypes.length + 1] ptp;
    int[pnotif.length + 1] pnt;
    static foreach (i; 0 .. sigs.length)   sigp[i] = (sigs[i] ~ "\0").ptr;
    static foreach (i; 0 .. slts.length)   sltp[i] = (slts[i] ~ "\0").ptr;
    static foreach (i; 0 .. pnames.length) pnp[i]  = (pnames[i] ~ "\0").ptr;
    static foreach (i; 0 .. ptypes.length) ptp[i]  = (ptypes[i] ~ "\0").ptr;
    static foreach (i; 0 .. pnotif.length) pnt[i]  = pnotif[i];
    void* key = qtd_qml_register_type(
        (uri ~ "\0").ptr, vmaj, vmin, (qmlName ~ "\0").ptr,
        (T.stringof ~ "\0").ptr,
        sigp.ptr, cast(int) sigs.length, sltp.ptr, cast(int) slts.length,
        pnp.ptr, ptp.ptr, pnt.ptr, cast(int) pnames.length,
        &__qmlMake, &__qmlDestroy, &__mocGlobalDispatch, &__mocGlobalProp);
    if (key is null)   // backend refused (Qt5 pool exhausted / qmlregister failed) -> OBSERVABLE
        throw new Exception("qmlRegisterType failed for " ~ T.stringof ~ " as " ~ pubKey
            ~ " (backend returned null; see stderr)");
    // per-T factory: the engine calls this (via __qmlMake) per instance created in QML.
    _qmlFactories[key] = (void* qobj) nothrow {
        try {
            T o = new T();
            wireQObject(o, qobj);
            return cast(void*) o;
        } catch (Exception e) { qtdOnCallbackError(e); return null; }
    };
    _qmlRegistered[pubKey] = typeId;
}

// ---- .qmltypes emission (type description for tooling) ----------------------
// Emits the QQmlJSTypeDescriptionReader-format block a `@QObject` D type would have
// if it were registered via qmlRegisterType — so qmllint / Qt Creator / qmltc can
// see D-defined QML types. This is qmltyperegistrar's `.qmltypes` output, produced
// by CTFE from the same __traits info the runtime meta-object is built from (no moc
// JSON). Pure compile-time string building; a tiny driver writes the result to disk.

/// The `.qmltypes` `Component { ... }` block describing `T` exported as `uri/qmlName vmaj.vmin`.
string qmlTypeComponent(T)(string uri, int vmaj, int vmin, string qmlName) {
    import std.traits : Parameters, ParameterIdentifierTuple;
    static assert(hasUDA!(T, QObject), "qtmoc: " ~ T.stringof ~ " precisa da UDA @QObject");
    // qmltyperegistrar encodes the export version as a metaobject revision (major<<8 | minor).
    immutable rev = (vmaj << 8) | vmin;
    string s = "    Component {\n";
    s ~= "        name: \"" ~ T.stringof ~ "\"\n";
    s ~= "        accessSemantics: \"reference\"\n";
    s ~= "        prototype: \"QObject\"\n";
    s ~= "        exports: [\"" ~ uri ~ "/" ~ qmlName ~ " " ~ itoa(vmaj) ~ "." ~ itoa(vmin) ~ "\"]\n";
    s ~= "        exportMetaObjectRevisions: [" ~ itoa(rev) ~ "]\n";
    int pidx = 0;
    static foreach (m; propMembers!T) {{
        enum note = propNote!(__traits(getMember, T, m));
        s ~= "        Property { name: \"" ~ m ~ "\"; type: \""
            ~ cppSig!(typeof(__traits(getMember, T, m))) ~ "\"";
        if (note.length) s ~= "; notify: \"" ~ note ~ "\"";
        s ~= "; index: " ~ itoa(pidx) ~ " }\n";
        pidx++;
    }}
    static foreach (m; signalMembers!T) {{
        static if (is(typeof(__traits(getMember, T, m)) == Signal!A, A...)) {
            s ~= "        Signal { name: \"" ~ m ~ "\"";
            static if (A.length) {
                s ~= "\n";
                static foreach (i, X; A)
                    s ~= "            Parameter { name: \"arg" ~ itoa(cast(int) i)
                        ~ "\"; type: \"" ~ cppSig!X ~ "\" }\n";
                s ~= "        }\n";
            } else s ~= " }\n";
        }
    }}
    static foreach (m; slotMembers!T) {{
        alias P = Parameters!(__traits(getMember, T, m));
        alias PN = ParameterIdentifierTuple!(__traits(getMember, T, m));
        s ~= "        Method { name: \"" ~ m ~ "\"";
        static if (P.length) {
            s ~= "\n";
            static foreach (i, X; P)
                s ~= "            Parameter { name: \"" ~ (PN[i].length ? PN[i] : "arg" ~ itoa(cast(int) i))
                    ~ "\"; type: \"" ~ cppSig!X ~ "\" }\n";
            s ~= "        }\n";
        } else s ~= " }\n";
    }}
    s ~= "    }\n";
    return s;
}

/// Wrap one or more `qmlTypeComponent` blocks into a complete `.qmltypes` document.
string qmlTypesModule(string[] components) {
    string s = "import QtQuick.tooling 1.2\n\n";
    s ~= "// This file describes D @QObject types registered for QML (qmlRegisterType).\n";
    s ~= "// Generated by qt-dlang-gen from the CTFE meta-object. For tooling only.\n\n";
    s ~= "Module {\n";
    foreach (c; components) s ~= c;
    s ~= "}\n";
    return s;
}

// ---- widget subclass + moc (merge trampoline + meta-object) -----------------
// (public helpers: the mixin below is instantiated in the user's module and resolves
//  in that scope, so it needs to see qtmoc's helpers/internals.)
/// Optional/documentary UDA: marks a method as an override of a base virtual.
struct Override {}

string itoa(int n) {   // simple CTFE
    if (n == 0) return "0";
    string s; bool neg = n < 0; if (neg) n = -n;
    while (n) { s = cast(char)('0' + n % 10) ~ s; n /= 10; }
    return neg ? "-" ~ s : s;
}
template __qtdIsFn(T, string m) {
    static if (is(typeof(__traits(getMember, T, m)) == function)) enum __qtdIsFn = true;
    else enum __qtdIsFn = false;
}
// generates the extern(C) trampoline that adapts the C++ virtual to the D method `vn`. A
// unique name per class (__ov_<Class>_<idx>) so it doesn't collide in C linkage.
string __ovTramp(T, string vn, size_t idx)() {
    import std.traits : ReturnType, Parameters;
    alias R = ReturnType!(__traits(getMember, T, vn));
    alias P = Parameters!(__traits(getMember, T, vn));
    string ps, as;
    static foreach (j, X; P) {
        ps ~= (j ? ", " : "") ~ X.stringof ~ " a" ~ itoa(cast(int) j);
        as ~= (j ? ", " : "") ~ "a" ~ itoa(cast(int) j);
    }
    auto nm = "__ov_" ~ T.stringof ~ "_" ~ itoa(cast(int) idx);
    auto call = "(cast(" ~ T.stringof ~ ") d)." ~ vn ~ "(" ~ as ~ ")";
    // A D exception can't unwind across the C++ virtual-call frame -> route it through the
    // callback error policy (counted/recorded/hooked), never silently swallowed.
    static if (is(R == void))
        return "extern(C) static void " ~ nm ~ "(void* d" ~ (ps.length ? ", " ~ ps : "")
            ~ ") nothrow { try { " ~ call ~ "; } catch (Exception e) { qtdOnCallbackError(e); } }\n";
    else
        return "extern(C) static " ~ R.stringof ~ " " ~ nm ~ "(void* d" ~ (ps.length ? ", " ~ ps : "")
            ~ ") nothrow { try { return " ~ call ~ "; } catch (Exception e) { qtdOnCallbackError(e); return "
            ~ R.stringof ~ ".init; } }\n";
}

/// Mixin for a Qt class subclassed in D that is ALSO @QObject: it overrides
/// virtuals (methods named after a base virtual, e.g. paintEvent) AND has
/// its own signals/slots/props.
mixin template QtdWidget(Base) {
    void* _qobj;
    private alias _Self = typeof(this);
    final void* __qtdObj() { return _qobj; }
    private enum string[] __vn = mixin("__" ~ Base.stringof ~ "_vnames");  // base virtuals (qtvirt)

    // extern(C) trampolines for the virtuals the class overrides (name matches).
    static foreach (i, vn; __vn)
        static if (__traits(hasMember, _Self, vn) && __qtdIsFn!(_Self, vn))
            mixin(__ovTramp!(_Self, vn, i));

    this() {
        // 1. create the subclass trampoline, plugging in the overridden cbs (the rest null)
        enum __callArgs = () {
            string a;
            static foreach (i, vn; __vn)
                a ~= ", " ~ ((__traits(hasMember, _Self, vn) && __qtdIsFn!(_Self, vn))
                    ? "&__ov_" ~ _Self.stringof ~ "_" ~ itoa(cast(int) i) : "null");
            return a;
        }();
        mixin("_qobj = cast(void*) " ~ Base.stringof ~ "_subclass(cast(void*) this" ~ __callArgs ~ ");");
        // WRAPPER mode: adopt the C++ trampoline as our _cpp + pin (C++ holds a raw dself).
        static if (__traits(hasMember, _Self, "_adopt")) this._adopt(_qobj);

        // 2. attach the runtime meta-object (own signals/slots/props)
        enum sigs = signalSigs!_Self; enum slts = slotSigs!_Self;
        enum pnames = propMembers!_Self; enum ptypes = propTypes!_Self; enum pnotif = propNotify!_Self;
        const(char)*[sigs.length + 1] sigp; const(char)*[slts.length + 1] sltp;
        const(char)*[pnames.length + 1] pnp; const(char)*[ptypes.length + 1] ptp; int[pnotif.length + 1] pnt;
        static foreach (i; 0 .. sigs.length)   sigp[i] = (sigs[i] ~ "\0").ptr;
        static foreach (i; 0 .. slts.length)   sltp[i] = (slts[i] ~ "\0").ptr;
        static foreach (i; 0 .. pnames.length) pnp[i]  = (pnames[i] ~ "\0").ptr;
        static foreach (i; 0 .. ptypes.length) ptp[i]  = (ptypes[i] ~ "\0").ptr;
        static foreach (i; 0 .. pnotif.length) pnt[i]  = pnotif[i];
        mixin("qtd_sub_" ~ Base.stringof ~ "_attach")(_qobj, (_Self.stringof ~ "\0").ptr,
            sigp.ptr, cast(int) sigs.length, sltp.ptr, cast(int) slts.length,
            pnp.ptr, ptp.ptr, pnt.ptr, cast(int) pnames.length,
            cast(void*) this, &__mocGlobalDispatch, &__mocGlobalProp);

        // 3. bind the signals + register the slot/prop dispatch (like newQObject)
        int __si = 0;
        static foreach (m; signalMembers!_Self) { __traits(getMember, this, m)._bind(_qobj, __si); __si++; }
        auto __self = this;
        void delegate(int, void**) nothrow __disp = (int idx, void** a) nothrow {
            try { static foreach (i, m; slotMembers!_Self) if (idx == i) { callSlot!(_Self, m)(__self, a); return; } }
            catch (Exception e) { qtdOnCallbackError(e); }
        };
        void delegate(int, int, void**) nothrow __prp = (int idx, int write, void** a) nothrow {
            try {
                static foreach (i, m; propMembers!_Self)
                    if (idx == i) { callProp!(_Self, m)(__self, _qobj, pnotif[i], write, a); return; }
            } catch (Exception e) { qtdOnCallbackError(e); }
        };
        _reg[cast(void*) this] = MocReg(_qobj, __disp, __prp);
        // Post-wire hook (same as free wireQObject): a qmltc-d-generated subclass connects its
        // bindings and sets base properties here, after the trampoline + meta-object exist.
        static if (__traits(hasMember, _Self, "__qmltcWire")) this.__qmltcWire();
    }
}

// ---- properties (access by name via QVariant) -------------------------------
/// Reads an int property by name (custom @Property or built-in).
private extern(C) void* qtd_attached_obj(void*, const(char)*, const(char)*);
/// The ATTACHED-properties object a registered QML type provides for `o` — QML's `Type.prop`.
/// The type is resolved by NAME in Qt's registry, so no compile-time knowledge of it is needed.
void* attachedObj(T)(T o, string uri, string typeName) {
    return qtd_attached_obj(qobjOf(o), (uri ~ "\0").ptr, (typeName ~ "\0").ptr);
}
private extern(C) void qtd_set_parent(void*, void*);
/// Give `child` a Qt parent, so Qt owns it and destroys it with the parent. That destruction is
/// what releases the child's registry entry — see the side-table note above.
void setQtParent(T, U)(T child, U parent) { qtd_set_parent(qobjOf(child), qobjOf(parent)); }
private extern(C) bool qtd_prop_reset(void*, const(char)*);
/// Reset a property to its default (QML's `prop: undefined`). Goes through QMetaProperty::reset —
/// a Q_PROPERTY RESET method is not a slot, so it cannot be invoked by name.
bool resetProp(T)(T o, string name) { return qtd_prop_reset(qobjOf(o), (name ~ "\0").ptr); }
private extern(C) void qtd_prop_set_obj(void*, const(char)*, void*);
/// Attach an object to a QObject*-valued property (the write counterpart of [propObj]).
void setPropObj(T, U)(T o, string name, U v) {
    qtd_prop_set_obj(qobjOf(o), (name ~ "\0").ptr, qobjOf(v));
}
private extern(C) bool qtd_invoke0(void*, const(char)*);
/// Invoke a parameterless member (signal or invokable) by name — used to emit a signal that
/// belongs to another object, e.g. a grouped property's.
bool invoke0(T)(T o, string member) { return qtd_invoke0(qobjOf(o), (member ~ "\0").ptr); }
private extern(C) void* qtd_prop_get_obj(void*, const(char)*);
/// The object held by a QObject*-valued property — how a GROUPED property (`group.count`) is
/// reached: the group is a child object, its members are plain properties on it.
void* propObj(T)(T o, string name) { return qtd_prop_get_obj(qobjOf(o), (name ~ "\0").ptr); }
int propInt(T)(T o, string name) { return qtd_prop_get_int(qobjOf(o), (name ~ "\0").ptr); }
/// Writes an int property by name (fires the notify, if any).
void setProp(T)(T o, string name, int v) { qtd_prop_set_int(qobjOf(o), (name ~ "\0").ptr, v); }
/// Reads a real (double) property by name.
double propDouble(T)(T o, string name) { return qtd_prop_get_double(qobjOf(o), (name ~ "\0").ptr); }
/// Writes a real (double) property by name (fires the notify, if any).
void setProp(T)(T o, string name, double v) { qtd_prop_set_double(qobjOf(o), (name ~ "\0").ptr, v); }
/// Reads a bool property by name.
bool propBool(T)(T o, string name) { return qtd_prop_get_bool(qobjOf(o), (name ~ "\0").ptr); }
/// Writes a bool property by name (fires the notify, if any).
void setProp(T)(T o, string name, bool v) { qtd_prop_set_bool(qobjOf(o), (name ~ "\0").ptr, v); }
/// Reads a QString property by name as a D string.
string propStr(T)(T o, string name) {
    auto qs = qtd_prop_get_qs(qobjOf(o), (name ~ "\0").ptr);
    auto s = qsToD(qs); qtd_qs_free(qs); return s;
}
/// Writes a QString property by name (fires the notify, if any).
void setProp(T)(T o, string name, string v) {
    qtd_prop_set_qs(qobjOf(o), (name ~ "\0").ptr, v.ptr, cast(int) v.length);
}

// ---- connection -------------------------------------------------------------
/// Connects signal->slot by signature ("valueChanged(int)"). Symmetric: each
/// end can be a D @QObject or a raw built-in QObject (void*), in any
/// combination — both have a meta-object.
void connectMeta(A, B)(A sender, string sig, B receiver, string slot) {
    if (!tryConnectMeta(sender, sig, receiver, slot))
        throw new Exception("connectMeta failed: no such signal \"" ~ sig ~ "\" or slot \""
                            ~ slot ~ "\" (or a null endpoint)");
}

/// Same, but reports failure instead of throwing — for callers that legitimately probe.
bool tryConnectMeta(A, B)(A sender, string sig, B receiver, string slot) {
    return qtd_connect_meta(qobjOf(sender), (sig ~ "\0").ptr,
                            qobjOf(receiver), (slot ~ "\0").ptr) != 0;
}
