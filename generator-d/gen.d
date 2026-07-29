// gen.d — shared front-end for the binding generator, in D on the libclang C API
// (native, no Python cindex). Discovery, the shiboken typesystem rules (loadRules),
// name/keyword helpers, and AST utilities used by the extern(C++) emitter (emit_cxx.d).
// (A few unused C-ABI helper functions still linger here from the removed old path.)
module gen;

import clang_c;
import std.stdio, std.string, std.array, std.algorithm, std.conv, std.json,
       std.process, std.file, std.path;

// --- type mapping ----------------------------------------------------------
enum string[string] PRIM = [
    "void": "void", "bool": "bool",
    "char": "char", "signed char": "byte", "unsigned char": "ubyte",
    "short": "short", "unsigned short": "ushort",
    "int": "int", "unsigned int": "uint",
    "long": "long", "unsigned long": "ulong",
    "long long": "long", "unsigned long long": "ulong",
    "float": "float", "double": "double", "long double": "real",
    "char16_t": "wchar", "char32_t": "dchar", "wchar_t": "dchar",
];

struct Conv { string cppDeref, cppWrap, dToRaw, dFromRaw, dFromRawOwned, dFree; string idty = "string"; }
Conv[string] CONV;   // filled in main (value types marshaled to a native D type)

// Container instantiations (QList<T>/QVector<T>) seen this run; D can't
// instantiate C++ templates, so we emit an explicit shim per concrete T.
struct Container { string cppType, tid, elemC, elemDRaw, elemIdty, atWrap, elemFromRaw; }
Container[string] CONTAINERS;

string tidOf(string spelling) {
    return spelling.replace(" *", "p").replace("*", "p").replace(" ", "_").replace(":", "_");
}

// element -> (C type of at(), raw D type, idiomatic D type, C++ wrap of at(i), D from-raw|null)
bool mapElem(CXType elem, out string ec, out string edraw, out string eid, out string aw, out string efr) {
    auto c = canon(elem);
    if (auto cv = c in CONV) { ec = "void*"; edraw = "void*"; eid = cv.idty; aw = cv.cppWrap; efr = cv.dFromRawOwned; return true; }
    if (auto p = c in PRIM)  { ec = c; edraw = *p; eid = *p; aw = "{}"; efr = null; return true; }
    if (elem.kind == CXType_Pointer && isRecord(clang_getPointeeType(elem))) {
        ec = "void*"; edraw = "void*"; eid = "void*"; aw = "(void*)({})"; efr = null; return true;  // strip const
    }
    return false;
}

string tryContainer(CXType t) {
    auto ck = clang_getCanonicalType(t);
    if (clang_Type_getNumTemplateArguments(ck) != 1) return "";
    auto declName = clang_getCursorSpelling(clang_getTypeDeclaration(ck)).str;
    if (declName != "QList" && declName != "QVector") return "";
    auto elem = clang_Type_getTemplateArgumentAsType(ck, 0);
    string ec, edraw, eid, aw, efr;
    if (!mapElem(elem, ec, edraw, eid, aw, efr)) return "";
    auto id = tidOf(canon(elem));
    CONTAINERS[id] = Container(clang_getTypeSpelling(ck).str, id, ec, edraw, eid, aw, efr);
    return id;
}

// Associative container QHash<K,V>/QMap<K,V> -> D `V[K]` (iterator-based).
struct Assoc {
    string kind, cppType, kid, vid;
    string keyC, keyDRaw, keyIdty, keyWrap, keyFrom;
    string valC, valDRaw, valIdty, valWrap, valFrom;
    string pfx() const { return "qtd_" ~ kind ~ "_" ~ kid ~ "_" ~ vid; }
}
Assoc[string] ASSOCS;

string tryAssoc(CXType t) {
    auto ck = clang_getCanonicalType(t);
    if (clang_Type_getNumTemplateArguments(ck) != 2) return "";
    auto dn = clang_getCursorSpelling(clang_getTypeDeclaration(ck)).str;
    if (dn != "QHash" && dn != "QMap") return "";
    auto kt = clang_Type_getTemplateArgumentAsType(ck, 0);
    auto vt = clang_Type_getTemplateArgumentAsType(ck, 1);
    string kc, kdr, kid, kw, kf, vc, vdr, vid, vw, vf;
    if (!mapElem(kt, kc, kdr, kid, kw, kf)) return "";
    if (!mapElem(vt, vc, vdr, vid, vw, vf)) return "";
    auto id = dn ~ "_" ~ tidOf(canon(kt)) ~ "_" ~ tidOf(canon(vt));
    ASSOCS[id] = Assoc(dn, clang_getTypeSpelling(ck).str, tidOf(canon(kt)), tidOf(canon(vt)),
        kc, kdr, kid, kw, kf, vc, vdr, vid, vw, vf);
    return id;
}

// Hand-tuned rules taken from PySide/shiboken's typesystem XML — "what doesn't
// come for free": which classes/methods to skip, and value-type vs object-type
// (object-types are QObject-derived / non-copyable, so never heap-copy by value).
struct Rules {
    bool[string] rejectedClass;    // "QAlgorithmsPrivate"
    bool[string] rejectedMethod;   // "QMetaObject::activate"
    bool[string] objectType;       // "QObject" (non-copyable)
    bool[string] valueType;        // "QPoint"  (copyable)
}
Rules RULES;
__gshared string qtMarker = "/qt6/";   // path fragment identifying Qt framework headers
__gshared string sourceFilter;         // when set: bind ANY class defined in files
                                       // whose path contains this (your own Qt C++)

string lastNs(string s) { auto i = s.lastIndexOf("::"); return i >= 0 ? s[i + 2 .. $] : s; }

// Qt method names that are D keywords (cast/function/scope/version/in/out/...) get a `_`.
enum string[] DKEYWORDS = ["abstract","alias","align","asm","assert","auto","body","bool",
    "break","byte","case","cast","catch","cdouble","cent","cfloat","char","class","const",
    "continue","creal","dchar","debug","default","delegate","delete","deprecated","do","double",
    "else","enum","export","extern","false","final","finally","float","for","foreach",
    "foreach_reverse","function","goto","idouble","if","ifloat","immutable","import","in","inout",
    "int","interface","invariant","ireal","is","lazy","long","macro","mixin","module","new",
    "nothrow","null","out","override","package","pragma","private","protected","public","pure",
    "real","ref","return","scope","shared","short","static","struct","super","switch",
    "synchronized","template","this","throw","true","try","typeid","typeof","ubyte","ucent","uint",
    "ulong","union","unittest","ushort","version","void","wchar","while","with","__gshared",
    "string","wstring","dstring","size_t","ptrdiff_t"];   // D aliases: shadow the type if used as a method name
string dname(string n) { return DKEYWORDS.canFind(n) ? n ~ "_" : n; }
// Module/file base for a class name: lowercased and keyword-safe (a D module name
// can't be a keyword, e.g. class `Private` -> module `private_`). Must be used at
// EVERY site that derives a module name, import, or output filename so they match.
string modBase(string n) { auto b = n.toLower; return DKEYWORDS.canFind(b) ? b ~ "_" : b; }

Rules loadRules(string dir, string glob) {
    import std.regex, std.file, std.path;
    Rules r;
    auto reRejWhole = regex(`<rejection\s+class="([^"]+)"\s*/>`);
    auto reRejFn    = regex(`<rejection\s+class="([^"]+)"\s+function-name="([^"]+)"`);
    auto reObj      = regex(`<object-type\b[^>]*\bname="([^"]+)"`);
    auto reVal      = regex(`<value-type\b[^>]*\bname="([^"]+)"`);
    foreach (de; dirEntries(dir, glob, SpanMode.shallow)) {
        auto txt = readText(de.name);
        foreach (m; txt.matchAll(reRejWhole)) r.rejectedClass[m[1]] = true;
        foreach (m; txt.matchAll(reRejFn))    r.rejectedMethod[m[1] ~ "::" ~ m[2]] = true;
        foreach (m; txt.matchAll(reObj))      r.objectType[lastNs(m[1])] = true;
        foreach (m; txt.matchAll(reVal))      r.valueType[lastNs(m[1])] = true;
    }
    return r;
}

struct PMap {
    string cty, dty = "void*", cpp = "{}", idty;
    string toRaw, fromRaw, free;   // idiomatic conversion snippets ({} = name)
    string containerTid;           // set if this return is a QList<T>
    string assocKey;               // set if this return is a QHash<K,V>/QMap<K,V>
    bool convertible() const { return toRaw.length || fromRaw.length; }
}

final class Unmappable : Exception { this(string m) { super(m); } }

string canon(CXType t) {
    return clang_getTypeSpelling(clang_getCanonicalType(t)).str
        .replace("const ", "").replace(" &", "").strip;
}

bool isPrivate(string c) {
    return c.canFind("QtPrivate") || c.canFind("QPrivateSignal") || c.canFind("function<");
}

PMap mapParam(CXType t) {
    auto ck = clang_getCanonicalType(t);            // resolve typedefs/elaborated
    if (ck.kind == CXType_LValueReference) {
        auto pt = clang_getPointeeType(ck);
        auto c = canon(pt);
        if (isPrivate(c)) throw new Unmappable("private type");
        if (auto cv = c in CONV) return PMap("void*", "void*", cv.cppDeref, cv.idty, cv.dToRaw, null, cv.dFree);
        if (auto p = c in PRIM)  return PMap(c ~ "*", *p ~ "*", "*{}", *p ~ "*");
        if (clang_getCanonicalType(pt).kind == CXType_Enum)
            return PMap("int", "int", format("static_cast<%s>({})", c), "int");
        if (isRecord(pt)) return PMap("void*", "void*", format("*static_cast<%s*>({})", c), "void*");
        throw new Unmappable("ref to " ~ clang_getTypeSpelling(pt).str);
    }
    auto c = canon(t);
    if (isPrivate(c)) throw new Unmappable("private type");
    if (auto cv = c in CONV) return PMap("void*", "void*", cv.cppDeref, cv.idty, cv.dToRaw, null, cv.dFree);
    if (auto p = c in PRIM)  return PMap(c, *p, "{}", *p);
    if (ck.kind == CXType_Enum) return PMap("int", "int", format("static_cast<%s>({})", c), "int");
    if (clang_getCursorSpelling(clang_getTypeDeclaration(ck)).str == "QFlags")
        return PMap("int", "int", format("%s({})", clang_getTypeSpelling(ck).str), "int");
    if (ck.kind == CXType_Pointer) {
        auto pt = clang_getPointeeType(ck);
        auto pc = canon(pt);
        if (pc == "char")
            return clang_getTypeSpelling(pt).str.canFind("const")
                ? PMap("const char*", "const(char)*", "{}", "const(char)*")
                : PMap("char*", "char*", "{}", "char*");     // non-const char* out-param
        if (pc == "void") return PMap("void*", "void*", "(void*)({})", "void*");
        if (auto p = pc in PRIM) return PMap(pc ~ "*", *p ~ "*", "{}", *p ~ "*");  // typed ptr (qintptr* etc.)
        if (isRecord(pt)) return PMap("void*", "void*", format("static_cast<%s*>({})", pc), "void*");
        throw new Unmappable("pointer to " ~ clang_getTypeSpelling(pt).str);
    }
    if (ck.kind == CXType_Record)
        return PMap("void*", "void*", format("*static_cast<%s*>({})", c), "void*");
    throw new Unmappable("type " ~ clang_getTypeSpelling(t).str);
}

PMap mapReturn(CXType t) {
    auto ck = clang_getCanonicalType(t);
    auto c = canon(t);
    if (c == "void") return PMap("void", "void", "{}", "void");
    if (isPrivate(c)) throw new Unmappable("private type");
    if (auto cv = c in CONV) return PMap("void*", "void*", cv.cppWrap, cv.idty, null, cv.dFromRaw, cv.dFree);
    if (auto p = c in PRIM)  return PMap(c, *p, "{}", *p);
    if (ck.kind == CXType_Enum) return PMap("int", "int", "static_cast<int>({})", "int");
    if (clang_getCursorSpelling(clang_getTypeDeclaration(ck)).str == "QFlags")
        return PMap("int", "int", "static_cast<int>({})", "int");
    if (ck.kind == CXType_LValueReference) {          // const T& brush()
        auto pt = clang_getPointeeType(ck);
        auto pc = canon(pt);
        if (auto cv = pc in CONV) return PMap("void*", "void*", cv.cppWrap, cv.idty, null, cv.dFromRaw, cv.dFree);
        if (auto p = pc in PRIM)  return PMap(pc, *p, "{}", *p);             // deref to value
        if (isRecord(pt)) return PMap("void*", "void*", "(void*)&({})", "void*");  // borrowed handle
        throw new Unmappable("return ref to " ~ clang_getTypeSpelling(pt).str);
    }
    auto tid = tryContainer(t);
    if (tid.length) {                          // QList<T> -> heap handle + D array
        auto pm = PMap("void*", "void*", format("new %s({})", CONTAINERS[tid].cppType),
                       CONTAINERS[tid].elemIdty ~ "[]");
        pm.containerTid = tid;
        return pm;
    }
    auto ak = tryAssoc(t);
    if (ak.length) {                           // QHash<K,V>/QMap -> heap handle + D AA
        auto a = ASSOCS[ak];
        auto pm = PMap("void*", "void*", format("new %s({})", a.cppType),
                       format("%s[%s]", a.valIdty, a.keyIdty));
        pm.assocKey = ak;
        return pm;
    }
    if (ck.kind == CXType_Pointer) {
        auto pt = clang_getPointeeType(ck);
        auto pc = canon(pt);
        if (pc == "char")
            return clang_getTypeSpelling(pt).str.canFind("const")
                ? PMap("const char*", "const(char)*", "{}", "const(char)*")
                : PMap("char*", "char*", "{}", "char*");
        if (pc == "void" || pc in PRIM || isRecord(pt))
            return PMap("void*", "void*", "(void*)({})", "void*");   // strip const
    }
    if (ck.kind == CXType_Record) {
        // object-types (QObject-derived) aren't copyable — don't heap-copy by value
        if (lastNs(c) in RULES.objectType)
            throw new Unmappable("object-type by value: " ~ c);
        return PMap("void*", "void*", format("new %s({})", c), "void*");
    }
    throw new Unmappable("return " ~ clang_getTypeSpelling(t).str);
}

bool isRecord(CXType t) {
    auto d = clang_getTypeDeclaration(clang_getCanonicalType(t));
    return d.kind == CXCursor_ClassDecl || d.kind == CXCursor_StructDecl;
}

// --- AST helpers -----------------------------------------------------------
private struct Ctx { CXCursor[] kids; }
extern (C) CXChildVisitResult collect(CXCursor c, CXCursor, CXClientData d) {
    (cast(Ctx*) d).kids ~= c;
    return CXChildVisitResult.Continue;
}
CXCursor[] children(CXCursor c) {
    Ctx ctx;
    clang_visitChildren(c, &collect, &ctx);
    return ctx.kids;
}

bool hasDefault(CXCursor param) {
    foreach (ch; children(param))
        if (ch.kind >= CXCursor_FirstExpr) return true;
    return false;
}

// The D ` = <literal>` for a param's C++ default, evaluated with libclang, so a
// ctor like QWidget(QWidget* parent = nullptr, Qt::WindowFlags f = {}) keeps BOTH
// defaults (D requires trailing params to be defaulted once any earlier one is).
// `dtype` is the mapped D type. Returns "" if there's no default / it can't be
// evaluated (the caller supplies a `.init` fallback to preserve arg ordering).
string paramDefault(CXCursor param, string dtype) {
    if (dtype.startsWith("ref ")) return "";      // can't default a ref param
    CXCursor expr; bool found;
    foreach (ch; children(param))
        if (ch.kind >= CXCursor_FirstExpr) { expr = ch; found = true; }   // last expr = the default
    if (!found) return "";
    if (dtype.endsWith("*")) return " = null";    // nullptr / pointer default
    auto ev = clang_Cursor_Evaluate(expr);
    if (ev is null) return "";
    scope(exit) clang_EvalResult_dispose(ev);
    auto k = clang_EvalResult_getKind(ev);
    if (k == 1) {                                  // integer-valued
        auto v = clang_EvalResult_getAsLongLong(ev);
        if (dtype == "bool") return v ? " = true" : " = false";
        if (dtype == "float" || dtype == "double" || dtype == "real") return format(" = %d", v);
        if (dtype in PRIMSET) return format(" = %d", v);        // int / uint / long / ...
        return format(" = cast(%s) %d", dtype, v);             // enum type
    }
    if (k == 2 && (dtype == "float" || dtype == "double" || dtype == "real"))
        return format(" = %g", clang_EvalResult_getAsDouble(ev));
    return "";
}
// D primitive type names (the values of PRIM) for quick membership tests.
__gshared bool[string] PRIMSET;
shared static this() { foreach (_, v; PRIM) PRIMSET[v] = true; }
bool isPublic(CXCursor c) { return clang_getCXXAccessSpecifier(c) == CX_CXXPublic; }

// --- extraction ------------------------------------------------------------
struct Method { string kind, name, fn; PMap ret; Param[] params; bool isStatic; }
struct Param { string name; PMap m; }

Param[] params(CXCursor cur) {
    Param[] r;
    auto n = clang_Cursor_getNumArguments(cur);
    foreach (i; 0 .. n) {
        auto a = clang_Cursor_getArgument(cur, i);
        if (hasDefault(a)) break;                 // drop defaulted trailing args
        r ~= Param(text("a", i, "_", clang_getCursorSpelling(a).str), mapParam(clang_getCursorType(a)));
    }
    return r;
}

// The base-SPECIFIER cursors, in declaration order and parallel to baseDecls(). baseDecls
// resolves each to its type declaration, which loses the access specifier — and that specifier
// decides whether an upcast to the base is even legal C++. QQuickItemGroup inherits
// QQuickItemChangeListener protectedly; emitting a static_cast to it does not compile.
CXCursor[] baseSpecs(CXCursor node) {
    CXCursor[] r;
    foreach (c; children(node))
        if (c.kind == CXCursor_CXXBaseSpecifier)
            r ~= c;
    return r;
}

CXCursor[] baseDecls(CXCursor node) {
    // Resolve to the DEFINITION first. A cursor that is only a declaration has no children, so a
    // base reached that way came back with no bases of its own and the ancestry walk stopped one
    // level in: QQuickCheckLabel -> QQuickText -> [] made derivesFrom(QQuickItem) false, and every
    // QtQuick.Controls.impl type deriving through QQuickText was silently left unsubclassed (and
    // so absent from qmlmap). isQObject and collectVirt walk the same chain and had the same hole.
    auto def = clang_getCursorDefinition(node);
    if (def.kind < CXCursor_FirstInvalid) node = def;
    CXCursor[] r;
    foreach (c; children(node))
        if (c.kind == CXCursor_CXXBaseSpecifier)
            r ~= clang_getTypeDeclaration(clang_getCursorType(c));
    return r;
}
// True if `node` transitively derives from QObject — those classes get the
// BindingManager treatment (identity, destroyed()-invalidation, ownership).
bool isQObject(CXCursor node) {
    bool[string] seen;
    return isQObjectRec(node, seen);
}
private bool isQObjectRec(CXCursor node, ref bool[string] seen) {
    auto k = clang_getCursorSpelling(node).str;
    if (k.length) { if (k in seen) return false; seen[k] = true; }
    foreach (b; baseDecls(node)) {
        if (clang_getCursorSpelling(b).str == "QObject") return true;
        if (isQObjectRec(b, seen)) return true;
    }
    return false;
}
// True if `node` IS or transitively derives from a class named `baseName` — used to auto-select
// every discovered subtype of a base (e.g. all QQuickItem-derived visual types) for subclassing,
// so the wrapper generator never needs a hand-maintained per-type list.
bool derivesFrom(CXCursor node, string baseName) {
    bool[string] seen;
    return derivesFromRec(node, baseName, seen);
}
private bool derivesFromRec(CXCursor node, string baseName, ref bool[string] seen) {
    if (clang_getCursorSpelling(node).str == baseName) return true;
    auto k = clang_getCursorUSR(node).str;
    if (k.length) { if (k in seen) return false; seen[k] = true; }
    foreach (b; baseDecls(node))
        if (derivesFromRec(b, baseName, seen)) return true;
    return false;
}
// True if `node` can be default-constructed by a D subclass: concrete (not abstract) and has a
// PUBLIC default constructor (or no user-declared ctors -> implicit public default). Auto-subclass
// only these — an abstract type (pure virtuals) or one whose only ctors are protected/parameterised
// (e.g. QQuickImplicitSizeItem) can't back a trampoline that default-constructs its base.
bool isSubclassable(CXCursor node) {
    if (clang_CXXRecord_isAbstract(node)) return false;
    // Must be EXPORTED (Q_*_EXPORT -> Default visibility under -fvisibility=hidden): a subclass
    // references the base's ctor + staticMetaObject, so those symbols must be linkable. Legacy
    // compat types (QQuickPre64TextEdit) are hidden -> their symbols aren't in the .so -> link error.
    // This test only means something for a type coming from a SHARED LIBRARY. In headers-mode the
    // sources are the user's own and get compiled into the binary, so an unexported class (an app
    // type with no export macro at all — the normal case) is perfectly linkable.
    if (!sourceFilter.length && clang_getCursorVisibility(node) != 3) return false;
    bool anyCtor = false, pubDefault = false;
    foreach (c; children(node))
        if (c.kind == CXCursor_Constructor) {
            anyCtor = true;
            if (isPublic(c) && clang_CXXConstructor_isDefaultConstructor(c)) pubDefault = true;
        }
    return pubDefault || !anyCtor;
}
void collectVirt(CXCursor node, ref bool[string] pur, ref bool[string] impl, ref bool[string] seen) {
    auto k = clang_getCursorUSR(node).str;
    if (k.length) { if (k in seen) return; seen[k] = true; }
    foreach (c; children(node))
        if (c.kind == CXCursor_CXXMethod) {
            auto n = clang_getCursorSpelling(c).str;
            if (clang_CXXMethod_isPureVirtual(c)) pur[n] = true; else impl[n] = true;
        }
    foreach (b; baseDecls(node)) collectVirt(b, pur, impl, seen);
}
// Abstract if any pure-virtual (from this class or a base) is left unimplemented.
bool isAbstractRec(CXCursor node) {
    bool[string] pur, impl, seen;
    collectVirt(node, pur, impl, seen);
    foreach (n; pur.byKey) if (n !in impl) return true;
    return false;
}

Method[] extract(CXCursor node) {
    Method[] ms;
    auto className = clang_getCursorSpelling(node).str;
    bool abstract_ = isAbstractRec(node);
    foreach (c; children(node)) {
        if (!isPublic(c)) continue;
        try {
            if (c.kind == CXCursor_Constructor && !abstract_) {
                if (clang_CXXConstructor_isCopyConstructor(c) || clang_CXXConstructor_isMoveConstructor(c))
                    continue;
                ms ~= Method("ctor", "", null, PMap.init, params(c), false);
            } else if (c.kind == CXCursor_CXXMethod) {
                auto sp = clang_getCursorSpelling(c).str;
                if (sp.startsWith("operator")) continue;
                // moc boilerplate that isn't useful to bind
                if (["metaObject", "qt_metacall", "qt_metacast", "qt_static_metacall",
                     "tr", "trUtf8", "d_func"].canFind(sp)) continue;
                if ((className ~ "::" ~ sp) in RULES.rejectedMethod) continue;  // shiboken rejection
                auto rt = clang_getTypeSpelling(clang_getCursorResultType(c)).str;
                if (rt.canFind("iterator") || rt.canFind("Iterator")) continue;  // begin()/end() etc.
                ms ~= Method("method", sp, null, mapReturn(clang_getCursorResultType(c)),
                             params(c), clang_CXXMethod_isStatic(c) != 0);
            }
        } catch (Unmappable u) { MISSING[normalizeMiss(u.msg)]++; }
    }
    return ms;
}

__gshared int[string] MISSING;   // histogram of what we can't map yet

// collapse "return QFoo", "type QFoo", "pointer to QFoo *" into a stable key
string normalizeMiss(string m) {
    foreach (pre; ["return ", "type ", "pointer to ", "ref to "])
        if (m.startsWith(pre)) return m[pre.length .. $].replace(" *", "*").strip;
    return m;
}
