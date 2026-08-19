// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// emit.d — the generator driver: parse the spec, discover classes, drive the
// extern(C++) emitter (emit_cxx.d), write the .d/.cpp files, and report coverage.
module emit;

import clang_c, gen, emit_cxx;
import std.stdio, std.string, std.array, std.algorithm, std.conv, std.json,
       std.process, std.file, std.path, std.datetime.stopwatch;
import std.digest.sha : sha256Of, toHexString;   // the input digest in the provenance line

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

    // FAIL CLOSED ON THE ABI, once and before anything else. This check used to live inside the
    // per-class emit loop, where the exception it threw was caught by that loop's own handler and
    // printed as "[Shape] skipped: only abi:cxx is supported" — once per class — after which the
    // run finished and exited 0 with an empty binding. A spec-wide configuration error was being
    // reported as a per-class problem, and the exit status said success.
    //
    // Measured 2026-08-18 on generator/spec_userlib.json, the example BOTH READMEs point at for
    // binding your own library: 2 classes discovered, 0 emitted, exit 0. xiboca/README.md already
    // said "a non-cxx spec now errors"; it did not, and now it does. Same shape as the incomplete
    // translation unit below: an empty binding must never be a successful run.
    if (("abi" in spec.object) is null || spec["abi"].str != "cxx") {
        stderr.writefln(`xiboca: %s: only abi:cxx is supported (the C-ABI emitter was removed). `
                        ~ `Add "abi": "cxx" to the spec.`, specPath);
        import core.stdc.stdlib : exit;
        exit(1);
    }

    // WHICH Qt, and which other libraries — asked of the spec, not of the environment.
    // pkg_config alone answers "which modules" and leaves "which installation" to whatever
    // PKG_CONFIG_PATH happened to hold, which is invisible in the spec and therefore unrecorded:
    // the same spec then binds against a different Qt on a different machine and nothing says so.
    // Listed dirs are prepended, so a spec's choice wins over the environment's, and relative ones
    // resolve against the spec file like every other path here.
    if (auto pp = "pkg_config_path" in spec.object) {
        string[] dirs;
        foreach (p; pp.array)
            dirs ~= isAbsolute(p.str) ? p.str : buildNormalizedPath(specPath.dirName, p.str);
        auto prev = environment.get("PKG_CONFIG_PATH", "");
        environment["PKG_CONFIG_PATH"] = dirs.join(":") ~ (prev.length ? ":" ~ prev : "");
    }
    // The escape hatch for a library that ships no .pc file — VTK, OpenCASCADE, anything that is
    // CMake-config-only. pkg_config cannot name it, so its flags are given directly. `cflags`
    // reaches the parse; `libs` reaches the symbol scan (and is what a build needs to link).
    string[] rawCflags, rawLibs;
    if (auto cf = "cflags" in spec.object) foreach (x; cf.array) rawCflags ~= x.str;
    if (auto lb = "libs" in spec.object)   foreach (x; lb.array) rawLibs ~= x.str;

    auto pkgs = spec["pkg_config"].str.split;
    loadDefinedSymbols(pkgs, rawLibs);   // refuse to bind a symbol the linked libs do not define
    auto cflags = execute(["pkg-config", "--cflags"] ~ pkgs).output.split ~ rawCflags;
    auto res = execute(["clang", "-print-resource-dir"]).output.strip;
    string[] extraI;
    // Relative include paths resolve against the SPEC (like out_dir), not the cwd: xiboca is invoked
    // from the repo root by the build and from generator/ by hand, and both must find the headers.
    if (auto ip = "include_paths" in spec.object)
        foreach (p; ip.array)
            extraI ~= "-I" ~ (isAbsolute(p.str) ? p.str : buildNormalizedPath(specPath.dirName, p.str));
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
    // Ownership that moves at a call. See the note on TRANSFER_IN in emit_cxx.d — these are
    // audited per class against Qt's own documentation, not inferred.
    if (auto s = "transfer_in" in spec.object)
        foreach (x; s.array) TRANSFER_IN[x.str] = true;
    if (auto s = "transfer_out" in spec.object)
        foreach (x; s.array) TRANSFER_OUT[x.str] = true;
    if (auto s = "disposable" in spec.object)
        foreach (x; s.array) DISPOSABLE[x.str] = true;
    if (auto s = "ctor_parents" in spec.object)
        foreach (k, v; s.object) foreach (x; v.array) CTOR_PARENTS[k] ~= x.str;

    // discover_module and headers COMBINE: a module (e.g. <QtQuick>) plus extra headers (e.g. the
    // private element headers that declare QQuickRectangle/QQuickText) are all scanned together.
    string src;
    if (discMod.length) src = format("#include <%s>\n", discMod);
    if (headers.length) src ~= headers.map!(h => format("#include <%s>", h)).join("\n") ~ "\n";
    if (!src.length) src = spec["classes"].array.map!(c => format("#include <%s>", c["include"].str)).join("\n") ~ "\n";

    CXUnsavedFile uf;
    uf.Filename = "_gen.cpp".toStringz;
    uf.Contents = src.toStringz;
    uf.Length = src.length;

    auto sw = StopWatch(AutoStart.yes);
    auto index = clang_createIndex(0, 0);
    auto tu = clang_parseTranslationUnit(index, "_gen.cpp",
        cast(const(char*)*) cargv.ptr, cast(int) cargv.length, &uf, 1, 0x02 /*Incomplete*/);
    auto tuCursor = clang_getTranslationUnitCursor(tu);

    // FAIL CLOSED on a translation unit that did not parse. libclang happily returns a TU with
    // fatal errors (a header it could not find yields an EMPTY one), and discovery then reports
    // "0 classes" and exits 0 — a binding with nothing in it, which the build accepts because it
    // pipes this output to /dev/null. That is how a spec whose include path stopped resolving can
    // rot invisibly.
    {
        int fatal = 0;
        auto nd = clang_getNumDiagnostics(tu);
        foreach (i; 0 .. nd) {
            auto d = clang_getDiagnostic(tu, i);
            if (clang_getDiagnosticSeverity(d) >= 3) {   // Error = 3, Fatal = 4
                if (fatal < 10) stderr.writefln("xiboca: %s", clang_formatDiagnostic(d, 0).str);
                fatal++;
            }
            clang_disposeDiagnostic(d);
        }
        if (fatal) {
            stderr.writefln("xiboca: %s: %d parse error(s) — refusing to emit a binding from an "
                ~ "incomplete translation unit", specPath, fatal);
            import core.stdc.stdlib : exit;
            exit(1);
        }
    }

    // resolve target class cursors
    CXCursor[] targets; string[] includes;
    CXCursor[] freeFns;   // namespace/global free functions (discovery mode only)
    if (discMod.length || headers.length) {
        DiscCtx ctx;
        clang_visitChildren(tuCursor, &discVisit, &ctx);
        freeFns = ctx.functions;
        int droppedPriv;
        foreach (cur; ctx.classes) {
            // The type's own declaring header (needed for private types the umbrella misses).
            CXFile f; uint ln, col, off;
            clang_getFileLocation(clang_getCursorLocation(cur), &f, &ln, &col, &off);
            string decl = f ? clang_getFileName(f).str : "";
            // A discover_module umbrella (<QtQuick>) reaches only PUBLIC types; a type declared in
            // one of Qt's two NON-public header dirs (.../private/, .../qpa/) is NOT visible
            // through it, so it must include its own header.
            if (discMod.length && (decl.canFind("/private/") || decl.canFind("/qpa/"))) {
                // ...but ONLY when that header is EXPLICITLY listed. A private element header
                // (qquickpositioners_p.h) transitively drags in the non-public guts of OTHER
                // modules (QtGui's qevent_p.h and qpa/qplatformwindow.h, QtQml's
                // qqmltypeloader_p.h), whose types are internal implementation detail: protected
                // ctors, incomplete forward-declared members, fn-ptr accessors, and no include
                // the aggregated shim can name. Binding them emits C++ that cannot compile.
                // The spec's `headers` list IS the scope: list a header to bind its types.
                if (!headers.any!(h => decl.endsWith(h))) { droppedPriv++; continue; }
                // Even in a LISTED private header, only an EXPORTED type is bindable: a
                // non-Q_*_EXPORT class there (the attached-property helpers —
                // QQuickPositionerAttached, QQuickPathViewAttached, QQuickDropAreaDrag) is
                // Hidden, so its ctors/signals/staticMetaObject are not in the .so. ldc2's
                // --gc-sections drops the dead references; dmd's whole-program link does not.
                if (clang_getCursorVisibility(cur) != 3) { droppedPriv++; continue; }
                includes ~= decl;
            }
            else if (discMod.length) includes ~= discMod;
            // headers-mode: your own class -> the header it's defined in. Prefer the name AS
            // LISTED in the spec: `decl` is the path libclang resolved, which for a relative
            // include_path is relative to the GENERATOR's cwd and so unusable from the build's.
            // The listed name resolves against the include_path, which every consumer is given.
            // headers-mode: your own class -> the header it's defined in. If the spec listed that
            // header by a RELATIVE name, prefer the listed form: `decl` is the path libclang
            // resolved from the generator's cwd, which the build can't use. An absolute listed
            // path needs no such substitution — and substituting the umbrella header for a type
            // actually defined in a sibling header drops that sibling's include entirely.
            else {
                string inc = decl;
                foreach (h; headers)
                    if (!isAbsolute(h) && decl.endsWith(h)) { inc = h; break; }
                includes ~= inc;
            }
            targets ~= cur;
        }
        writefln("discovered %d classes%s%s", targets.length,
                 discMod.length ? " in <" ~ discMod ~ ">" : " in your headers",
                 droppedPriv ? format(" (%d unlisted-private skipped)", droppedPriv) : "");
        // subclass_derived: auto-subclass EVERY discovered class transitively deriving from a listed
        // base (e.g. all QQuickItem-derived visual types). A wrapper generator must not carry a
        // hand-maintained per-type subclass list — whatever is discovered under the base is wrapped.
        // The EXPLICIT `subclass` list gets the same test the derived one already applies. A class
        // with no public default constructor (QQuickBasePositioner) or an abstract one cannot back
        // a trampoline: the generated C++ then fails with "must explicitly initialize the base
        // class", hundreds of lines into a generated file, naming the trampoline rather than the
        // spec entry that asked for it. Dropping it here says which entry is at fault and why.
        if ("subclass" in spec.object) {
            foreach (cur; targets) {
                auto nm = clang_getCursorSpelling(cur).str;
                if (nm !in SUBCLASS || isSubclassable(cur)) continue;
                writefln("spec `subclass`: %s cannot be subclassed (abstract, or no public default "
                         ~ "constructor) — dropped; a trampoline for it would not compile", nm);
                SUBCLASS.remove(nm);
            }
        }
        if (auto sd = "subclass_derived" in spec.object) {
            int n0 = cast(int) SUBCLASS.length;
            foreach (baseJ; sd.array)
                foreach (cur; targets) {
                    auto __n = clang_getCursorSpelling(cur).str;
                    if (derivesFrom(cur, baseJ.str) && isSubclassable(cur))
                        SUBCLASS[__n] = true;
                }
            writefln("subclass_derived: %d classes auto-subclassed", cast(int) SUBCLASS.length - n0);
        }
    } else {
        bool[string] want;
        foreach (c; spec["classes"].array) want[c["name"].str] = true;
        DiscCtx ctx;
        clang_visitChildren(tuCursor, &discVisit, &ctx);
        foreach (cur; ctx.classes)
            if (clang_getCursorSpelling(cur).str in want) targets ~= cur;
        foreach (c; spec["classes"].array) includes ~= c["include"].str;
    }

    // THE OUTPUT NOTICE AND ITS PROVENANCE (docs/licensing-plan.md § Generated-output policy).
    //
    // A consumer holding one generated file must be able to answer three questions from the file
    // itself: what may I do with this, what was it made from, and what does that grant NOT cover.
    // The third is the one a licence line alone gets wrong — the grant is over the generator's own
    // text, not over the user's input and not over the APIs the output refers to.
    //
    // The provenance is here rather than only in a side manifest because a file travels alone: it
    // is copied into bug reports, pasted into questions, and vendored by people who never see the
    // package it came from.
    // …and it must say when the revision is NOT the whole answer. A bare SHA from a modified tree
    // is a claim the reader can check and will find false: the commit that first emitted this very
    // line is a0b3b94, and the 824 files in the package on disk when this was written all said
    // `generator=fa680f9` — the commit BEFORE it. Code that did not exist in fa680f9 wrote a line
    // asserting fa680f9, because generation ran with those changes still uncommitted. `-dirty` is
    // the difference between a provenance record and a plausible-looking one.
    auto genRev = () {
        auto root = dirName(dirName(__FILE_FULL_PATH__));
        auto r = execute(["git", "-C", root, "rev-parse", "--short", "HEAD"]);
        if (r.status != 0) return "unknown";
        auto d = execute(["git", "-C", root, "status", "--porcelain", "--untracked-files=no"]);
        return r.output.strip ~ (d.status == 0 && d.output.strip.length ? "-dirty" : "");
    }();
    // WHICH INPUT, not just which revision (round 15 #6). `spec=<basename>` describes a filename:
    // two different specs with the same basename in two checkouts produced byte-identical
    // provenance, and editing a spec without committing produced `-dirty`, which says correctly
    // that the SHA is not enough and still does not say what changed. The digest names the exact
    // bytes this was generated from. `qt=` also carried only major.minor while this project treats
    // patch drift as an ABI risk everywhere else, so the full version travels too.
    auto specSha = () {
        try return sha256Of(cast(ubyte[]) std.file.read(specPath)).toHexString[0 .. 12].idup;
        catch (Exception) return "unknown";
    }();
    auto qtFull = () {
        auto mods = ("pkg_config" in spec.object) ? spec["pkg_config"].str.split(" ") : [];
        foreach (m; mods) {
            if (!m.startsWith("Qt")) continue;
            auto r = execute(["pkg-config", "--modversion", m]);
            if (r.status == 0) return r.output.strip;
        }
        return "";
    }();
    auto modList = ("pkg_config" in spec.object) ? spec["pkg_config"].str : "";
    auto manifest = "// GENERATED by qt-dlang-gen (D) from Qt " ~ spec["qt_version"].str ~ ".\n"
        ~ "// Do NOT edit — regenerate via xiboca.\n"
        ~ "//\n"
        ~ "// SPDX-FileCopyrightText: 2026 Marcelo A Caetano\n"
        ~ "// SPDX-License-Identifier: BSL-1.0\n"
        ~ "//\n"
        ~ "// The generator-authored portions of this file — its structure, boilerplate and\n"
        ~ "// templates — are offered under BSL-1.0. That grant does NOT change the licence or the\n"
        ~ "// ownership of the input this was generated from, and it grants no rights in the Qt\n"
        ~ "// APIs named here: Qt is a separate work under its own terms, normally LGPLv3 for the\n"
        ~ "// open-source distribution, and linking this file into a program does not discharge\n"
        ~ "// them. See LICENSE and docs/licensing.md.\n"
        ~ "//\n"
        ~ "// provenance: generator=" ~ genRev ~ " qt=" ~ spec["qt_version"].str
        ~ (qtFull.length ? " qtfull=" ~ qtFull : "")
        ~ (modList.length ? " modules=" ~ modList : "") ~ " spec=" ~ baseName(specPath)
        ~ " specsha256=" ~ specSha ~ " notice=v1";
    bool cxxAbi = ("abi" in spec.object) !is null && spec["abi"].str == "cxx";
    bool[string] cxxGen, cxxRef;   // proper class names: fully-emitted vs referenced
    bool qt5 = spec["qt_version"].str.startsWith("5");   // value-type ABI differs between Qt5 and Qt6
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
        // Verify the translated inlines of ALL classes in a single ldc2 (instead of
        // one per class — that was the generation bottleneck); fix only the ones that fail.
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
        // The umbrella <QtQuick> reaches only public types; private types (QQuickGradient etc.) the
        // aggregated shims reference need their own header appended.
        auto privInc = includes.dup.sort.uniq.filter!(i => i.canFind("/private/") || i.canFind("/qpa/"))
            .map!(i => format("#include \"%s\"\n", i)).join;
        auto sigInc = discMod.length ? (format("#include <%s>\n", discMod) ~ privInc)
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
        string[] virtImps;
        std.file.write(buildPath(dsub, "qtvirt.d"), virtD(manifest, dpkg, virtImps));
        foreach (r; virtImps) cxxRef[r] = true;   // a trampoline-only type still needs its stub
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
            // ...and the QML half, which lives in its own unit (critics r9 #2 / r11 #5). Copied
            // unconditionally: every one of its functions keeps a no-op body without QtQml, so the
            // ABI a binding links against does not change with the module list.
            if (exists(buildPath(mocSrcDir, "qtdmoc_qml.cpp")))
                std.file.copy(buildPath(mocSrcDir, "qtdmoc_qml.cpp"), buildPath(outDir, "qtdmoc_qml.cpp"));
            std.file.copy(buildPath(mocSrcDir, "qtmoc.d"),    buildPath(outDir, "qtmoc.d"));
            cxxGen["qtmoc"] = true;
        }
        if (TRAMPS.length) writefln("cxx: %d subclass trampoline(s) -> qtvirt.d", TRAMPS.length);
        if ("qtmoc" in cxxGen) writeln("cxx: moc runtime -> qtmoc.d (@QObject/Signal/@Slot, runtime meta-object)");
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
                    : format("%s\nmodule %s.%s;\nextern (C++) class %s {%s}\n", manifest, dpkg, modBase(r), r,
                        // A class referenced for its NESTED ENUM still needs those enums in the
                        // stub — `QQmlDelegateModel.DelegateModelAccess` must resolve even though
                        // the class itself is out of scope (its private header isn't listed).
                        (r in PENDING_ENUMSCOPE) ? "\n" ~ nestedEnumLines(PENDING_ENUMSCOPE[r]).join("\n") ~ "\n" : "");
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
    string man = "# cppClass\tsymbol\tusr\tfate\n";
    foreach (r; rows) man ~= r ~ "\n";
    std.file.write(buildPath(outDir, "coverage-manifest.tsv"), man);

    // qmlmap.tsv: the QML-element-name -> (C++ class, D module) table, read from the module's OWN
    // plugins.qmltypes (Qt's authoritative type registry) and restricted to the classes we subclass.
    // This is what makes the wrapper's QML type vocabulary DATA — qmltc-d looks types up here instead
    // of carrying a hand-coded name map.
    if (auto qt = "qmltypes" in spec.object) {
        import std.regex : matchFirst, matchAll, regex;
        import std.array : join;
        auto reName = regex(`\n {8}name: "([^"]+)"`);
        auto reExp  = regex(`exports: \[([^\]]*)\]`);
        // "QtQuick.Templates/Overlay 2.3" — the URI is as much a part of the export as the name,
        // and reaching an ATTACHED type needs it (attachedObj resolves by uri + type at runtime).
        auto reQml  = regex(`"([^"/]+)/([A-Za-z0-9_]+) `);
        // The export's VERSION, read separately: this regex is what keys the whole registry, and
        // adding a group to it stopped ~9000 property rows from matching their export at all —
        // they fell back to the C++-class key, giving a registry the same SIZE as before and keyed
        // differently. Nothing looked wrong until a fixture stopped compiling.
        auto reQmlVer = regex(`"[^"/]+/[A-Za-z0-9_]+ ([0-9]+\.[0-9]+)"`);
        // A singleton's METHODS, with the types a call has to marshal by. The nested braces are the
        // Parameter blocks, which are single-line.
        auto reMethod = regex(`Method \{((?:[^{}]|\{[^{}]*\})*)\}`, "s");
        auto reMName  = regex(`name: "([A-Za-z0-9_]+)"`);
        auto reMType  = regex(`type: "([^"]+)"`);
        auto rePrototype = regex(`\n {8}prototype: "([A-Za-z0-9_:]+)"`);
        // The DEFAULT property is not always `data`: QQuickFlickable declares `flickableData`
        // (children are reparented into the flickable's contentItem) and QQuickPopup/Control
        // `contentData`. Placing a default child by hand as an item child of the type itself put
        // it somewhere the ENGINE never has it -- the oracle refused the label path outright
        // (ComboBox: popup.contentItem.data[0]). The registry publishes it; carry it.
        auto reDefaultProp = regex(`\n {8}defaultProperty: "([A-Za-z0-9_]+)"`);
        // `Window.window` reads the ATTACHED type's property, not QQuickWindow's. The registry names
        // the attached class in the export's `attachedType`, so the compiler can prove such a read is
        // an object instead of refusing the whole expression (Qt's Menu.qml:
        // `interactive: Window.window ? … : false`).
        auto reAttachedT = regex(`\n {8}attachedType: "([A-Za-z0-9_:]+)"`);
        // One level of nesting: a Signal block contains Parameter blocks, so `[^}]*` would stop at
        // the first inner `}` and every notify would come out parameterless.
        auto reSignal = regex(`Signal \{((?:[^{}]|\{[^{}]*\})*)\}`, "s");
        auto rePropBlock = regex(`Property \{([^}]*)\}`, "s");
        auto reName2  = regex(`name: "([A-Za-z0-9_]+)"`);
        auto reType2  = regex(`type: "([A-Za-z0-9_:]+)"`);
        auto reNotify = regex(`notify: "([A-Za-z0-9_]+)"`);
        // A parameter carries `isPointer` just as a property does, and the meta-object signature
        // Qt registers keeps the `*`: `clicked(QQuickMouseEvent*)`. Dropping it produced a
        // signature that connectMeta could not find at RUNTIME — the compile was happy and the
        // handler simply never fired, which is the failure mode this whole exercise is about.
        auto reParam = regex(`Parameter \{([^}]*)\}`);
        auto reParamT = regex(`type: "([A-Za-z0-9_:<> ]+)"`);
        static string dScalar(string t) {
            switch (t) {
                case "int", "qint32", "uint": return "int";
                case "bool": return "bool";
                case "double", "float", "qreal": return "double";
                case "QString", "string": return "string";
                default: return "";
            }
        }
        static string cxxParam(string t) {
            switch (t) {
                case "double", "float", "qreal": return "double";
                case "string": return "QString";
                default: return t;
            }
        }
        // A value type whose QML-visible members come from an EXTENSION (`extension:` in the
        // registry) is NOT writable through the plain meta-object channel: QFont carries
        // `extension: "QQuickFontValueType"` and has no gadget meta-object of its own, while
        // QQuickIcon has none and IS the gadget. That is the difference between a grouped write
        // that works and one that throws at construction — and it is data, not a list of names.
        bool[string] extendedValueType;
        string[string] protoOf, qmlOf, defPropOf;
        // Every exported type, bound or not: an ATTACHED read (`Window.window`) must be provable as an
        // object, and that proof reads the property table. Restricting it to bound types left the
        // compiler unable to tell an object member from a scalar on a type it does not subclass.
        string[string] qmlOfAll;
        string[string] attachedOf;   // QML name -> the class its ATTACHED properties live on
        // Signals per class, kept rather than discarded after the notify lookup: a handler for a
        // BOUND type's own signal (`onClicked`) needs the name AND the full signature to connect,
        // and 226 of the 373 handlers in the QML Qt ships are exactly that shape — against 147
        // notify handlers, which were the only ones reachable while this table did not exist.
        string[string][string] ownProps, ownNotify, ownSignals;
        string qmap, qprops; int rows2, rows3; string[][] qmapRows;
        // QML name -> module URIs, for EVERY exported type. A LIST, not one answer: each Controls
        // style ships its own BusyIndicatorImpl/SliderGroove/..., so one row per name silently
        // picked whichever module was scanned last and Qt's Fusion BusyIndicator was compiled to
        // build the BASIC impl. The compiler picks the one the document imports.
        string[][string] uriRows;
        string[string] singletonRows;   // QML name -> "<uri>\t<version>", for every QML SINGLETON
        string methodRows;              // <QML name>\t<method>\t<return type>\t<param types>
        foreach (qtj; qt.array) {
            if (!exists(qtj.str)) continue;
            foreach (blk; readText(qtj.str).split("Component {")) {
                auto nm = blk.matchFirst(reName);
                auto ex = blk.matchFirst(reExp);
                // A Component with NO exports is still reachable through a property: `RangeSlider.first`
                // is a QQuickRangeSliderNode*, a grouped-property helper Qt does not export as an
                // element, and `control.first.pressed` could not be typed because the property table
                // covered exported types only. Record it keyed by the C++ CLASS name — which is exactly
                // what the compiler holds at that point — before the export filter drops it.
                // ...and it must NOT displace a real QML name the same class already has. The two
                // spellings are read from different .qmltypes files and the last one won: in the
                // Controls binding a re-declaration of QQuickText with no export overwrote
                // `QQuickText -> Text`, so every property of Text was filed under `QQuickText` and
                // the compiler could not type a single `Text` binding. One type, silently, in a
                // registry of 10874 rows -- `opacity: Tumbler.displacement` was refused with
                // "declared type '?'" and the reason was this.
                if (!nm.empty && ex.empty && nm[1] !in qmlOfAll) qmlOfAll[nm[1]] = nm[1];
                if (nm.empty || ex.empty) continue;
                auto cpp = nm[1];
                // The URI of EVERY exported type, whether or not we bind it: an ATTACHED read
                // (`Window.window` in Qt's Menu.qml) needs the attached type's module to resolve at
                // runtime, and Window is not a type we subclass. Without this the compiler had to
                // guess the URI, which would make attachedObj fail, return null, and the expression
                // yield a value that matches the engine BY ACCIDENT.
                auto qn0 = ex[1].matchFirst(reQml);
                if (!qn0.empty) {
                    if (auto known = qn0[2] in uriRows) { if (!(*known).canFind(qn0[1])) *known ~= qn0[1]; }
                    else uriRows[qn0[2]] = [qn0[1]];
                    qmlOfAll[cpp] = qn0[2];
                }
                // A Component with NO export is still reachable: `RangeSlider.first` is a
                // QQuickRangeSliderNode*, a grouped-property helper Qt does not export as an element,
                // and a read through it (`control.first.pressed`) could not be typed because the
                // property table only covered exported types. Key those rows by the C++ CLASS name,
                // which is exactly what the compiler holds at that point.
                else qmlOfAll[cpp] = cpp;   // exported but with no parsable QML name
                // NOTE: this block goes AFTER the if/else above, not between them. Sitting in the
                // middle, its `if` stole the `else` — so every exported non-singleton type was
                // keyed by its C++ class instead of its QML name. The registry kept its SIZE and
                // changed its keys, which is why the corpus still built and one fixture did not.
                // A QML SINGLETON is a type with ONE instance the engine owns: `Color.blend(...)`
                // in Qt's own controls is a method call on one. The registry says so outright
                // (`isSingleton: true`) and gives the module and version the instance is fetched
                // with, so nothing here is guessed. Recorded with its METHODS and their parameter
                // types, since a call has to marshal its arguments by type.
                // METHODS are recorded for EVERY exported type, not only for singletons. A QML
                // handler calls one on an ordinary object -- Qt's editing Actions are
                // `onTriggered: editor.undo()` -- and without a row saying the type HAS that
                // method, calling it would be a guess. The singleton case below needs the same
                // rows and used to be the only one that collected them.
                if (!qn0.empty) {
                    foreach (mm; blk.matchAll(reMethod)) {
                        string sig = mm[1];
                        auto mn = sig.matchFirst(reMName);
                        if (mn.empty) continue;
                        auto mt = sig.matchFirst(reMType);
                        string ps;
                        foreach (pp; sig.matchAll(regex(`Parameter \{([^}]*)type: "([^"]+)"([^}]*)\}`)))
                            ps ~= (ps.length ? "," : "") ~ pp[2]
                                ~ ((pp[1] ~ pp[3]).canFind("isPointer: true") ? "*" : "");
                        methodRows ~= qn0[2] ~ "\t" ~ mn[1] ~ "\t" ~ (mt.empty ? "" : mt[1])
                                    ~ "\t" ~ ps ~ "\n";
                    }
                }
                if (!qn0.empty && blk.canFind("isSingleton: true")) {
                    auto vv = ex[1].matchFirst(reQmlVer);
                    if (vv.empty) continue;      // no version, no way to fetch the one instance
                    string ver = vv[1];
                    singletonRows[qn0[2]] = qn0[1] ~ "\t" ~ ver;
                    static if (false) foreach (mm; blk.matchAll(reMethod)) {
                        string sig = mm[1];
                        auto mn = sig.matchFirst(reMName);
                        if (mn.empty) continue;
                        auto mt = sig.matchFirst(reMType);
                        string ps;
                        // ...with the POINTER marker the registry gives (`isPointer: true`). Qt's
                        // Fusion computes its colours from `buttonColor(QQuickPalette*, bool, …)`,
                        // and without the `*` the compiler could not tell an object parameter from
                        // a value it could pass as text — so every one of those calls was refused.
                        foreach (pp; sig.matchAll(regex(`Parameter \{([^}]*)type: "([^"]+)"([^}]*)\}`)))
                            ps ~= (ps.length ? "," : "") ~ pp[2]
                                ~ ((pp[1] ~ pp[3]).canFind("isPointer: true") ? "*" : "");
                        methodRows ~= qn0[2] ~ "\t" ~ mn[1] ~ "\t" ~ (mt.empty ? "" : mt[1])
                                    ~ "\t" ~ ps ~ "\n";
                    }
                }
                auto at0 = blk.matchFirst(reAttachedT);
                if (!at0.empty && !qn0.empty) attachedOf[qn0[2]] = at0[1];
                if (cpp !in SUBCLASS) continue;      // only types we actually subclass are usable
                auto qn = ex[1].matchFirst(reQml);
                if (qn.empty) continue;
                qmapRows ~= [qn[2], cpp, dpkg ~ "." ~ cpp.toLower, qn[1]]; rows2++;
                qmlOf[cpp] = qn[2];
            }
        }
        // …and each QML name's scalar PROPERTIES. qmlmap says which class backs a name, which is
        // enough to CONSTRUCT one but not to read a member off it. A type's own block declares only
        // what IT adds (IntValidator declares `locale`; top/bottom come from QIntValidator), so the
        // prototype chain is walked. The notify's FULL signature is recorded too: a Qt notify often
        // carries the new value (topChanged(int)), and connecting to "topChanged()" fails.
        foreach (qtj; qt.array) {
            if (!exists(qtj.str)) continue;
            foreach (blk; readText(qtj.str).split("Component {")) {
                auto nm = blk.matchFirst(reName);
                if (nm.empty) continue;
                auto pr = blk.matchFirst(rePrototype);
                if (!pr.empty) protoOf[nm[1]] = pr[1];
                auto dpm = blk.matchFirst(reDefaultProp);
                if (!dpm.empty) defPropOf[nm[1]] = dpm[1];
                string[string] sigOf;
                foreach (sm; blk.matchAll(reSignal)) {
                    auto sn = sm[1].matchFirst(reName2);
                    if (sn.empty) continue;
                    string[] ptypes;
                    foreach (par; sm[1].matchAll(reParam)) {
                        auto pt2 = par[1].matchFirst(reParamT);
                        if (pt2.empty) continue;
                        ptypes ~= cxxParam(pt2[1]) ~ (par[1].canFind("isPointer: true") ? "*" : "");
                    }
                    sigOf[sn[1]] = sn[1] ~ "(" ~ ptypes.join(",") ~ ")";
                    ownSignals[nm[1]][sn[1]] = sigOf[sn[1]];
                }
                if (blk.canFind("accessSemantics: \"value\"") && blk.canFind("extension: \""))
                    extendedValueType[nm[1]] = true;
                foreach (pm; blk.matchAll(rePropBlock)) {
                    auto pn = pm[1].matchFirst(reName2);
                    auto pt = pm[1].matchFirst(reType2);
                    if (pn.empty || pt.empty) continue;
                    // A property whose C++ type has no D scalar mapping used to be DROPPED here,
                    // taking its notify with it — 194 of 458 declared properties across the bound
                    // QtQuick types, 26 of them QColor. They are not unreachable: QVariant
                    // converts, which is how `color` already works. Record the row with an empty
                    // D type and the raw C++ type name, and let the consumer decide.
                    auto pty = dScalar(pt[1]);
                    // `isPointer: true` marks a property that holds an OBJECT rather than a value.
                    // That distinction is not recoverable from the type NAME (`QQuickScaleGrid`
                    // and `QFont` look alike), and it decides how a grouped assignment must be
                    // compiled: an object group is reached with propObj + setProp, a value group
                    // needs a read-modify-write of the whole value. Recorded as a trailing `*`.
                    auto isPtr = pm[1].canFind("isPointer: true");
                    // `isList: true` is a THIRD kind: `transitions: Transition {}` assigns one
                    // object to a LIST property, and the engine holds it at transitions[0]. Compiled
                    // as an object assignment it named a path the engine does not have (ScrollBar).
                    // Recorded as a trailing `[]`, the same way isPointer is recorded as `*`.
                    auto isList = pm[1].canFind("isList: true");
                    ownProps[nm[1]][pn[1]] = pty.length ? pty
                                           : ("\x01" ~ pt[1] ~ (isPtr ? "*" : "") ~ (isList ? "[]" : ""));
                    auto nt = pm[1].matchFirst(reNotify);
                    if (!nt.empty) {
                        auto sg = nt[1] in sigOf;
                        ownNotify[nm[1]][pn[1]] = sg ? *sg : (nt[1] ~ "()");
                    }
                    // A CONSTANT property (Q_PROPERTY ... CONSTANT, published here as
                    // `isPropertyConstant`) has no notify BECAUSE IT NEVER CHANGES. Dropping that
                    // fact made the two indistinguishable downstream, so a binding reading one
                    // (`model: control.contentModel`) was refused as "would not update" — when it
                    // is in fact complete and correct with no connection at all. Carried in the
                    // notify column as `!const`: it inherits down the prototype chain with the
                    // rest, which is where the reader needs it (TabBar reads Container's).
                    else if (pm[1].canFind("isPropertyConstant: true"))
                        ownNotify[nm[1]][pn[1]] = "!const";
                }
            }
        }
        foreach (cpp, qmlName; qmlOfAll) {
            bool[string] emitted;
            for (string c = cpp; c.length;) {
                if (auto ps = c in ownProps)
                    foreach (pn, pty; *ps)
                        if (pn !in emitted) {
                            emitted[pn] = true;
                            string nsig;
                            if (auto nm2 = c in ownNotify) if (auto x = pn in *nm2) nsig = *x;
                            // dtype is empty for a non-scalar; the raw C++ name follows it.
                            string dty = pty, cxx = pty;
                            if (pty.length && pty[0] == '\x01') { dty = ""; cxx = pty[1 .. $]; }
                            // `^` marks a value type reached through an extension: its members are
                            // not writable through the plain channel (see extendedValueType).
                            if (cxx.length && cxx[$ - 1] != '*' && cxx in extendedValueType) cxx ~= "^";
                            qprops ~= qmlName ~ "\t" ~ pn ~ "\t" ~ dty ~ "\t" ~ nsig
                                    ~ "\t" ~ cxx ~ "\n"; rows3++;
                        }
                auto nx = c in protoOf;
                c = nx ? *nx : "";
            }
        }
        // 5th column: the default property, resolved UP the prototype chain (ListView does not
        // declare one -- QQuickFlickable does). Empty when the type has none.
        foreach (r; qmapRows) {
            string dp, c = r[1];
            while (c.length) {
                if (auto d = c in defPropOf) { dp = *d; break; }
                auto nx = c in protoOf; c = nx ? *nx : "";
            }
            qmap ~= r[0] ~ "\t" ~ r[1] ~ "\t" ~ r[2] ~ "\t" ~ r[3] ~ "\t" ~ dp ~ "\n";
        }
        std.file.write(buildPath(outDir, "qmlmap.tsv"), qmap);
        {
            string u;
            foreach (n2_, us2; uriRows) foreach (u2; us2) u ~= n2_ ~ "\t" ~ u2 ~ "\n";
            std.file.write(buildPath(outDir, "qmluris.tsv"), u);
            string sg;
            foreach (n3_, u3; singletonRows) sg ~= n3_ ~ "\t" ~ u3 ~ "\n";
            std.file.write(buildPath(outDir, "qmlsingletons.tsv"), sg);
            // C++ CLASS -> QML name, for EVERY exported type. qmlmap carries this only for types we
            // subclass, so a property whose C++ type is an unbound helper (`palette` is a
            // QQuickPalette*) could not be followed: the compiler had the class name and no way to
            // reach the rows the registry files under the QML name.
            string cn;
            foreach (c4, q4; qmlOfAll) if (c4 != q4) cn ~= c4 ~ "\t" ~ q4 ~ "\n";
            std.file.write(buildPath(outDir, "qmlcxxnames.tsv"), cn);
            std.file.write(buildPath(outDir, "qmlmethods.tsv"), methodRows);
            writefln("qmlsingletons: %d singleton rows -> qmlsingletons.tsv", singletonRows.length);
            string qa;   // qmlattached.tsv: <QML name>\t<prop>\t<dtype>\t<notify>\t<cxx type>
            foreach (qn2, acls; attachedOf) {
                for (string c2 = acls; c2.length;) {
                    if (auto ps2 = c2 in ownProps)
                        foreach (pn2, pty2; *ps2) {
                            string dty2 = pty2, cxx2 = pty2;
                            if (pty2.length && pty2[0] == '\x01') { dty2 = ""; cxx2 = pty2[1 .. $]; }
                            string ns2;
                            if (auto nm3 = c2 in ownNotify) if (auto x2 = pn2 in *nm3) ns2 = *x2;
                            qa ~= qn2 ~ "\t" ~ pn2 ~ "\t" ~ dty2 ~ "\t" ~ ns2 ~ "\t" ~ cxx2 ~ "\n";
                        }
                    auto nx2 = c2 in protoOf; c2 = nx2 ? *nx2 : "";
                }
            }
            std.file.write(buildPath(outDir, "qmlattached.tsv"), qa);
            writefln("qmlattached: %d attached-type rows -> qmlattached.tsv", attachedOf.length);
            writefln("qmluris: %d QML-name -> module rows -> qmluris.tsv", uriRows.length);
        }
        std.file.write(buildPath(outDir, "qmlprops.tsv"), qprops);
        // …and the signal table, walked up the prototype chain the same way, so a Button carries
        // AbstractButton's `clicked`.
        string qsigs; int rows4;
        foreach (cpp, qmlName; qmlOf) {
            bool[string] seenSig;
            for (string c = cpp; c.length;) {
                if (auto ss = c in ownSignals)
                    foreach (sn, sig; *ss)
                        if (sn !in seenSig) { seenSig[sn] = true; qsigs ~= qmlName ~ "\t" ~ sn ~ "\t" ~ sig ~ "\n"; rows4++; }
                auto nx = c in protoOf;
                c = nx ? *nx : "";
            }
        }
        std.file.write(buildPath(outDir, "qmlsignals.tsv"), qsigs);
        writefln("qmlsignals.tsv: %d signal rows", rows4);
        writefln("qmlmap: %d QML-name -> class rows -> qmlmap.tsv (%d property rows -> qmlprops.tsv)",
                 rows2, rows3);
    }

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

