// emit.d — emission (C shim + extern(C) D + idiomatic struct) and the driver.
module emit;

import clang_c, gen, emit_cxx;
import std.stdio, std.string, std.array, std.algorithm, std.conv, std.json,
       std.process, std.file, std.path, std.datetime.stopwatch;

string cIdent(string cty) {
    return cty.replace("unsigned ", "u").replace("*", "p").replace(" ", "_");
}

// (DKEYWORDS/dname moved to gen.d so both emitters share them.)

// Root `Object` methods a `class` wrapper inherits — a Qt method of the same name
// would implicitly override them (different semantics), so escape it with a `_`.
enum string[] OBJECTMEMBERS = ["toString", "toHash", "opEquals", "opCmp", "factory"];

struct Out { string h, cpp, d; }

Out emitClass(string name, string cppName, string include, string dpkg, Method[] ms, string manifest, bool isQObject) {
    auto pfx = "qtd_" ~ name;   // name = unqualified (D/file/pfx); cppName = qualified (C++)
    // overload-aware, collision-free C names
    int[string] baseCount;
    foreach (m; ms) baseCount[m.kind == "ctor" ? pfx ~ "_new" : pfx ~ "_" ~ m.name]++;
    bool[string] used = [pfx ~ "_delete": true];
    string fname(string base, Param[] ps) {
        auto cand = base;
        if (baseCount[base] > 1 && ps.length)
            cand = base ~ ps.map!(p => "_" ~ cIdent(p.m.cty)).join;
        auto fin = cand; int n = 1;
        while (fin in used) { n++; fin = text(cand, "_", n); }
        used[fin] = true; return fin;
    }

    string[] hdr, cpp, decl;
    hdr ~= format("void %s_delete(%sHandle self);", pfx, pfx);
    cpp ~= format("void %s_delete(%sHandle self) { delete static_cast<%s*>(self); }", pfx, pfx, cppName);
    decl ~= format("    void %s_delete(void* self);", pfx);

    foreach (ref m; ms) {
        auto cargs = m.params.map!(p => p.m.cpp.replace("{}", p.name)).join(", ");
        auto dparams = m.params.map!(p => p.m.dty ~ " " ~ p.name).array;   // D types for extern(C)
        if (m.kind == "ctor") {
            m.fn = fname(pfx ~ "_new", m.params);
            auto sig = m.params.map!(p => p.m.cty ~ " " ~ p.name).join(", ");
            hdr ~= format("%sHandle %s(%s);", pfx, m.fn, sig);
            cpp ~= format("%sHandle %s(%s) { return new %s(%s); }", pfx, m.fn, sig, cppName, cargs);
            decl ~= format("    void* %s(%s);", m.fn, dparams.join(", "));
        } else {
            string sig, callexpr, dsig;
            if (m.isStatic) {
                sig = m.params.map!(p => p.m.cty ~ " " ~ p.name).join(", ");
                dsig = dparams.join(", ");
                callexpr = format("%s::%s(%s)", cppName, m.name, cargs);
            } else {
                sig = ([format("%sHandle self", pfx)] ~ m.params.map!(p => p.m.cty ~ " " ~ p.name).array).join(", ");
                dsig = (["void* self"] ~ dparams).join(", ");
                callexpr = format("static_cast<%s*>(self)->%s(%s)", cppName, m.name, cargs);
            }
            m.fn = fname(pfx ~ "_" ~ m.name, m.params);
            auto body_ = m.ret.cpp.replace("{}", callexpr);
            auto ret = m.ret.cty == "void" ? "" : "return ";
            hdr ~= format("%s %s(%s);", m.ret.cty, m.fn, sig);
            cpp ~= format("%s %s(%s) { %s%s; }", m.ret.cty, m.fn, sig, ret, body_);
            decl ~= format("    %s %s(%s);", m.ret.dty, m.fn, dsig);
        }
    }

    auto usesContainer = ms.any!(m => m.kind != "ctor" && (m.ret.containerTid.length || m.ret.assocKey.length));
    auto uses = ms.any!(m => m.params.any!(p => p.m.convertible)
        || (m.kind != "ctor" && m.ret.convertible))
        || ms.any!(m => m.kind != "ctor" && m.ret.containerTid.length
            && CONTAINERS[m.ret.containerTid].elemFromRaw.length)
        || ms.any!(m => m.kind != "ctor" && m.ret.assocKey.length
            && (ASSOCS[m.ret.assocKey].keyFrom.length || ASSOCS[m.ret.assocKey].valFrom.length));
    auto imports = (uses ? "import qtd_convert;\n" : "")
        ~ (usesContainer ? "import qtcontainers;\n" : "")
        ~ (isQObject ? "import bindingmanager;\n" : "");
    auto guard = "QTD_" ~ name.toUpper ~ "_H";
    Out o;
    o.h = format("%s\n#ifndef %s\n#define %s\n#ifdef __cplusplus\nextern \"C\" {\n#endif\n"
        ~ "typedef void *%sHandle; /* %s* */\n\n%s\n\n#ifdef __cplusplus\n}\n#endif\n#endif\n",
        manifest, guard, guard, pfx, name, hdr.join("\n"));
    auto incLine = (include.canFind('/') || include.endsWith(".h") || include.endsWith(".hpp"))
        ? format("#include \"%s\"", include) : format("#include <%s>", include);
    o.cpp = format("%s\n#include \"%s.h\"\n#include <QString>\n#include <QVariant>\n%s\n\nextern \"C\" {\n\n%s\n\n} // extern \"C\"\n",
        manifest, name.toLower, incLine, cpp.join("\n"));
    o.d = format("%s\nmodule %s.%s;\n%s\nextern (C) nothrow @nogc {\n%s\n}\n\n%s",
        manifest, dpkg, name.toLower, imports,
        decl.join("\n"), emitStruct(name, pfx, ms, isQObject));
    return o;
}

// Idiomatic D reference wrapper: a `class` with real constructors, so Qt classes
// are built the D way — `new QLabel("hi")`. QObject-derived classes additionally
// go through the BindingManager (à la Shiboken): wrap() returns the SAME wrapper
// for a pointer (identity), the wrapper is invalidated when C++ destroys the
// object (destroyed() hook), and dispose() never deletes an object Qt owns.
string emitStruct(string name, string pfx, Method[] ms, bool isQObject) {
    string[] L = [format("class %s {", name), "    void* _h;", "    alias _h this;",
        "    private this(void* h, typeof(null)) @nogc nothrow { _h = h; }"];
    if (isQObject) {
        L ~= "    private void _register() { bindingmanager.register(_h, this, &_invalidate, true); }";
        L ~= format("    private static void _invalidate(Object o) nothrow { (cast(%s) o)._h = null; }", name);
        L ~= format("    static %s wrap(void* h) {", name);
        L ~= "        if (h is null) return null;";
        L ~= format("        if (auto e = bindingmanager.retrieve(h)) return cast(%s) e;", name);
        L ~= format("        auto w = new %s(h, null); w._register(); return w;", name);
        L ~= "    }";
        L ~= "    void dispose() {";
        L ~= "        if (_h is null) return;";
        L ~= format("        if (!bindingmanager.cppOwns(_h)) %s_delete(_h);", pfx);
        L ~= "    }";
    } else {
        L ~= format("    static %s wrap(void* h) { return new %s(h, null); }", name, name);
        L ~= format("    void dispose() { %s_delete(_h); }", pfx);
    }
    bool[string] seen;
    foreach (m; ms) {
        // D method name: escape keywords, the fixed class members (dispose/wrap),
        // and inherited Object methods (toString/toHash/opEquals/...).
        auto dn = m.kind == "ctor" ? "\0ctor" : dname(m.name);
        if (m.kind != "ctor" && (dn == "dispose" || dn == "wrap" || OBJECTMEMBERS.canFind(dn)))
            dn ~= "_";
        auto key = text(dn, "|", m.params.map!(p => p.m.idty).join(","), "|", m.isStatic);
        if (key in seen) continue;
        seen[key] = true;
        auto idp = m.params.map!(p => p.m.idty ~ " " ~ p.name).join(", ");
        string[] pre; string[] callArgs;
        if (m.kind != "ctor" && !m.isStatic) callArgs ~= "_h";
        foreach (i, p; m.params) {
            if (p.m.toRaw.length) {
                auto v = text("_a", i);
                pre ~= format("        auto %s = %s;", v, p.m.toRaw.replace("{}", p.name));
                if (p.m.free.length)
                    pre ~= format("        scope(exit) %s;", p.m.free.replace("{}", v));
                callArgs ~= v;
            } else callArgs ~= p.name;
        }
        auto call = format("%s(%s)", m.fn, callArgs.join(", "));
        if (m.kind == "ctor") {
            L ~= format("    this(%s) {", idp);
            L ~= pre;
            L ~= format("        _h = %s;", call);
            if (isQObject) L ~= "        _register();";   // identity + destroyed() hook
            L ~= "    }";
        } else {
            auto kw = m.isStatic ? "static " : "";
            if (m.ret.containerTid.length) {                    // QList<T> -> T[]
                auto ct = CONTAINERS[m.ret.containerTid];
                auto cp = "qtd_QList_" ~ ct.tid;
                auto elem = ct.elemFromRaw.length
                    ? ct.elemFromRaw.replace("{}", cp ~ "_at(_r, _i)")
                    : cp ~ "_at(_r, _i)";
                L ~= format("    %s%s[] %s(%s) {", kw, ct.elemIdty, dn, idp);
                L ~= pre;
                L ~= format("        auto _r = %s;", call);
                L ~= format("        auto _n = %s_size(_r);", cp);
                L ~= format("        %s[] _v; _v.length = _n;", ct.elemIdty);
                L ~= format("        foreach (_i; 0 .. _n) _v[_i] = %s;", elem);
                L ~= format("        %s_delete(_r);", cp);
                L ~= "        return _v;"; L ~= "    }";
            } else if (m.ret.assocKey.length) {                // QHash/QMap -> V[K]
                auto a = ASSOCS[m.ret.assocKey];
                auto ap = a.pfx;
                auto kE = a.keyFrom.length ? a.keyFrom.replace("{}", ap ~ "_iter_key(_it)") : ap ~ "_iter_key(_it)";
                auto vE = a.valFrom.length ? a.valFrom.replace("{}", ap ~ "_iter_val(_it)") : ap ~ "_iter_val(_it)";
                L ~= format("    %s%s[%s] %s(%s) {", kw, a.valIdty, a.keyIdty, dn, idp);
                L ~= pre;
                L ~= format("        auto _r = %s;", call);
                L ~= format("        %s[%s] _aa;", a.valIdty, a.keyIdty);
                L ~= format("        auto _it = %s_iter_new(_r);", ap);
                L ~= format("        while (%s_iter_valid(_r, _it)) {", ap);
                L ~= format("            auto _k = %s; auto _v2 = %s;", kE, vE);
                L ~= "            _aa[_k] = _v2;";
                L ~= format("            %s_iter_next(_it);", ap);
                L ~= "        }";
                L ~= format("        %s_iter_delete(_it);", ap);
                L ~= format("        %s_delete(_r);", ap);
                L ~= "        return _aa;"; L ~= "    }";
            } else if (m.ret.cty == "void") {
                L ~= format("    %svoid %s(%s) {", kw, dn, idp);
                L ~= pre; L ~= format("        %s;", call); L ~= "    }";
            } else if (m.ret.convertible) {
                L ~= format("    %s%s %s(%s) {", kw, m.ret.idty, dn, idp);
                L ~= pre;
                L ~= format("        auto _r = %s;", call);
                L ~= format("        auto _v = %s;", m.ret.fromRaw.replace("{}", "_r"));
                if (m.ret.free.length)
                    L ~= format("        %s;", m.ret.free.replace("{}", "_r"));
                L ~= "        return _v;"; L ~= "    }";
            } else {
                L ~= format("    %s%s %s(%s) {", kw, m.ret.idty, dn, idp);
                L ~= pre; L ~= format("        return %s;", call); L ~= "    }";
            }
        }
    }
    L ~= "}";
    return L.join("\n") ~ "\n";
}

// --- discovery / driver ----------------------------------------------------
struct DiscCtx { CXCursor[] classes; CXCursor[] functions; bool[string] seen; }
extern (C) CXChildVisitResult discVisit(CXCursor c, CXCursor, CXClientData d) {
    auto ctx = cast(DiscCtx*) d;
    if ((c.kind == CXCursor_ClassDecl || c.kind == CXCursor_StructDecl) && clang_isCursorDefinition(c)) {
        auto n = clang_getCursorSpelling(c).str;
        if (n.length && !n.canFind('<') && !n.canFind('(') && !n.endsWith("Private")
                && !n.canFind("PrivateSignal") && n !in ctx.seen) {
            CXFile f; uint ln, col, off;
            clang_getFileLocation(clang_getCursorLocation(c), &f, &ln, &col, &off);
            auto loc = f ? clang_getFileName(f).str : "";
            // your-own-code mode: any class defined in your files; else Qt framework
            bool want = sourceFilter.length ? loc.canFind(sourceFilter)
                                            : (n[0] == 'Q' && loc.canFind(qtMarker));
            if (want) { ctx.seen[n] = true; ctx.classes ~= c; }
        }
    }
    // free (namespace/global) functions -> bound as extern(C++) free functions.
    else if (c.kind == CXCursor_FunctionDecl) {
        auto n = clang_getCursorSpelling(c).str;
        if (n.length && !n.startsWith("operator") && !n.canFind('<')) {
            CXFile f; uint ln, col, off;
            clang_getFileLocation(clang_getCursorLocation(c), &f, &ln, &col, &off);
            auto loc = f ? clang_getFileName(f).str : "";
            bool want = sourceFilter.length ? loc.canFind(sourceFilter) : loc.canFind(qtMarker);
            if (want) ctx.functions ~= c;   // overloads kept (distinct cursors)
        }
    }
    return CXChildVisitResult.Recurse;
}

// The generator no longer compiles C++ or D: it only emits sources. reggae owns the
// whole build graph (compile each .cpp/.d, archive per-module, link). The former
// gen-phase clang++/ar helper (buildCxxLib) and the Qt private-header discovery
// (mocPrivateFlags) moved to reggae/qtd_build.d.

void main(string[] args) {
    CONV["QString"]    = Conv("*static_cast<QString*>({})", "new QString({})", "toQString({})", "toDString({})", "toDStringOwned({})", "qtd_qstring_delete({})");
    CONV["QByteArray"] = Conv("*static_cast<QByteArray*>({})", "new QByteArray({})", "toQByteArray({})", "fromQByteArray({})", "fromQByteArrayOwned({})", "qtd_qbytearray_delete({})");
    CONV["QUrl"]       = Conv("*static_cast<QUrl*>({})", "new QUrl({})", "toQUrl({})", "fromQUrl({})", "fromQUrlOwned({})", "qtd_qurl_delete({})");
    // string views: reuse the QString/QByteArray helpers; only the C++ deref/wrap differ
    CONV["QStringView"]    = Conv("QStringView(*static_cast<QString*>({}))", "new QString(({}).toString())", "toQString({})", "toDString({})", "toDStringOwned({})", "qtd_qstring_delete({})");
    CONV["QAnyStringView"] = Conv("QAnyStringView(*static_cast<QString*>({}))", "new QString(({}).toString())", "toQString({})", "toDString({})", "toDStringOwned({})", "qtd_qstring_delete({})");
    CONV["QByteArrayView"] = Conv("QByteArrayView(*static_cast<QByteArray*>({}))", "new QByteArray(({}).toByteArray())", "toQByteArray({})", "fromQByteArray({})", "fromQByteArrayOwned({})", "qtd_qbytearray_delete({})");
    // QVariant -> idiomatic QtVariant struct (owns the handle; no temp free)
    CONV["QVariant"] = Conv("*static_cast<QVariant*>({})", "new QVariant({})", "({}).handle", "QtVariant({})", "QtVariant({})", "", "QtVariant");

    auto specPath = args.length > 1 ? args[1] : "spec.json";
    auto spec = parseJSON(readText(specPath));
    auto outDir = buildNormalizedPath(specPath.dirName, spec["out_dir"].str);
    mkdirRecurse(outDir);
    auto dpkg = spec["d_package"].str;
    // Each dpkg-scoped module is written at a path matching its `module` name
    // (dots -> dirs), so reggae compiles per-module and `import qt.pkg.x` resolves
    // against `-I<outDir>`. Top-level runtime modules (cxxrt/holder/qtmoc) and the
    // .cpp shims (no D module) stay at outDir root.
    auto dsub = buildPath(outDir, dpkg.replace(".", dirSeparator));
    mkdirRecurse(dsub);
    if (auto qm = "qt_marker" in spec.object) qtMarker = qm.str;
    if (auto sf = "source_filter" in spec.object) sourceFilter = sf.str;

    // "what doesn't come for free": rules from PySide/shiboken's typesystem XML
    if (auto ts = "typesystem_dir" in spec.object) {
        RULES = loadRules(ts.str, ("typesystem_glob" in spec.object) ? spec["typesystem_glob"].str : "typesystem_*.xml");
        writefln("shiboken rules: %d rejected classes, %d rejected methods, %d object-types, %d value-types",
            RULES.rejectedClass.length, RULES.rejectedMethod.length, RULES.objectType.length, RULES.valueType.length);
    }

    auto pkgs = spec["pkg_config"].str.split;
    auto cflags = execute(["pkg-config", "--cflags"] ~ pkgs).output.split;
    auto res = execute(["clang", "-print-resource-dir"]).output.strip;
    string[] extraI;
    if (auto ip = "include_paths" in spec.object)
        foreach (p; ip.array) extraI ~= "-I" ~ p.str;
    // Make Qt signals detectable: Q_SIGNALS expands to
    // `public QT_ANNOTATE_ACCESS_SPECIFIER(qt_signal)`, so defining the annotation
    // hook tags every signal method with an AnnotateAttr("qt_signal") (shiboken's way).
    // -fvisibility=hidden: unmarked (internal) classes become Hidden while Q_*_EXPORT ones
    // stay Default — so clang_getCursorVisibility distinguishes a public type (linkable
    // dtor/copy-ctor -> safe to mark non-trivial) from an internal one (unlinkable).
    auto argv = ["-x", "c++", "-std=c++17", "-fvisibility=hidden", "-isystem", buildPath(res, "include"),
        "-DQT_ANNOTATE_ACCESS_SPECIFIER(x)=__attribute__((annotate(#x)))"] ~ cflags ~ extraI;
    auto cargv = argv.map!(a => a.toStringz).array;

    string discMod;
    if (auto p = "discover_module" in spec.object) discMod = p.str;
    string[] headers;   // your own Qt C++ headers to scan
    if (auto h = "headers" in spec.object) foreach (x; h.array) headers ~= x.str;
    if (auto s = "subclass" in spec.object)   // classes to subclass from D (trampolines)
        foreach (x; s.array) SUBCLASS[x.str] = true;

    string src;
    if (headers.length) src = headers.map!(h => format("#include \"%s\"", h)).join("\n") ~ "\n";
    else if (discMod.length) src = format("#include <%s>\n", discMod);
    else src = spec["classes"].array.map!(c => format("#include <%s>", c["include"].str)).join("\n") ~ "\n";

    CXUnsavedFile uf;
    uf.Filename = "_gen.cpp".toStringz;
    uf.Contents = src.toStringz;
    uf.Length = src.length;

    auto sw = StopWatch(AutoStart.yes);
    auto index = clang_createIndex(0, 0);
    auto tu = clang_parseTranslationUnit(index, "_gen.cpp",
        cast(const(char*)*) cargv.ptr, cast(int) cargv.length, &uf, 1, 0x02 /*Incomplete*/);
    auto tuCursor = clang_getTranslationUnitCursor(tu);

    // resolve target class cursors
    CXCursor[] targets; string[] includes;
    CXCursor[] freeFns;   // namespace/global free functions (discovery mode only)
    if (discMod.length || headers.length) {
        DiscCtx ctx;
        clang_visitChildren(tuCursor, &discVisit, &ctx);
        targets = ctx.classes;
        freeFns = ctx.functions;
        foreach (cur; targets) {
            if (discMod.length) includes ~= discMod;
            else {   // your own class -> the header it's defined in
                CXFile f; uint ln, col, off;
                clang_getFileLocation(clang_getCursorLocation(cur), &f, &ln, &col, &off);
                includes ~= f ? clang_getFileName(f).str : "";
            }
        }
        writefln("discovered %d classes%s", targets.length,
                 discMod.length ? " in <" ~ discMod ~ ">" : " in your headers");
    } else {
        bool[string] want;
        foreach (c; spec["classes"].array) want[c["name"].str] = true;
        DiscCtx ctx;
        clang_visitChildren(tuCursor, &discVisit, &ctx);
        foreach (cur; ctx.classes)
            if (clang_getCursorSpelling(cur).str in want) targets ~= cur;
        foreach (c; spec["classes"].array) includes ~= c["include"].str;
    }

    auto manifest = "// GENERATED by qt-dlang-gen (D) from " ~ spec["qt_version"].str
        ~ ".\n// Do NOT edit — regenerate via generator-d.";
    bool cxxAbi = ("abi" in spec.object) !is null && spec["abi"].str == "cxx";
    bool[string] cxxGen, cxxRef;   // proper class names: fully-emitted vs referenced
    bool qt5 = spec["qt_version"].str.startsWith("5");   // value-type ABI difere Qt5<->Qt6
    QT5 = qt5;   // tryQList needs it to distinguish Qt5 QVector (QArrayData) from QList (QListData)
    WRAPPER = ("wrapper" in spec.object) !is null && spec["wrapper"].type == JSONType.true_;   // GC wrapper mode
    if (cxxAbi) {
        std.file.write(buildPath(outDir, "cxxrt.d"), cxxRuntime(manifest));
        std.file.write(buildPath(dsub, "qstring.d"), qstringRuntime(manifest, dpkg, qt5));
        std.file.write(buildPath(dsub, "qbytearray.d"), qbytearrayRuntime(manifest, dpkg, qt5));
        std.file.write(buildPath(dsub, "qanystringview.d"), qanystringviewRuntime(manifest, dpkg));
        cxxGen["QString"] = true;      // provided by smart runtimes, not stubbed/generated
        cxxGen["QByteArray"] = true;
        cxxGen["QAnyStringView"] = true;
        cxxGen["qtcontainers"] = true;
    }
    int ok, total;
    int rejected;
    foreach (i, cur; targets) {
        auto name = clang_getCursorSpelling(cur).str;
        auto cppName = clang_getTypeSpelling(clang_getCursorType(cur)).str;  // qualified (Qt3DCore::QEntity)
        if (name in RULES.rejectedClass) { rejected++; continue; }   // shiboken rejection
        // Provided by a hand-written smart runtime (QString/QByteArray/QAnyStringView)
        // — pre-marked in cxxGen; must NOT be overwritten by a generated class.
        if (cxxAbi && name in cxxGen) continue;
        auto inc = discMod.length ? discMod : (i < includes.length ? includes[i] : name);
        try {
            if (cxxAbi) {   // pure extern(C++): one .d, no shim
                string[] imps;
                auto d = emitCxxUnit(cur, name, cppName, dpkg, manifest, imps);
                std.file.write(buildPath(dsub, modBase(name) ~ ".d"), d);
                cxxGen[name] = true;
                foreach (r; imps) cxxRef[r] = true;
                ok++;
            } else {
                auto ms = extract(cur);
                auto o = emitClass(name, cppName, inc, dpkg, ms, manifest, isQObject(cur));
                auto base = buildPath(outDir, name.toLower);
                std.file.write(base ~ ".h", o.h);
                std.file.write(base ~ ".cpp", o.cpp);
                std.file.write(base ~ ".d", o.d);
                ok++; total += cast(int) ms.length;
            }
        } catch (Exception e) {
            stderr.writefln("[%s] skipped: %s", name, e.msg);
        }
    }
    // Referenced-but-not-requested types get an opaque stub: enough to be a valid
    // pointer target, with NO methods and NO transitive imports. This is what keeps
    // the binding à la carte — pulling QTimer doesn't drag in all of QtCore.
    // transitive base closure: every base of a generated class is generated in
    // full (vtable + exact size) — bases can never be opaque stubs.
    if (cxxAbi) while (true) {
        string[] todo;
        foreach (bn, _; PENDING_BASES) if (bn !in cxxGen) todo ~= bn;
        if (!todo.length) break;
        foreach (bn; todo) {
            auto bcur = PENDING_BASES[bn];
            auto bcpp = clang_getTypeSpelling(clang_getCursorType(bcur)).str;
            string[] bimps;
            try {
                auto d = emitCxxUnit(bcur, bn, bcpp, dpkg, manifest, bimps);
                std.file.write(buildPath(dsub, modBase(bn) ~ ".d"), d);
                cxxGen[bn] = true;
                foreach (r; bimps) cxxRef[r] = true;
            } catch (Exception e) {
                stderr.writefln("[%s base] skipped: %s", bn, e.msg);
                cxxGen[bn] = true;
            }
        }
    }
    if (cxxAbi) {
        // Verifica os inlines traduzidos de TODAS as classes num único ldc2 (em vez
        // de um por classe — era o gargalo da geração); conserta só os que falham.
        verifyInlinesBatched(outDir, dpkg);
        if (freeFns.length) {   // namespace/global free functions -> one functions.d module
            string[] fimps;
            std.file.write(buildPath(dsub, "functions.d"), emitFunctionsModule(freeFns, dpkg, manifest, fimps));
            cxxGen["functions"] = true;
            foreach (r; fimps) cxxRef[r] = true;
            writefln("cxx: bound %d free functions -> functions.d", freeFns.length);
        }
        foreach (en, decl; ENUMS) {   // referenced enums -> their own D modules
            std.file.write(buildPath(dsub, modBase(en) ~ ".d"), emitEnumModule(decl, dpkg, manifest));
            cxxGen[en] = true;
        }
        foreach (tid, e; QLISTS) {    // QList<T> instantiations -> per-T D modules
            std.file.write(buildPath(dsub, "qlist_" ~ tid ~ ".d"), emitQListModule(tid, e, dpkg, manifest, qt5));
            cxxGen["qlist_" ~ tid] = true;
        }
        // Container runtime — emitted NOW (after all units registered their combos in
        // COMBOS) so it's demand-driven. Template shims are the ONLY generated C++.
        // The generator is a pure code generator: it EMITS every .cpp/.d source here
        // but compiles nothing — reggae owns the whole build graph (C+++D->link).
        std.file.write(buildPath(outDir, "qtcontainers.cpp"), containersCpp(manifest));
        std.file.write(buildPath(dsub, "qtcontainers.d"), containersD(manifest, dpkg));
        if (COMBOS.length) cxxGen["qtcontainers"] = true;
        // Signal/slot bridge — one functor-connect shim per parameterless signal.
        auto sigInc = discMod.length ? format("#include <%s>\n", discMod)
            : includes.sort.uniq.map!(i => (i.canFind('/') || i.endsWith(".h"))
                ? format("#include \"%s\"\n", i) : format("#include <%s>\n", i)).join;
        std.file.write(buildPath(outDir, "qtsignals.cpp"), signalsCpp(manifest, sigInc));
        std.file.write(buildPath(dsub, "qtsignals.d"), signalsD(manifest, dpkg));
        if (SIGNALS.length) cxxGen["qtsignals"] = true;
        // Multiple-inheritance upcast shims — one static_cast per (class, secondary base).
        std.file.write(buildPath(outDir, "qtmi.cpp"), miCpp(manifest, sigInc));
        std.file.write(buildPath(dsub, "qtmi.d"), miD(manifest, dpkg));
        if (MICASTS.length) cxxGen["qtmi"] = true;
        // Subclass trampolines — a C++ trampoline per spec-listed class whose virtuals fwd to D.
        std.file.write(buildPath(outDir, "qtvirt.cpp"), virtCpp(manifest, sigInc));
        std.file.write(buildPath(dsub, "qtvirt.d"), virtD(manifest, dpkg));
        if (TRAMPS.length) cxxGen["qtvirt"] = true;
        // Out-of-line copy-ctor/dtor (gap: std:: by value) + inline-ctor shims (gap: no symbol).
        std.file.write(buildPath(outDir, "qtdctor.cpp"), ctorCpp(manifest, sigInc));
        if (CTORCOPY.length || CTORSHIM.length || METHODSHIM.length) cxxGen["qtctor"] = true;
        // wrapper lifetime holder — fixed sources copied from runtime/holder/* (top-level
        // module `holder`); reggae compiles qtd_holder.cpp + holder.d.
        if (WRAPPER) {
            enum holderSrcDir = buildPath(dirName(dirName(__FILE_FULL_PATH__)), "runtime", "holder");
            std.file.copy(buildPath(holderSrcDir, "qtd_holder.cpp"), buildPath(outDir, "qtd_holder.cpp"));
            std.file.copy(buildPath(holderSrcDir, "holder.d"), buildPath(outDir, "holder.d"));
            cxxGen["holder"] = true;
        }
        // moc runtime — fixed sources copied from runtime/qtmoc/* (top-level module `qtmoc`);
        // reggae compiles qtdmoc.cpp with the Qt private-API flags (QMetaObjectBuilder).
        enum mocSrcDir = buildPath(dirName(dirName(__FILE_FULL_PATH__)), "runtime", "qtmoc");
        if (exists(buildPath(mocSrcDir, "qtdmoc.cpp"))) {
            std.file.copy(buildPath(mocSrcDir, "qtdmoc.cpp"), buildPath(outDir, "qtdmoc.cpp"));
            std.file.copy(buildPath(mocSrcDir, "qtmoc.d"),    buildPath(outDir, "qtmoc.d"));
            cxxGen["qtmoc"] = true;
        }
        if (TRAMPS.length) writefln("cxx: %d subclass trampoline(s) -> qtvirt.d", TRAMPS.length);
        if ("qtmoc" in cxxGen) writeln("cxx: moc runtime -> qtmoc.d (@QObject/Signal/@Slot, meta-objeto em runtime)");
        int stubs;
        foreach (r; cxxRef.byKey)
            if (r !in cxxGen) {
                // In WRAPPER mode a referenced object type must still be a QtdObject-based
                // wrapper (so .ptr()/.wrap() work at unwrap/wrap sites), just with no methods.
                auto stub = (WRAPPER && r in WRAPREFS)
                    ? format("%s\nmodule %s.%s;\nimport holder;\nclass %s : QtdObject {\n"
                        ~ "    this(void* c) @nogc nothrow { super(c, false); }\n"   // opaque handle: dispose-only
                        ~ "    static %s wrap(void* c) { return cast(%s) holder.wrap(c, (void* p) => cast(QtdObject) new %s(p)); }\n}\n",
                        manifest, dpkg, modBase(r), r, r, r, r)
                    : format("%s\nmodule %s.%s;\nextern (C++) class %s {}\n", manifest, dpkg, modBase(r), r);
                std.file.write(buildPath(dsub, modBase(r) ~ ".d"), stub);
                stubs++;
            }
        writefln("cxx: %d full + %d enum + %d opaque stub modules", ok, ENUMS.length, stubs);
    }
    if (CONTAINERS.length || ASSOCS.length)
        emitContainers(outDir, manifest, discMod, headers);
    sw.stop();
    writefln("done: %d classes emitted (%d shiboken-rejected), %d functions, %d list + %d assoc containers -> %s  (%d ms)",
        ok, rejected, total, CONTAINERS.length, ASSOCS.length, outDir, sw.peek.total!"msecs");

    import std.algorithm : sort;
    auto miss = MISSING.byKeyValue.array.sort!((a, b) => a.value > b.value);
    long skipped = 0; foreach (kv; miss) skipped += kv.value;
    writefln("\nUNMAPPED: %d methods skipped across %d distinct types. top 30:", skipped, miss.length);
    foreach (kv; miss[0 .. min(30, $)])
        writefln("  %5d  %s", kv.value, kv.key);
}

void emitContainers(string outDir, string manifest, string discMod, string[] headers) {
    string[] hdr, cpp, decl;
    foreach (ct; CONTAINERS.byValue) {
        auto p = "qtd_QList_" ~ ct.tid, T = ct.cppType, E = ct.elemC;
        auto at = ct.atWrap.replace("{}", format("static_cast<%s*>(h)->at(i)", T));
        hdr ~= [format("void *%s_new(void);", p), format("int %s_size(void *h);", p),
                format("%s %s_at(void *h, int i);", E, p), format("void %s_delete(void *h);", p)];
        cpp ~= [format("void *%s_new(void) { return new %s(); }", p, T),
                format("int %s_size(void *h) { return static_cast<%s*>(h)->size(); }", p, T),
                format("%s %s_at(void *h, int i) { return %s; }", E, p, at),
                format("void %s_delete(void *h) { delete static_cast<%s*>(h); }", p, T)];
        decl ~= [format("    void* %s_new();", p), format("    int %s_size(void* h);", p),
                 format("    %s %s_at(void* h, int i);", ct.elemDRaw, p), format("    void %s_delete(void* h);", p)];
    }
    foreach (a; ASSOCS.byValue) {                          // QHash<K,V>/QMap<K,V>
        auto p = a.pfx, T = a.cppType, IT = format("%s::const_iterator", a.cppType);
        auto itc = format("(*static_cast<%s*>(it))", IT);
        auto keyRet = a.keyWrap.replace("{}", itc ~ ".key()");
        auto valRet = a.valWrap.replace("{}", itc ~ ".value()");
        hdr ~= [format("void *%s_new(void);", p), format("int %s_size(void *h);", p),
                format("void *%s_iter_new(void *h);", p), format("int %s_iter_valid(void *h, void *it);", p),
                format("%s %s_iter_key(void *it);", a.keyC, p), format("%s %s_iter_val(void *it);", a.valC, p),
                format("void %s_iter_next(void *it);", p), format("void %s_iter_delete(void *it);", p),
                format("void %s_delete(void *h);", p)];
        cpp ~= [format("void *%s_new(void) { return new %s(); }", p, T),
                format("int %s_size(void *h) { return static_cast<%s*>(h)->size(); }", p, T),
                format("void *%s_iter_new(void *h) { return new %s(static_cast<%s*>(h)->constBegin()); }", p, IT, T),
                format("int %s_iter_valid(void *h, void *it) { return *static_cast<%s*>(it) != static_cast<%s*>(h)->constEnd(); }", p, IT, T),
                format("%s %s_iter_key(void *it) { return %s; }", a.keyC, p, keyRet),
                format("%s %s_iter_val(void *it) { return %s; }", a.valC, p, valRet),
                format("void %s_iter_next(void *it) { ++%s; }", p, itc),
                format("void %s_iter_delete(void *it) { delete static_cast<%s*>(it); }", p, IT),
                format("void %s_delete(void *h) { delete static_cast<%s*>(h); }", p, T)];
        decl ~= [format("    void* %s_new();", p), format("    int %s_size(void* h);", p),
                 format("    void* %s_iter_new(void* h);", p), format("    int %s_iter_valid(void* h, void* it);", p),
                 format("    %s %s_iter_key(void* it);", a.keyDRaw, p), format("    %s %s_iter_val(void* it);", a.valDRaw, p),
                 format("    void %s_iter_next(void* it);", p), format("    void %s_iter_delete(void* it);", p),
                 format("    void %s_delete(void* h);", p)];
    }
    auto incs = discMod.length ? format("#include <%s>\n", discMod)
        : headers.map!(h => format("#include \"%s\"\n", h)).join;
    std.file.write(buildPath(outDir, "qtcontainers.h"),
        format("%s\n#ifndef QTD_CONTAINERS_H\n#define QTD_CONTAINERS_H\n#ifdef __cplusplus\nextern \"C\" {\n#endif\n%s\n#ifdef __cplusplus\n}\n#endif\n#endif\n",
            manifest, hdr.join("\n")));
    std.file.write(buildPath(outDir, "qtcontainers.cpp"),
        format("%s\n#include \"qtcontainers.h\"\n#include <QString>\n#include <QList>\n#include <QHash>\n#include <QMap>\n%s\nextern \"C\" {\n\n%s\n\n} // extern \"C\"\n",
            manifest, incs, cpp.join("\n")));
    std.file.write(buildPath(outDir, "qtcontainers.d"),
        format("%s\nmodule qtcontainers;\n\nextern (C) nothrow @nogc {\n%s\n}\n", manifest, decl.join("\n")));
}
