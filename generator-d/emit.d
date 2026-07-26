// emit.d — the generator driver: parse the spec, discover classes, drive the
// extern(C++) emitter (emit_cxx.d), write the .d/.cpp files, and report coverage.
module emit;

import clang_c, gen, emit_cxx;
import std.stdio, std.string, std.array, std.algorithm, std.conv, std.json,
       std.process, std.file, std.path, std.datetime.stopwatch;

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
    EXCEPTIONS = ("exceptions" in spec.object) !is null && spec["exceptions"].type == JSONType.true_;   // C++->D exc
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
    int ok;
    int rejected;
    long cxxBound;   // public D bindings emitted on the extern(C++) path (methods/ctors/overloads)
    // Count callable D bindings in a generated unit: a line that defines/declares something
    // callable (extern(D)/final/static/this), excluding the private raw/guard plumbing.
    static long countBindings(string d) {
        import std.string : stripLeft, startsWith, indexOf;
        long n;
        foreach (line; d.splitter('\n')) {
            auto s = line.stripLeft;
            if (s.startsWith("private")) continue;                 // __raw_/__ctor_/guard decls
            if ((s.startsWith("extern(D)") || s.startsWith("final ") || s.startsWith("static ")
                 || s.startsWith("this(")) && s.indexOf('(') >= 0)
                n++;
        }
        return n;
    }
    foreach (i, cur; targets) {
        auto name = clang_getCursorSpelling(cur).str;
        auto cppName = clang_getTypeSpelling(clang_getCursorType(cur)).str;  // qualified (Qt3DCore::QEntity)
        if (name in RULES.rejectedClass) { rejected++; continue; }   // shiboken rejection
        // Provided by a hand-written smart runtime (QString/QByteArray/QAnyStringView)
        // — pre-marked in cxxGen; must NOT be overwritten by a generated class.
        if (cxxAbi && name in cxxGen) continue;
        try {
            if (cxxAbi) {   // pure extern(C++): one .d, no shim
                string[] imps;
                auto d = emitCxxUnit(cur, name, cppName, dpkg, manifest, imps);
                std.file.write(buildPath(dsub, modBase(name) ~ ".d"), d);
                cxxGen[name] = true;
                foreach (r; imps) cxxRef[r] = true;
                ok++; cxxBound += countBindings(d);
            } else {
                throw new Exception("only abi:cxx is supported (the C-ABI emitter was removed)");
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
                cxxBound += countBindings(d);
            } catch (Exception e) {
                stderr.writefln("[%s base] skipped: %s", bn, e.msg);
                cxxGen[bn] = true;
            }
        }
    }
    // Nested value classes referenced by a bound signature (QMetaObject::Connection from
    // QObject::connect) -> emitted on demand as their own module (a size/ABI-faithful handle).
    if (cxxAbi) while (true) {
        string[] todo;
        foreach (nn, _; PENDING_NESTED) if (nn !in cxxGen) todo ~= nn;
        if (!todo.length) break;
        foreach (nn; todo) {
            auto ncur = PENDING_NESTED[nn];
            auto ncpp = clang_getTypeSpelling(clang_getCursorType(ncur)).str;
            try {
                auto d = emitNestedValue(ncur, nn, ncpp, dpkg, manifest);
                std.file.write(buildPath(dsub, modBase(nn) ~ ".d"), d);
                cxxGen[nn] = true;
            } catch (Exception e) {
                stderr.writefln("[%s nested] skipped: %s", nn, e.msg);
                cxxGen[nn] = true;
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
        // `qt` aggregator: bare-name aliases for Qt-namespace enum values (2-part `Qt::X` in
        // .ui). Emitted after the enums so QT_ALIASES is fully collected.
        auto agg = qtAggregator(dpkg, manifest);
        if (agg.length) std.file.write(buildPath(dsub, "qt.d"), agg);
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
        if (CTORCOPY.length || CTORSHIM.length || METHODSHIM.length || ITEROPS.length || GUARDS.length)
            cxxGen["qtctor"] = true;
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
    sw.stop();
    writefln("done: %d classes emitted (%d shiboken-rejected), %d D bindings -> %s  (%d ms)",
        ok, rejected, cxxBound, outDir, sw.peek.total!"msecs");

    writefln("\ncxx path: %d D bindings emitted, %d methods/ctors dropped (unmapped-type).",
        cxxBound, CXX_SKIP);
    // Per-symbol manifest (round-4 #1): one TSV row per API method with its fate. Answers
    // "what happened to each Qt symbol?" — bound/shimmed/signal/inherited/pure-virtual/
    // unmapped-type/inline-failed. Covers the object-method path (the bulk); value-type and
    // wrapper drops are in the aggregate CXX_SKIP. Sorted for a stable, diffable artifact.
    import std.algorithm : sort, count;
    auto rows = MANIFEST.dup.sort.array;
    long[string] byFate;
    foreach (r; rows) byFate[r.split("\t")[$ - 1]]++;
    string man = "# cppClass\tsymbol\tfate\n";
    foreach (r; rows) man ~= r ~ "\n";
    std.file.write(buildPath(outDir, "coverage-manifest.tsv"), man);

    // coverage.txt: the human summary. The fate breakdown IS the per-symbol manifest — now
    // covering the object-method AND the value-type/wrapper/ctor paths (every Unmappable drop is
    // recordSym'd). Any residual (aggregate drops not in the manifest) is stated plainly.
    long manifestDrops = byFate.get("unmapped-type", 0) + byFate.get("inline-failed", 0);
    long residual = CXX_SKIP - manifestDrops;
    string cov = format("qt-dlang-gen coverage — %s (extern(C++))\n"
        ~ "%d classes emitted, %d shiboken-rejected.\n"
        ~ "per-symbol manifest: coverage-manifest.tsv, %d rows. fate breakdown:\n",
        spec["qt_version"].str, ok, rejected, rows.length);
    foreach (f; byFate.byKey.array.sort) cov ~= format("  %-14s %d\n", f, byFate[f]);
    if (residual == 0)
        cov ~= format("aggregate drops across ALL paths: %d — all per-symbol in the manifest above.\n", CXX_SKIP);
    else
        cov ~= format("aggregate drops across ALL paths: %d; %d in the manifest, %d not yet per-symbol.\n",
            CXX_SKIP, manifestDrops, residual);
    std.file.write(buildPath(outDir, "coverage.txt"), cov);
}

