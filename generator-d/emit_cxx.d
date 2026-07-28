// emit_cxx.d — the extern(C++) emitter. Output is 100% D: a class declaration
// mangles straight to the Qt symbols, so there is NO C shim and NO wrapper body
// to compile. Binding a class you never import costs nothing (à la carte).
//
// Only two things still need C++, both out of band: template instantiation
// (QList<T> — a tiny precompiled runtime) and inline-method recovery (skipped
// here; value-type fields are exposed directly instead).
module emit_cxx;

import clang_c, gen;
import std.stdio, std.string, std.array, std.algorithm, std.conv, std.format;

// Enums referenced in signatures this run — emitted as their own modules at the
// end. D enums are ABI-identical to C++ (value AND, with extern(C++,ns), mangling).
__gshared CXCursor[string] ENUMS;    // unqualified enum name -> decl cursor
// Old-style 2-part Qt enums (`Qt::Horizontal`, dominant in real .ui files vs the 3-part
// `Qt::Orientation::Horizontal`) name a value without its enum. D named-enum members need
// qualification (`Orientation.Horizontal`), so we emit a `qt` aggregator module of
// `alias Horizontal = Orientation.Horizontal;` for every Qt-namespace value (the Qt namespace
// is flat -> names are unique -> no clashes). The uic imports it and emits the bare name.
__gshared string[] QT_ALIASES;
__gshared bool[string] QT_ALIAS_MODS;   // enum modules the aggregator must import

// QList<T>/QVector<T> instantiations seen this run -> a per-T D struct that reads
// the layout {d, T* ptr, size}, converts each element, and releases the array by
// hand (refcount deref + deallocate; plus per-element release for QString/QByteArray).
struct QListElem {
    string layoutTy;   // element type in the D array (QString/QByteArray/class-ref/prim)
    string idiomTy;    // idiomatic element (string / class / prim)
    long   elemSize;   // sizeof(element) for deallocate
    string fromRaw;    // ptr[i] -> idiom ({} = the element)
    bool   release;    // element owns refcounted data (QString/QByteArray)
    string imp;        // module to import for the element type
    bool   isVector;   // Qt5: this came from QVector/QStack (QArrayData layout, NOT QListData)
}
__gshared QListElem[string] QLISTS;    // tid -> element info
__gshared bool QT5;    // Qt5 target: QVector<T> has a distinct layout from QList<T>
// Wrapper lifetime mode: object types become GC wrappers extending holder.QtdObject
// (hold a nullable _cpp, delegate to C++ via pragma(mangle) with explicit self, are
// pinned when parented, invalidated on destroyed()). Off = the legacy extern(C++)
// class-ref-is-the-pointer form. Gated so both coexist during the rollout.
__gshared bool WRAPPER;
// Translate C++ exceptions crossing a trampoline into D QtCppException (Lippincott).
// Opt-in per spec ("exceptions": true): a binding for a Qt built with QT_NO_EXCEPTIONS —
// or a non-Qt lib — leaves it off (no try/catch overhead, no exception runtime in cxxrt,
// which also keeps the fragile whole-program DCE of such bindings undisturbed).
__gshared bool EXCEPTIONS;

bool qlistElem(CXType elem, ref QListElem o) {
    auto ck = clang_getCanonicalType(elem);
    auto c = canon(elem);
    if (auto p = c in PRIM) { o = QListElem(*p, *p, clang_Type_getSizeOf(ck), "%s", false, ""); return true; }
    if (ck.kind == CXType_Pointer && isRecord(clang_getPointeeType(ck))) {
        auto pt = clang_getPointeeType(ck);
        auto n = lastNs(canon(pt));
        // WRAPPER: an object-pointer element is a wrapper — the slot holds a raw void*, the
        // idiom layer wraps each (n.wrap(...)). Value-record pointers keep the struct ref.
        if (WRAPPER && !isValueRecord(pt)) {
            WRAPREFS[n] = true;
            o = QListElem("void*", n, 8, n ~ ".wrap(cast(void*) %s)", false, n); return true;
        }
        o = QListElem(n, n, 8, "%s", false, n); return true;      // element is a class ref
    }
    if (c == "QString")    { o = QListElem("QString", "string", 24, "%s.toString()", true, "QString"); return true; }
    if (c == "QByteArray") { o = QListElem("QByteArray", "string", 24, "%s.toString()", true, "QByteArray"); return true; }
    return false;
}
// Returns the tid (registering the QList) or "" if the container/element is unsupported.
string tryQList(CXType t) {
    auto ck = clang_getCanonicalType(t);
    if (clang_Type_getNumTemplateArguments(ck) != 1) return "";
    auto dn = clang_getCursorSpelling(clang_getTypeDeclaration(ck)).str;
    // Qt6: QVector==QList; QStack/QQueue derive with no extra members -> identical layout.
    // Qt5: QVector/QStack use QArrayData (contiguous, {d} single ptr), QList/QQueue use
    // QListData (array of void* slots) — DIFFERENT layouts, so they need distinct modules.
    if (dn != "QList" && dn != "QVector" && dn != "QStack" && dn != "QQueue") return "";
    QListElem e;
    if (!qlistElem(clang_Type_getTemplateArgumentAsType(ck, 0), e)) return "";
    bool vec = QT5 && (dn == "QVector" || dn == "QStack");
    e.isVector = vec;
    auto tid = e.layoutTy.toLower.replace("*", "p").replace(" ", "_");  // unique per element type
    if (vec) tid ~= "_qv";   // distinct module from QList<same T> (different layout)
    QLISTS[tid] = e;
    return tid;
}

// Raw QList-returning decl + an idiomatic method returning `elem[]`. [] if a
// param doesn't map. Registers the qlist_<tid> module import.
string[] emitQListReturn(CXCursor c, string mn, string qtid, string kw, string cst,
                         ref bool[string] impSet, string dpkg) {
    auto e = QLISTS[qtid];
    if (e.imp.length) impSet[e.imp] = true;
    impSet["qlist_" ~ qtid] = true;             // import dpkg.qlist_<tid>
    string[] rps, declps, callargs;
    auto na = clang_Cursor_getNumArguments(c);
    foreach (i; 0 .. na) {
        auto a = clang_Cursor_getArgument(c, i);
        string pimp, pd;
        try pd = mapCxxType(clang_getCursorType(a), pimp); catch (Unmappable) return [];
        if (pimp.length) impSet[pimp] = true;
        auto pw = WRAPPER ? wrapperTypeOf(clang_getCursorType(a)) : "";
        rps ~= format("%s a%d", pd, i);
        declps ~= format("%s a%d", pw.length ? "void*" : pd, i);
        callargs ~= pw.length ? format("(a%d is null ? null : a%d.ptr())", i, i) : format("a%d", i);
    }
    auto mg = clang_Cursor_getMangling(c).str;
    auto rawName = "__" ~ dname(mn) ~ "_ql";
    auto fromRaw = e.fromRaw.replace("%s", "_l.at(_i)");   // Qt5/Qt6-agnostic access
    if (WRAPPER) {
        // raw: module-level free function taking void* self; idiom: a wrapper method.
        auto declSelf = kw.canFind("static") ? "" : (declps.length ? "void* self, " : "void* self");
        auto self = kw.canFind("static") ? "" : (callargs.length ? "this.ptr(), " : "this.ptr()");
        auto raw = format("private pragma(mangle, \"%s\") extern(C++) QList_%s %s(%s%s);",
            mg, qtid, rawName, declSelf, declps.join(", "));
        auto idiom = format("    %s%s[] %s(%s) {\n"
            ~ "        auto _l = %s(%s%s);\n        %s[] _r; _r.length = cast(size_t) _l.length;\n"
            ~ "        foreach (_i; 0 .. _l.length) _r[_i] = %s;\n        return _r;\n    }",
            kw, e.idiomTy, dname(mn), rps.join(", "), rawName, self, callargs.join(", "),
            e.idiomTy, fromRaw);
        return [raw, idiom];
    }
    auto raw = format("    pragma(mangle, \"%s\") %sQList_%s %s(%s)%s;",
        mg, kw, qtid, rawName, rps.join(", "), cst);
    auto idiom = format("    extern (D) %s%s[] %s(%s)%s {\n"
        ~ "        auto _l = %s(%s);\n        %s[] _r; _r.length = cast(size_t) _l.length;\n"
        ~ "        foreach (_i; 0 .. _l.length) _r[_i] = %s;\n        return _r;\n    }",
        kw, e.idiomTy, dname(mn), rps.join(", "), cst, rawName, callargs.join(", "), e.idiomTy, fromRaw);
    return [raw, idiom];
}

// The per-T QList struct module: layout + hand-rolled release. Exposed through an
// abstract interface (`length`/`at(i)`) so the idiomatic method doesn't depend on
// the physical layout, which differs between Qt5 and Qt6.
string emitQListModule(string tid, QListElem e, string dpkg, string manifest, bool qt5 = false) {
    auto elemImp = e.imp.length ? format("import %s.%s;\n", dpkg, modBase(e.imp)) : "";
    if (qt5 && e.isVector) {
        // Qt5 QVector<T>/QStack<T> = { QArrayData* d } (8 bytes). QArrayData: int ref@0,
        // int size@4, uint alloc@8, qptrdiff offset@16; data is CONTIGUOUS at (char*)d +
        // offset. Verified empirically (offset=24 for QVector<double>). Free: per-element
        // release + QArrayData::deallocate (Qt5 mangle uses size_t = `mm`). size@4.
        auto al = e.elemSize >= 8 ? 8 : e.elemSize;   // natural alignment for our elem types
        auto rel = e.release
            ? format("            foreach (i; 0 .. _n) ptr[i].__release();\n")
            : "";
        return manifest ~ format("\nmodule %s.qlist_%s;\n%simport core.atomic : atomicOp;\n\n"
            ~ "struct QList_%s {\n    void* d;    // QArrayData* (ref@0, size@4, offset@16), data at d+offset\n"
            ~ "    @disable this(this);\n"
            ~ "    private int _size() const { return *cast(const(int)*)(cast(const(char)*) d + 4); }\n"
            ~ "    private %s* _ptr() const { return cast(%s*)(cast(char*) d + *cast(const(long)*)(cast(const(char)*) d + 16)); }\n"
            ~ "    @property long length() const { return d is null ? 0 : _size(); }\n"
            ~ "    %s at(size_t i) { return _ptr()[i]; }\n"
            ~ "    ~this() {\n        if (d is null) return;\n        auto _r = cast(shared(int)*) d;\n"
            ~ "        if (*cast(int*) d < 0) { d = null; return; }   // static shared_null: plain read (atomicLoad seq would fault on .rodata)\n"
            ~ "        if (atomicOp!\"-=\"(*_r, 1) == 0) {\n"
            ~ "            auto _n = _size(); auto ptr = _ptr();\n%s"
            ~ "            __qad_dealloc_qt5(d, %d, %d);\n        }\n        d = null;\n    }\n}\n"
            ~ "private pragma(mangle, \"_ZN10QArrayData10deallocateEPS_mm\") extern (C++) void __qad_dealloc_qt5(void*, size_t, size_t);\n",
            dpkg, tid, elemImp, tid, e.layoutTy, e.layoutTy, e.layoutTy, rel, e.elemSize, al);
    }
    if (qt5) {
        // Qt5 QList<T> = { QListData::Data* d } (8 bytes). Data: ref@0, alloc@4,
        // begin@8, end@12, void* array[]@16. Elements <= sizeof(void*) and movable/
        // prim (all the ones we support) sit INLINE in the slot. Free: per-element
        // release (QString/QByteArray) + QListData::dispose (an exported symbol that
        // runs ::free on the block). size = end - begin.
        auto rel = e.release
            ? "            foreach (_i; _b .. _e) (cast(" ~ e.layoutTy ~ "*) &_a[_i]).__release();\n"
            : "";
        return manifest ~ format("\nmodule %s.qlist_%s;\n%simport core.atomic : atomicOp;\n\n"
            ~ "struct QList_%s {\n    void* d;    // QListData::Data* (ref@0, begin@8, end@12, array@16)\n"
            ~ "    @disable this(this);\n"
            ~ "    private int _begin() const { return *cast(const(int)*)(cast(const(char)*) d + 8); }\n"
            ~ "    private int _end()   const { return *cast(const(int)*)(cast(const(char)*) d + 12); }\n"
            ~ "    private void** _arr() const { return cast(void**)(cast(char*) d + 16); }\n"
            ~ "    @property long length() const { return d is null ? 0 : _end() - _begin(); }\n"
            ~ "    %s at(size_t i) { return *cast(%s*) &_arr()[_begin() + i]; }   // inline in the slot\n"
            ~ "    ~this() {\n        if (d is null) return;\n        auto _r = cast(shared(int)*) d;\n"
            ~ "        if (*cast(int*) d < 0) { d = null; return; }   // static sentinel: plain read (shared_null is .rodata; an atomicLoad seq would fault)\n"
            ~ "        if (atomicOp!\"-=\"(*_r, 1) == 0) {\n"
            ~ "            auto _b = _begin(); auto _e = _end(); auto _a = _arr();\n%s"
            ~ "            __qld_dispose(d);\n        }\n        d = null;\n    }\n}\n"
            ~ "private pragma(mangle, \"_ZN9QListData7disposeEPNS_4DataE\") extern (C++) void __qld_dispose(void*);\n",
            dpkg, tid, elemImp, tid, e.layoutTy, e.layoutTy, rel);
    }
    // Qt6 QList<T> = QArrayDataPointer { void* d; T* ptr; long size } — elements
    // contiguous in ptr; per-element release + QArrayData::deallocate.
    auto rel = e.release
        ? format("            foreach (i; 0 .. size) ptr[i].__release();\n")
        : "";
    return manifest ~ format("\nmodule %s.qlist_%s;\n%simport core.atomic : atomicOp;\n\n"
        ~ "struct QList_%s {\n    void* d;\n    %s* ptr;\n    long size;\n    @disable this(this);\n"
        ~ "    @property long length() const { return size; }\n"
        ~ "    %s at(size_t i) { return ptr[i]; }\n"
        ~ "    ~this() {\n        if (d is null) return;\n        auto r = cast(shared(int)*) d;\n"
        ~ "        if (*cast(int*) d < 0) return;\n        if (atomicOp!\"-=\"(*r, 1) == 0) {\n%s"
        ~ "            __qad_deallocate(d, %d, 8);\n        }\n    }\n}\n"
        ~ "private pragma(mangle, \"_ZN10QArrayData10deallocateEPS_xx\") extern (C++) void __qad_deallocate(void*, long, long);\n",
        dpkg, tid, elemImp, tid, e.layoutTy, e.layoutTy, rel, e.elemSize);
}
// Base classes referenced by generated classes: these MUST be generated in full
// (vtable + exact size), never opaque-stubbed, or inheritance/construction breaks.
__gshared CXCursor[string] PENDING_BASES;   // base name -> its definition cursor

// Signals seen this run -> a per-signal functor-connect shim in qtsignals.cpp
// (public-API QObject::connect to a lambda that calls a D delegate). The signal's
// arguments are marshaled to the delegate: prim/enum/class-ptr by value, a
// const-value& as a pointer.
struct Signal {
    string dClass, cppClass, name;
    string lambdaParams;   // C++ lambda params, e.g. "bool a0, int a1"
    string passArgs;       // args the lambda forwards to the C callback: ", a0, a1"
    string cbCppParams;    // C callback param types (after void*): "bool, int"
    string cbDParams;      // D delegate/callback param types (delegate-facing): "bool, QWidget"
    string cbRawParams;    // D trampoline INCOMING types (C ABI): objects are void* here
    string trampArgs;      // args the D trampoline forwards to the delegate ("QWidget.wrap(a0)" in wrapper mode)
    string[] imports;
}
__gshared Signal[] SIGNALS;

// Classify one signal argument for C++->D marshaling; false if unsupported.
bool signalArg(CXType at, int i, ref Signal s) {
    auto ak = clang_getCanonicalType(at);
    auto cpp = clang_getTypeSpelling(at).str;
    if (canon(at).canFind("<") || canon(at).canFind("std::")) return false;
    if (ak.kind == CXType_LValueReference && !isRecord(clang_getPointeeType(ak))) return false;
    string lp, pass, cbc, cbd, tramp, cbRaw;
    tramp = "a%d".format(i);
    if (auto p = canon(at) in PRIM) {
        lp = "%s a%d".format(cpp, i); pass = "a%d".format(i); cbc = cpp; cbd = *p;
    } else if (ak.kind == CXType_Enum) {
        // qualified name (the lambda lives outside the class); static_cast handles
        // scoped enums (enum class doesn't implicitly convert to int).
        string ip; auto ed = mapCxxType(at, ip); if (ip.length) s.imports ~= ip;
        lp = "%s a%d".format(canon(at), i); pass = "static_cast<int>(a%d)".format(i);
        cbc = "int"; cbd = ed;
    } else if (ak.kind == CXType_Pointer && isRecord(clang_getPointeeType(ak))) {
        // A pointer to a forward-declared-only (foreign) object type — e.g. QWidget* on
        // QSignalMapper::mapped, in a QtQml binding that doesn't include QtWidgets — can't be a
        // proper QMetaType: Qt5's functor-connect instantiates QMetaTypeId<T*>, which needs T
        // complete. It's also opaque from D. Skip the whole signal (bound module types are full
        // definitions here, so this only drops genuinely-foreign object signals).
        if (!clang_isCursorDefinition(clang_getTypeDeclaration(clang_getPointeeType(ak)))) return false;
        auto dn = clang_getPointeeType(ak).canon.lastNs; s.imports ~= dn;
        lp = "%s a%d".format(cpp, i); pass = "a%d".format(i);   // cpp spelling keeps ptr/qualification
        cbc = cpp; cbd = dn;
        // WRAPPER: the delegate gets a wrapper (cbd), but the C ABI delivers a raw pointer
        // (void*) -> the tramp wraps it. (An object arg is polymorphic; value records fall
        // through to the const& branch below and stay as-is.)
        if (WRAPPER && !isValueRecord(clang_getPointeeType(ak))) {
            cbRaw = "void*"; tramp = format("%s.wrap(a%d)", dn, i);
        }
    } else if (ak.kind == CXType_LValueReference && isValueRecord(clang_getPointeeType(ak))
               && clang_getTypeSpelling(at).str.canFind("const")) {
        auto dn = clang_getPointeeType(ak).canon.lastNs; s.imports ~= dn;
        lp = "%s a%d".format(cpp, i); pass = "&a%d".format(i);  // keep the const& (canon strips it)
        cbc = "const " ~ dn ~ "*"; cbd = "const(" ~ dn ~ ")*";
    } else return false;
    s.lambdaParams = s.lambdaParams.length ? s.lambdaParams ~ ", " ~ lp : lp;
    s.passArgs ~= ", " ~ pass;
    s.cbCppParams = s.cbCppParams.length ? s.cbCppParams ~ ", " ~ cbc : cbc;
    s.cbDParams = s.cbDParams.length ? s.cbDParams ~ ", " ~ cbd : cbd;
    if (!cbRaw.length) cbRaw = cbd;   // non-object args: raw type == delegate type
    s.cbRawParams = s.cbRawParams.length ? s.cbRawParams ~ ", " ~ cbRaw : cbRaw;
    s.trampArgs = s.trampArgs.length ? s.trampArgs ~ ", " ~ tramp : tramp;
    return true;
}

// Secondary bases of multiply-inherited classes. D single-inherits (the primary
// base), so each secondary base is reached through a static_cast shim that applies
// the correct pointer offset (qtmi.cpp) — exposed as an as<Base>() method.
struct MICast { string dClass, cppClass, sbDClass, sbCppClass; }
__gshared MICast[] MICASTS;

// Classes the user wants to SUBCLASS from D (spec "subclass" list). Each gets a
// C++ trampoline (qtvirt) whose virtuals forward to D callbacks — so a C++
// framework calling a virtual dispatches into the D override.
__gshared bool[string] SUBCLASS;
struct TrampVirt {
    string name, cppRet, cbCppRet, cbDRet, overrideParams, passArgs, origArgs, cbCppParams, cbDParams;
    string[] imports;
    bool isPure, isConst, retVoid, retEnum;
}
struct Trampoline { string dClass, cppClass; TrampVirt[] virts; }
__gshared Trampoline[] TRAMPS;

// Value types that are NOT trivially copyable (hold a std::string/CoW/etc. by value):
// a bitwise copy breaks (SSO self-pointer, CoW refcount). We emit an out-of-line C++
// shim (qtdctor) with the real copy-ctor + dtor, and the D struct gets a copy
// constructor + ~this() that call it. Each entry: (dName, cppName).
struct CtorCopy { string dName, cppName; }
__gshared CtorCopy[] CTORCOPY;

// Value/object types whose (only) ctor is inline/`= default` -> no linkable symbol ->
// no _new -> not constructible from pure extern(C++) (Reference: `Reference(int=-1)`
// inline; Overload: `= default` ctor). We emit an out-of-line C++ shim that instantiates
// the ctor (placement-new), giving a symbol. Only for ABI-simple params (scalars /
// pointers): by-value/ref params would need marshaling and stay a gap for now.
struct CtorShim { string dName, cppName, shimFn; string[] cppParams, argNames; }
__gshared CtorShim[] CTORSHIM;

// Inline methods on OBJECT (polymorphic) types have no linkable symbol, and their body
// can't be translated in D (the class is opaque — no named fields). So each inline
// getter/setter gets an out-of-line C++ trampoline that calls `self->method(args)`,
// compiled against the headers. Restricted to ABI-simple return+params (scalars/
// pointers/void) — the getter/setter shape. Each entry emits one qtd_m_<Class>_<i>.
struct MethodShim { string shimFn, cppName, cppRet, method; string[] cppParams, argNames; bool isStatic, isConst; }
__gshared MethodShim[] METHODSHIM;

// ============================================================================================
// EXCEPTION GUARDS  (the "how does this witchcraft work" section — read this before editing)
// ============================================================================================
// PROBLEM. When a spec has "exceptions": true we must catch C++ exceptions that Qt throws
// (std::bad_alloc, QException, ...) and re-raise them as a D `QtCppException`, instead of
// letting a C++ exception unwind into D as undefined behaviour. To catch a C++ exception there
// MUST be a C++ `try/catch` around the actual Qt call. Our normal out-of-line methods are bound
// as `pragma(mangle) final <ret> method(params);` — D calls the Qt symbol DIRECTLY, so there is
// no C++ frame to put a try/catch in.
//
// NAIVE FIX. Emit one C++ trampoline per method: `<ret> qtd_m(void* self, params){ try { return
// self->method(args);} catch(...){...} }`. Correct, but that is ~8000 near-identical functions
// for QtWidgets — a giant qtdctor.cpp and slow to compile.
//
// WHAT WE DO INSTEAD — one guard per SIGNATURE, shared across every method of that shape.
// Key trick (Itanium C++ ABI): a non-virtual member function `R C::m(A...)` is ABI-identical to
// a free function `R(void* self, A...)` — the implicit `this` is simply the first argument, same
// registers, same calling convention. And calling a virtual method through its out-of-line
// SYMBOL (not the vtable) is exactly what `pragma(mangle)` already does. So we can:
//   1. take the ADDRESS of the Qt method's symbol on the D side (a nullary
//      `pragma(mangle,"<sym>") extern(C++) void __raw_X();` — declared only so `&__raw_X` yields
//      the symbol address; its declared type is irrelevant, we never CALL __raw_X), and
//   2. pass that address + self + args to ONE shared C++ guard for the (return, params) shape,
//      which `reinterpret_cast`s the pointer to the exact signature and calls it in try/catch:
//        <cppRet> qtd_g_N(void* fn, void* self, <cppParams>) {
//            try { return reinterpret_cast<cppRet(*)(void*, cppParams)>(fn)(self, args); }
//            catch (...) { qtd_lippincott(); }   // classifies + re-raises as a D exception
//        }
// Because the guard's C++ signature is TYPED (not void*/varargs), the compiler emits the correct
// ABI for value-type params, sret value RETURNS (QString text() etc.), floats — all of it. That
// is why per-signature, not per-arity-void* (which can't express sret / xmm). One guard serves
// every `void(bool)` method (setDefault/setFlat/...), every `QString() const` getter, etc.
//
// THREE GOTCHAS that will bite you (all learned the hard way):
//  (a) The D forwarder MUST be `extern(D)`. It lives inside an `extern(C++) class`, so without
//      it D would mangle `gesture(GestureType) const` to the *exact* Qt symbol `__raw` points at
//      — the forwarder would both COLLIDE with __raw and REDEFINE the C++ method. extern(D) makes
//      it a plain D method whose name never touches the C++ symbol table.
//  (b) Forwarders are DEFINITIONS, so two that collapse to the same D signature (e.g.
//      `scroller(QObject*)` and `scroller(const QObject*)`, both -> `scroller(QObject)`) conflict.
//      Direct `pragma(mangle)` DECLS could coexist; definitions can't. So we dedup by D signature.
//  (c) `&__raw_X` FORCES a reference to the symbol even if the method is never called (defeating
//      some DCE). Fine for real methods (they resolve from Qt), but `qt_check_for_QGADGET_macro`
//      is DECLARED-but-never-DEFINED by Q_GADGET -> undefined reference. We skip that one.
//
// Ctors reuse the void-return guards: a constructor's ABI is `void(void* self, A...)` (the object
// is heap-allocated by __cpp_new first, then the ctor runs on it), i.e. the same shape as a
// void-returning non-static method.
//
// SCOPE: only when EXCEPTIONS is on. Methods/ctors whose signature the guard can't express stay
// on the direct path (fn-pointer return/params, container-param, QList-returning methods).
struct Guard { string name, cppRet, retD; string[] cppTypes, dParams; bool isStatic; }
__gshared Guard[string] GUARDS;   // key "(s)|cppRet|cppTypes" -> the ONE guard for that shape

// Register-once (dedup by signature) and return the guard's function name. cppTypes = canonical
// C++ param types WITHOUT names (for the reinterpret_cast target + the guard's own C++ params);
// dParams = D param decls ("int a0", "ref const(QString) a1", for the guard's extern(C) D decl);
// retD = the D return type. Static methods have no `self`, so they key separately.
string guardFor(string cppRet, string[] cppTypes, string retD, string[] dParams, bool isStatic) {
    auto key = (isStatic ? "s|" : "|") ~ cppRet ~ "|" ~ cppTypes.join(",");
    if (auto g = key in GUARDS) return g.name;
    auto nm = format("qtd_g_%d", cast(int) GUARDS.length);
    GUARDS[key] = Guard(nm, cppRet, retD, cppTypes.dup, dParams.dup, isStatic);
    return nm;
}

// All overridable virtuals of a class (own + inherited, most-derived kept, deduped
// by name+param types) — the vtable a D subclass can override.
void collectVirtuals(CXCursor cls, ref CXCursor[] result, ref bool[string] seen) {
    foreach (c; children(cls))
        if (c.kind == CXCursor_CXXMethod && clang_CXXMethod_isVirtual(c)) {
            auto key = clang_getCursorSpelling(c).str ~ "(" ~ clang_getTypeSpelling(clang_getCursorType(c)).str ~ ")";
            if (key in seen) continue;
            seen[key] = true;
            // A PRIVATE virtual is overridable but not CALLABLE: the trampoline's default branch
            // is a qualified `Base::f()`, and that name lookup is access-checked in Base (e.g.
            // QQuickImageBase::requestFinished, QQuickTableView::minXExtent). Mark it seen so an
            // accessible base declaration isn't picked in its place — the derived class hid it.
            if (clang_getCXXAccessSpecifier(c) == CX_CXXPrivate) continue;
            result ~= c;
        }
    foreach (b; baseDecls(cls)) {
        auto bd = clang_getCursorDefinition(b);
        if (bd.kind == CXCursor_ClassDecl || bd.kind == CXCursor_StructDecl)
            collectVirtuals(bd, result, seen);
    }
}

// Build a TrampVirt for a virtual whose signature the trampoline supports (prim /
// class-ptr / const-ref-to-value args; void / prim / class-ptr return). Returns
// false to skip virtuals with types we can't marshal yet (value return, etc.).
bool trampVirt(CXCursor m, string cppClass, out TrampVirt tv) {
    auto rt = clang_getCursorResultType(m);
    auto rc = canon(rt);
    if (rc.canFind("<") || rc.canFind("std::")) return false;   // template/std return
    tv.retVoid = rc == "void";
    auto rck = clang_getCanonicalType(rt);
    // return: void / primitive / enum / class-pointer
    tv.cppRet = clang_getTypeSpelling(rt).str;
    if (tv.retVoid) { tv.cbDRet = "void"; tv.cbCppRet = "void"; }
    else if (auto p = rc in PRIM) { tv.cbDRet = *p; tv.cbCppRet = tv.cppRet; }
    else if (rck.kind == CXType_Enum) {   // ABI = int; marshal as int (C++ side), enum (D side)
        string ip; tv.cbDRet = mapCxxType(rt, ip); if (ip.length) tv.imports ~= ip;
        tv.cbCppRet = "int"; tv.retEnum = true;
    } else if (rck.kind == CXType_Pointer && isRecord(clang_getPointeeType(rck))) {
        tv.cbDRet = lastNs(canon(clang_getPointeeType(rck))); tv.imports ~= tv.cbDRet;
        tv.cbCppRet = tv.cppRet;
    } else return false;
    string[] op, pass, cbc, cbd, orig;
    auto na = clang_Cursor_getNumArguments(m);
    foreach (i; 0 .. na) {
        auto a = clang_Cursor_getArgument(m, i);
        auto at = clang_getCursorType(a);
        auto ak = clang_getCanonicalType(at);
        auto cpp = clang_getTypeSpelling(at).str;
        if (canon(at).canFind("<") || canon(at).canFind("std::")) return false;   // template/std arg
        // reference to a non-record (int&, etc.) is an out-param we can't marshal yet
        if (ak.kind == CXType_LValueReference && !isRecord(clang_getPointeeType(ak))) return false;
        op ~= format("%s a%d", cpp, i);
        orig ~= format("a%d", i);
        if (auto p = canon(at) in PRIM) {                        // primitive
            pass ~= format("a%d", i); cbc ~= cpp; cbd ~= *p;
        } else if (ak.kind == CXType_Enum) {                     // enum by value (ABI = int)
            string ip; auto ed = mapCxxType(at, ip);
            pass ~= format("a%d", i); cbc ~= "int"; cbd ~= ed; if (ip.length) tv.imports ~= ip;
        } else if (ak.kind == CXType_Pointer && isRecord(clang_getPointeeType(ak))) {  // class pointer
            // Skip a virtual whose pointee is a NESTED type (a record inside a class, e.g.
            // QQuickItem::UpdatePaintNodeData): its spelling is unqualified in the header (breaks the
            // free C++ trampoline) and it has no top-level bound D module. We don't override these.
            auto pdecl = clang_getTypeDeclaration(clang_getCanonicalType(clang_getPointeeType(ak)));
            auto pk = clang_getCursorSemanticParent(pdecl).kind;
            if (pk == CXCursor_ClassDecl || pk == CXCursor_StructDecl) return false;
            auto dn = lastNs(canon(clang_getPointeeType(ak)));
            pass ~= format("a%d", i); cbc ~= cpp; cbd ~= dn; tv.imports ~= dn;
        } else if (ak.kind == CXType_LValueReference && isRecord(clang_getPointeeType(ak))
                   && isValueRecord(clang_getPointeeType(ak))
                   && clang_getTypeSpelling(at).str.canFind("const")) {                 // const value&
            auto pt = clang_getPointeeType(ak);
            auto dn = lastNs(canon(pt));
            pass ~= format("&a%d", i);
            cbc ~= "const " ~ lastNs(canon(pt)) ~ "*";
            cbd ~= "const(" ~ dn ~ ")*"; tv.imports ~= dn;
        } else return false;   // unsupported arg type
    }
    tv.name = clang_getCursorSpelling(m).str;
    tv.overrideParams = op.join(", ");
    tv.passArgs = pass.length ? ", " ~ pass.join(", ") : "";
    tv.origArgs = orig.join(", ");
    tv.cbCppParams = cbc.join(", ");
    tv.cbDParams = cbd.join(", ");
    tv.isPure = clang_CXXMethod_isPureVirtual(m) != 0;
    tv.isConst = clang_CXXMethod_isConst(m) != 0;
    return true;
}

// The as<Base>() method: upcast this to a secondary base via the offset shim.
string miCastMethod(string dClass, string sbDClass) {
    if (WRAPPER)   // secondary-base subobject pointer -> wrap it (a distinct holder key)
        return format("    final %s as%s() { return %s.wrap(qtd_upcast_%s_%s(this.ptr())); }",
            sbDClass, sbDClass, sbDClass, dClass, sbDClass);
    return format("    final %s as%s() { return cast(%s) qtd_upcast_%s_%s(cast(void*) this); }",
        sbDClass, sbDClass, sbDClass, dClass, sbDClass);
}

// The D `connect<Signal>(void delegate())` method emitted on the owning class.
// Boxes the delegate, roots it, calls the extern(C) shim, returns a handle.
string signalConnectMethod(Signal s) {
    auto cap = s.name.length ? (cast(char)(s.name[0] & ~0x20) ~ s.name[1 .. $]) : s.name;
    // delegate to the per-signal qtsignals runtime helper (keeps GC/box out of here).
    return format(
        "    extern(D) final QtdConnection connect%s(void delegate(%s) dg) {\n"
        ~ "        return __conn_%s_%s(%s, dg);\n    }",
        cap, s.cbDParams, s.dClass, s.name, WRAPPER ? "this.ptr()" : "cast(void*) this");
}

// Is this record a class nested inside another class (QJsonObject::iterator)?
bool nestedInClass(CXType t) {
    auto d = clang_getTypeDeclaration(clang_getCanonicalType(t));
    auto p = clang_getCursorSemanticParent(d);
    return p.kind == CXCursor_ClassDecl || p.kind == CXCursor_StructDecl;
}

// Nested value classes referenced by a bound signature -> emitted on demand as their own
// module (QMetaObject::Connection -> qt.<pkg>.qmetaobject_connection). Demand-driven like
// PENDING_BASES. Only VALUE records (non-polymorphic) that are publicly accessible qualify.
__gshared CXCursor[string] PENDING_NESTED;   // D name -> nested-class definition cursor

// Classes referenced ONLY as the scope of a nested enum (QQmlDelegateModel::DelegateModelAccess
// on a QQuickItemView signature). If such a class ends up an opaque stub — it is not a discovered
// target, or its header isn't in scope — the stub must still carry its nested enums, else the D
// reference `Parent.Enum` doesn't resolve. Keyed by D class name -> the class definition cursor.
__gshared CXCursor[string] PENDING_ENUMSCOPE;

// Outer::Inner -> "Outer_Inner" (namespaces dropped): a unique, collision-safe D name that,
// unlike lastNs, keeps QJsonObject::iterator and QJsonArray::iterator distinct.
string nestedDName(string qn) {
    auto parts = qn.split("::");
    if (parts.length < 2) return qn;
    return parts[$ - 2] ~ "_" ~ parts[$ - 1];
}

// Register a nested VALUE class for on-demand emission; returns its D name. Throws (so the
// referencing method is skipped as before) if it isn't a publicly-accessible value record.
string registerNested(CXType t) {
    if (!isValueRecord(t)) throw new Unmappable("nested object-type record");
    auto decl = clang_getCursorDefinition(clang_getTypeDeclaration(clang_getCanonicalType(t)));
    if (decl.kind != CXCursor_ClassDecl && decl.kind != CXCursor_StructDecl)
        throw new Unmappable("nested non-record");
    if (clang_getCXXAccessSpecifier(decl) > CX_CXXPublic)   // protected/private in the outer class
        throw new Unmappable("non-public nested record");
    auto nn = nestedDName(canon(t));
    PENDING_NESTED[nn] = decl;
    return nn;
}

// Minimal emission for a nested value class: an ABI-faithful opaque handle — a size/align
// blob + (if the C++ type is non-trivially copyable) a copy-ctor/~this that run the REAL
// C++ copy/dtor via the qtdctor shims. No methods (no cascade). Enough for by-value
// return/param (QMetaObject::Connection from QObject::connect): correct size + sret ABI.
string emitNestedValue(CXCursor cur, string name, string cppName, string dpkg, string manifest) {
    auto ct = clang_getCursorType(cur);
    auto sz = clang_Type_getSizeOf(ct), al = clang_Type_getAlignOf(ct);
    if (sz <= 0) sz = 1;
    string bodyN = format("    align(%d) ubyte[%d] __data;", al > 0 ? al : 1, sz);
    string factories;
    if (nonTriviallyCopyable(ct) && !copyDeleted(cur)) {
        CTORCOPY ~= CtorCopy(name, cppName);
        factories = format("extern(C) private void qtd_cctor_%s(void*, const(void)*) nothrow;\n"
            ~ "extern(C) private void qtd_dtor_%s(void*) nothrow;", name, name);
        bodyN ~= format(
            "\n    extern(D) this(ref const(%s) rhs) nothrow { qtd_cctor_%s(cast(void*)&this, cast(const(void)*)&rhs); }"
            ~ "\n    extern(D) ~this() nothrow { qtd_dtor_%s(cast(void*)&this); }", name, name, name);
    }
    // No ns clause: we never rely on this struct's own D mangling (its symbols go through
    // the qtdctor shims, which use the real C++ name cppName) — extern(C++) alone is enough.
    return format("%s\nmodule %s.%s;\n\nextern (C++) struct %s {\n%s\n}\n%s\n",
        manifest, dpkg, modBase(name), name, bodyN, factories);
}

// A C++ forward iterator -> a D range. Emitted C++ ops over the iterator's bytes.
struct IterOp { string iName, iCpp, eCpp; }
__gshared IterOp[string] ITEROPS;   // iterator D name -> deref/incr/ne shim spec (emit once)

// If T has begin()/end() returning the same iterator record I (with operator* / prefix
// operator++ / operator!=), synthesize a D range so `foreach (x; t[])` works — the whole
// point of emitting the nested iterator type. `front` yields I's `value_type` (a proxy deref
// like QCborValueRef converts to it at the C++ boundary). Returns [rangeStruct, accessor,
// moduleDecls] (accessor goes INSIDE T; the other two at module scope) or [] if T has no
// iterable begin/end. impSet gains the element + iterator modules.
string[] rangeFor(CXCursor t, string tName, ref bool[string] impSet) {
    CXCursor beginM, endM; bool haveB, haveE;
    foreach (c; children(t)) {
        if (c.kind != CXCursor_CXXMethod || !isPublic(c)) continue;
        if (clang_Cursor_getNumArguments(c) != 0 || clang_CXXMethod_isConst(c)) continue;
        auto nm = clang_getCursorSpelling(c).str;
        if (nm == "begin") { beginM = c; haveB = true; }
        else if (nm == "end") { endM = c; haveE = true; }
    }
    if (!haveB || !haveE) return [];
    auto itT = clang_getCursorResultType(beginM);
    if (!isRecord(itT) || canon(clang_getCursorResultType(endM)) != canon(itT)) return [];
    auto itDecl = clang_getCursorDefinition(clang_getTypeDeclaration(clang_getCanonicalType(itT)));
    if (itDecl.kind != CXCursor_ClassDecl && itDecl.kind != CXCursor_StructDecl) return [];
    string iimp, iD;
    try iD = mapCxxType(itT, iimp); catch (Unmappable) return [];   // must be a type WE emit
    if (!iimp.length) return [];
    // Essential forward-iterator members: operator* (deref) + prefix operator++. Comparison
    // is NOT required as a member — Qt6 iterators get != from the comparison-helper templates
    // (qcompare_impl.h), and the `*a != *b` in the emitted C++ shim resolves through it.
    bool hasDeref, hasIncr; CXType derefT;
    foreach (c; children(itDecl)) {
        if (c.kind != CXCursor_CXXMethod || !isPublic(c)) continue;
        auto op = clang_getCursorSpelling(c).str;
        auto na = clang_Cursor_getNumArguments(c);
        if (op == "operator*" && na == 0) { hasDeref = true; derefT = clang_getCursorResultType(c); }
        else if (op == "operator++" && na == 0) hasIncr = true;   // prefix ++it
    }
    if (!hasDeref || !hasIncr) return [];
    // element type = the iterator's `value_type` typedef (clean value; the proxy deref
    // converts to it in C++) if it maps, else operator*'s own return type.
    CXType elemT = derefT; bool haveVT;
    foreach (c; children(itDecl))
        if ((c.kind == CXCursor_TypedefDecl || c.kind == CXCursor_TypeAliasDecl)
                && clang_getCursorSpelling(c).str == "value_type") {
            elemT = clang_getTypedefDeclUnderlyingType(c); haveVT = true; break;
        }
    string eimp, eD;
    try eD = mapCxxType(elemT, eimp);
    catch (Unmappable) {
        if (!haveVT) return [];
        try { eD = mapCxxType(derefT, eimp); elemT = derefT; } catch (Unmappable) return [];
    }
    if (eimp.length) impSet[eimp] = true;
    impSet[iimp] = true;
    if (iD !in ITEROPS) ITEROPS[iD] = IterOp(iD, canon(itT), canon(elemT));
    auto decls = format(
        "extern(C) private %s qtd_ideref_%s(void*);\n"
        ~ "extern(C) private void qtd_iincr_%s(void*);\n"
        ~ "extern(C) private bool qtd_ine_%s(void*, void*);", eD, iD, iD, iD);
    auto rangeStruct = format(
        "struct %s_Range {\n"
        ~ "    private %s _cur, _end;\n"
        ~ "    this(%s b, %s e) { _cur = b; _end = e; }\n"
        ~ "    @property bool empty() { return !qtd_ine_%s(cast(void*)&_cur, cast(void*)&_end); }\n"
        ~ "    @property %s front() { return qtd_ideref_%s(cast(void*)&_cur); }\n"
        ~ "    void popFront() { qtd_iincr_%s(cast(void*)&_cur); }\n"
        ~ "}", tName, iD, iD, iD, iD, eD, iD, iD);
    auto accessor = format(
        "    extern(D) %s_Range opSlice() { return %s_Range(begin(), end()); }", tName, tName);
    return [rangeStruct, accessor, decls];
}

// Map a C++ type to the D type that mangles identically under extern(C++).
// `imp` gets the unqualified module name when a class type is referenced.
// Throws Unmappable for what this first pass doesn't handle yet (refs, enums,
// records-by-value, QString, containers) so the method is simply skipped.
string mapCxxType(CXType t, ref string imp) {
    imp = "";
    auto ck = clang_getCanonicalType(t);
    auto c = canon(t);
    if (c == "void") return "void";
    if (isPrivate(c)) throw new Unmappable("private " ~ c);
    // QFlags<Enum> is an int-sized struct; map to int (pragma(mangle) fixes the symbol).
    if (clang_getCursorSpelling(clang_getTypeDeclaration(ck)).str == "QFlags") return "int";
    if (c.canFind("<") || c.canFind("std::")) throw new Unmappable("template/std: " ~ c);
    // Function pointer param (e.g. `void (*)(void*)`) -> `void*`. D can't spell an
    // inline `extern(C) ret function(args)` param type, and the C++ ptr is ABI-a-pointer
    // anyway (pragma(mangle) fixes the symbol), so a `void*` un-drops the method and is
    // callable with `cast(void*) &fn`. (Type-safe fn-ptr params are a rare Qt case.)
    if (ck.kind == CXType_Pointer
        && clang_getCanonicalType(clang_getPointeeType(ck)).kind == CXType_FunctionProto)
        return "void*";
    // lambda closures / anonymous types spell with '(' — never a valid D type or module
    // name (would even break the output filename).
    if (c.canFind("(")) throw new Unmappable("anon/lambda: " ~ c);
    if (auto p = c in PRIM) return *p;
    if (ck.kind == CXType_Enum) {                 // ABI-identical D enum
        auto decl = clang_getTypeDeclaration(ck);
        auto en = lastNs(c);
        auto parent = clang_getCursorSemanticParent(decl);
        // Nested in a class -> emit inside that class (mangling substitution needs
        // the same enclosing scope, e.g. QThread::setPriority(QThread::Priority)).
        if (parent.kind == CXCursor_ClassDecl || parent.kind == CXCursor_StructDecl) {
            auto pn = clang_getCursorSpelling(parent).str;
            auto pdef = clang_getCursorDefinition(parent);
            if (pdef.kind == CXCursor_ClassDecl || pdef.kind == CXCursor_StructDecl)
                PENDING_ENUMSCOPE[pn] = pdef;   // stub must still carry the enum (see decl)
            imp = pn; return pn ~ "." ~ en;
        }
        ENUMS[en] = decl; imp = en; return en;    // namespace/global -> own module
    }
    if (ck.kind == CXType_Pointer) {
        auto pt = clang_getPointeeType(ck);
        auto pc = canon(pt);
        if (pc == "char")
            return clang_getTypeSpelling(pt).str.canFind("const") ? "const(char)*" : "char*";
        if (pc == "void") return "void*";
        if (auto p = pc in PRIM) return *p ~ "*";
        if (isRecord(pt)) {
            if (nestedInClass(pt)) { auto nn = registerNested(pt); imp = nn; return nn ~ "*"; }
            auto n = lastNs(pc); imp = n;
            // A polymorphic class maps to a D `extern(C++) class` (already a reference/
            // pointer), so X* -> X. A value type maps to a D struct, so X* -> X* (a real
            // pointer to the struct) — else a returned/passed pointer is read by value.
            return isValueRecord(pt) ? n ~ "*" : n;
        }
    }
    // const T& / T& to a value-type record -> ref (const) Struct (mangles RK.../R...)
    if (ck.kind == CXType_LValueReference) {
        auto pt = clang_getPointeeType(ck);
        auto pc = canon(pt);
        auto konst = clang_getTypeSpelling(ck).str.canFind("const");
        // parenthesize the const so a return-position `ref const(X) f() const` isn't
        // read as declaring the function const twice (bare leading const binds to the fn).
        if (auto p = pc in PRIM) return konst ? "ref const(" ~ *p ~ ")" : "ref " ~ *p;
        if (isRecord(pt) && isValueRecord(pt)) {
            auto n = nestedInClass(pt) ? registerNested(pt) : lastNs(pc); imp = n;
            return konst ? "ref const(" ~ n ~ ")" : "ref " ~ n;
        }
        // object-type record by reference (const QPixmap&, const QIcon&…): a C++ reference is
        // ABI-a-pointer, and a D `extern(C++) class` IS already a pointer, so pass the class
        // directly — exactly like an X* pointer param (const-ness doesn't change the ABI).
        // Unblocks e.g. QLabel::setPixmap(const QPixmap&).
        if (isRecord(pt) && !nestedInClass(pt)) {
            auto n = lastNs(pc); imp = n;
            return n;
        }
        throw new Unmappable("ref to " ~ clang_getTypeSpelling(pt).str);
    }
    // value-type record BY VALUE (QPoint/QSize/QRect) -> the extern(C++) struct
    if (ck.kind == CXType_Record) {
        if (!isValueRecord(t)) throw new Unmappable("object-type by value: " ~ c);
        auto n = nestedInClass(t) ? registerNested(t) : lastNs(c); imp = n; return n;
    }
    throw new Unmappable("cxx type " ~ clang_getTypeSpelling(t).str);
}

// In WRAPPER mode: the wrapper class name iff `t` is a pointer to an OBJECT-type
// (polymorphic) record — i.e. what mapCxxType maps to a bare class name `N` (see the
// `isValueRecord(pt) ? n~"*" : n` at the pointer branch). Such a param/return crosses
// the boundary as a wrapper on the D side but a raw C++ pointer on the C++ side, so it
// must be unwrapped (param) / wrapped (return). Empty for anything else.
__gshared bool[string] WRAPREFS;   // object types referenced as wrappers -> wrapper stubs
__gshared long CXX_SKIP;   // extern(C++) methods/ctors dropped as unmapped-type (honest coverage)
// Per-symbol coverage manifest (round-4 #1): one TSV row per processed API symbol with its
// FATE — bound / shimmed / signal / inherited / pure-virtual / unmapped-type / inline-failed /
// opaque-stub. Answers "what happened to each Qt symbol?", not just an aggregate count.
__gshared string[] MANIFEST;
// The USR (clang Unified Symbol Resolution) is a canonical per-symbol identity that INCLUDES the
// signature — so overloads get distinct rows (critics r6 #2: class+name collapsed them and let a
// regressed/vanished overload pass the gate). Column order keeps `fate` LAST so the coverage.txt
// breakdown (splits on the last column) is unaffected.
void recordSym(string cppClass, string sym, string fate, CXCursor c) {
    auto usr = clang_getCursorUSR(c).str;
    MANIFEST ~= cppClass ~ "\t" ~ sym ~ "\t" ~ usr ~ "\t" ~ fate;
    if (fate == "unmapped-type" || fate == "inline-failed") CXX_SKIP++;   // only real drops
}
string wrapperTypeOf(CXType t) {
    auto ck = clang_getCanonicalType(t);
    if (ck.kind != CXType_Pointer) return "";
    auto pt = clang_getPointeeType(ck);
    if (!isRecord(pt) || nestedInClass(pt) || isValueRecord(pt)) return "";
    auto n = lastNs(canon(pt));
    WRAPREFS[n] = true;
    return n;
}

// A record that is passed/returned by value: not QObject-derived and not
// polymorphic (those aren't copyable / have a vtable).
bool isValueRecord(CXType t) {
    auto decl = clang_getCursorDefinition(clang_getTypeDeclaration(clang_getCanonicalType(t)));
    if (decl.kind != CXCursor_ClassDecl && decl.kind != CXCursor_StructDecl) return false;
    if (isQObject(decl)) return false;
    foreach (m; children(decl))
        if ((m.kind == CXCursor_CXXMethod || m.kind == CXCursor_Destructor) && clang_CXXMethod_isVirtual(m))
            return false;
    return true;
}

// Non-trivially-copyable: a bitwise copy is WRONG (std::string's SSO self-pointer,
// a CoW refcount, owned resources). Precise — I do NOT use plain isPOD because a
// value type with a user ctor but scalar members (Point: double x,y; copy/dtor
// `= default`) is non-POD and YET trivially copyable; marking it would change the
// return-by-value ABI and break it. Criterion: (a) a user-provided copy-ctor or
// dtor (not `= default`, not `= delete`) — CoW à la QPen; or (b) a record field
// embedded BY VALUE that is itself non-trivial — std::string.
// Surgical trigger: a value type that embeds a STANDARD-LIBRARY type by value
// (std::string, std::vector, std::list, ...). Those need a REAL deep copy — bitwise
// breaks (std::string SSO self-pointer; std::vector owning pointer). This is the only
// trigger: Qt CoW types hold a d POINTER (QFooPrivate*), not a std:: by value, so they
// do NOT fire and stay as before (no regression across the 150+ Qt classes). It also
// avoids Qt's non-copyable internals (QBasicAtomicInt/QArrayData/etc.).
bool nonTriviallyCopyable(CXType t) {
    if (clang_isPODType(t) != 0) return false;   // POD -> bitwise copy is safe
    auto decl = clang_getCursorDefinition(clang_getTypeDeclaration(clang_getCanonicalType(t)));
    if (decl.kind != CXCursor_ClassDecl && decl.kind != CXCursor_StructDecl) return false;
    // Criterion (a) is only safe for EXPORTED types: the copy-ctor/~this shims call the real
    // C++ copy-ctor/dtor, whose symbols must be linkable. A public Q_*_EXPORT type has them
    // (Default visibility); a Qt-internal one (e.g. QOpenGLVersionFunctionsStorage, Hidden)
    // does not — marking it non-trivial would emit an unlinkable dtor reference.
    bool exported = clang_getCursorVisibility(decl) == 3;   // CXVisibility_Default
    foreach (c; children(decl)) {
        // (a) a USER-PROVIDED (not =default/=delete) copy-ctor or dtor -> the C++ ABI returns
        // this type via sret and expects a real copy/dtor. This is the Qt CoW case (QIcon/
        // QFont/QPen/…: a QFooPrivate* d-pointer + `~QFoo()`). Without the D copy-ctor/~this
        // the D struct is trivial, D uses the register-return ABI, and a by-value return
        // (icon(), font(), …) crashes on the ABI mismatch. `= default` copy/dtor (POD-ish
        // value types like Point) stay trivial and are NOT marked (that would break their ABI).
        if (exported && c.kind == CXCursor_Destructor
                && clang_CXXMethod_isDefaulted(c) == 0 && clang_CXXMethod_isDeleted(c) == 0)
            return true;
        if (exported && c.kind == CXCursor_Constructor && clang_CXXConstructor_isCopyConstructor(c)
                && clang_CXXMethod_isDefaulted(c) == 0 && clang_CXXMethod_isDeleted(c) == 0)
            return true;
        // (b) a std::-library member by value (std::string SSO / std::vector owning ptr).
        if (c.kind == CXCursor_FieldDecl) {
            auto ft = clang_getCanonicalType(clang_getCursorType(c));
            while (ft.kind == CXType_ConstantArray) ft = clang_getArrayElementType(ft);
            if (ft.kind == CXType_Record && clang_getTypeSpelling(ft).str.startsWith("std::"))
                return true;   // std:: member by value -> needs a deep copy
        }
    }
    return false;
}

// A D type with a trivial ABI for an extern(C) shim: scalar or pointer (incl. const(char)*).
// (by-value/ref would need marshaling — out of scope for a ctor shim.)
bool simpleAbiType(string pd) {
    static immutable scalars = ["bool", "byte", "ubyte", "short", "ushort", "int", "uint",
        "long", "ulong", "float", "double", "real", "char", "wchar", "dchar", "size_t"];
    return pd.endsWith("*") || scalars.canFind(pd);
}

// A nested type declared protected/private is unnameable/inaccessible from an
// out-of-line shim compiled at namespace scope -> never emit a shim referencing it.
// Namespace-scope types have access spec 0 (invalid) and are fine.
bool nestedInaccessible(CXCursor decl) {
    auto acc = clang_getCXXAccessSpecifier(decl);
    return acc == 2 || acc == 3;   // 2=protected, 3=private
}

// A `= delete`d copy ctor (DISABLE_COPY) or an inaccessible type: skip deep-copy.
bool copyDeleted(CXCursor decl) {
    if (nestedInaccessible(decl)) return true;
    foreach (c; children(decl))
        if (c.kind == CXCursor_Constructor && clang_CXXConstructor_isCopyConstructor(c)
            && clang_CXXMethod_isDeleted(c))
            return true;   // DISABLE_COPY
    return false;
}

// A move-only value type (deleted copy ctor) passed BY VALUE. A method-shim forwards its
// by-value params as lvalues (`self->m(a0)`), which COPIES them — impossible for a move-only
// type. Such methods can't go through the shim; they use the direct-symbol path instead (a
// pragma(mangle) decl has no body, so the ABI handles the move). Pointers/refs never copy.
bool moveOnlyByValue(CXType t) {
    auto ct = clang_getCanonicalType(t);
    if (ct.kind != CXType_Record) return false;   // by-value record only (not ptr/ref)
    return copyDeleted(clang_getCursorDefinition(clang_getTypeDeclaration(ct)));
}

// Is a method inline (has an inline definition -> no out-of-line symbol to link)?
// Catches both `int f(){...}` in-class AND out-of-class `inline int C::f(){...}`.
// Inline (no linkable symbol) — check the in-class declaration AND its definition:
// Qt often declares a method in-class and defines it `inline` later in the same
// header (QToolBox::addItem, QVector2D::length), which the declaration cursor alone
// doesn't reveal. An out-of-line (.cpp) definition isn't in the TU -> stays false.
bool isInline(CXCursor m) {
    if (clang_Cursor_isFunctionInlined(m) != 0) return true;
    return clang_Cursor_isFunctionInlined(clang_getCursorDefinition(m)) != 0;
}

// A Qt signal? Detected by the AnnotateAttr("qt_signal") the parse flags inject
// (Q_SIGNALS -> public __attribute__((annotate("qt_signal")))). Signals ARE moc-
// generated (they have a linkable symbol) but you connect to them, not call them.
bool isSignal(CXCursor m) {
    foreach (ch; children(m))
        if (ch.kind == CXCursor_AnnotateAttr && clang_getCursorSpelling(ch).str == "qt_signal")
            return true;
    return false;
}

// Real argument count, excluding Qt6's trailing QPrivateSignal marker (moc adds it
// to every signal to block direct emission; it's not a real parameter).
int realArgCount(CXCursor c) {
    int n = 0;
    auto na = clang_Cursor_getNumArguments(c);
    foreach (i; 0 .. na)
        if (!canon(clang_getCursorType(clang_Cursor_getArgument(c, i))).canFind("QPrivateSignal")) n++;
    return n;
}

// ---- Demand-driven container shims -------------------------------------------
// Any container×element combo seen in a signature registers itself here; the
// runtime (qtcontainers.cpp/.d) is generated for exactly those combos at the end
// of the run — the whole Qt container lib is covered without a hardcoded list.
// Container KINDS: seq (QList/QVector/QStack/QQueue), set (QSet), assoc
// (QHash/QMap/QMultiHash/QMultiMap). ELEMENTS: basic types marshal natively
// (string<->QString, ubyte[]<->QByteArray, prim<->prim); anything else is skipped
// (opaque-element containers are a later TODO).
enum CKind { seq, set, assoc }
struct CElem {
    string cxx;    // C++ element type for the typedef: QString / QByteArray / int / double ...
    string dtype;  // D idiomatic element type: string / ubyte[] / int / double ...
    string kind;   // marshaling strategy: "str" | "bytes" | "prim"
}
struct Combo {
    CKind  kind;
    string ctmpl;    // container template name: QList / QStack / QSet / QHash / QMultiMap ...
    string cxxType;  // full C++ type: QHash<QString,QString>
    string id;       // unique symbol id: qhash_str_str / qlist_int / qset_str ...
    string idiomD;   // D container type: string[string] / int[] / string[] ...
    CElem  key;      // assoc only
    CElem  val;      // element (seq/set) or value (assoc)
}
__gshared Combo[string] COMBOS;   // id -> combo (populated during emission)

// Resolve one template argument to a marshalable element, or false (unsupported).
bool comboElem(CXType t, out CElem e) {
    auto c = canon(t);
    if (c == "QString")    { e = CElem("QString", "string", "str");       return true; }
    if (c == "QByteArray") { e = CElem("QByteArray", "ubyte[]", "bytes"); return true; }
    if (c == "void") return false;
    if (auto p = c in PRIM) { e = CElem(c, *p, "prim"); return true; }
    return false;
}
string elemSlug(CElem e) { return e.kind == "str" ? "str" : e.kind == "bytes" ? "bytes" : e.dtype; }

// Register the container combo behind `t` (resolved canonically). Returns its id,
// or "" if it isn't a supported container / an element isn't marshalable.
string registerCombo(CXType t) {
    auto ck = clang_getCanonicalType(t);
    auto dn = clang_getCursorSpelling(clang_getTypeDeclaration(ck)).str;   // QVector canonicalizes to QList
    CKind kind;
    if (dn == "QList" || dn == "QVector" || dn == "QStack" || dn == "QQueue") kind = CKind.seq;
    else if (dn == "QSet") kind = CKind.set;
    else if (dn == "QHash" || dn == "QMultiHash" || dn == "QMap" || dn == "QMultiMap") kind = CKind.assoc;
    else return "";
    auto nargs = clang_Type_getNumTemplateArguments(ck);
    Combo cb; cb.kind = kind; cb.ctmpl = dn;
    if (kind == CKind.assoc) {
        if (nargs < 2) return "";
        if (!comboElem(clang_Type_getTemplateArgumentAsType(ck, 0), cb.key)) return "";
        if (!comboElem(clang_Type_getTemplateArgumentAsType(ck, 1), cb.val)) return "";
        cb.id      = dn.toLower ~ "_" ~ elemSlug(cb.key) ~ "_" ~ elemSlug(cb.val);
        cb.cxxType = format("%s<%s,%s>", dn, cb.key.cxx, cb.val.cxx);
        cb.idiomD  = format("%s[%s]", cb.val.dtype, keyDType(cb.key));
    } else {
        if (nargs < 1) return "";
        if (!comboElem(clang_Type_getTemplateArgumentAsType(ck, 0), cb.val)) return "";
        cb.id      = dn.toLower ~ "_" ~ elemSlug(cb.val);
        cb.cxxType = format("%s<%s>", dn, cb.val.cxx);
        cb.idiomD  = cb.val.dtype ~ "[]";
    }
    COMBOS[cb.id] = cb;
    return cb.id;
}

// Param is a supported container? -> helper = combo id, idiom = D container type.
// Raw param becomes void* (the container ptr, built by the runtime from native data).
bool containerParam(CXType t, out string helper, out string idiom) {
    auto ck = clang_getCanonicalType(t);
    auto pt = ck.kind == CXType_LValueReference ? clang_getPointeeType(ck) : ck;
    auto id = registerCombo(pt);
    if (!id.length) return false;
    helper = id; idiom = COMBOS[id].idiomD; return true;
}

// Return is a set/assoc container handled by a sret+iterate shim? (seq returns are
// handled pure-D via tryQList; only set/assoc need the by-value+destruct shim.)
bool containerReturn(CXType t, out string helper, out string idiom, out string retStruct) {
    auto ck = clang_getCanonicalType(t);
    auto dn = clang_getCursorSpelling(clang_getTypeDeclaration(ck)).str;
    if (dn != "QSet" && dn != "QHash" && dn != "QMultiHash" && dn != "QMap" && dn != "QMultiMap") return false;
    auto id = registerCombo(ck);
    if (!id.length) return false;
    helper = id; idiom = COMBOS[id].idiomD; retStruct = "Ret_" ~ id; return true;
}

// PySide-style `string` overload for a method with `const QString&` params
// (`w.setText("hi")`): converts each to a scoped QString and calls the raw. ""
// if the method has no such param. `pds` are the raw D param types in order.
// Like strOverload, but generates a struct CONSTRUCTOR `this(string...)` that
// delegates to the raw ctor — so the value type is built idiomatically: X("foo")
// instead of X_new("foo"). (only QString/QByteArray/QAnyStringView; a container ctor is rare.)
string ctorStrOv(string[] pds, ref bool[string] seen) {
    if (!pds.any!(p => p == "ref const(QString)" || p == "ref const(QByteArray)"
        || p == "QAnyStringView")) return "";
    string[] op, pre, ca;
    foreach (i, pd; pds) {
        if (pd == "ref const(QString)") {
            op ~= format("string a%d", i); pre ~= format("        auto _q%d = qstr(a%d);", i, i); ca ~= format("_q%d", i);
        } else if (pd == "ref const(QByteArray)") {
            op ~= format("string a%d", i); pre ~= format("        auto _q%d = qba(a%d);", i, i); ca ~= format("_q%d", i);
        } else if (pd == "QAnyStringView") {
            op ~= format("string a%d", i); pre ~= format("        auto _q%d = QAnyStringView(a%d);", i, i); ca ~= format("_q%d", i);
        } else { op ~= format("%s a%d", pd, i); ca ~= format("a%d", i); }
    }
    auto key = "this|" ~ op.map!(o => o[0 .. o.lastIndexOf(' ')]).join(",");
    if (key in seen) return "";
    seen[key] = true;
    return format("    extern(D) this(%s) {\n%s\n        this(%s);\n    }", op.join(", "), pre.join("\n"), ca.join(", "));
}

string strOverload(string mn, string retD, string kw, string cst, string[] pds, ref bool[string] seen) {
    if (!pds.any!(p => p == "ref const(QString)" || p == "ref const(QByteArray)"
        || p == "QAnyStringView" || p.startsWith("C:"))) return "";
    string[] op, pre, ca;
    foreach (i, pd; pds) {
        if (pd == "ref const(QString)") {
            op  ~= format("string a%d", i);
            pre ~= format("        auto _q%d = qstr(a%d);", i, i);
            ca  ~= format("_q%d", i);
        } else if (pd == "ref const(QByteArray)") {
            op  ~= format("string a%d", i);
            pre ~= format("        auto _q%d = qba(a%d);", i, i);
            ca  ~= format("_q%d", i);
        } else if (pd == "QAnyStringView") {
            op  ~= format("string a%d", i);
            pre ~= format("        auto _q%d = QAnyStringView(a%d);", i, i);
            ca  ~= format("_q%d", i);
        } else if (pd.startsWith("C:")) {       // container param: build via runtime helper
            auto pp = pd[2 .. $].split(":");    // [helper, idiom]
            op  ~= format("%s a%d", pp[1], i);
            pre ~= format("        auto _q%d = %s_from(a%d); scope(exit) %s_del(_q%d);", i, pp[0], i, pp[0], i);
            ca  ~= format("_q%d", i);
        } else { op ~= format("%s a%d", pd, i); ca ~= format("a%d", i); }
    }
    // dedup: an overload on both `const QString&` AND `const QByteArray&` (same other
    // params) would yield two identical `(..., string)` overloads — keep the first.
    auto key = dname(mn) ~ "|" ~ op.map!(o => o[0 .. o.lastIndexOf(' ')]).join(",") ~ "|" ~ cst;
    if (key in seen) return "";
    seen[key] = true;
    auto ret = retD == "void" ? "" : "return ";
    return format("    extern(D) %s%s %s(%s)%s {\n%s\n        %s%s(%s);\n    }",
        kw, retD, dname(mn), op.join(", "), cst, pre.join("\n"), ret, dname(mn), ca.join(", "));
}

// The D primitive a field really is, unwrapping single-member wrapper structs
// (Qt6 stores QSize/QPoint members as QtPrivate::QCheckedInt<int> — layout = int).
string underlyingPrim(CXType t, int depth = 0) {
    if (auto p = canon(t) in PRIM) return *p;
    if (depth > 3) return null;
    auto ck = clang_getCanonicalType(t);
    // wrapper templated on its value type: Qt6 QCheckedInt<int, ...> -> int (the
    // first template arg is the stored value). ONLY if it's layout-compatible (same
    // sizeof) — otherwise std::basic_string<char> would become `char` (it's templated
    // on char, but is 32 bytes: pointer+size+cap). Then the struct would have the wrong size.
    if (clang_Type_getNumTemplateArguments(ck) >= 1) {
        auto ta = clang_Type_getTemplateArgumentAsType(ck, 0);
        if (clang_Type_getSizeOf(ck) == clang_Type_getSizeOf(ta))
            if (auto r = underlyingPrim(ta, depth + 1)) return r;
    }
    // single-field wrapper struct
    auto d = clang_getCursorDefinition(clang_getTypeDeclaration(ck));
    if (d.kind == CXCursor_ClassDecl || d.kind == CXCursor_StructDecl) {
        CXType[] fs;
        foreach (ch; children(d))
            if (ch.kind == CXCursor_FieldDecl) fs ~= clang_getCursorType(ch);
        if (fs.length == 1) return underlyingPrim(fs[0], depth + 1);
    }
    return null;
}

// Source text of an inline method's body ({...}), read straight from the header.
// The translator is deliberately crude (C++ and D share expression syntax); the
// per-module compile check is the safety net.
private string[string] _fileCache;
string bodyText(CXCursor m) {
    import std.file : readText;
    auto d = clang_getCursorDefinition(m);        // in-class decl -> its inline definition
    auto ext = clang_getCursorExtent(d);
    CXFile f; uint l, c, so, eo;
    clang_getFileLocation(clang_getRangeStart(ext), &f, &l, &c, &so);
    clang_getFileLocation(clang_getRangeEnd(ext), &f, &l, &c, &eo);
    auto path = f ? clang_getFileName(f).str : "";
    if (!path.length) return "";
    if (path !in _fileCache) { try { _fileCache[path] = readText(path); } catch (Exception) { _fileCache[path] = ""; } }
    auto src = _fileCache[path];
    if (eo > src.length || so >= eo) return "";
    auto slice = src[so .. eo];
    auto b = slice.indexOf('{');
    return b < 0 ? "" : slice[b .. $].idup;   // "{ ... }"
}

// Does a plain struct with these fields + inline methods compile standalone?
// (No imports/Qt — the translator only needs to be self-consistent.)
bool compileOk(string name, string[] fields, string[] methods) {
    import std.file : write, remove, tempDir; import std.process : execute; import std.path : buildPath;
    auto code = format("struct %s {\n%s\n%s\n}\n", name, fields.join("\n"), methods.join("\n"));
    auto tmp = buildPath(tempDir, "qtd_vfy_" ~ name ~ ".d");
    write(tmp, code);
    scope (exit) remove(tmp);
    return execute(["dmd", "-o-", tmp]).status == 0;   // dmd: type-check only, fast startup (vs ldc2/LLVM)
}

// Keep only the translated inlines that actually compile. Fast path: try them all
// at once; if that fails, fall back to per-method so one bad translation doesn't
// sink the good ones. This is the safety net that lets the translator stay crude.
string[] keepInlines(string name, string[] fields, string[] inlines) {
    if (!inlines.length || compileOk(name, fields, inlines)) return inlines;
    string[] kept;
    foreach (m; inlines) if (compileOk(name, fields, [m])) kept ~= m;
    return kept;
}

// Inline verification: compiling one dmd per class (keepInlines) was the bottleneck
// (~200+ spawns => ~50s). Now it's hybrid, in two phases:
//  1) libdparse IN-PROCESS (no spawn): parse each inline; the ones that don't parse
//     (C++ leakage: `::`, `template<>`, C++ casts...) are the majority and drop out
//     here for free. µs per inline.
//  2) a single `dmd -o-` over the SURVIVORS: catches the SEMANTIC errors (type, symbol)
//     the parser doesn't see. Since phase 1 already removed the syntax errors, dmd
//     doesn't go into recovery/cascade, so one pass with per-(file, line) attribution
//     is enough — each struct is its own bN.d file.
struct InlineJob {
    string name; string[] fields; string[] inlines;
    // Parallel to `inlines` (index-aligned): a trampoline fallback for each inline method.
    // If verifyInlinesBatched DROPS inlines[i] (its D-body references a private member),
    // and forwarders[i] is non-empty, the method is recovered as a qtd_m_ C++ trampoline:
    // the dropped body is replaced by forwarders[i], decls[i] is appended at module scope,
    // and shims[i] is registered in METHODSHIM (ctorCpp emits its C++). Empty = drop as before.
    string[] forwarders; string[] decls; MethodShim[] shims;
}
__gshared InlineJob[] INLINE_JOBS;

// Parse-check in-process via libdparse (syntax only). true = parses clean.
private bool inlineParses(string inline) {
    import dparse.lexer : getTokensForParser, LexerConfig, StringCache;
    import dparse.parser : parseModule, MessageDelegate;
    import dparse.rollback_allocator : RollbackAllocator;
    auto code = "struct S {\n" ~ inline ~ "\n}\n";
    LexerConfig cfg;
    auto cache = new StringCache(StringCache.defaultBucketCount);
    auto toks = getTokensForParser(cast(ubyte[]) code, cfg, cache);
    RollbackAllocator rba;
    uint errs;
    MessageDelegate noop = (string fn, size_t l, size_t c, string m, bool e){};   // silence messages
    parseModule(toks, "c.d", &rba, noop, &errs);
    return errs == 0;
}

void verifyInlinesBatched(string outDir, string dpkg) {
    import std.file : readText, write, mkdirRecurse, rmdirRecurse, exists, tempDir;
    import std.process : execute, thisProcessID; import std.path : buildPath, dirSeparator;
    import std.array : replace; import std.regex : matchAll, regex;
    import std.conv : to;
    if (!INLINE_JOBS.length) return;

    // PHASE 1 — libdparse: keep only the inlines that parse (in-process, no spawn).
    string[][] cur; cur.length = INLINE_JOBS.length;
    bool[size_t] touched;
    foreach (ji, j; INLINE_JOBS)
        foreach (m; j.inlines) { if (inlineParses(m)) cur[ji] ~= m; else touched[ji] = true; }

    // PHASE 2 — dmd over the survivors: remove SEMANTIC errors. Iterates because removing
    // one method can break another that called it (semantic cascade: `last` calls
    // `verify`; if `verify` drops, `last` becomes "undefined verify"). Phase 1 already
    // removed the syntax errors, so it converges in 1-2 passes.
    // Unique per PROCESS: reggae runs several gend processes in parallel, so a shared
    // temp dir would race (one process's rmdirRecurse deletes another's b*.d).
    auto dir = buildPath(tempDir, "qtd_vfy_" ~ thisProcessID.to!string);
    if (dir.exists) rmdirRecurse(dir);
    mkdirRecurse(dir); scope (exit) rmdirRecurse(dir);
    foreach (_iter; 0 .. 32) {
        int[2][][] ranges; ranges.length = INLINE_JOBS.length;
        string[] files;
        foreach (ji, j; INLINE_JOBS) {
            if (!cur[ji].length) continue;
            string content = format("struct %s {\n", j.name);
            int line = 2;
            foreach (f; j.fields) { content ~= f ~ "\n"; line += cast(int) f.count('\n') + 1; }
            int[2][] rr;
            foreach (m; cur[ji]) { auto s = line; content ~= m ~ "\n"; line += cast(int) m.count('\n') + 1; rr ~= [s, line - 1]; }
            content ~= "}\n";
            ranges[ji] = rr;
            auto f = buildPath(dir, format("b%d.d", ji));
            write(f, content); files ~= f;
        }
        if (!files.length) break;
        auto r = execute(["dmd", "-o-", "-verrors=0"] ~ files);
        if (r.status == 0) break;                        // everything compiles -> done
        bool[size_t][size_t] drop;
        foreach (mt; r.output.matchAll(regex(`b(\d+)\.d\((\d+)`))) {
            auto ji = mt[1].to!size_t, ln = mt[2].to!int;
            if (ji >= INLINE_JOBS.length) continue;
            foreach (i, rg; ranges[ji]) if (ln >= rg[0] && ln <= rg[1]) { drop[ji][i] = true; break; }
        }
        if (!drop.length) break;
        foreach (ji, ds; drop) {
            string[] keep;
            foreach (i, m; cur[ji]) if (i !in ds) keep ~= m;
            cur[ji] = keep; touched[ji] = true;
        }
    }

    // rewrite only the modules that lost inlines. A dropped inline whose D-body references
    // private members (e.g. QSizePolicy::bits.horStretch) is NOT lost: it becomes a qtd_m_
    // C++ trampoline (forwarder in the struct + module-level decl + MethodShim -> ctorCpp emits the C++).
    foreach (ji; touched.byKey) {
        auto j = INLINE_JOBS[ji];
        bool[string] kept; foreach (m; cur[ji]) kept[m] = true;
        auto path = buildPath(outDir, dpkg.replace(".", dirSeparator), modBase(j.name) ~ ".d");
        auto content = readText(path);
        string extraDecls;
        foreach (i, m; j.inlines) {
            if (m in kept) continue;                       // survived as a D body -> keep it
            if (i < j.forwarders.length && j.forwarders[i].length) {
                content = content.replace(m, j.forwarders[i]);   // body -> trampoline forwarder
                extraDecls ~= j.decls[i] ~ "\n";
                METHODSHIM ~= j.shims[i];                   // register the C++ shim (ctorCpp emits it)
            } else {
                content = content.replace(m, "");          // no fallback -> drop as before
            }
        }
        if (extraDecls.length) content ~= "\n" ~ extraDecls;
        write(path, content);
    }
}

// Methods declared in any (transitive) base. `names` = the spellings (a derived method
// SHARING a base name shadows the inherited overloads in D — we un-hide them with an
// alias). `sigs` = the full signatures (name+params, via displayName); a derived method
// with an EXACT base signature is a real override that would clash with the inherited
// `final`, so it is skipped and the base decl used.
// `aliasable[name]` + `aliasBase[name]` = the nearest base that declares `name` as an
// emittable method (not pure-virtual/inline/operator, so it has a linkable D symbol) —
// the target for the un-hiding alias.
void baseMethodNames(CXCursor node, ref bool[string] names, ref bool[string] sigs,
                     ref bool[string] aliasable, ref string[string] aliasBase, ref bool[string] seen) {
    foreach (b0; baseDecls(node)) {
        auto b = clang_getCursorDefinition(b0);   // base decl -> its definition (has children)
        auto bn = clang_getCursorSpelling(b).str;
        auto k = clang_getCursorUSR(b).str;
        if (k.length) { if (k in seen) continue; seen[k] = true; }
        foreach (c; children(b))
            if (c.kind == CXCursor_CXXMethod && isPublic(c)) {
                auto sp = clang_getCursorSpelling(c).str;
                names[sp] = true;
                sigs[clang_getCursorDisplayName(c).str] = true;
                if (sp !in aliasable && !clang_CXXMethod_isPureVirtual(c) && !isInline(c)
                        && !sp.startsWith("operator")) {
                    aliasable[sp] = true;
                    aliasBase[sp] = bn;
                }
            }
        baseMethodNames(b, names, sigs, aliasable, aliasBase, seen);
    }
}

// The namespace clause for extern(C++, ...) from a qualified C++ name, or "".
string nsClause(string cppName) {
    auto i = cppName.lastIndexOf("::");
    if (i < 0) return "";
    auto ns = cppName[0 .. i];                       // e.g. "Qt3DCore" or "A::B"
    return `, ` ~ ns.split("::").map!(p => `"` ~ p ~ `"`).join(", ");
}

// Emit the full .d unit for one class. Returns the D source (no .cpp/.h at all).
// `imports` collects sibling module names this unit references.
// A type has a vtable iff it (or any transitive base) declares a virtual method.
// A base alone does NOT imply polymorphism — QMutex : QBasicMutex is a pure value
// hierarchy. Getting this right decides struct (value) vs class (reference) emission.
bool hasVirtualMethods(CXCursor decl) {
    foreach (c; children(decl))
        if ((c.kind == CXCursor_CXXMethod || c.kind == CXCursor_Destructor)
            && clang_CXXMethod_isVirtual(c)) return true;
    foreach (b; baseDecls(decl)) {
        auto bd = clang_getCursorDefinition(b);
        if ((bd.kind == CXCursor_ClassDecl || bd.kind == CXCursor_StructDecl)
            && hasVirtualMethods(bd)) return true;
    }
    return false;
}

// Value-type inheritance: D structs can't inherit, so a non-polymorphic derived
// struct inlines its base(s)' fields first (C++ single-inheritance layout order),
// then its own — preserving sizeof and field offsets. Names are de-duplicated.
void collectValueFields(CXCursor decl, ref string[] fields, ref bool[string] seen) {
    foreach (b; baseDecls(decl)) {
        auto bd = clang_getCursorDefinition(b);
        if (bd.kind == CXCursor_ClassDecl || bd.kind == CXCursor_StructDecl)
            collectValueFields(bd, fields, seen);
    }
    foreach (c; children(decl))
        if (c.kind == CXCursor_FieldDecl) {
            auto fn0 = dname(clang_getCursorSpelling(c).str);
            auto fn = fn0; int k = 1;
            while (fn in seen) fn = format("%s_%d", fn0, ++k);
            seen[fn] = true;
            auto ft = clang_getCursorType(c);
            auto fsz = clang_Type_getSizeOf(ft);
            // constant array field (float v[2]) -> the D fixed array, so inline methods
            // reading v[i] see the real element type, not a reinterpreted byte.
            auto fca = clang_getCanonicalType(ft);
            if (fca.kind == CXType_ConstantArray) {
                auto el = underlyingPrim(clang_getArrayElementType(fca));
                if (el !is null && el != "void") {
                    fields ~= format("    %s[%d] %s;", el, clang_getArraySize(fca), fn);
                    continue;
                }
            }
            auto p = underlyingPrim(ft);
            if (p !is null && p != "void" && fsz > 0)
                fields ~= format("    %s %s%s;", p, fn, paramDefault(c, p));   // keep the C++ DMI
            else if (fsz > 0) fields ~= format("    ubyte[%d] %s;", fsz, fn);
            else fields ~= format("    void* %s;", fn);   // incomplete/opaque -> pointer-width
        }
}

// The operand's value type: strip a leading `ref const(X)` / `ref X` down to X so
// a D operator overload can take it by value (and pass it as an lvalue to the raw).
string paramValueType(string pd) {
    if (pd.startsWith("ref const(") && pd.endsWith(")")) return pd["ref const(".length .. $ - 1];
    if (pd.startsWith("ref ")) return pd["ref ".length .. $];
    return pd;
}

// Map a C++ operator method to a D operator overload that calls the hidden raw
// method `rawName`. Returns "" for operators D can't express this way.
string operatorWrapper(string cxxOp, int nargs, string retD, string rawName, string pv, string cst) {
    auto sym = cxxOp["operator".length .. $];
    enum string[] bin = ["+", "-", "*", "/", "%", "&", "|", "^", "<<", ">>"];
    if (nargs == 1 && bin.canFind(sym))
        return format("    %s opBinary(string op)(%s rhs)%s if (op == \"%s\") { return %s(rhs); }",
            retD, pv, cst, sym, rawName);
    if (nargs == 1 && sym == "==")
        return format("    bool opEquals(%s rhs)%s { return %s(rhs); }", pv, cst, rawName);
    if (nargs == 0 && (sym == "-" || sym == "+" || sym == "~"))
        return format("    %s opUnary(string op)()%s if (op == \"%s\") { return %s(); }", retD, cst, sym, rawName);
    return "";   // comparison (< > need opCmp/int), []/(), assignment, etc. — not yet
}

string emitCxxUnit(CXCursor cur, string name, string cppName, string dpkg,
                   string manifest, out string[] imports) {
    // template classes (QMetaTypeId<T>, ...) can't be bound and their qualified name
    // carries '<' that would break the extern(C++, ns) clause — skip (becomes a stub).
    if (cppName.canFind("<")) throw new Unmappable("template class: " ~ cppName);
    // a class in an anonymous namespace has internal linkage (no cross-TU symbol)
    // and its ns clause would carry "(anonymous namespace)" — unbindable, skip.
    if (cppName.canFind("(anonymous")) throw new Unmappable("anonymous-namespace class: " ~ cppName);
    bool[string] impSet;
    bool[string] seenStrOv;   // dedup string-convert overloads (QString&/QByteArray& collide)
    auto sz = clang_Type_getSizeOf(clang_getCursorType(cur));   // bytes, C++ layout

    // primary base (single-inheritance chain modelled directly; secondary bases
    // would get a pure-D offset accessor — not in this first pass)
    string baseName, baseClause;
    long baseSz = 0;
    auto bases = baseDecls(cur);
    // vtable iff a virtual exists anywhere in the hierarchy — a base alone doesn't
    // imply one (QMutex : QBasicMutex is a pure value hierarchy).
    bool hasVirtual = hasVirtualMethods(cur);
    bool valueType = !hasVirtual;         // no vtable -> a by-value struct
    // Inherit in D ONLY from a polymorphic base (real vtable/class). A non-polymorphic
    // base of a polymorphic class (QTextStream : QIODeviceBase — a pure enum-holder
    // mixin) is dropped: it has no vtable, so this class is the vtable root, and its
    // bytes are absorbed by the size-padding below (ABI size stays correct).
    string[] miMethods;   // as<Base>() upcasts for secondary bases (MI)
    if (bases.length && !valueType) {
        auto b = bases[0];
        auto bdef = clang_getCursorDefinition(b);
        bool basePoly = (bdef.kind == CXCursor_ClassDecl || bdef.kind == CXCursor_StructDecl)
            && hasVirtualMethods(bdef);
        if (basePoly) {
            baseName = clang_getCursorSpelling(b).str;
            baseClause = " : " ~ baseName;
            baseSz = clang_Type_getSizeOf(clang_getCursorType(b));
            impSet[baseName] = true;
            PENDING_BASES[baseName] = bdef;   // must be generated in full
        }
        // Secondary bases: D can't multi-inherit, so reach each polymorphic secondary
        // base via a static_cast offset shim (qtmi) exposed as as<Base>().
        foreach (b2; bases[1 .. $]) {
            auto b2def = clang_getCursorDefinition(b2);
            if ((b2def.kind != CXCursor_ClassDecl && b2def.kind != CXCursor_StructDecl)
                || !hasVirtualMethods(b2def)) continue;   // only polymorphic secondary bases
            auto sbName = clang_getCursorSpelling(b2).str;
            auto sbCpp = clang_getTypeSpelling(clang_getCursorType(b2)).str;
            if (sbCpp.canFind("<")) continue;             // template base -> skip
            impSet[sbName] = true;
            PENDING_BASES[sbName] = b2def;
            impSet["qtmi"] = true;
            MICASTS ~= MICast(name, cppName, sbName, sbCpp);
            miMethods ~= miCastMethod(name, sbName);
        }
    }
    bool[string] baseM, baseSig, baseAliasable, seenB;
    string[string] aliasBase;
    baseMethodNames(cur, baseM, baseSig, baseAliasable, aliasBase, seenB);

    // Subclass trampoline (spec "subclass"): collect the overridable virtuals whose
    // signatures we can marshal, and register a Trampoline emitted into qtvirt.
    if (!valueType && (name in SUBCLASS)) {
        CXCursor[] vs; bool[string] vseen;
        collectVirtuals(cur, vs, vseen);
        TrampVirt[] tvs;
        bool buildable = true;
        foreach (v; vs) {
            auto vn = clang_getCursorSpelling(v).str;
            // moc internals must NOT be overridden; operators aren't methods here.
            if (vn.startsWith("operator") || vn == "metaObject" || vn.startsWith("qt_")) continue;
            TrampVirt tv; bool mapped;
            try mapped = trampVirt(v, cppName, tv); catch (Unmappable) mapped = false;
            if (mapped) tvs ~= tv;
            else if (clang_CXXMethod_isPureVirtual(v) != 0) {
                // an un-overridable pure virtual leaves the trampoline abstract
                // (uninstantiable) — skip the whole class rather than emit broken C++.
                stderr.writefln("subclass %s skipped: pure virtual %s(...) has an unmarshalable signature", name, vn);
                buildable = false; break;
            }
        }
        // A class asked for in `subclass` that yields NO overridable virtual gets no trampoline —
        // and used to get no message either, so it simply was not there when something tried to
        // subclass it (`__<Class>_vnames` undefined, hundreds of lines away). Say so here.
        if (buildable && !tvs.length)
            stderr.writefln("subclass %s skipped: no overridable virtual with a marshalable "
                            ~ "signature — a D subclass of it cannot be generated", name);
        if (buildable && tvs.length) TRAMPS ~= Trampoline(name, cppName, tvs);
    }

    // ---- value type: ONE extern(C++) struct. Fields exposed (unwrapped); out-of-
    // line methods are decls that link to Qt; INLINE methods are re-implemented in
    // D by translating their body text (crude — the compile check keeps the ones
    // that work). Construct via D field literal `QRect(x1, y1, x2, y2)`. ----------
    if (valueType) {
        string[] fields, rawDecls, inlineDefs;
        // Trampoline fallbacks, index-aligned with inlineDefs (see InlineJob): filled for
        // every mappable inline method so verifyInlinesBatched can recover a dropped one.
        string[] inFwd, inDecl; MethodShim[] inShim;
        int vmi;   // qtd_m_<name>_<vmi> shim index for value-type inline trampolines
        bool[string] seenInlineFb;   // dedup fallback D signatures (collapsed inline overloads)
        bool[string] seenF;
        int opIdx;
        collectValueFields(cur, fields, seenF);   // base fields flattened in first (layout order)
        // A value type whose ONLY data member is an anonymous union / bitfield struct
        // (e.g. QSizePolicy's `union { Bits bits; quint32 data; }`) yields NO nameable
        // field — libclang reports the union instance as an implicit, empty-named FieldDecl
        // that collectValueFields can't emit. The D struct would then be size 0 and any
        // (now-trampolined) setter would scribble past it. Give it a correctly-aligned blob
        // matching the C++ size so pass-by-value and the setters stay in-bounds.
        if (fields.length == 0) {
            auto ct = clang_getCursorType(cur);
            auto vsz = clang_Type_getSizeOf(ct), val = clang_Type_getAlignOf(ct);
            if (vsz > 0) fields ~= format("    align(%d) ubyte[%d] __data;", val > 0 ? val : 1, vsz);
        }
        foreach (c; children(cur)) {
            if (!isPublic(c) || c.kind != CXCursor_CXXMethod) continue;
            auto mn = clang_getCursorSpelling(c).str;
            if (mn in baseM) continue;
            bool isOp = mn.startsWith("operator");
            if (isOp && isInline(c)) continue;   // inline operator -> no symbol (TODO: translate)
            try {
                string imp; auto retD = mapCxxType(clang_getCursorResultType(c), imp);
                if (imp.length) impSet[imp] = true;
                auto na = clang_Cursor_getNumArguments(c);
                auto cst = clang_CXXMethod_isConst(c) ? " const" : "";
                auto kw = clang_CXXMethod_isStatic(c) ? "static " : "";
                if (isInline(c)) {
                    auto b = bodyText(c);
                    if (!b.length) continue;
                    // A function-LOCAL return type (e.g. QChar::fromUcs4's local `struct R`)
                    // can't be named in a shim decl; its bogus D body was always dropped by
                    // verify anyway -> skip the whole method (no D body, no trampoline).
                    {
                        auto rp = clang_getCursorSemanticParent(
                            clang_getTypeDeclaration(clang_getCanonicalType(clang_getCursorResultType(c))));
                        if (rp.kind == CXCursor_FunctionDecl || rp.kind == CXCursor_CXXMethod) continue;
                    }
                    string[] ps, fps, cppPs, anames;   // ps: D-body params (real names); fps: forwarder params (a0..)
                    bool fbOk = !isOp && !retD.startsWith("ref ");   // ref returns: keep D-body-only (no trampoline)
                    // A fn-ptr RETURN is equally unspellable in the shim: `void (*)(int) f(void*)`
                    // is invalid C++ (the name must sit INSIDE the parens). Keep it D-body-only.
                    if (clang_getTypeSpelling(clang_getCanonicalType(clang_getCursorResultType(c))).str.canFind("(*"))
                        fbOk = false;
                    foreach (i; 0 .. na) {
                        auto a = clang_Cursor_getArgument(c, i);
                        string pimp; auto pd = mapCxxType(clang_getCursorType(a), pimp);
                        if (pimp.length) impSet[pimp] = true;
                        auto pn = clang_getCursorSpelling(a).str; if (!pn.length) pn = format("a%d", i);
                        ps ~= format("%s %s", pd, dname(pn));   // real names -> body refers to them
                        auto cpps = clang_getTypeSpelling(clang_getCanonicalType(clang_getCursorType(a))).str;
                        if (cpps.canFind("(*")) fbOk = false;   // fn-ptr param: shim C++ decl needs the name in-parens
                        cppPs ~= format("%s a%d", cpps, i);
                        fps ~= format("%s a%d", pd, i);
                        anames ~= format("a%d", i);
                    }
                    inlineDefs ~= format("    %s%s %s(%s)%s %s", kw, retD, dname(mn), ps.join(", "), cst, b);
                    // Precompute the trampoline fallback (activated only if this body is dropped).
                    // Skip if the D name collides with a field (e.g. QArrayData: field `ref_` +
                    // method `ref()`), or if a prior inline collapsed to the same D signature.
                    auto fbSig = format("%s|%s|%s%s", dname(mn), fps.join(","),
                        clang_CXXMethod_isStatic(c) ? "s" : "", cst);
                    if (dname(mn) in seenF || fbSig in seenInlineFb) fbOk = false;
                    if (fbOk) {
                        seenInlineFb[fbSig] = true;
                        bool isStat = clang_CXXMethod_isStatic(c) != 0;
                        bool isCst0 = clang_CXXMethod_isConst(c) != 0;
                        auto shimFn = format("qtd_m_%s_%d", name, vmi++);
                        auto cppRet = retD == "void" ? "void"
                            : clang_getTypeSpelling(clang_getCanonicalType(clang_getCursorResultType(c))).str;
                        auto self = isStat ? "" : "cast(void*)&this";
                        auto callList = self ~ ((self.length && anames.length) ? ", " : "") ~ anames.join(", ");
                        auto ret = retD == "void" ? "" : "return ";
                        inFwd ~= format("    %s%s %s(%s)%s { %s%s(%s); }",
                            kw, retD, dname(mn), fps.join(", "), cst, ret, shimFn, callList);
                        auto declSelf = isStat ? "" : (fps.length ? "void* self, " : "void* self");
                        inDecl ~= format("extern(C) private %s %s(%s%s);",
                            retD, shimFn, declSelf, fps.join(", "));
                        inShim ~= MethodShim(shimFn, cppName, cppRet, mn, cppPs, anames, isStat, isCst0);
                    } else {
                        inFwd ~= ""; inDecl ~= ""; inShim ~= MethodShim.init;
                    }
                } else {
                    string[] ps, pds;
                    foreach (i; 0 .. na) {
                        auto a = clang_Cursor_getArgument(c, i);
                        string pimp; auto pd = mapCxxType(clang_getCursorType(a), pimp);
                        if (pimp.length) impSet[pimp] = true;
                        ps ~= format("%s a%d", pd, i);
                        pds ~= pd;
                    }
                    auto mg = clang_Cursor_getMangling(c).str;
                    if (isOp) {   // operator -> hidden raw + a D operator overload
                        auto pv = na == 1 ? paramValueType(pds[0]) : "";
                        auto rawNm = format("__op%d", opIdx);
                        auto opw = operatorWrapper(mn, cast(int) na, retD, rawNm, pv, cst);
                        if (!opw.length) continue;   // operator D can't express -> skip
                        rawDecls ~= format("    private pragma(mangle, \"%s\") %s%s %s(%s)%s;",
                            mg, kw, retD, rawNm, ps.join(", "), cst);
                        rawDecls ~= opw;
                        opIdx++;
                        continue;
                    }
                    rawDecls ~= format("    pragma(mangle, \"%s\") %s%s %s(%s)%s;",
                        mg, kw, retD, dname(mn), ps.join(", "), cst);
                    auto ov = strOverload(mn, retD, kw, cst, pds, seenStrOv);
                    if (ov.length) rawDecls ~= ov;
                }
            } catch (Unmappable) { recordSym(cppName, clang_getCursorSpelling(c).str, "unmapped-type", c); }
        }
        // Inline verification deferred to a single batch at the end (verifyInlinesBatched)
        // — compiling one ldc2 per class here was the generation bottleneck.
        if (inlineDefs.length)
            INLINE_JOBS ~= InlineJob(name, fields.dup, inlineDefs.dup, inFwd.dup, inDecl.dup, inShim.dup);
        // Value-type ctor factories: a value type with a non-trivial (out-of-line)
        // ctor (QFont/QPen/QIcon...) can't be built by a field literal. Emit a
        // `<Name>_new(...)` that constructs in place via the mangled ctor.
        string[] ctorFactories;     // free-functions <Name>_new (compat + no-arg)
        string[] ctorMethods;       // this(args) constructors INSIDE the struct (idiomatic)
        bool[string] seenCtorSig;   // dedup: distinct C++ ctors can collapse into the
        int vci;                    // same D signature (e.g. QPaintDevice* vs const*)
        // A D struct with ANY constructor loses the positional struct-literal. If the
        // value type's own inlines build it by literal (e.g. QTime(msecs) sets the
        // field), we do NOT emit this() — it would keep the literal broken. Then only _new remains.
        bool selfLiteral = inlineDefs.any!(d => d.canFind(name ~ "("));
        foreach (c; children(cur)) {
            if (!isPublic(c) || c.kind != CXCursor_Constructor) continue;
            if (clang_CXXConstructor_isCopyConstructor(c) || clang_CXXConstructor_isMoveConstructor(c)) continue;
            if (clang_CXXMethod_isDeleted(c)) continue;   // `= delete` ctor -> not constructible
            // Inline/`= default` ctor -> no symbol. Instead of skipping, emit an out-of-line
            // C++ shim (gap 1) — but only if the params are ABI-simple (scalars/pointers).
            bool viaShim = isInline(c);
            try {
                string[] rps, fps, pds, ca, cppPs;
                bool allDeflt = true;   // all params defaulted? -> don't emit this() (would be struct this())
                bool allSimple = true;
                auto na = clang_Cursor_getNumArguments(c);
                foreach (i; 0 .. na) {
                    auto a = clang_Cursor_getArgument(c, i);
                    string pimp; auto pd = mapCxxType(clang_getCursorType(a), pimp);
                    if (pimp.length) impSet[pimp] = true;
                    if (!simpleAbiType(pd)) allSimple = false;
                    // canonical spelling -> nested param types come out fully qualified
                    auto _cpps = clang_getTypeSpelling(clang_getCanonicalType(clang_getCursorType(a))).str;
                    if (_cpps.canFind("(*")) allSimple = false;   // fn-ptr param: shim C++ decl needs the name inside the parens
                    cppPs ~= format("%s a%d", _cpps, i);
                    rps ~= format("%s a%d", pd, i);
                    string deflt;
                    if (hasDefault(a)) {
                        deflt = paramDefault(a, pd);
                        if (!deflt.length && !pd.startsWith("ref ")) deflt = format(" = %s.init", pd);
                    } else allDeflt = false;
                    fps ~= format("%s a%d%s", pd, i, deflt);
                    pds ~= pd; ca ~= format("a%d", i);
                }
                if (viaShim && (!allSimple || nestedInaccessible(cur))) continue;   // still a gap
                auto sigKey = pds.join(",");   // same D signature -> redefinition; keep only the 1st
                if (sigKey in seenCtorSig) continue;
                seenCtorSig[sigKey] = true;
                auto rawNm = format("__ctor_%s_%d", name, vci);
                if (viaShim) {
                    auto shimFn = format("qtd_new_%s_%d", name, vci);
                    CTORSHIM ~= CtorShim(name, cppName, shimFn, cppPs, ca);
                    ctorFactories ~= format("extern(C) private void %s(%s* self%s);",
                        shimFn, name, rps.length ? ", " ~ rps.join(", ") : "");
                    rawNm = shimFn;
                } else {
                auto mg = clang_Cursor_getMangling(c).str;
                ctorFactories ~= format("private pragma(mangle, \"%s\") extern(C++) void %s(%s* self%s);",
                    mg, rawNm, name, rps.length ? ", " ~ rps.join(", ") : "");
                }
                // Factory reached via `make!T(args)` (cxxrt.make -> T.__make). JUSTIFIED only
                // because a struct can't have a no-arg this() and a CoW type's `.init` is a null
                // d-pointer; parameterized value types should prefer the plain `T(args)` ctor below.
                ctorMethods ~= format("    static %s __make(%s) {\n        %s r = void;\n        %s(&r%s);\n        return r;\n    }",
                    name, fps.join(", "), name, rawNm, ca.length ? ", " ~ ca.join(", ") : "");
                auto ov = strOverload("__make", name, "static ", "", pds, seenStrOv);
                if (ov.length) ctorMethods ~= ov;
                // Idiomatic this(args) ctor INSIDE the struct: X("foo") instead of
                // X_new("foo"). Parameterized only (D forbids this() with no args).
                if (na > 0 && !allDeflt && !selfLiteral) {   // !allDeflt: all-default this() is illegal for a struct
                    // extern(D): otherwise an extern(C++) struct's ctor auto-mangles to
                    // the C++ ctor symbol and collides with the raw __ctor (same mangle).
                    ctorMethods ~= format("    extern(D) this(%s) { %s(&this%s); }",
                        fps.join(", "), rawNm, ca.length ? ", " ~ ca.join(", ") : "");
                    auto ovc = ctorStrOv(pds, seenStrOv);
                    if (ovc.length) ctorMethods ~= ovc;
                }
                vci++;
            } catch (Unmappable) { recordSym(cppName, clang_getCursorSpelling(c).str, "unmapped-type", c); }
        }
        // Deep copy: a non-POD value type (std::string/CoW/... by value) can't be
        // copied bitwise — the SSO self-pointer / the CoW refcount break. We emit a
        // copy constructor + ~this() that call the out-of-line C++ shim (qtdctor),
        // which runs the REAL C++ copy-ctor/dtor. Skip if the copy is deleted
        // (DISABLE_COPY): the current bitwise behavior stays.
        bool needsDeepCopy = nonTriviallyCopyable(clang_getCursorType(cur)) && !copyDeleted(cur);
        if (needsDeepCopy) {
            CTORCOPY ~= CtorCopy(name, cppName);
            // extern(C) decls at MODULE scope (on a static member extern(C) doesn't take
            // C linkage — the name comes out D-mangled); copy-ctor/~this() in the struct.
            // nothrow: C++ copy-ctors/dtors of Qt value types are noexcept, and the ~this
            // is called from nothrow contexts (signal trampolines take such types by value).
            ctorFactories ~= format(
                "extern(C) private void qtd_cctor_%s(void*, const(void)*) nothrow;\n"
                ~ "extern(C) private void qtd_dtor_%s(void*) nothrow;", name, name);
            inlineDefs ~= format(
                "    extern(D) this(ref const(%s) rhs) nothrow { qtd_cctor_%s(cast(void*)&this, cast(const(void)*)&rhs); }\n"
                ~ "    extern(D) ~this() nothrow { qtd_dtor_%s(cast(void*)&this); }",
                name, name, name);
        }
        auto rng = rangeFor(cur, name, impSet);   // begin()/end() -> a D range (foreach x; t[])
        if (rng.length) { inlineDefs ~= rng[1]; ctorFactories ~= rng[2] ~ "\n" ~ rng[0]; }
        impSet.remove(name);
        imports = impSet.byKey.array.sort.array;
        auto impLines = imports.map!(m => format("import %s.%s;", dpkg, modBase(m))).join("\n");
        auto bodyV = (nestedEnumLines(cur) ~ fields ~ rawDecls ~ inlineDefs ~ ctorMethods).join("\n");
        return format("%s\nmodule %s.%s;\n%s\n\nextern (C++%s) struct %s {\n%s\n}\n%s\n",
            manifest, dpkg, modBase(name), impLines, nsClause(cppName), name, bodyV,
            ctorFactories.join("\n"));
    }

    // ---- WRAPPER mode: a GC wrapper class extending holder.QtdObject that holds a
    // nullable _cpp and delegates to C++ via module-level pragma(mangle) decls taking an
    // explicit `void* self`. Object params are unwrapped (a.ptr()), object returns wrapped
    // (T.wrap(r)). Signals/containers/MI/trampolines are added in later steps (skipped here).
    if (WRAPPER) {
        auto wbase = baseName.length ? baseName : "QtdObject";
        string[] wm;      // wrapper class methods
        string[] wctors;  // idiomatic `this(args)` constructors -> `new QWidget(parent)`
        string[] wd;      // module-scope decls (pragma(mangle) members, enum size, ctor factories)
        bool[string] seenW, seenSigW;
        int[string] sigNameCountW, allNameCountW;
        foreach (c; children(cur))
            if (c.kind == CXCursor_CXXMethod) {
                auto nm = clang_getCursorSpelling(c).str;
                allNameCountW[nm]++;
                if (isSignal(c)) sigNameCountW[nm]++;
            }
        int wi;
        // one method: build the module-level self-taking decl + the delegating wrapper method
        void emitWrapMethod(CXCursor c) {
            auto mn = clang_getCursorSpelling(c).str;
            // qt_* are MOC/Q_GADGET internals (qt_metacast, qt_metacall,
            // qt_check_for_QGADGET_macro) — never user-callable, and some reference
            // symbols Qt doesn't export (ldc dead-strips them; dmd whole-program breaks).
            if (mn.startsWith("operator") || mn.startsWith("qt_") || mn in baseM) return;
            // Qt signal -> a connect<Signal>(delegate) method (object args wrapped by the tramp).
            if (isSignal(c)) {
                if (sigNameCountW.get(mn, 0) == 1 && allNameCountW.get(mn, 0) == 1 && mn !in seenSigW) {
                    Signal s; s.dClass = name; s.cppClass = cppName; s.name = mn;
                    bool ok = true;
                    auto nas = clang_Cursor_getNumArguments(c);
                    foreach (i; 0 .. nas) {
                        auto at = clang_getCursorType(clang_Cursor_getArgument(c, i));
                        if (canon(at).canFind("QPrivateSignal")) continue;
                        try { if (!signalArg(at, cast(int) i, s)) { ok = false; break; } }
                        catch (Unmappable) { ok = false; break; }
                    }
                    if (ok) {
                        seenSigW[mn] = true; SIGNALS ~= s; impSet["qtsignals"] = true;
                        foreach (im; s.imports) impSet[im] = true;
                        wm ~= signalConnectMethod(s);
                    }
                }
                return;
            }
            if (clang_CXXMethod_isPureVirtual(c)) { hasVirtual = true; return; }
            bool inl = isInline(c);   // no symbol -> a qtd_m_ C++ trampoline shim (self->method)
            auto rrt = clang_getCursorResultType(c);
            string _a, _b, _cc;
            if (containerReturn(rrt, _a, _b, _cc)) return;   // QHash/QMap: later step
            auto qtidR = inl ? "" : tryQList(rrt);   // QList<T> return -> T[]; inline QList has no symbol -> skip
            if (qtidR.length) {
                auto kw2 = clang_CXXMethod_isStatic(c) ? "static " : "final ";
                auto cst2 = clang_CXXMethod_isConst(c) ? " const" : "";
                auto pr = emitQListReturn(c, mn, qtidR, kw2, cst2, impSet, dpkg);
                if (pr.length) { wd ~= pr[0]; wm ~= pr[1]; }   // raw -> module scope, idiom -> class
                return;
            }
            try {
                bool isStat = clang_CXXMethod_isStatic(c) != 0;
                string imp; auto retD = mapCxxType(rrt, imp); if (imp.length) impSet[imp] = true;
                auto retW = wrapperTypeOf(rrt);
                string[] wps, declps, callargs, wrapArgs, cppPs, anames;
                auto na = clang_Cursor_getNumArguments(c);
                foreach (i; 0 .. na) {
                    auto a = clang_Cursor_getArgument(c, i);
                    string helper, idiom;
                    if (containerParam(clang_getCursorType(a), helper, idiom)) return;   // later step
                    string pimp; auto pd = mapCxxType(clang_getCursorType(a), pimp);
                    if (pimp.length) impSet[pimp] = true;
                    auto pw = wrapperTypeOf(clang_getCursorType(a));
                    auto cpps = clang_getTypeSpelling(clang_getCanonicalType(clang_getCursorType(a))).str;
                    if (inl && cpps.canFind("(*")) return;   // fn-ptr param can't be a shim decl
                    wps ~= format("%s a%d", pd, i);
                    declps ~= format("%s a%d", pw.length ? "void*" : pd, i);
                    cppPs ~= format("%s a%d", cpps, i);
                    anames ~= format("a%d", i);
                    callargs ~= pw.length ? format("(a%d is null ? null : a%d.ptr())", i, i) : format("a%d", i);
                    if (pw.length) wrapArgs ~= format("a%d", i);
                }
                if (inl && nestedInaccessible(cur)) return;
                auto key = dname(mn) ~ "|" ~ wps.join(",") ~ "|" ~ (isStat ? "s" : "");
                if (key in seenW) return;
                seenW[key] = true;
                bool isConst0 = clang_CXXMethod_isConst(c) != 0;
                auto declRet = retW.length ? "void*" : retD;
                auto callFn = format(inl ? "qtd_m_%s_%d" : "__%s_%d", name, wi);
                auto declSelf = isStat ? "" : (declps.length ? "void* self, " : "void* self");
                if (inl) {
                    auto cppRet = retW.length ? clang_getTypeSpelling(clang_getCanonicalType(rrt)).str
                        : retD == "void" ? "void" : clang_getTypeSpelling(clang_getCanonicalType(rrt)).str;
                    METHODSHIM ~= MethodShim(callFn, cppName, cppRet, mn, cppPs, anames, isStat, isConst0);
                    wd ~= format("extern(C) private %s %s(%s%s);", declRet, callFn, declSelf, declps.join(", "));
                } else
                    wd ~= format("private pragma(mangle, \"%s\") extern(C++) %s %s(%s%s);",
                        clang_Cursor_getMangling(c).str, declRet, callFn, declSelf, declps.join(", "));
                auto self = isStat ? "" : (callargs.length ? "this.ptr(), " : "this.ptr()");
                auto callE = format("%s(%s%s)", callFn, self, callargs.join(", "));
                auto kw = isStat ? "static " : "final ";
                // A non-const method may re-parent `this` or an object arg (setParent, a layout
                // add/remove, ...). Re-check their pins after the call: gained a parent -> pin,
                // lost it -> unpin (so an unparented, unheld child becomes GC-collectable).
                bool isConst = clang_CXXMethod_isConst(c) != 0;
                string[] reck;
                if (!isConst) {
                    if (!isStat) reck ~= "holder.reparented(this);";
                    foreach (wa; wrapArgs) reck ~= format("holder.reparented(%s);", wa);
                }
                string body_;
                // ref returns are accessors that don't reparent -> keep the one-liner (a
                // local + `return _r` would escape a reference to the local anyway).
                if (reck.length && !retD.startsWith("ref ")) {   // multi-statement: call, re-check, return
                    auto pre = retD == "void" ? format("%s;", callE) : format("auto _r = %s;", callE);
                    auto ret = retD == "void" ? "" : (retW.length ? format(" return %s.wrap(_r);", retW) : " return _r;");
                    body_ = pre ~ " " ~ reck.join(" ") ~ ret;
                } else {
                    body_ = retD == "void" ? format("%s;", callE)
                        : retW.length ? format("return %s.wrap(%s);", retW, callE) : format("return %s;", callE);
                }
                wm ~= format("    %s%s %s(%s) { %s }", kw, retD, dname(mn), wps.join(", "), body_);
                wi++;
            } catch (Unmappable) { recordSym(cppName, clang_getCursorSpelling(c).str, "unmapped-type", c); }
        }
        // one constructor: a _new factory that heap-allocates, runs the C++ ctor, and wraps.
        int wci; bool[string] seenCW;
        bool abstractW = clang_CXXRecord_isAbstract(cur) != 0;
        void emitWrapCtor(CXCursor c) {
            if (clang_CXXMethod_isDeleted(c)) return;
            bool viaShim = isInline(c);
            try {
                string[] dparams, declps, callargs, cppPs, anames; bool allSimple = true;
                auto na = clang_Cursor_getNumArguments(c);
                foreach (i; 0 .. na) {
                    auto a = clang_Cursor_getArgument(c, i);
                    string pimp; auto pd = mapCxxType(clang_getCursorType(a), pimp);
                    if (pimp.length) impSet[pimp] = true;
                    auto pw = wrapperTypeOf(clang_getCursorType(a));
                    if (!simpleAbiType(pd) && pw.length == 0) allSimple = false;
                    auto cpps = clang_getTypeSpelling(clang_getCanonicalType(clang_getCursorType(a))).str;
                    if (cpps.canFind("(*")) allSimple = false;
                    cppPs ~= format("%s a%d", cpps, i);
                    anames ~= format("a%d", i);
                    declps ~= format("%s a%d", pw.length ? "void*" : pd, i);
                    string deflt = pw.length ? " = null" : (hasDefault(a) && !pd.startsWith("ref ") ? paramDefault(a, pd) : "");
                    if (!deflt.length && !pd.startsWith("ref ") && hasDefault(a)) deflt = format(" = %s.init", pd);
                    dparams ~= format("%s a%d%s", pd, i, deflt);
                    callargs ~= pw.length ? format("(a%d is null ? null : a%d.ptr())", i, i) : format("a%d", i);
                }
                if (viaShim && (!allSimple || nestedInaccessible(cur))) return;
                auto sk = declps.map!(p => p.split(" ")[0]).join(",");
                if (sk in seenCW) return; seenCW[sk] = true;
                string ctorFn;
                if (viaShim) {
                    ctorFn = format("qtd_new_%s_%d", name, wci);
                    CTORSHIM ~= CtorShim(name, cppName, ctorFn, cppPs, anames);
                    wd ~= format("extern(C) private void %s(void* self%s);", ctorFn,
                        declps.length ? ", " ~ declps.join(", ") : "");
                } else {
                    ctorFn = format("__ctor_%s_%d", name, wci);
                    wd ~= format("private pragma(mangle, \"%s\") extern(C++) void %s(void* self%s);",
                        clang_Cursor_getMangling(c).str, ctorFn, declps.length ? ", " ~ declps.join(", ") : "");
                }
                // Idiomatic `new QWidget(parent)`: the wrapper is a GC class, so `new` allocates
                // the wrapper; the ctor heap-allocates the C++ object (__cpp_new), runs its C++
                // ctor, delegates to the adopt ctor `this(void* c)` (sets _cpp up the base chain),
                // then _register()s for identity + destroyed()-tracking + parent-pin. Safe because
                // the C++ object is C++-heap-owned (Qt deletes it) while the GC owns only the small
                // wrapper. `this(void* c)` (the wrap adopt ctor) stays distinct by param type.
                wctors ~= format("    this(%s) {\n        auto __r = __cpp_new(__%s_size);\n"
                    ~ "        %s(__r%s);\n        this(__r);\n        _register();\n    }",
                    dparams.join(", "), name, ctorFn,
                    callargs.length ? ", " ~ callargs.join(", ") : "");
                wci++;
            } catch (Unmappable) { recordSym(cppName, clang_getCursorSpelling(c).str, "unmapped-type", c); }
        }
        foreach (c; children(cur))
            if (isPublic(c) && c.kind == CXCursor_CXXMethod) emitWrapMethod(c);
        if (!abstractW) foreach (c; children(cur))
            if (isPublic(c) && c.kind == CXCursor_Constructor
                && !clang_CXXConstructor_isCopyConstructor(c) && !clang_CXXConstructor_isMoveConstructor(c))
                emitWrapCtor(c);
        impSet.remove(name);
        imports = impSet.byKey.array.sort.array;
        auto impLines = "import holder;\nimport cxxrt;\n"
            ~ imports.map!(m => format("import %s.%s;", dpkg, modBase(m))).join("\n");
        // isQObject is constant per wrapper hierarchy -> set at the base-less root; derived
        // just super(c). Non-QObjects (no destroyed()/parent()) are dispose-only in the holder.
        // isQObject walks BASES for QObject, so QObject itself reports false — include it.
        auto ctorSuper = baseName.length ? "super(c)"
            : format("super(c, %s)", (isQObject(cur) || name == "QObject") ? "true" : "false");
        auto ctorBody = format("    this(void* c) @nogc nothrow { %s; }\n"
            ~ "    static %s wrap(void* c) { return cast(%s) holder.wrap(c, (void* p) => cast(QtdObject) new %s(p)); }",
            ctorSuper, name, name, name);
        auto body_ = ([ctorBody] ~ wctors ~ nestedEnumLines(cur) ~ wm ~ miMethods).join("\n");
        return format("%s\nmodule %s.%s;\n%s\n\nenum __%s_size = %d;\nclass %s : %s {\n%s\n}\n\n%s\n",
            manifest, dpkg, modBase(name), impLines, name, clang_Type_getSizeOf(clang_getCursorType(cur)),
            name, wbase, body_, wd.join("\n"));
    }

    string[] methodLines;
    string[] shimDecls;     // module-scope extern(C) decls for inline-method trampolines
    int guardRawIdx;        // per-class counter for __raw_<name>_<i> symbol-address decls
    bool[string] guardDeclsEmitted;   // per-module dedup of the shared guards' extern(C) decls
    bool[string] seenGuardSig;        // guard forwarders are DEFINITIONS -> dedup by D signature
                                      // (pragma(mangle) DECLs may share a sig; definitions can't)
    bool[string] aliasNames;   // base names we shadow with a new overload -> re-alias to un-hide
    bool[string] seenMethodShimSig;   // dedupe inline overloads that collapse to one D sig
    bool[string] seenSig;   // dedupe overloaded signals (one connect<Sig> per name)
    int[string] sigNameCount, allNameCount;
    foreach (c; children(cur))
        if (c.kind == CXCursor_CXXMethod) {
            auto nm = clang_getCursorSpelling(c).str;
            allNameCount[nm]++;                          // &Class::nm is ambiguous if nm collides
            if (isSignal(c)) sigNameCount[nm]++;         // with ANY other method (e.g. QProcess::error)
        }
    CXCursor[] ctors;
    foreach (c; children(cur)) {
        if (!isPublic(c)) continue;
        if (c.kind == CXCursor_Constructor) {
            if (clang_CXXConstructor_isCopyConstructor(c) || clang_CXXConstructor_isMoveConstructor(c))
                continue;
            ctors ~= c;
            continue;
        }
        if (c.kind != CXCursor_CXXMethod) continue;
        auto mn = clang_getCursorSpelling(c).str;
        if (mn.startsWith("operator")) continue;
        // Q_GADGET/Q_OBJECT emit `static void qt_check_for_QGADGET_macro()` — DECLARED but
        // never DEFINED (a compile-time check helper). A plain decl was harmless, but the
        // guard forwarder takes `&__raw` (its address) -> forces a reference to a symbol that
        // doesn't exist in the Qt lib -> link error (surfaces on dmd's whole-program link).
        if (mn == "qt_check_for_QGADGET_macro") continue;
        // Per-symbol coverage manifest: one row per method, its fate filled in below and written
        // on every exit path (signal/inherited/shim/bound/unmapped) via scope(exit).
        string _fate = "bound";
        scope(exit) recordSym(cppName, mn, _fate, c);
        // Qt signal -> a connect<Signal>(delegate) method (via a gen-phase functor
        // shim), NOT a callable binding. Non-overloaded; args marshaled to the delegate.
        if (isSignal(c)) {
            // A signal REDECLARED in this subclass (e.g. QQuickMouseArea shadowing QQuickItem's
            // `enabled` -> its own `enabledChanged`) already has a `final connect<Signal>` on the
            // base; re-emitting it here would illegally override that final method. Use the base's.
            if ((mn in baseM) !is null) { _fate = "inherited"; continue; }
            _fate = "signal";
            if (sigNameCount.get(mn, 0) == 1 && allNameCount.get(mn, 0) == 1 && mn !in seenSig) {
                Signal s; s.dClass = name; s.cppClass = cppName; s.name = mn;
                bool ok = true;
                auto na = clang_Cursor_getNumArguments(c);
                foreach (i; 0 .. na) {
                    auto at = clang_getCursorType(clang_Cursor_getArgument(c, i));
                    if (canon(at).canFind("QPrivateSignal")) continue;   // Qt's marker arg
                    try { if (!signalArg(at, cast(int) i, s)) { ok = false; break; } }
                    catch (Unmappable) { ok = false; break; }
                }
                if (ok) {
                    seenSig[mn] = true;
                    SIGNALS ~= s;
                    impSet["qtsignals"] = true;
                    foreach (im; s.imports) impSet[im] = true;
                    methodLines ~= signalConnectMethod(s);
                }
            }
            continue;                                 // never emit a signal as a plain method
        }
        // A virtual redeclaration of a base name is a real override (clashes with the
        // inherited `final`); an exact-signature match is a redeclaration — both use the
        // base decl. A method merely SHARING a base name is a NEW overload: emit it, and
        // re-alias the base's (emittable) overloads it would otherwise hide in D.
        if ((clang_CXXMethod_isVirtual(c) != 0 && (mn in baseM) !is null)
                || (clang_getCursorDisplayName(c).str in baseSig)) { _fate = "inherited"; continue; }
        if ((mn in baseM) !is null && (mn in baseAliasable) !is null) {
            aliasNames[mn] = true;
            impSet[aliasBase[mn]] = true;   // the aliased base type must be imported
        }
        if (clang_CXXMethod_isPureVirtual(c)) { hasVirtual = true; _fate = "pure-virtual"; continue; }
        // Route through a C++ trampoline shim (`static_cast<Class*>(self)->method(args)`) in TWO
        // cases:
        //   (1) INLINE methods — no out-of-line symbol exists to pragma(mangle), so we must call
        //       through C++. Return must be ABI-simple (value-by-value returns need sret we don't
        //       do here), but PARAMS can be anything mapCxxType handles: the shim takes them by
        //       canonical C++ type (const QString&, QWidget*, …); extern "C" allows C++ ref/ptr.
        //   (2) VIRTUAL (non-static) methods — a direct pragma(mangle) call binds the DECLARING
        //       class's symbol NON-virtually, so an OVERRIDE in a subclass is silently bypassed
        //       (e.g. QBoxLayout::setSpacing overrides QLayout::setSpacing; calling QLayout's
        //       symbol writes the wrong storage). The shim's `self->method()` is a real C++ virtual
        //       call, so the correct override runs even when reached via the base class's method.
        // The shim body is exception-wrapped identically to the guard (Lippincott). A virtual with
        // a NON-simple signature (value/container/QList return, fn-ptr) can't use the shim, so it
        // falls through to the direct guard path below — bound, but non-virtually (a known gap).
        bool viaShim = isInline(c)
            || (clang_CXXMethod_isVirtual(c) != 0 && clang_CXXMethod_isStatic(c) == 0);
        if (viaShim) {
            bool handled = false;   // emitted, or deliberately skipped -> `continue` (don't fall through)
            try {
                string imp; auto retD = mapCxxType(clang_getCursorResultType(c), imp);
                // A VALUE-record return (QSize/QRect/…) is fine: the C++ shim returns it by value
                // (sret) and the extern(C) D decl matches that ABI — exactly what the guard path
                // already does, so we just gain virtual dispatch. The only returns the shim can't
                // take are the ones with SPECIALISED guard-path emission (container -> V[K],
                // QList -> T[]) or an unspellable shim return type (fn-ptr); those fall through.
                string _ch, _cid, _crs;
                auto _cppRetCanon = clang_getTypeSpelling(clang_getCanonicalType(clang_getCursorResultType(c))).str;
                bool simpleRet = !_cppRetCanon.canFind("(*")
                    && !containerReturn(clang_getCursorResultType(c), _ch, _cid, _crs)
                    && tryQList(clang_getCursorResultType(c)).length == 0;
                bool isStat = clang_CXXMethod_isStatic(c) != 0;
                string[] rps, ca, cppPs; bool okParams = true;
                auto na = clang_Cursor_getNumArguments(c);
                foreach (i; 0 .. na) {
                    auto a = clang_Cursor_getArgument(c, i);
                    string pimp; auto pd = mapCxxType(clang_getCursorType(a), pimp);
                    if (pimp.length) impSet[pimp] = true;
                    auto _cpps = clang_getTypeSpelling(clang_getCanonicalType(clang_getCursorType(a))).str;
                    if (_cpps.canFind("(*")) okParams = false;   // fn-ptr param: shim C++ decl needs the name inside the parens
                    if (moveOnlyByValue(clang_getCursorType(a))) okParams = false;   // shim would copy it
                    cppPs ~= format("%s a%d", _cpps, i);
                    rps ~= format("%s a%d", pd, i);
                    ca ~= format("a%d", i);
                }
                if (simpleRet && okParams && !nestedInaccessible(cur)) {
                    // dedupe overloads that collapse to one D signature (e.g. setTextAlignment(int)
                    // and setTextAlignment(Qt::Alignment) both map to (int)); keep the first.
                    auto msKey = dname(mn) ~ "|" ~ rps.join(",") ~ "|" ~ (isStat ? "s" : "");
                    if (msKey in seenMethodShimSig) handled = true;   // overload already covered
                    else {
                        seenMethodShimSig[msKey] = true;
                        if (imp.length) impSet[imp] = true;
                        auto shimFn = format("qtd_m_%s_%d", name, methodLines.length);
                        auto cppRet = clang_getTypeSpelling(clang_getCanonicalType(clang_getCursorResultType(c))).str;
                        bool isCst = clang_CXXMethod_isConst(c) != 0;
                        METHODSHIM ~= MethodShim(shimFn, cppName, cppRet, mn, cppPs, ca, isStat, isCst);
                        auto kw = isStat ? "static " : "final ";
                        auto cst = isCst ? " const" : "";
                        auto selfDecl = isStat ? "" : "void* self";
                        auto declPs = (selfDecl.length && rps.length) ? selfDecl ~ ", " ~ rps.join(", ")
                                    : selfDecl ~ rps.join(", ");
                        // extern(C) decl at MODULE scope (a static member wouldn't get C linkage)
                        shimDecls ~= format("extern(C) private %s %s(%s);", retD, shimFn, declPs);
                        auto callArgs = isStat ? ca.join(", ")
                            : (ca.length ? "cast(void*) this, " ~ ca.join(", ") : "cast(void*) this");
                        auto ret = retD == "void" ? "" : "return ";
                        // extern(D) is MANDATORY: in an extern(C++) class a bodied method mangles
                        // to its Qt symbol (e.g. QObject::event) and would DEFINE/interpose it —
                        // Qt's own calls would then loop through our shim. extern(D) keeps it a
                        // D-only method (same gotcha the guard forwarder documents). Harmless for
                        // inline methods (their Qt symbol doesn't exist out-of-line anyway).
                        methodLines ~= format("    extern(D) %s%s %s(%s)%s { %s%s(%s); }",
                            kw, retD, dname(mn), rps.join(", "), cst, ret, shimFn, callArgs);
                        handled = true; _fate = "shimmed";
                    }
                }
            } catch (Unmappable) { if (isInline(c)) handled = true; }
            if (handled) continue;
            if (isInline(c)) { _fate = "inline-failed"; continue; }   // opaque inline, no workable shim
            // else: a virtual with a complex signature -> fall through to the direct guard path.
        }
        try {
            string ch, cid, crs;   // QHash<K,V> return -> V[K] via sret + iterate shim
            if (containerReturn(clang_getCursorResultType(c), ch, cid, crs)) {
                impSet["qtcontainers"] = true;
                auto kw2 = clang_CXXMethod_isStatic(c) ? "static " : "final ";
                auto cst2 = clang_CXXMethod_isConst(c) ? " const" : "";
                string[] rps, cargs; bool okc = true;
                auto nap = clang_Cursor_getNumArguments(c);
                foreach (i; 0 .. nap) {
                    auto a = clang_Cursor_getArgument(c, i);
                    string pimp, pd;
                    try pd = mapCxxType(clang_getCursorType(a), pimp); catch (Unmappable) { okc = false; break; }
                    if (pimp.length) impSet[pimp] = true;
                    rps ~= format("%s a%d", pd, i); cargs ~= format("a%d", i);
                }
                if (okc) {
                    auto mgc = clang_Cursor_getMangling(c).str;
                    auto rawN = "__" ~ dname(mn) ~ "_qc";
                    methodLines ~= format("    private pragma(mangle, \"%s\") %s%s %s(%s)%s;",
                        mgc, kw2, crs, rawN, rps.join(", "), cst2);
                    methodLines ~= format("    extern (D) %s%s %s(%s)%s {\n        auto _r = %s(%s);\n        return %s_to(cast(void*) &_r);\n    }",
                        kw2, cid, dname(mn), rps.join(", "), cst2, rawN, cargs.join(", "), ch);
                }
                continue;
            }
            auto qtid = tryQList(clang_getCursorResultType(c));   // QList<T> return -> T[]
            if (qtid.length) {
                auto kw2 = clang_CXXMethod_isStatic(c) ? "static " : "final ";
                auto cst2 = clang_CXXMethod_isConst(c) ? " const" : "";
                auto pr = emitQListReturn(c, mn, qtid, kw2, cst2, impSet, dpkg);
                if (pr.length) { methodLines ~= pr[0]; methodLines ~= pr[1]; }
                continue;
            }
            string imp;
            auto retD = mapCxxType(clang_getCursorResultType(c), imp);
            if (imp.length) impSet[imp] = true;
            string[] ps, pds, cppTypes;   // cppTypes: canonical C++ param types (for the guard)
            bool guardable = EXCEPTIONS;
            auto na = clang_Cursor_getNumArguments(c);
            foreach (i; 0 .. na) {
                auto a = clang_Cursor_getArgument(c, i);
                string helper, idiom;
                if (containerParam(clang_getCursorType(a), helper, idiom)) {
                    impSet["qtcontainers"] = true;      // raw takes the container ptr as void*
                    ps ~= format("void* a%d", i);
                    pds ~= "C:" ~ helper ~ ":" ~ idiom;
                    guardable = false;                  // container-param methods stay direct
                } else {
                    string pimp;
                    auto pd = mapCxxType(clang_getCursorType(a), pimp);
                    if (pimp.length) impSet[pimp] = true;
                    ps ~= format("%s a%d", pd, i);
                    pds ~= pd;
                    auto cpps = clang_getTypeSpelling(clang_getCanonicalType(clang_getCursorType(a))).str;
                    if (cpps.canFind("(*")) guardable = false;   // fn-ptr param: can't reinterpret cleanly
                    if (moveOnlyByValue(clang_getCursorType(a))) guardable = false;   // guard would copy it
                    cppTypes ~= cpps;
                }
            }
            auto kw = clang_CXXMethod_isStatic(c) ? "static " : "final ";
            auto cst = clang_CXXMethod_isConst(c) ? " const" : "";
            auto mg = clang_Cursor_getMangling(c).str;
            auto cppRet = retD == "void" ? "void"
                : clang_getTypeSpelling(clang_getCanonicalType(clang_getCursorResultType(c))).str;
            if (cppRet.canFind("(*")) guardable = false;   // fn-ptr return can't be a guard sig
            // EXCEPTIONS on -> route this out-of-line method through its per-signature guard
            // instead of binding the Qt symbol directly. See the big block at `struct Guard`
            // for the full rationale; this just emits the three pieces for THIS method.
            if (guardable) {
                // Gotcha (b): forwarders are DEFINITIONS -> two that collapse to the same D
                // signature would clash. Keep only the first (the extra overload is anyway
                // indistinguishable to a D caller).
                auto dsig = dname(mn) ~ "|" ~ ps.join(",") ~ "|"
                    ~ (clang_CXXMethod_isStatic(c) ? "s" : "") ~ cst;
                if (dsig in seenGuardSig) continue;
                seenGuardSig[dsig] = true;
            }
            if (guardable) {
                bool isStat = clang_CXXMethod_isStatic(c) != 0;
                auto gn = guardFor(cppRet, cppTypes, retD, ps, isStat);
                // (1) the shared guard's D-side extern(C) decl (once per module it's used in).
                //     Its D param types (ps) are ABI-identical to the guard's C++ params.
                if (gn !in guardDeclsEmitted) {
                    guardDeclsEmitted[gn] = true;
                    auto selfP = isStat ? "" : (ps.length ? "void* self, " : "void* self");
                    shimDecls ~= format("extern(C) private %s %s(void* fn%s%s);",
                        retD, gn, ps.length || !isStat ? ", " : "", selfP ~ ps.join(", "));
                }
                // (2) a nullary decl whose ONLY purpose is `&__raw` = the Qt symbol's address
                //     (its declared type is a lie we never call — see the Guard block).
                auto raw = format("__raw_%s_%d", name, guardRawIdx++);
                shimDecls ~= format("private pragma(mangle, \"%s\") extern(C++) void %s();", mg, raw);
                // (3) the extern(D) forwarder (gotcha (a): extern(D) so it doesn't mangle to the
                //     Qt symbol): pass &sym + self + args to the guard, which try/catches.
                string[] callArgs = ["cast(void*)&" ~ raw];
                if (!isStat) callArgs ~= "cast(void*) this";
                foreach (i; 0 .. na) callArgs ~= format("a%d", i);
                auto retkw = retD == "void" ? "" : "return ";
                // extern(D): the forwarder is a D-only method — without it, an extern(C++)
                // member mangles to the very Qt symbol __raw points at (collision + it would
                // redefine the C++ method).
                methodLines ~= format("    extern(D) %s%s %s(%s)%s { %s%s(%s); }",
                    kw, retD, dname(mn), ps.join(", "), cst, retkw, gn, callArgs.join(", "));
            } else {
                // pragma(mangle) with clang's exact symbol -> identical on ldc & dmd
                // (D's own extern(C++) mangling diverges on Itanium substitutions).
                methodLines ~= format("    pragma(mangle, \"%s\") %s%s %s(%s)%s;",
                    mg, kw, retD, dname(mn), ps.join(", "), cst);
            }
            auto ov = strOverload(mn, retD, kw, cst, pds, seenStrOv);
            if (ov.length) methodLines ~= ov;
        } catch (Unmappable) { _fate = "unmapped-type"; /* recordSym (scope-exit) counts it */ }
    }
    // Re-alias base overloads that our new same-name overloads would hide (D name-hiding):
    // e.g. QGridLayout emits addWidget(w,row,col,...) -> without this, QLayout::addWidget(w)
    // would be invisible on QGridLayout. The `static if (__traits(hasMember))` guard is a
    // safety net: the base may have skipped that method (unmappable type) despite declaring
    // it, in which case there is nothing to un-hide.
    foreach (an; aliasNames.byKey)
        methodLines ~= format("    static if (__traits(hasMember, %s, \"%s\")) alias %s = %s.%s;",
            aliasBase[an], dname(an), dname(an), aliasBase[an], dname(an));

    // constructors -> C++-heap construction helpers (operator new + real ctor
    // via its exact mangled symbol). D `new` would GC-allocate, which crashes
    // when Qt deletes the object; C++-heap keeps the allocators matched.
    // Value-type ctors are inline (no symbol) — construct via D struct literal
    // `QSize(w, h)` instead. Only polymorphic classes get C++-heap ctor helpers.
    string[] ctorHelpers;
    int ci;
    // Abstract classes (an unoverridden pure virtual) can't be instantiated — their
    // complete-object ctor (C1) isn't even emitted by C++ — so skip the _new factory.
    bool abstractCls = clang_CXXRecord_isAbstract(cur) != 0;
    bool[string] seenCtorSig;   // dedup: distinct C++ ctors that collapse into the same D signature
    if (!valueType && !abstractCls) foreach (c; ctors) {
        if (clang_CXXMethod_isDeleted(c)) continue;   // `= delete` ctor -> not constructible
        // Inline/`= default` ctor -> no symbol. The out-of-line shim (gap 1) does a
        // placement-new into the heap buffer. Params can be anything mapCxxType handles:
        // the shim takes them by their canonical C++ type and qtd_mk forwards to the ctor
        // (this unblocks e.g. QSpacerItem(int,int,QSizePolicy::Policy,QSizePolicy::Policy)).
        // Fn-pointer params are still skipped (the C++ declarator needs the name in parens).
        bool viaShim = isInline(c);
        try {
            string[] sig, callArgs, dparams, pdtypes, cppPs, cppT;
            bool okParams = true;
            auto na = clang_Cursor_getNumArguments(c);
            foreach (i; 0 .. na) {
                auto a = clang_Cursor_getArgument(c, i);
                string pimp;
                auto pd = mapCxxType(clang_getCursorType(a), pimp);
                if (pimp.length) impSet[pimp] = true;
                auto _cpps = clang_getTypeSpelling(clang_getCanonicalType(clang_getCursorType(a))).str;
                if (_cpps.canFind("(*")) okParams = false;   // fn-ptr param: shim C++ decl needs the name inside the parens
                cppPs ~= format("%s a%d", _cpps, i);
                cppT ~= _cpps;
                pdtypes ~= pd;
                sig ~= format("%s a%d", pd, i);
                // Carry C++ defaults so ordering stays legal (D: once a param is
                // defaulted, all trailing ones must be too). Parent-type pointers
                // default to null as before; other defaulted params evaluate their
                // real C++ default, with a `.init` fallback to preserve ordering.
                string deflt;
                if (pd == baseName || pd.endsWith(name)) deflt = " = null";
                else if (hasDefault(a)) {
                    deflt = paramDefault(a, pd);
                    if (!deflt.length && !pd.startsWith("ref ")) deflt = format(" = %s.init", pd);
                }
                dparams ~= format("%s a%d%s", pd, i, deflt);
                callArgs ~= format("a%d", i);
            }
            if (viaShim && (!okParams || nestedInaccessible(cur))) continue;   // still a gap
            auto sigKey = pdtypes.join(",");   // same D signature -> redefinition; keep only the 1st
            if (sigKey in seenCtorSig) continue;
            seenCtorSig[sigKey] = true;
            auto ctorFn = format("__ctor_%s_%d", name, ci);
            auto selfTy = valueType ? name ~ "*" : name;   // struct ctor's `this` is a pointer
            auto callTail = callArgs.length ? ", " ~ callArgs.join(", ") : "";
            if (viaShim) {
                ctorFn = format("qtd_new_%s_%d", name, ci);
                CTORSHIM ~= CtorShim(name, cppName, ctorFn, cppPs, callArgs);
                ctorHelpers ~= format("extern(C) private void %s(%s self%s);",
                    ctorFn, selfTy, sig.length ? ", " ~ sig.join(", ") : "");
            }
            // Exceptions on, heap object ctor: route the ctor call through a void-guard too
            // (a ctor's ABI is void(self, args), so it reuses the void-return guards) — this
            // covers `new QButton()`. Value-type ctors keep the direct/shim path.
            bool ctorGuard = EXCEPTIONS && !valueType && !viaShim && okParams && !nestedInaccessible(cur);
            if (!viaShim && !ctorGuard) {
                auto mangled = clang_Cursor_getMangling(c).str;
                ctorHelpers ~= format(`private pragma(mangle, "%s") extern(C++) void %s(%s self%s);`,
                    mangled, ctorFn, selfTy, sig.length ? ", " ~ sig.join(", ") : "");
            }
            string cgn;   // guard name for the ctor, if guarded
            if (ctorGuard) {
                cgn = guardFor("void", cppT, "void", sig, false);
                if (cgn !in guardDeclsEmitted) {
                    guardDeclsEmitted[cgn] = true;
                    ctorHelpers ~= format("extern(C) private void %s(void* fn, void* self%s);",
                        cgn, sig.length ? ", " ~ sig.join(", ") : "");
                }
                ctorHelpers ~= format(`private pragma(mangle, "%s") extern(C++) void %s();`,
                    clang_Cursor_getMangling(c).str, ctorFn);
            }
            ctorHelpers ~= format("%s %s_new(%s) {", name, name, dparams.join(", "));
            if (valueType) {                                // by-value on the stack
                ctorHelpers ~= format("    %s self = void;", name);
                ctorHelpers ~= format("    %s(&self%s);", ctorFn, callTail);
            } else {                                        // C++ heap (Qt owns/deletes)
                ctorHelpers ~= format("    auto self = cast(%s) __cpp_new(__traits(classInstanceSize, %s));", name, name);
                if (ctorGuard)
                    ctorHelpers ~= format("    %s(cast(void*)&%s, cast(void*) self%s);", cgn, ctorFn, callTail);
                else
                    ctorHelpers ~= format("    %s(self%s);", ctorFn, callTail);
            }
            ctorHelpers ~= "    return self;";
            ctorHelpers ~= "}";
            ci++;
        } catch (Unmappable) { recordSym(cppName, clang_getCursorSpelling(c).str, "unmapped-type", c); }
    }

    string[] body_;
    if (valueType) {
        // Expose the real data members (from libclang): value-type accessors are
        // almost all inline (unlinkable), so direct field access is how you read
        // them. Layout matches C++, so `s.wd` reads the right bytes.
        foreach (c; children(cur))
            if (c.kind == CXCursor_FieldDecl) {
                auto fn = clang_getCursorSpelling(c).str;
                auto ft = clang_getCursorType(c);
                // A C++ default member initializer (`bool m_null = true;`) is part of the
                // type's default-constructed state. Dropping it left the D struct's .init
                // all-zero, so a default-constructed value silently disagreed with C++:
                // Color().isNull() was true in C++ and false in D.
                if (auto p = underlyingPrim(ft))
                    body_ ~= format("    %s %s%s;", p, dname(fn), paramDefault(c, p));
                else body_ ~= format("    ubyte[%d] %s;", clang_Type_getSizeOf(ft), dname(fn));
            }
    } else {
        // polymorphic: opaque padding so operator-new allocates the exact C++ size
        long pad = sz - (baseName.length ? baseSz : 8);   // 8 = the vptr on the root
        if (pad > 0) body_ ~= format("    ubyte[%d] __pad;", pad);
        // root gets its vptr via a declared dtor. EXTERN(D) + empty body: (a) a decl-
        // only `~this();` references the external C++ dtor, which isn't always exported
        // (QAbstractUndoItem is inline in Qt5 -> undefined); (b) `~this(){}` extern(C++)
        // DEFINES the C++ dtor symbol and clashes with a static lib that also defines
        // it (libsample.a). extern(D) mangles in D: it neither references nor defines the
        // C++ symbol. Polymorphic objects are owned by C++ (never destroyed by D).
        if (!baseName.length) body_ ~= "    extern(D) ~this() {}";

    }
    body_ = nestedEnumLines(cur) ~ body_ ~ methodLines ~ miMethods;   // + secondary-base upcasts
    shimDecls ~= nestedEnumAliases(cur, name);   // Class_Value aliases for the 2-part .ui form

    auto kind = hasVirtual ? "class" : "struct";
    impSet.remove(name);
    imports = impSet.byKey.array.sort.array;   // proper class names
    auto impLines = imports.map!(m => format("import %s.%s;", dpkg, modBase(m))).join("\n");

    return format("%s\nmodule %s.%s;\nimport cxxrt;\n%s\n\nextern (C++%s) %s %s%s {\n%s\n}\n\n%s\n%s\n",
        manifest, dpkg, modBase(name), impLines, nsClause(cppName), kind, name, baseClause,
        body_.join("\n"), ctorHelpers.join("\n"), shimDecls.join("\n"));
}

// Enums nested in a class -> emitted inside its D declaration (so the mangling
// substitution matches, e.g. QThread::Priority). Returns indented `enum` lines.
string[] nestedEnumLines(CXCursor cur) {
    string[] L;
    foreach (c; children(cur))
        // PROTECTED nested enums are emitted too. A protected virtual can take one
        // (QQuickAbstractButton::buttonChange(ButtonChange)), and the trampoline overriding it
        // needs the type BY NAME — without it the generated callback alias fails to compile,
        // pointing at a line with no hint that the enum was filtered out here.
        if (c.kind == CXCursor_EnumDecl
                && (isPublic(c) || clang_getCXXAccessSpecifier(c) == CX_CXXProtected)) {
            auto en = clang_getCursorSpelling(c).str;
            // anonymous enum: empty spelling, or libclang's synthetic "(unnamed enum at ...)".
            bool anon = !en.length || en.canFind('(');
            auto ut = canon(clang_getEnumDeclIntegerType(c));
            auto dut = ut in PRIM ? PRIM[ut] : "int";
            string[] ms;
            foreach (ch; children(c))
                if (ch.kind == CXCursor_EnumConstantDecl)
                    ms ~= format("        %s = cast(%s) %d,", dname(clang_getCursorSpelling(ch).str), dut,
                        clang_getEnumConstantDeclValue(ch));
            if (!ms.length) continue;
            // anonymous -> nameless D enum (`enum : uint {..}`), exposing the constants.
            L ~= format("    enum %s: %s {\n%s\n    }", anon ? "" : en ~ " ", dut, ms.join("\n"));
        }
    return L;
}

// MODULE-SCOPE, class-prefixed aliases for a class's nested enum values, so the OLD 2-part
// `.ui` form `QLineEdit::Password` / `QDialogButtonBox::Ok` resolves (the uic emits
// `QLineEdit_Password`). Module scope + the `Class_` prefix means: unique across classes, and
// NOT inherited — so unlike a class-member alias it can't shadow a type in a derived class
// (QEvent::Type::InputMethodQuery once shadowed the InputMethodQuery type in QInputMethodQueryEvent).
string[] nestedEnumAliases(CXCursor cur, string name) {
    string[] al; bool[string] seen;
    foreach (c; children(cur))
        // PROTECTED nested enums are emitted too. A protected virtual can take one
        // (QQuickAbstractButton::buttonChange(ButtonChange)), and the trampoline overriding it
        // needs the type BY NAME — without it the generated callback alias fails to compile,
        // pointing at a line with no hint that the enum was filtered out here.
        if (c.kind == CXCursor_EnumDecl
                && (isPublic(c) || clang_getCXXAccessSpecifier(c) == CX_CXXProtected)) {
            auto en = clang_getCursorSpelling(c).str;
            bool anon = !en.length || en.canFind('(');   // anon values are bare members: Class.Value
            foreach (ch; children(c))
                if (ch.kind == CXCursor_EnumConstantDecl) {
                    auto vn = dname(clang_getCursorSpelling(ch).str);
                    if (vn in seen) continue;
                    seen[vn] = true;
                    al ~= anon ? format("alias %s_%s = %s.%s;", name, vn, name, vn)
                               : format("alias %s_%s = %s.%s.%s;", name, vn, name, en, vn);
                }
        }
    return al;
}

// Emit one enum module: extern(C++, <scope>) enum Name : underlying { members }.
// The scope (class or namespace) makes the param mangle N<scope><name>E — matching
// C++ — while the enum is still plain D. `scope` covers Qt::X and QThread::Priority.
// Namespace/global free functions -> one `<dpkg>.functions` module of extern(C++)
// free-function declarations (pragma(mangle) with the exact symbol, which already
// encodes the namespace). Inline/template functions and unmapped signatures are
// skipped. Overloads with the same D signature are de-duplicated.
string emitFunctionsModule(CXCursor[] fns, string dpkg, string manifest, out string[] imports) {
    bool[string] impSet, seenSig;
    string[] lines;
    foreach (c; fns) {
        if (isInline(c)) continue;   // inline free function -> no linkable symbol
        auto mn = clang_getCursorSpelling(c).str;
        try {
            string imp;
            auto retD = mapCxxType(clang_getCursorResultType(c), imp);
            if (imp.length) impSet[imp] = true;
            string[] ps, pds;
            auto na = clang_Cursor_getNumArguments(c);
            foreach (i; 0 .. na) {
                auto a = clang_Cursor_getArgument(c, i);
                string pimp;
                auto pd = mapCxxType(clang_getCursorType(a), pimp);
                if (pimp.length) impSet[pimp] = true;
                ps ~= format("%s a%d", pd, i);
                pds ~= pd;
            }
            auto sig = dname(mn) ~ "(" ~ pds.join(",") ~ ")";
            if (sig in seenSig) continue;
            seenSig[sig] = true;
            auto mg = clang_Cursor_getMangling(c).str;
            lines ~= format("pragma(mangle, \"%s\") %s %s(%s);", mg, retD, dname(mn), ps.join(", "));
        } catch (Unmappable) { /* skip unmapped free function */ }
    }
    imports = impSet.byKey.array.sort.array;
    auto impLines = imports.map!(m => format("import %s.%s;", dpkg, modBase(m))).join("\n");
    return format("%s\nmodule %s.functions;\n%s\n\n%s\n", manifest, dpkg, impLines, lines.join("\n"));
}

string emitEnumModule(CXCursor decl, string dpkg, string manifest) {
    auto qn = canon(clang_getCursorType(decl));         // "Qt::AlignmentFlag" / "Priority"
    auto n = lastNs(qn);
    auto i = qn.lastIndexOf("::");
    auto sc = i >= 0 ? qn[0 .. i] : "";
    auto nsc = sc.length ? ", " ~ sc.split("::").map!(p => `"` ~ p ~ `"`).join(", ") : "";
    auto ut = canon(clang_getEnumDeclIntegerType(decl));
    auto dut = ut in PRIM ? PRIM[ut] : "int";
    string[] members;
    foreach (ch; children(decl))
        if (ch.kind == CXCursor_EnumConstantDecl) {
            auto mn = dname(clang_getCursorSpelling(ch).str);
            members ~= format("    %s = cast(%s) %d,", mn, dut, clang_getEnumConstantDeclValue(ch));
            if (sc == "Qt") {   // Qt-namespace value -> aggregate a bare-name alias
                QT_ALIASES ~= format("alias %s = %s.%s;", mn, n, mn);
                QT_ALIAS_MODS[n] = true;
            }
        }
    // Qt's empty strong-typedef enums (enum class QCborTag : quint64 {}) have no
    // members; a D enum needs >=1, so emit an ABI-identical alias to the underlying.
    if (!members.length)
        return format("%s\nmodule %s.%s;\nalias %s = %s;\n", manifest, dpkg, modBase(n), n, dut);
    return format("%s\nmodule %s.%s;\nextern (C++%s) enum %s : %s {\n%s\n}\n",
        manifest, dpkg, modBase(n), nsc, n, dut, members.join("\n"));
}

// The "smart" QString: a Qt value type wired for D <-> Qt string interop, pure D.
// Construct from a D string (QString(const QChar*,len), out-of-line); read via the
// UTF-16 layout; and — since QString's dtor is inline (no symbol) — release its
// refcounted data by hand (atomic deref + the exported QArrayData::deallocate).
// Non-copyable so it can only move / pass by ref (no double free).
string qstringRuntime(string manifest, string dpkg, bool qt5 = false) {
    // Qt5: QString is { QStringData* d } (a single pointer); the data lives at
    // (char*)d + d->offset, with ref(int)@0, size(int)@4, offset(qptrdiff)@16.
    // Qt6: QArrayDataPointer { void* d; wchar* ptr; long size }. The QString(
    // const QChar*, int/qsizetype) ctor and deallocate differ in mangling (i/x, mm/xx).
    if (qt5) return manifest ~ "\nmodule " ~ dpkg ~ ".qstring;\n" ~ q{
import std.utf : toUTF16;
import std.conv : to;
import core.atomic : atomicOp;

extern (C++) struct QString {
    void* d;          // QStringData* (QArrayData: ref@0, size@4, offset@16)
    extern (D) this(string s) {                            // QString("foo")
        auto w = s.toUTF16;
        __qstr_ctor(&this, w.ptr, cast(int) w.length);
    }
    this(this) {                                           // copy = share + refcount++ (Qt CoW)
        if (d is null) return;
        auto refp = cast(shared(int)*) d;
        if (*cast(int*) d >= 0) atomicOp!"+="(*refp, 1);   // sentinel: plain read (shared/static in .rodata)
    }
    extern (D) void __release() {
        if (d is null) return;
        auto refp = cast(shared(int)*) d;
        if (*cast(int*) d < 0) { d = null; return; }   // persistent/shared null (.rodata): plain read
        if (atomicOp!"-="(*refp, 1) == 0) __qad_deallocate(d, 2, 8);
        d = null;
    }
    ~this() { __release(); }
    extern (D) string toString() const {                   // qs.to!string uses this
        if (d is null) return "";
        auto size = *cast(const(int)*)(cast(const(char)*) d + 4);
        if (size == 0) return "";
        auto off  = *cast(const(long)*)(cast(const(char)*) d + 16);
        auto p    = cast(const(wchar)*)(cast(const(char)*) d + off);
        return (cast(const(wchar)[]) p[0 .. size]).to!string;
    }
}
private pragma(mangle, "_ZN7QStringC1EPK5QChari")
    extern (C++) void __qstr_ctor(QString* self, const(wchar)* d, int n);
private pragma(mangle, "_ZN10QArrayData10deallocateEPS_mm")
    extern (C++) void __qad_deallocate(void* d, size_t objSize, size_t alignment);

/// D string -> QString temporary (released when it leaves scope).
QString qstr(string s) {
    auto w = s.toUTF16;
    QString r = void;
    __qstr_ctor(&r, w.ptr, cast(int) w.length);
    return r;
}
};
    return manifest ~ "\nmodule " ~ dpkg ~ ".qstring;\n" ~ q{
import std.utf : toUTF16;
import std.conv : to;
import core.atomic : atomicOp;

extern (C++) struct QString {
    void* d;          // QArrayData* (ref count at offset 0)
    wchar* ptr;       // UTF-16 data
    long size;
    extern (D) this(string s) {                            // QString("foo")
        auto w = s.toUTF16;
        __qstr_ctor(&this, w.ptr, cast(long) w.length);
    }
    this(this) {                                           // copy = share + refcount++ (Qt CoW)
        if (d is null) return;
        auto refp = cast(shared(int)*) d;
        if (*cast(int*) d >= 0) atomicOp!"+="(*refp, 1);   // sentinel: plain read (shared/static in .rodata)
    }
    extern (D) void __release() {
        if (d is null) return;
        auto refp = cast(shared(int)*) d;
        if (*cast(int*) d < 0) { d = null; return; }   // persistent/shared null (.rodata): plain read
        if (atomicOp!"-="(*refp, 1) == 0) __qad_deallocate(d, 2, 8);
        d = null;
    }
    ~this() { __release(); }
    extern (D) string toString() const {                   // qs.to!string uses this
        if (ptr is null || size == 0) return "";
        return (cast(const(wchar)[]) ptr[0 .. size]).to!string;
    }
}
private pragma(mangle, "_ZN7QStringC1EPK5QCharx")
    extern (C++) void __qstr_ctor(QString* self, const(wchar)* d, long n);
private pragma(mangle, "_ZN10QArrayData10deallocateEPS_xx")
    extern (C++) void __qad_deallocate(void* d, long objSize, long alignment);

/// D string -> QString temporary (released when it leaves scope).
QString qstr(string s) {
    auto w = s.toUTF16;
    QString r = void;
    __qstr_ctor(&r, w.ptr, cast(long) w.length);
    return r;
}
};
}

// Smart QByteArray: same recipe as QString but UTF-8 (element size 1). Construct
// from a D string via QByteArray(const char*,len); read the bytes directly;
// release the refcounted data by hand (dtor is inline).
string qbytearrayRuntime(string manifest, string dpkg, bool qt5 = false) {
    // Qt5: QByteArray is { Data* d } (a single pointer); bytes at (char*)d + d->offset,
    // size(int)@4. Qt6: { d, ptr, size }. Ctor/deallocate differ in mangling.
    if (qt5) return manifest ~ "\nmodule " ~ dpkg ~ ".qbytearray;\n" ~ q{
import core.atomic : atomicOp;

extern (C++) struct QByteArray {
    void* d;          // Data* (QArrayData: ref@0, size@4, offset@16)
    extern (D) this(string s)  { __qba_ctor(&this, s.ptr, cast(int) s.length); }        // QByteArray("foo")
    extern (D) this(ubyte[] b) { __qba_ctor(&this, cast(const(char)*) b.ptr, cast(int) b.length); }  // raw bytes
    this(this) {                                                    // copy = share + refcount++
        if (d is null) return;
        auto refp = cast(shared(int)*) d;
        if (*cast(int*) d >= 0) atomicOp!"+="(*refp, 1);   // sentinel: plain read (shared/static in .rodata)
    }
    private const(char)* __data() const { return cast(const(char)*) d + *cast(const(long)*)(cast(const(char)*) d + 16); }
    private int __size() const { return d is null ? 0 : *cast(const(int)*)(cast(const(char)*) d + 4); }
    extern (D) ubyte[] toBytes() const { auto n = __size(); return n == 0 ? null : (cast(ubyte*) __data())[0 .. n].dup; }
    extern (D) void __release() {
        if (d is null) return;
        auto refp = cast(shared(int)*) d;
        if (*cast(int*) d < 0) { d = null; return; }   // static sentinel (.rodata): plain read
        if (atomicOp!"-="(*refp, 1) == 0) __qad_deallocate(d, 1, 8);   // char: objSize=1
        d = null;
    }
    ~this() { __release(); }
    extern (D) string toString() const { auto n = __size(); return n == 0 ? "" : __data()[0 .. n].idup; }
}
private pragma(mangle, "_ZN10QByteArrayC1EPKci")
    extern (C++) void __qba_ctor(QByteArray* self, const(char)* d, int n);
private pragma(mangle, "_ZN10QArrayData10deallocateEPS_mm")
    extern (C++) void __qad_deallocate(void* d, size_t objSize, size_t alignment);

/// D string -> QByteArray temporary (released when it leaves scope).
QByteArray qba(string s) {
    QByteArray r = void;
    __qba_ctor(&r, s.ptr, cast(int) s.length);
    return r;
}
};
    return manifest ~ "\nmodule " ~ dpkg ~ ".qbytearray;\n" ~ q{
import core.atomic : atomicOp;

extern (C++) struct QByteArray {
    void* d;          // QArrayData* (ref count at offset 0)
    char* ptr;
    long size;
    extern (D) this(string s)  { __qba_ctor(&this, s.ptr, cast(long) s.length); }        // QByteArray("foo")
    extern (D) this(ubyte[] b) { __qba_ctor(&this, cast(const(char)*) b.ptr, cast(long) b.length); }  // raw bytes
    this(this) {                                                    // copy = share + refcount++
        if (d is null) return;
        auto refp = cast(shared(int)*) d;
        if (*cast(int*) d >= 0) atomicOp!"+="(*refp, 1);   // sentinel: plain read (shared/static in .rodata)
    }
    extern (D) ubyte[] toBytes() const { return (ptr is null || size == 0) ? null : (cast(ubyte*) ptr)[0 .. size].dup; }
    extern (D) void __release() {
        if (d is null) return;
        auto refp = cast(shared(int)*) d;
        if (*cast(int*) d < 0) { d = null; return; }   // static sentinel (.rodata): plain read
        if (atomicOp!"-="(*refp, 1) == 0) __qad_deallocate(d, 1, 8);   // char: objSize=1
        d = null;
    }
    ~this() { __release(); }
    extern (D) string toString() const { return (ptr is null || size == 0) ? "" : ptr[0 .. size].idup; }
}
private pragma(mangle, "_ZN10QByteArrayC1EPKcx")
    extern (C++) void __qba_ctor(QByteArray* self, const(char)* d, long n);
private pragma(mangle, "_ZN10QArrayData10deallocateEPS_xx")
    extern (C++) void __qad_deallocate(void* d, long objSize, long alignment);

/// D string -> QByteArray temporary (released when it leaves scope).
QByteArray qba(string s) {
    QByteArray r = void;
    __qba_ctor(&r, s.ptr, cast(long) s.length);
    return r;
}
};
}

// QAnyStringView: a non-owning view {const void* data; size_t size}. Qt6 string
// setters take it by value. UTF-8 tag is 0b00, so a D string maps straight to
// {ptr, length} — no bit twiddling, no lifetime (the view borrows the D string).
string qanystringviewRuntime(string manifest, string dpkg) {
    return manifest ~ "\nmodule " ~ dpkg ~ ".qanystringview;\n" ~ q{
extern (C++) struct QAnyStringView {
    const(void)* m_data;
    size_t m_size;
    extern (D) this(string s) { m_data = s.ptr; m_size = s.length; }   // UTF-8, tag 0
}
};
}

// ---- Per-combo marshaling fragments ------------------------------------------
// C++ side: insert-param list / element-build expr / callback-param list / raw
// extraction from an accessor. `p` disambiguates key ("k") vs value ("v") vs the
// lone element (""). `acc` is the C++ element accessor ((*i), i.key(), i.value()).
private string cInsParams(CElem e, string p) {
    return e.kind == "prim" ? format("%s %sv", e.cxx, p) : format("const char* %sd, long %sn", p, p);
}
private string cInsBuild(CElem e, string p) {
    if (e.kind == "str")   return format("QString::fromUtf8(%sd,%sn)", p, p);
    if (e.kind == "bytes") return format("QByteArray(%sd,%sn)", p, p);
    return format("%sv", p);
}
private string cCbParams(CElem e, string p) {
    return e.kind == "prim" ? format("%s %sv", e.cxx, p) : format("const void* %sd, long %sn", p, p);
}
private string cCbExtract(CElem e, string acc) {
    if (e.kind == "str")   return format("%s.utf16(), %s.size()", acc, acc);
    if (e.kind == "bytes") return format("%s.constData(), %s.size()", acc, acc);
    return acc;
}
// D side: extern(C) insert / callback param decls, native->raw insert args,
// raw->native reconstruction.
private string dInsParams(CElem e, string p) {
    return e.kind == "prim" ? format("%s %sv", e.dtype, p) : format("const(char)* %sd, long %sn", p, p);
}
private string dCbParams(CElem e, string p) {
    return e.kind == "prim" ? format("%s %sv", e.dtype, p) : format("const(void)* %sd, long %sn", p, p);
}
private string dToArgs(CElem e, string x) {
    if (e.kind == "str")   return format("%s.ptr, cast(long) %s.length", x, x);
    if (e.kind == "bytes") return format("cast(const(char)*) %s.ptr, cast(long) %s.length", x, x);
    return x;
}
private string dFrom(CElem e, string p) {
    if (e.kind == "str")   return format("__u16(%sd, %sn)", p, p);
    if (e.kind == "bytes") return format("__bytes(%sd, %sn)", p, p);
    return format("%sv", p);
}
// AA KEY position: a D associative-array key must be immutable/value. `string` is
// already immutable(char)[]; `ubyte[]` (mutable) isn't a valid key, so a QByteArray
// key uses immutable(ubyte)[] (and .idup on reconstruction).
private string keyDType(CElem e) { return e.kind == "bytes" ? "immutable(ubyte)[]" : e.dtype; }
private string keyFrom(CElem e, string p) {
    return e.kind == "bytes" ? format("__bytes(%sd, %sn).idup", p, p) : dFrom(e, p);
}

// The C++ shim for one combo (new / add|insert / iterate / delete / destruct).
private string comboCpp(Combo c) {
    auto T = "T_" ~ c.id;
    string s = format("typedef %s %s;\n", c.cxxType, T);
    s ~= format("void* __%s_new() { return new %s(); }\n", c.id, T);
    if (c.kind == CKind.assoc) {
        s ~= format("void __%s_insert(void* h, %s, %s) { static_cast<%s*>(h)->insert(%s, %s); }\n",
            c.id, cInsParams(c.key, "k"), cInsParams(c.val, "v"), T, cInsBuild(c.key, "k"), cInsBuild(c.val, "v"));
        s ~= format("void __%s_iterate(void* h, void(*cb)(%s, %s, void*), void* ctx) { %s* p=static_cast<%s*>(h); for(auto i=p->constBegin();i!=p->constEnd();++i) cb(%s, %s, ctx); }\n",
            c.id, cCbParams(c.key, "k"), cCbParams(c.val, "v"), T, T, cCbExtract(c.key, "i.key()"), cCbExtract(c.val, "i.value()"));
    } else {
        auto add = c.kind == CKind.set ? "insert" : "append";
        s ~= format("void __%s_add(void* h, %s) { static_cast<%s*>(h)->%s(%s); }\n",
            c.id, cInsParams(c.val, ""), T, add, cInsBuild(c.val, ""));
        s ~= format("void __%s_iterate(void* h, void(*cb)(%s, void*), void* ctx) { %s* p=static_cast<%s*>(h); for(auto i=p->constBegin();i!=p->constEnd();++i) cb(%s, ctx); }\n",
            c.id, cCbParams(c.val, ""), T, T, cCbExtract(c.val, "(*i)"));
    }
    s ~= format("void __%s_delete(void* h) { delete static_cast<%s*>(h); }\n", c.id, T);
    s ~= format("void __%s_destruct(void* h) { static_cast<%s*>(h)->~%s(); }\n", c.id, T, T);   // by-value (sret) returns
    return s;
}

// Signal/slot bridge — a gen-phase functor-connect shim per parameterless signal
// (public API: QObject::connect(sender, static_cast<PMF>(&Class::sig), context,
// lambda). The lambda calls a D callback; the connection is owned by the sender
// (auto-dropped when it dies). `includeLine` is the #include for the class headers.
string signalsCpp(string manifest, string includeLine) {
    if (!SIGNALS.length) return manifest ~ "\n";
    string body;
    foreach (s; SIGNALS) {
        // The functor captures a move-only DHolder; when the connection dies (sender
        // destroyed OR disconnect), the lambda — and DHolder — are destroyed, and
        // ~DHolder calls back into D to unroot the delegate box. So the box lifetime
        // follows the Qt connection/sender: auto-freed, no manual disconnect needed.
        // The lambda receives the signal args and forwards them to the D callback.
        auto cbType = s.cbCppParams.length ? "void(*cb)(void*, " ~ s.cbCppParams ~ ")" : "void(*cb)(void*)";
        body ~= format(
            "void* qtd_conn_%s_%s(void* s, %s, void(*rel)(void*), void* ctx) {\n"
            ~ "    auto* o = static_cast<%s*>(s);\n"
            ~ "    return new QMetaObject::Connection(QObject::connect(o, &%s::%s, o,\n"
            ~ "        [cb, ctx, h = DHolder(rel, ctx)](%s) { cb(ctx%s); }));\n}\n",
            s.dClass, s.name, cbType, s.cppClass, s.cppClass, s.name, s.lambdaParams, s.passArgs);
    }
    return manifest ~ "\n#include <QObject>\n" ~ includeLine
        ~ "// Owns a D delegate box; ~DHolder releases it (called when the Qt connection\n"
        ~ "// is destroyed). Move-only so the release happens exactly once.\n"
        ~ "namespace { struct DHolder {\n"
        ~ "    void(*rel)(void*); void* box;\n"
        ~ "    DHolder(void(*r)(void*), void* b) : rel(r), box(b) {}\n"
        ~ "    DHolder(DHolder&& o) noexcept : rel(o.rel), box(o.box) { o.rel = nullptr; }\n"
        ~ "    DHolder(const DHolder&) = delete;\n"
        ~ "    ~DHolder() { if (rel) rel(box); }\n"
        ~ "}; }\n"
        ~ "extern \"C\" {\n" ~ body
        ~ "void qtd_disconnect(void* c) { auto* p = static_cast<QMetaObject::Connection*>(c);\n"
        ~ "    QObject::disconnect(*p); delete p; }\n}\n";
}

// D side: the connection handle + delegate box + trampoline + per-signal extern(C)
// decls. connect<Sig> methods (emitted on each class) call these.
string signalsD(string manifest, string dpkg) {
    auto head = manifest ~ "\nmodule " ~ dpkg ~ ".qtsignals;\n";
    if (!SIGNALS.length) return head;
    // per-signal: a typed delegate box, an extern(C) trampoline that unpacks the
    // callback args into the delegate, the shim decl, and a connect helper.
    bool[string] impSet;
    string perSig;
    foreach (s; SIGNALS) {
        foreach (im; s.imports) impSet[im] = true;
        auto dgT = format("void delegate(%s)", s.cbDParams);
        auto cbPs = s.cbRawParams.length ? "void*, " ~ s.cbRawParams : "void*";   // C ABI (objects = void*)
        auto trampPs = s.cbDParams.length ? "void* ctx, " ~ signalTrampParams(s) : "void* ctx";
        perSig ~= format("private struct DgBox_%s_%s { %s dg; }\n", s.dClass, s.name, dgT);
        perSig ~= format("private extern (C) void __tramp_%s_%s(%s) nothrow "
            ~ "{ try { (cast(DgBox_%s_%s*) ctx).dg(%s); } catch (Exception e) { qtdOnCallbackError(e); } }\n",
            s.dClass, s.name, trampPs, s.dClass, s.name, s.trampArgs);
        perSig ~= format("alias Cb_%s_%s = extern (C) void function(%s) nothrow;\n", s.dClass, s.name, cbPs);
        perSig ~= format("private extern (C) void* qtd_conn_%s_%s(void*, Cb_%s_%s, void function(void*) nothrow, void*) nothrow;\n",
            s.dClass, s.name, s.dClass, s.name);
        perSig ~= format("QtdConnection __conn_%s_%s(void* sender, %s dg) {\n"
            ~ "    auto b = new DgBox_%s_%s(dg); GC.addRoot(cast(void*) b);\n"
            ~ "    return QtdConnection(qtd_conn_%s_%s(sender, &__tramp_%s_%s, &__qtd_release, cast(void*) b));\n}\n",
            s.dClass, s.name, dgT, s.dClass, s.name, s.dClass, s.name, s.dClass, s.name);
    }
    auto impLines = impSet.byKey.array.sort.map!(m => format("import %s.%s;", dpkg, modBase(m))).join("\n");
    return head
        ~ "import core.memory : GC;\nimport qtmoc : qtdOnCallbackError;\n" ~ impLines ~ "\n"
        ~ "// C++ DHolder dtor calls this when the connection dies -> unroot the box.\n"
        ~ "private extern (C) void __qtd_release(void* box) nothrow { GC.removeRoot(box); }\n"
        ~ "// A live signal->delegate connection. Optional disconnect(); otherwise it and\n"
        ~ "// the delegate box are freed when the sender QObject dies.\n"
        ~ "struct QtdConnection {\n    void* _c;\n"
        ~ "    void disconnect() { if (_c !is null) { qtd_disconnect(_c); _c = null; } }\n}\n"
        ~ "private extern (C) void qtd_disconnect(void*) nothrow;\n"
        ~ perSig;
}

// D trampoline param list for a signal's callback args, named a0.. (parallel to
// cbDParams which is just the types).
string signalTrampParams(Signal s) {
    if (!s.cbRawParams.length) return "";   // C-ABI types (objects are void* here)
    string[] ps; int i;
    foreach (t; s.cbRawParams.split(", ")) { ps ~= format("%s a%d", t, i); i++; }
    return ps.join(", ");
}

// Multiple-inheritance upcast shims: one static_cast per (class, secondary base),
// applying the correct pointer offset. Same gen-phase-C++ rule as containers/signals.
string miCpp(string manifest, string includeLine) {
    if (!MICASTS.length) return manifest ~ "\n";
    string body;
    foreach (m; MICASTS)
        body ~= format("void* qtd_upcast_%s_%s(void* p) { return static_cast<%s*>(static_cast<%s*>(p)); }\n",
            m.dClass, m.sbDClass, m.sbCppClass, m.cppClass);
    return manifest ~ "\n" ~ includeLine ~ "extern \"C\" {\n" ~ body ~ "}\n";
}
string miD(string manifest, string dpkg) {
    auto head = manifest ~ "\nmodule " ~ dpkg ~ ".qtmi;\n";
    if (!MICASTS.length) return head;
    string decls;
    foreach (m; MICASTS)
        decls ~= format("    void* qtd_upcast_%s_%s(void*);\n", m.dClass, m.sbDClass);
    return head ~ "extern (C) nothrow {\n" ~ decls ~ "}\n";
}

// Out-of-line copy-ctor + dtor for non-trivially-copyable value types. Compiled against
// the real headers: an implicit/inline copy-ctor (e.g. Str with std::string) is
// instantiated here and gets a symbol. std::destroy_at calls the right dtor without
// having to write the unqualified name. The D decls live at module scope (extern(C)).
string ctorCpp(string manifest, string includeLine) {
    if (!CTORCOPY.length && !CTORSHIM.length && !METHODSHIM.length && !ITEROPS.length && !GUARDS.length)
        return manifest ~ "\n";
    // Templated helpers with if constexpr: if a type (surprisingly) isn't copyable/
    // destructible, they degrade to a no-op instead of breaking the whole lib's compile
    // (one bad class must not take down the other 150).
    // templates OUTSIDE extern "C" (templates require C++ linkage)
    string tmpl =
        "template<class T> static inline void qtd_cc(void* d, const void* s) {\n"
        ~ "    if constexpr (std::is_copy_constructible_v<T>) ::new(d) T(*static_cast<const T*>(s)); }\n"
        ~ "template<class T> static inline void qtd_dt(void* p) {\n"
        ~ "    if constexpr (std::is_destructible_v<T>) std::destroy_at(static_cast<T*>(p)); }\n"
        ~ "template<class T, class...A> static inline void qtd_mk(void* self, A...a) {\n"
        ~ "    if constexpr (std::is_constructible_v<T, A...>) ::new(self) T(a...); }\n"
        // Lippincott: from a trampoline's catch(...), classify the in-flight C++ exception
        // and raise a D exception via the qtd_throw_d callback (cxxrt.d). The D exception
        // unwinds back THROUGH this C++ frame to the D caller — verified on ldc AND dmd.
        ~ (!EXCEPTIONS ? "" :
            "extern \"C\" [[noreturn]] void qtd_throw_d(const char* type, const char* msg);\n"
          ~ "[[noreturn]] static void qtd_lippincott() {\n"
          ~ "    try { throw; }\n"
          ~ "    catch (const std::exception& e) { qtd_throw_d(typeid(e).name(), e.what()); }\n"
          ~ "    catch (...) { qtd_throw_d(\"\", \"unknown C++ exception\"); }\n"
          ~ "    __builtin_unreachable();\n}\n");
    // Wrap a trampoline body so a C++ exception becomes a D one (no-op when EXCEPTIONS off).
    string tryO = EXCEPTIONS ? "try { " : "";
    string tryC = EXCEPTIONS ? " } catch (...) { qtd_lippincott(); }" : "";
    string body;
    foreach (c; CTORCOPY)
        body ~= format(
            "void qtd_cctor_%s(void* d, const void* s) { qtd_cc<%s>(d, s); }\n"
            ~ "void qtd_dtor_%s(void* p) { qtd_dt<%s>(p); }\n",
            c.dName, c.cppName, c.dName, c.cppName);
    // Gap 1: out-of-line shim for an inline/`= default` ctor — placement-new gives the
    // symbol. Routed through qtd_mk so a rare non-constructible type no-ops instead of
    // breaking the whole lib's compile (see qtd_mk above).
    foreach (c; CTORSHIM)
        body ~= format("void %s(void* self%s) { %sqtd_mk<%s>(self%s);%s }\n",
            c.shimFn, c.cppParams.length ? ", " ~ c.cppParams.join(", ") : "", tryO,
            c.cppName, c.argNames.length ? ", " ~ c.argNames.join(", ") : "", tryC);
    // Inline methods on object types: out-of-line trampoline calling self->method(args).
    foreach (m; METHODSHIM) {
        auto ret = m.cppRet == "void" ? "" : "return ";
        // const self for const methods -> overload resolution can't pick a non-const
        // (possibly private) same-name overload (e.g. Overload2::doNothingInPublic).
        auto selfCast = m.isConst ? format("static_cast<const %s*>(self)", m.cppName)
                                  : format("static_cast<%s*>(self)", m.cppName);
        auto call = m.isStatic
            ? format("%s::%s(%s)", m.cppName, m.method, m.argNames.join(", "))
            : format("%s->%s(%s)", selfCast, m.method, m.argNames.join(", "));
        auto ps = m.isStatic ? m.cppParams.join(", ")
            : (m.cppParams.length ? "void* self, " ~ m.cppParams.join(", ") : "void* self");
        body ~= format("%s %s(%s) { %s%s%s;%s }\n",
            m.cppRet, m.shimFn, ps, tryO, ret, call, tryC);
    }
    // Iterator range ops: deref (** = the proxy, converts to value_type), prefix ++, and !=.
    foreach (op; ITEROPS) {
        body ~= format("%s qtd_ideref_%s(void* self) { %sreturn **static_cast<%s*>(self);%s }\n",
            op.eCpp, op.iName, tryO, op.iCpp, tryC);
        body ~= format("void qtd_iincr_%s(void* self) { ++*static_cast<%s*>(self); }\n",
            op.iName, op.iCpp);
        body ~= format("bool qtd_ine_%s(void* a, void* b) { return *static_cast<%s*>(a) != *static_cast<%s*>(b); }\n",
            op.iName, op.iCpp, op.iCpp);
    }
    // The per-signature exception guards (see the big block at `struct Guard` in this file).
    // Each is: reinterpret the passed Qt symbol address `fn` to this exact signature (Itanium
    // ABI: the object `self` is just argument 0), call it, and translate any C++ exception via
    // the Lippincott handler. ONE guard is shared by every method/ctor of the same shape.
    //   decl   = the guard's own C++ parameters:      (void* self, int a0, ...)   [self if !static]
    //   castTs = the fn-pointer's parameter TYPES:    (void*, int, ...)            [what we cast to]
    //   callAs = the arguments forwarded to the call: (self, a0, ...)
    foreach (g; GUARDS) {
        string[] decl, castTs, callAs;
        if (!g.isStatic) { decl ~= "void* self"; castTs ~= "void*"; callAs ~= "self"; }
        foreach (i, t; g.cppTypes) { decl ~= format("%s a%d", t, i); castTs ~= t; callAs ~= format("a%d", i); }
        auto ret = g.cppRet == "void" ? "" : "return ";
        body ~= format("%s %s(void* fn%s%s) { try { %sreinterpret_cast<%s(*)(%s)>(fn)(%s); }"
                ~ " catch (...) { qtd_lippincott(); } }\n",
            g.cppRet, g.name, decl.length ? ", " : "", decl.join(", "),
            ret, g.cppRet, castTs.join(", "), callAs.join(", "));
    }
    return manifest ~ "\n#include <new>\n#include <memory>\n#include <type_traits>\n"
        ~ "#include <exception>\n#include <typeinfo>\n" ~ includeLine
        ~ tmpl ~ "extern \"C\" {\n" ~ body ~ "}\n";
}

// Subclass trampolines: a C++ class per subclassed type whose virtuals forward to
// D callbacks. C++ frameworks calling the virtual dispatch into the D override
// (pure virtuals require the callback; non-pure fall back to the base impl).
string virtCpp(string manifest, string includeLine) {
    if (!TRAMPS.length) return manifest ~ "\n";
    string body;
    foreach (t; TRAMPS) {
        // C++ function-pointer field/param declarator for virtual #i.
        string cbDecl(TrampVirt v, string nm) {
            auto ps = v.cbCppParams.length ? "void*, " ~ v.cbCppParams : "void*";
            return format("%s(*%s)(%s)", v.cbCppRet, nm, ps);   // enum returns marshal as int
        }
        string fields, ctorPs, ctorInit, methods, subPs, subAs;
        foreach (i, v; t.virts) {
            fields  ~= format("    %s;\n", cbDecl(v, format("cb_%d", i)));
            ctorPs  ~= format(", %s", cbDecl(v, format("c%d", i)));
            ctorInit ~= format(", cb_%d(c%d)", i, i);
            subPs   ~= format(", %s", cbDecl(v, format("c%d", i)));
            subAs   ~= format(", c%d", i);
            auto cst = v.isConst ? " const" : "";
            auto ccast = v.retEnum ? format("(%s)", v.cppRet) : "";   // int -> enum on return
            auto call = format("%scb_%d(d%s)", ccast, i, v.passArgs);
            string fwd;
            if (v.retVoid)
                fwd = v.isPure ? format("%s;", call)
                    : format("if (cb_%d) %s; else %s::%s(%s);", i, call, t.cppClass, v.name, v.origArgs);
            else
                fwd = v.isPure ? format("return %s;", call)
                    : format("return cb_%d ? %s : %s::%s(%s);", i, call, t.cppClass, v.name, v.origArgs);
            methods ~= format("    %s %s(%s)%s override { %s }\n",
                v.cppRet, v.name, v.overrideParams, cst, fwd);
        }
        // Attachable moc: the trampoline delegates metaObject/qt_metacall to the
        // generic helpers (qtdmoc.cpp) — so a D subclass can be @QObject (have its
        // own signals/slots/props) IN ADDITION to overriding virtuals. If nothing is
        // attached (qtd_moc_meta==null), it falls back to the base behavior.
        //
        // A DYNAMIC meta-object installed on us wins over the attached one, exactly as in
        // QtdMocObject: QML installs a QQmlVMEMetaObject for the members a .qml declares, and it
        // chains ours as its parent. Note the inversion this fixes — the fallback branch calls
        // Base::metaObject(), which DOES honour the dynamic one, so it was only the interesting
        // case (an attached @QObject subclass) that shadowed it.
        auto moc = format(
            "    const QMetaObject* metaObject() const override {\n"
            ~ "        if (d_ptr->metaObject) return d_ptr->dynamicMetaObject();\n"
            ~ "        auto m = qtd_moc_meta((void*)this); return m ? static_cast<const QMetaObject*>(m) : %s::metaObject(); }\n"
            ~ "    void* qt_metacast(const char* n) override {\n"
            ~ "        if (qtd_moc_classmatch((void*)this, n)) return this;\n"
            ~ "        return %s::qt_metacast(n); }\n"
            ~ "    int qt_metacall(QMetaObject::Call c, int id, void** a) override {\n"
            ~ "        id = %s::qt_metacall(c, id, a); if (id < 0) return id;\n"
            ~ "        return qtd_moc_metacall((void*)this, (int)c, id, a); }\n",
            t.cppClass, t.cppClass, t.cppClass);
        body ~= format("struct Qtd_%s : %s {\n    void* d;\n%s%s"
            ~ "    Qtd_%s(void* dobj%s): d(dobj)%s {}\n"
            // Qt destroys the trampoline (parent ownership) -> drop the side-tables (g_moAttach +
            // the D _reg), closing the QtdWidget lifetime the same way ~QtdMocObject closes newQObject.
            ~ "    ~Qtd_%s() { qtd_moc_detach((void*)this, d); }\n%s};\n"
            ~ "extern \"C\" void* qtd_sub_%s(void* dobj%s) { return new Qtd_%s(dobj%s); }\n"
            // binds a runtime meta-object to the already-created trampoline (Base::staticMetaObject as super).
            ~ "extern \"C\" void qtd_sub_%s_attach(void* self, const char* cn,\n"
            ~ "    const char** sigs, int nsig, const char** slotSigs, int nslot,\n"
            ~ "    const char** propN, const char** propT, const int* propNotify, int nprop,\n"
            ~ "    void* dobj, QtdSlotCb slotcb, QtdPropCb propcb) {\n"
            ~ "    qtd_moc_attach(self, cn, &%s::staticMetaObject, sigs, nsig, slotSigs, nslot,\n"
            ~ "        propN, propT, propNotify, nprop, dobj, slotcb, propcb); }\n",
            t.dClass, t.cppClass, fields, moc, t.dClass, ctorPs, ctorInit, t.dClass, methods,
            t.dClass, subPs, t.dClass, subAs, t.dClass, t.cppClass);
    }
    // declares the generic moc helpers (in qtdmoc.cpp / lib qtmoc) used above.
    auto mocDecl =
        "extern \"C\" {\n"
        ~ "typedef void (*QtdSlotCb)(void*, int, void**);\n"
        ~ "typedef void (*QtdPropCb)(void*, int, int, void**);\n"
        ~ "const void* qtd_moc_meta(void*);\n"
        ~ "bool qtd_moc_classmatch(void*, const char*);\n"
        ~ "int qtd_moc_metacall(void*, int, int, void**);\n"
        ~ "void qtd_moc_attach(void*, const char*, const void*, const char**, int, const char**, int,\n"
        ~ "    const char**, const char**, const int*, int, void*, QtdSlotCb, QtdPropCb);\n"
        ~ "void qtd_moc_detach(void*, void*);\n}\n";
    // force a synchronous paintEvent on a QWidget (headless render / test): grab()
    // renders (repaint()/processEvents() with no args are inline, no symbol). Only compiled when
    // QtWidgets is on the include path — a non-widgets binding (e.g. QtQuick) has no <QWidget>.
    auto forcePaint = "#if __has_include(<QWidget>)\n#include <QWidget>\n#include <QPixmap>\n"
        ~ "extern \"C\" void qtd_force_paint(void* w) {\n"
        ~ "    auto* wd = static_cast<QWidget*>(w); wd->resize(20, 20); wd->grab(); }\n#endif\n";
    return manifest ~ "\n" ~ includeLine ~ mocDecl ~ "namespace {\n" ~ body ~ "}\n" ~ forcePaint;
}

// D side: per-subclass factory taking the override callbacks and returning the
// class (a live C++ object whose vtable calls back into D). Callback types are
// named aliases (an inline `extern(C) T function(..)` param confuses the parser).
// `imps` reports the modules qtvirt.d imports, so the caller can mark them REFERENCED: a virtual's
// parameter type (QChildEvent, QTimerEvent, …) may be reachable from no bound signature other than
// this trampoline, and without a stub the generated import doesn't resolve.
string virtD(string manifest, string dpkg, out string[] imps) {
    auto head = manifest ~ "\nmodule " ~ dpkg ~ ".qtvirt;\n";
    if (!TRAMPS.length) return head;
    bool[string] impSet;
    string aliases, decls, facts;
    foreach (t; TRAMPS) {
        impSet[t.dClass] = true;
        string[] declPs, factPs, factAs;
        foreach (i, v; t.virts) {
            auto al = format("Cb_%s_%d", t.dClass, i);
            auto ps = v.cbDParams.length ? "void*, " ~ v.cbDParams : "void*";
            aliases ~= format("alias %s = extern (C) %s function(%s) nothrow;\n", al, v.cbDRet, ps);
            declPs ~= al;
            factPs ~= format("%s cb%d", al, i);
            factAs ~= format("cb%d", i);
            foreach (im; v.imports) impSet[im] = true;   // class / enum / value modules referenced
        }
        decls ~= format("    void* qtd_sub_%s(void*, %s);\n", t.dClass, declPs.join(", "));
        // attach decl (binds the runtime meta-object to the trampoline) + the virtual
        // names in order (index = cb position), so the mixin maps override->cb.
        decls ~= format("    void qtd_sub_%s_attach(void*, const(char)*, const(char)**, int, const(char)**, int,"
            ~ " const(char)**, const(char)**, const(int)*, int, void*, __QtdSlotCb, __QtdPropCb);\n", t.dClass);
        facts ~= format("%s %s_subclass(void* ctx, %s) {\n    return cast(%s) qtd_sub_%s(ctx, %s);\n}\n",
            t.dClass, t.dClass, factPs.join(", "), t.dClass, t.dClass, factAs.join(", "));
        facts ~= format("enum string[] __%s_vnames = [%s];\n",
            t.dClass, t.virts.map!(v => '"' ~ v.name ~ '"').join(", "));
    }
    auto cbAliases = "alias __QtdSlotCb = extern (C) void function(void*, int, void**) nothrow;\n"
        ~ "alias __QtdPropCb = extern (C) void function(void*, int, int, void**) nothrow;\n";
    imps = impSet.byKey.array.sort.array;
    auto impLines = imps.map!(m => format("import %s.%s;", dpkg, modBase(m))).join("\n");
    return head ~ impLines ~ "\n" ~ cbAliases ~ aliases ~ "extern (C) nothrow {\n" ~ decls ~ "}\n" ~ facts;
}

// Container interop — the ONE bit of generated C++, compiled at the generation
// phase into qtcontainers.o. Demand-driven: exactly the combos seen this run.
// Thin per-container shims: D feeds native data (from) / Qt hands raw basic data
// back to a D callback (iterate/to). Both directions, no QVariant.
string containersCpp(string manifest) {
    if (!COMBOS.length) return manifest ~ "\n";
    string body;
    foreach (id; COMBOS.keys.sort) body ~= comboCpp(COMBOS[id]);
    return manifest ~ "\n"
        ~ "#include <QString>\n#include <QByteArray>\n#include <QList>\n#include <QStack>\n"
        ~ "#include <QQueue>\n#include <QSet>\n#include <QHash>\n#include <QMap>\n"
        ~ "extern \"C\" {\n" ~ body ~ "}\n";
}

// The D side of the container runtime: per-combo callback alias + extern(C) decls +
// by-value return struct (sret; dtor releases via destruct shim) + native<->Qt helpers.
string containersD(string manifest, string dpkg) {
    auto head = manifest ~ "\nmodule " ~ dpkg ~ ".qtcontainers;\n";
    if (!COMBOS.length) return head;
    string aliases, decls, rets, helpers;
    foreach (id; COMBOS.keys.sort) {
        auto c = COMBOS[id];
        if (c.kind == CKind.assoc) {
            aliases ~= format("alias Emit_%s = extern (C) void function(%s, %s, void*) nothrow;\n",
                c.id, dCbParams(c.key, "k"), dCbParams(c.val, "v"));
            decls ~= format("    void* __%s_new(); void __%s_insert(void*, %s, %s); void __%s_iterate(void*, Emit_%s, void*); void __%s_delete(void*); void __%s_destruct(void*);\n",
                c.id, c.id, dInsParams(c.key, "k"), dInsParams(c.val, "v"), c.id, c.id, c.id, c.id);
            helpers ~= format("void* %s_from(%s aa) { auto h = __%s_new(); foreach (k, v; aa) __%s_insert(h, %s, %s); return h; }\n",
                c.id, c.idiomD, c.id, c.id, dToArgs(c.key, "k"), dToArgs(c.val, "v"));
            helpers ~= format("private extern (C) void __%s_cb(%s, %s, void* ctx) nothrow { try { (*cast(%s*) ctx)[%s] = %s; } catch (Exception e) { qtdOnCallbackError(e); } }\n",
                c.id, dCbParams(c.key, "k"), dCbParams(c.val, "v"), c.idiomD, keyFrom(c.key, "k"), dFrom(c.val, "v"));
        } else {
            aliases ~= format("alias Emit_%s = extern (C) void function(%s, void*) nothrow;\n", c.id, dCbParams(c.val, ""));
            decls ~= format("    void* __%s_new(); void __%s_add(void*, %s); void __%s_iterate(void*, Emit_%s, void*); void __%s_delete(void*); void __%s_destruct(void*);\n",
                c.id, c.id, dInsParams(c.val, ""), c.id, c.id, c.id, c.id);
            helpers ~= format("void* %s_from(%s a) { auto h = __%s_new(); foreach (x; a) __%s_add(h, %s); return h; }\n",
                c.id, c.idiomD, c.id, c.id, dToArgs(c.val, "x"));
            helpers ~= format("private extern (C) void __%s_cb(%s, void* ctx) nothrow { try { (*cast(%s*) ctx) ~= %s; } catch (Exception e) { qtdOnCallbackError(e); } }\n",
                c.id, dCbParams(c.val, ""), c.idiomD, dFrom(c.val, ""));
        }
        // by-value (sret) return struct; QHash/QSet/QMap dtors are inline so release
        // is hand-rolled via the destruct shim.
        rets ~= format("extern (C++) struct Ret_%s { void* d; ~this() { __%s_destruct(&this); } }\n", c.id, c.id);
        helpers ~= format("%s %s_to(void* h) { %s r; __%s_iterate(h, &__%s_cb, &r); return r; }\n",
            c.idiomD, c.id, c.idiomD, c.id, c.id);
        helpers ~= format("void %s_del(void* h) { __%s_delete(h); }\n", c.id, c.id);
    }
    return head
        ~ "import std.conv : to;\nimport qtmoc : qtdOnCallbackError;\n"
        ~ `private string __u16(const(void)* p, long n) { return n <= 0 ? "" : (cast(const(wchar)[]) (cast(const(wchar)*) p)[0 .. n]).to!string; }` ~ "\n"
        ~ "private ubyte[] __bytes(const(void)* p, long n) { return n <= 0 ? null : (cast(const(ubyte)*) p)[0 .. cast(size_t) n].dup; }\n"
        ~ aliases
        ~ "extern (C) nothrow {\n" ~ decls ~ "}\n"
        ~ rets
        ~ helpers;
}

// The `qt` aggregator: bare-name aliases for every Qt-namespace enum value, so the uic can
// resolve the old 2-part `Qt::Horizontal` form (see QT_ALIASES). "" if none were collected.
string qtAggregator(string dpkg, string manifest) {
    if (!QT_ALIASES.length) return "";
    auto imps = QT_ALIAS_MODS.byKey.array.sort
        .map!(m => format("import %s.%s;", dpkg, modBase(m))).join("\n");
    return format("%s\nmodule %s.qt;\n%s\n\n%s\n", manifest, dpkg, imps, QT_ALIASES.join("\n"));
}

// The one shared runtime module: C++ operator new / delete by their real
// libstdc++ symbols, so construction/destruction match Qt's allocator. No C++.
string cxxRuntime(string manifest) {
    auto exc = !EXCEPTIONS ? "" :
        // NOTE: no Phobos import — cxxrt is linked into EVERY binding; std.utf via
        // `import std.string` perturbs fragile whole-program DCE. Hand-roll the copy.
          "private string qtd_fromCStr(const(char)* s) {\n"
        ~ "    if (s is null) return \"\";\n"
        ~ "    size_t n = 0; while (s[n]) ++n;\n"
        ~ "    return s[0 .. n].idup;\n"
        ~ "}\n"
        // A C++ exception that crossed a binding trampoline, translated to D. `cppType` is
        // the mangled std::type_info name (e.g. "St12out_of_range"); `msg` is what().
        ~ "class QtCppException : Exception {\n"
        ~ "    string cppType;\n"
        ~ "    this(string type, string msg) { cppType = type; super(msg.length ? msg : type); }\n"
        ~ "}\n"
        // Called by the C++ Lippincott shim from within a trampoline's catch(...): raises a
        // D exception that unwinds back through the C++ frame to the D caller (ldc + dmd).
        ~ "extern(C) void qtd_throw_d(const(char)* type, const(char)* msg) {\n"
        ~ "    throw new QtCppException(qtd_fromCStr(type), qtd_fromCStr(msg));\n"
        ~ "}\n";
    // make!T(args): the JUSTIFIED value-type factory. D forbids a no-arg struct this(), and a
    // CoW value type's `.init` leaves a null d-pointer — so a value type that can't be built by a
    // struct ctor (no-arg / all-defaulted) exposes `static T __make(...)` running the real C++
    // ctor. Parameterized value types should prefer plain `T(args)`; reach for make!T only when
    // that can't apply. (Object types use `new T(args)`, never a factory.)
    auto mk = "T make(T, A...)(auto ref A args) { return T.__make(args); }\n";
    return manifest ~ "\nmodule cxxrt;\n"
        ~ `pragma(mangle, "_Znwm") extern(C++) void* __cpp_new(size_t);` ~ "\n"
        ~ `pragma(mangle, "_ZdlPv") extern(C++) void __cpp_delete(void*);` ~ "\n"
        ~ mk ~ exc;
}
