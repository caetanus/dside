// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// qtd_build.d — shared reggae helpers for building qt-dlang-gen bindings and apps.
//
// The generator (`xiboca`) is a pure code generator: it emits a nested-layout binding
// (`<genDir>/qt/<pkg>/*.d` matching each `module` name, plus top-level cxxrt/holder/
// qtmoc and the C++ shim `.cpp`). reggae owns the whole build graph:
//
//   gen (run xiboca)  ->  shims.a (clang++ every .cpp)      \
//                    ->  binding_<dc>.a (compile every .d   >-- link app
//                        per-module, archive)              /
//
// The archive is the key: the linker pulls only the members an app references, so the
// per-app import-closure BFS the old shell scripts did is gone (proven: dmd linking a
// full webengine binding directly fails on an unreferenced inline symbol; the same
// objects in an archive link clean). D is compiled with ldc2 AND dmd (parity).
module qtd_build;

import reggae;
import std.json, std.file, std.path, std.process, std.string, std.array, std.algorithm;

// PATHS THIS BUILD PUTS IN SHELL COMMANDS ARE POSIX-SHAPED.
//
// Every command here is `sh -c`, and on Windows std.path.buildPath returns backslashes — which sh
// eats as escapes. The first full build there died on `mkdir -p C:\Users\...` for exactly that
// reason. Windows accepts forward slashes everywhere this build cares about (clang, ldc2, dmd,
// llvm-lib, and Git Bash itself), so the separator is normalised at the one place every path is
// composed instead of at the hundreds where they are used.
//
// On POSIX this is the identity.
string buildPath(A...)(A args) {
    import std.path : stdBuildPath = buildPath;
    import std.string : replace;
    return stdBuildPath(args).replace("\\", "/");
}

// ...and the other composer. Missing this one let a native path reach a command, where the shell
// ate the separators outright: clang++ was handed 'C:Userscaetanodsidegenerated...' and reported
// no input files. Both composers, or neither.
string buildNormalizedPath(A...)(A args) {
    import std.path : stdNorm = buildNormalizedPath;
    import std.string : replace;
    return stdNorm(args).replace("\\", "/");
}


// ---------------------------------------------------------------------------------------------
// WHERE QT IS — asked through six questions, not through one tool.
//
// The build used pkg-config in 35 places to decide what exists, where its headers are and which
// version it is. Qt's MSVC builds ship no .pc files at all, so on Windows the reggaefile could not
// even LIST its targets: it died in spawnProcess before constructing the graph.
//
// Those 35 calls turned out to be six distinct questions. They are answered here, by pkg-config
// where it exists and from a Qt prefix where it does not — so the rest of the build asks about Qt
// rather than about a tool that happens to know about Qt.
//
// On Windows the prefix comes from QTDIR, and its absence is a clear refusal rather than an empty
// answer: an empty answer would build a graph with no Qt targets in it and call that success, which
// is the vacuous-pass shape this project keeps finding.
// `/c/Qt/x` and `/cygdrive/c/Qt/x` -> `C:/Qt/x`. Anything else passes through untouched, so a
// native path, a relative path and the empty string are all unharmed.
//
// EVERY path this build reads from the environment comes from an MSYS shell and is in that form —
// QTDIR, and the entries of PATH. The tools it hands them to are native Windows programs, and none
// of them says so: clang++ reports a missing header, lld-link reads a leading `/` as an option and
// reports an undefined symbol, and a PATH scan simply finds nothing where the tool plainly is.
// The other direction: `C:/Qt/5.15.2` -> `/c/Qt/5.15.2`. A path that has to live INSIDE a PATH
// list cannot keep its drive letter — `:` is the separator there, and `C:/x:/d/y` is unparseable.
// MSYS translates PATH back to the native form when it spawns a native program, so this is the
// form to hand it.
string msysPath(string d) {
    version (Windows) {
        import std.ascii : isAlpha, toLower;
        if (d.length >= 2 && d[0].isAlpha && d[1] == ':')
            return "/" ~ d[0].toLower ~ d[2 .. $].replace("\\", "/");
    }
    return d;
}

string nativePath(string d) {
    version (Windows) {
        import std.ascii : isAlpha, toUpper;
        if (d.startsWith("/cygdrive/")) d = d["/cygdrive".length .. $];
        if (d.length >= 2 && d[0] == '/' && d[1].isAlpha && (d.length == 2 || d[2] == '/'))
            return d[1].toUpper ~ ":" ~ d[2 .. $];
    }
    return d;
}

private struct QtProbe {
    static bool usePkgConfig() {
        static int cached = -1;
        if (cached < 0) {
            try cached = (execute(["pkg-config", "--version"]).status == 0) ? 1 : 0;
            catch (Exception) cached = 0;
        }
        return cached == 1;
    }

    // A PREFIX THE NATIVE TOOLCHAIN CAN OPEN.
    //
    // The build is driven from an MSYS shell, where `QTDIR=/c/Qt/6.10.3/msvc2022_64` is the natural
    // thing to export — but clang++ and lld-link are native Windows programs with no idea what
    // `/c` mounts. The failure does not look like a path failure in either tool:
    //
    //   clang++   -I/c/Qt/.../include   ->  fatal error: 'QString' file not found
    //   lld-link   /c/Qt/.../Qt6Core.lib ->  a leading `/` IS an option, so the library is
    //                                        "ignored" and the link fails with undefined symbols
    //
    // So the drive-letter form is restored here, once, rather than at the ~40 places that consume
    // a path derived from the prefix.
    // THE PREFIX FOR A GIVEN MODULE, because a dual-target build has two Qt installations and
    // one QTDIR cannot name both. QTDIR5/QTDIR6 win when set; QTDIR is the answer for a machine
    // with a single Qt, which is what it has always meant.
    static string prefix(string mod = "") {
        auto v = (mod.length > 2 && mod.startsWith("Qt") && (mod[2] == '5' || mod[2] == '6'))
               ? environment.get("QTDIR" ~ mod[2 .. 3], "") : "";
        return nativePath(v.length ? v : environment.get("QTDIR", ""));
    }

    // ...and the same question asked with a whole module list: they never mix majors.
    static string prefixOf(string[] mods) { return prefix(mods.length ? mods[0] : ""); }


    // Qt6Core -> QtCore, Qt5Widgets -> QtWidgets: the include directory Qt installs per module.
    static string moduleDirOf(string mod) { return moduleDir(mod); }

    private static string moduleDir(string mod) {
        if (mod.length > 3 && mod.startsWith("Qt") && (mod[2] == '5' || mod[2] == '6'))
            return "Qt" ~ mod[3 .. $];
        return mod;
    }

    // QT'S OWN MODULE METADATA, which every Qt 5 and Qt 6 install ships on every platform:
    //
    //   <prefix>/mkspecs/modules/qt_lib_widgets.pri
    //     QT.widgets.name    = QtWidgets     <- the include directory
    //     QT.widgets.module  = Qt6Widgets    <- the library base name
    //     QT.widgets.depends =  core gui     <- what pkg-config's `Requires:` gives us for free
    //
    // Asking for a module has always meant asking for what it needs. Without this, a binding that
    // asked for Qt6Widgets got `-I…/include/QtWidgets` and nothing else, and `#include <QString>`
    // was not found — invisible on Linux, where pkg-config resolves `Requires:` and hands back
    // QtCore and QtGui unasked. The answer is Qt's own data rather than a table of dependencies
    // maintained here, which would be one more thing that can disagree with the Qt in front of us.
    private static string priPath(string pfx, string key) {
        return buildPath(pfx, "mkspecs", "modules", "qt_lib_" ~ key ~ ".pri");
    }

    private static string priField(string pfx, string key, string field) {
        auto p = priPath(pfx, key);
        if (!std.file.exists(p)) return "";
        auto want = "QT." ~ key ~ "." ~ field;
        foreach (line; readText(p).splitLines) {
            auto t = line.strip;
            if (!t.startsWith(want)) continue;
            auto eq = t.indexOf('=');
            // `QT.widgets.name` must not match `QT.widgets.name_extra`: everything between the
            // field and the `=` has to be whitespace.
            if (eq > 0 && t[want.length .. eq].strip.length == 0) return t[eq + 1 .. $].strip;
        }
        return "";
    }

    // Qt6Widgets -> widgets
    private static string priKey(string mod) {
        import std.uni : toLower;
        auto d = moduleDir(mod);
        return (d.startsWith("Qt") ? d[2 .. $] : d).toLower;
    }

    // The dependency closure, dependencies BEFORE dependents, deduplicated. Empty when this Qt
    // ships no mkspecs (then the callers fall back to the modules they were handed).
    private static string[] closure(string[] mods) {
        auto pfx = prefixOf(mods);
        string[] keys;
        bool[string] seen;
        void visit(string k) {
            if (k in seen || !std.file.exists(priPath(pfx, k))) return;
            seen[k] = true;                       // before recursing: a cycle must not hang the build
            foreach (d; priField(pfx, k, "depends").split) visit(d);
            keys ~= k;
        }
        foreach (m; mods) visit(priKey(m));
        return keys;
    }

    static bool exists(string mod) {
        if (usePkgConfig) return execute(["pkg-config", "--exists", mod]).status == 0;
        auto p = prefix(mod);
        return p.length && std.file.exists(buildPath(p, "lib", mod ~ ".lib"));
    }

    static string cflags(string[] mods) {
        if (usePkgConfig) return execute(["pkg-config", "--cflags"] ~ mods).output.strip;
        auto p = prefixOf(mods);
        if (!p.length) return "";
        string[] f = ["-I" ~ buildPath(p, "include")];
        auto keys = closure(mods);
        if (keys.length)
            foreach (k; keys) {
                auto n = priField(p, k, "name");
                if (n.length) f ~= "-I" ~ buildPath(p, "include", n);
                // ...AND THE MODULE'S OWN DEFINE. pkg-config's Cflags carry `-DQT_QML_LIB`,
                // `-DQT_WIDGETS_LIB` and so on, and Qt's headers are written against them: the
                // generated qtdmoc.cpp guards its QtQml includes with `#ifdef QT_QML_LIB`, so
                // without it the file compiled, saw only a forward declaration and failed with
                // `variable has incomplete type 'QQmlProperty'` — 600 lines from the include that
                // was silently skipped. Same source as everything else here: `QT.qml.DEFINES`.
                foreach (d; priField(p, k, "DEFINES").split) f ~= "-D" ~ d;
            }
        else
            foreach (m; mods) f ~= "-I" ~ buildPath(p, "include", moduleDir(m));
        return f.join(" ");
    }

    static string libs(string[] mods) {
        if (usePkgConfig) return execute(["pkg-config", "--libs"] ~ mods).output.strip;
        auto p = prefixOf(mods);
        if (!p.length) return "";
        auto keys = closure(mods);
        if (!keys.length) return mods.map!(m => buildPath(p, "lib", m ~ ".lib")).join(" ");
        // Dependents before dependencies, which is the order a linker that resolves left to right
        // wants — the reverse of the order the closure produces them in.
        string[] libs;
        foreach_reverse (k; keys) {
            auto m = priField(p, k, "module");
            if (m.length) libs ~= buildPath(p, "lib", m ~ ".lib");
        }
        return libs.join(" ");
    }

    static string modversion(string mod) {
        if (usePkgConfig) {
            auto r = execute(["pkg-config", "--modversion", mod]);
            return r.status == 0 ? r.output.strip : "";
        }
        // The version is the directory Qt installs its private headers under.
        auto p = prefix(mod);
        if (!p.length) return "";
        foreach (e; dirEntries(buildPath(p, "include", "QtCore"), SpanMode.shallow))
            if (e.isDir && baseName(e.name).length && baseName(e.name)[0] >= '5'
                        && baseName(e.name)[0] <= '9')
                return baseName(e.name);
        return "";
    }

    // moc and friends live in libexec on Linux and in bin on Windows.
    static string libexecdir(string mod) {
        if (usePkgConfig)
            return execute(["pkg-config", "--variable=libexecdir", mod]).output.strip;
        auto p = prefix(mod);
        return p.length ? buildPath(p, "bin") : "";
    }

    static string bindir(string mod) {
        if (usePkgConfig)
            return execute(["pkg-config", "--variable=bindir", mod]).output.strip;
        auto p = prefix(mod);
        return p.length ? buildPath(p, "bin") : "";
    }
}

// Import path for test-support modules that are pure manifest constants — appctor.d, which
// carries the application constructor's symbol for this ABI. Manifest constants emit no symbols,
// so an import path is the whole wiring: nothing to compile, nothing to link.
string dSupport(string root) { return " -I" ~ buildPath(root, "tests", "support"); }

// An executable's file name. Qt installs `moc` on POSIX and `moc.exe` on Windows, and a build that
// tests for the file rather than relying on PATH has to ask for the right one — otherwise a present
// tool reads as missing, which is what "moc=MISSING" meant on a machine where moc was right there.
string exeName(string n) {
    version (Windows) return n ~ ".exe";
    else              return n;
}

// Whether the build can rely on pkg-config for this run. Same question the probe asks, exposed so
// the gen step can decide whether a spec needs its flags filled in.
bool havePkgConfigForBuild() {
    static int cached = -1;
    if (cached < 0) {
        try cached = (execute(["pkg-config", "--version"]).status == 0) ? 1 : 0;
        catch (Exception) cached = 0;
    }
    return cached == 1;
}

// Position-independent code is a POSIX shared-library concern. On Windows every image is
// relocatable by construction and clang-cl/clang targeting MSVC rejects the flag outright:
//
//     clang++: error: unsupported option '-fPIC' for target 'x86_64-pc-windows-msvc'
//
// So the flag is named here rather than spelled at each of the twenty-odd compile lines.
string cxxPic() {
    version (Windows) return "";
    else              return "-fPIC";
}

// Making a static archive. `ar rcs <lib> <objs>` on POSIX; on Windows the archiver is llvm-lib,
// which takes /OUT: and no operation letters. Named here so the twenty call sites ask for "an
// archive of these objects" rather than for one platform's tool.
//
// The object extension differs too — .o against .obj — and follows the same rule.
// Archiving a binding means naming a few thousand object files, and Windows has a hard limit on
// the length of a command line that `ar` on POSIX does not:
//
//     sh: llvm-lib: Argument list too long
//
// llvm-lib reads a RESPONSE FILE with `@`, one path per line, which has no such limit. The list is
// still produced by the shell expanding the same glob — `printf` is a builtin, so writing the file
// never builds an argument list either.
string arCmd(string lib, string objs) {
    version (Windows) {
        auto rsp = lib ~ ".rsp";
        return "printf '%s\\n' " ~ objs ~ " > " ~ rsp ~ " && llvm-lib /OUT:" ~ lib ~ " @" ~ rsp;
    } else return "ar rcs " ~ lib ~ " " ~ objs;
}

// The C++ runtime is a library you name on POSIX and part of the CRT on Windows, where asking for
// it by name gets `lld-link: error: could not open 'stdc++.lib'`.
// ...and the same answer as a linker fragment, for the many command strings that concatenate one.
// LINK EVERY OBJECT OF AN ARCHIVE, whatever the linker calls it. A Qt type's
// QQmlModuleRegistration is a static object nobody references, so without this the linker drops
// it and the module simply is not there at run time:
//
//     module "QmltcTests" is not installed
//
// lld-link does not know `--whole-archive`: it says `ignoring unknown argument` and carries on,
// which is how this produced a QML error rather than a link error.
string wholeArchive(string lib) {
    // -Wl, on BOTH: this goes to the clang++ DRIVER, and a bare `/WHOLEARCHIVE:…` reads as an
    // input file path to a gnu-style driver, which silently does nothing. The archive is still
    // named separately — /WHOLEARCHIVE only asks for it to be pulled in whole.
    version (Windows) return "-Wl,/WHOLEARCHIVE:" ~ lib ~ " " ~ lib;
    else              return "-Wl,--whole-archive " ~ lib ~ " -Wl,--no-whole-archive";
}

// ...and the same for a D compiler's link line, where each token is passed with -L.
string wholeArchiveD(string lib) {
    version (Windows) return "-L/WHOLEARCHIVE:" ~ lib;
    else              return "-L--whole-archive -L=" ~ lib ~ " -L--no-whole-archive";
}

string cxxRuntimeFlag() {
    version (Windows) return "";
    else              return " -L-lstdc++";
}

string[] cxxRuntimeLibs() {
    version (Windows) return [];
    else              return ["-lstdc++"];
}

string objExt() {
    version (Windows) return ".obj";
    else              return ".o";
}

// The six questions, as free functions so call sites read as questions about Qt.
bool   qtHasModule(string mod)      { return QtProbe.exists(mod); }
string qtCflags(string[] mods)      { return QtProbe.cflags(mods); }
string qtLibsOf(string[] mods)      { return QtProbe.libs(mods); }
string qtModVersion(string mod)     { return QtProbe.modversion(mod); }
string qtLibexecDir(string mod)     { return QtProbe.libexecdir(mod); }
string qtBinDir(string mod)         { return QtProbe.bindir(mod); }

// --- pkg-config ---------------------------------------------------------------

string pkgCflags(string[] mods) {
    return qtCflags(mods);
}

// Linker flags for the D compiler: each `-lFoo`/`-L/path` token wrapped as `-L<tok>`
// (ldc2/dmd forward `-L…` to the C linker), plus libstdc++ for the C++ runtime.
string pkgLibs(string[] mods) {
    auto toks = qtLibsOf(mods).split ~ cxxRuntimeLibs();
    return toks.map!(t => "-L" ~ t).join(" ");
}

// QMetaObjectBuilder lives in Qt's PRIVATE API: from the pkg-config `-I…/QtCore`, find
// the sibling `-I…/QtCore/<full.patch.version>[/QtCore]` that has QtCore/private. Ported
// verbatim from the old generator (emit.d) — qtdmoc.cpp needs these to compile.
// For a Qt module dir `-I…/QtX`, find the sibling `-I…/QtX/<full.patch.ver>[/QtX]` that holds
// `QtX/private` (Qt private API). Generic over the module name.
string[] modulePrivateFlags(string cflags, string mod) {
    foreach (f; cflags.split)
        if (f.startsWith("-I") && f.endsWith("/" ~ mod) && exists(f[2 .. $]))
            foreach (de; dirEntries(f[2 .. $], SpanMode.shallow))
                if (de.isDir && exists(buildPath(de.name, mod, "private")))
                    // FORWARD SLASHES. These two come from dirEntries, which returns native paths,
                    // and a backslash does not survive the way to the compiler: the flag read
                    // `-I…/include/QtQml\6.10.3` in the command and arrived as
                    // `-I…/include/QtQml6.10.3`, so clang reported
                    // `'QtQml/private/qqmljsengine_p.h' file not found` about a header that was
                    // plainly there. Every other path in these flags already uses `/`.
                    return [fwdSlash("-I" ~ de.name), fwdSlash("-I" ~ buildPath(de.name, mod))];
    return [];
}

// A path as every tool this build talks to will accept it. Windows accepts `/` everywhere;
// `\` is the one that gets eaten between cmd.exe and sh.
string fwdSlash(string p) {
    version (Windows) return p.replace("\\", "/");
    else              return p;
}
string[] mocPrivateFlags(string cflags) { return modulePrivateFlags(cflags, "QtCore"); }

// qmlcachegen (Qt's AOT QML bytecode compiler) lives under the Qt libexecdir. Returns "" if
// it isn't installed, so callers can skip the AOT targets on a system that lacks it.
string qmlcachegenPath() {
    auto le = qtLibexecDir("Qt6Qml");
    // exeName: it is `qmlcachegen.exe` on Windows, and asking for the bare name found nothing —
    // so every AOT target silently left the graph, the same way `moc` read as MISSING once.
    auto p = buildPath(le, exeName("qmlcachegen"));
    return exists(p) ? p : "";
}

// lrelease (Qt's .ts -> .qm compiler) — a user-facing tool, usually in bindir or PATH.
// Returns "" if absent so the translation round-trip test degrades to an identity-only check.
string lreleasePath() {
    auto bd = qtBinDir("Qt6Core");
    foreach (p; [buildPath(bd, exeName("lrelease")), "/usr/bin/lrelease"])
        if (exists(p)) return p;
    return execute(["which", exeName("lrelease")]).status == 0 ? "lrelease" : "";
}

// --- the binding graph --------------------------------------------------------

struct QtdBinding {
    Target gen;       // runs xiboca -> a stamp (the whole genDir is regenerated clean)
    Target shims;     // libshims.a (all .cpp, C++)
    string root;
    string genDir;    // pure generated sources (owned by xiboca, wiped on each regen)
    string bdir;      // reggae build artifacts (objects, archives) — kept out of genDir
    string[] mods;    // pkg-config modules (Qt6Widgets, …)
    string specName;  // the spec file this binding was generated from — gates that read DECLARED
                      // policy (ownership transfers) need the spec, not just its output
}

// The Qt minor a binding was generated for ("6.11"), taken from its genDir (…/qt-6.11/cxx-…),
// and the minor actually installed. A coverage baseline is only meaningful against the SDK it was
// recorded on, so these two decide whether the manifest gate can be enforced or must stay
// advisory — the answer is a version question, not a permanent exemption.
string bindingQtMinor(string genDir) {
    // Walk from the RIGHT and require a digit after "qt-": the project directory itself is
    // called qt-dlang-gen, which a plain startsWith("qt-") happily matched first.
    auto parts = genDir.split(dirSeparator);
    foreach_reverse (part; parts) {
        if (!part.startsWith("qt-") || part.length <= 3) continue;
        auto rest = part["qt-".length .. $];
        if (rest[0] >= '0' && rest[0] <= '9') return rest;
    }
    return "";
}

string installedQtMinor(string pkgMod) {
    auto v = qtModVersion(pkgMod).split(".");
    return v.length >= 2 ? v[0] ~ "." ~ v[1] : "";
}

// dub names the executable for the platform, so the file on disk is `xiboca.exe` on Windows —
// and this path is BOTH the target's declared output and the program the gen step runs. Without
// the suffix reggae watched a file that never appears (so the target could never be up to date)
// and the runner could not find the binary. MSYS's sh hid the second half by appending `.exe`
// itself when the exact name does not exist; CreateProcess does not.
private string gendPath(string root) { return buildPath(root, "xiboca", exeName("xiboca")); }

// The generator binary is an INPUT to every gen step, but it was only ever built by hand
// (`dub build` in xiboca/). Editing emit_cxx.d therefore changed nothing: the build kept
// running a months-old xiboca and re-emitted identical bindings, so a generator fix looked like it
// had no effect. Measured: after teaching the generator to keep C++ default member initializers,
// the regenerated color.d still said `bool m_null;` until xiboca was rebuilt by hand.
// Now it is a real target, rebuilt from its own sources before anything depends on it.
// WHERE THE LINKER FINDS libclang, on a platform with no default library path.
//
// `libs-windows: ["libclang"]` names the library; nothing tells the linker where it lives, and
// POSIX gets away with that because /usr/lib is searched by default:
//
//     LINK : fatal error LNK1104: cannot open file 'libclang.lib'
//
// The answer is next to the clang++ this build already uses — <llvm>/bin/clang++ -> <llvm>/lib —
// so it is derived from PATH rather than configured.
//
// It is handed over as DFLAGS, which dub appends to the compiler's flags, and NOT as the `LIB`
// environment variable: dmd's sc.ini SETS LIB in its own [Environment64] section, which replaces
// whatever was inherited. Measured — the command carried `LIB=C:/Users/caetano/llvm/lib` and the
// link still failed with LNK1104.
//
// Returns "" when clang++ is not on PATH or the sibling lib/ is absent, leaving the linker's own
// defaults, which is as good an answer as we have.
string llvmLibEnv() {
    version (Windows) {
        // PATH comes from the MSYS shell, so its entries need the same treatment as QTDIR —
        // otherwise the scan finds nothing where clang++ plainly is. MSYS also separates with `:`
        // rather than the `;` a native build expects, and a piece may be in either form, so only
        // a piece that STARTS as an MSYS path is split further: splitting `C:/llvm/bin` on `:`
        // would hand the scan `C` and `/llvm/bin`, neither of which exists.
        string[] dirs;
        foreach (piece; environment.get("PATH", "").split(pathSeparator))
            dirs ~= piece.startsWith("/") ? piece.split(':') : [piece];
        foreach (raw; dirs) {
            auto dir = nativePath(raw);
            if (!dir.length) continue;
            if (!std.file.exists(buildPath(dir, exeName("clang++")))) continue;
            auto lib = buildNormalizedPath(dir, "..", "lib");
            // Forward slashes SURVIVE the executeShell -> cmd.exe -> sh chain; backslashes do not.
            if (std.file.exists(lib)) return `DFLAGS="-L/LIBPATH:` ~ lib.replace("\\", "/") ~ `" `;
        }
    }
    return "";
}

// The same value, without the `NAME="…" ` shell dressing: the PowerShell half sets the variable
// itself, and there is no shell in between to strip the quotes.
string llvmLibDflags() {
    auto s = llvmLibEnv();
    if (!s.length) return "";
    auto i = s.indexOf('"');
    auto j = s.lastIndexOf('"');
    return (i < 0 || j <= i) ? "" : s[i + 1 .. j].idup;
}

Target gendTarget(string root) {
    auto dir = buildPath(root, "xiboca");
    auto xiboca = gendPath(root);
    auto srcs = ["clang_c.d", "gen.d", "emit.d", "emit_cxx.d"].map!(f => buildPath(dir, f)).array;
    // dub decides itself whether a relink is needed; guarded() keeps concurrent gen steps from
    // racing into the same dub build, and skips it outright when xiboca is already newest.
    // The PowerShell half was `null` here for a long time and nothing noticed, because xiboca's
    // sources had not changed since the conversion and the step was always skipped as up to date.
    // The first edit to the generator brought it back with `flock: command not found` — a step
    // whose second dialect is missing is not a step that fails, it is a step that waits.
    auto df = llvmLibDflags();
    auto cmd = guarded(buildPath(dir, "xiboca.lock"),
        "cd " ~ dir ~ " && " ~ llvmLibEnv() ~ "dub build --quiet",
        psStep("dub.ps1", ["-Dir", dir] ~ (df.length ? ["-DFlags", df] : [])),
        xiboca, srcs);
    return Target(xiboca, cmd, srcs.map!(f => Target(f)).array);
}

// WHEN A NODE NEEDS THIS (the rule, so the next shared node doesn't slip through): a node needs
// guarding only if the SAME output can be produced by more than one scheduled command. Two shapes
// cause that — (a) a diamond, where many consumers depend on one expensive producer, and (b) a
// Target rebuilt by a factory that several call sites invoke, which yields several distinct
// Target objects writing the same path. For (b) the fix is to MEMOISE the factory so there is one
// node (see uidumpObj/qmltcTool in reggaefile.d), not to add a lock. A node with a unique output
// and one consumer needs neither. Audited: the shared nodes here are gen/shims/lib (guarded),
// uidump.o and the qmltc tool (memoised); two from-scratch builds completed clean.
//
// reggae's binary backend can schedule a shared diamond node (many apps -> one binding's
// gen/shims/lib) more than once concurrently. Two overlapping `rm -rf … && rebuild` on
// the same output then truncate each other's files. Wrap such a command so it is (a)
// serialized by an flock on `lock`, and (b) a no-op when `output` is already newer than
// every `newerThan` input. Single quotes in `cmd` are escaped for the `sh -c '…'` wrapper.
// Same, for a command that LINKS a binary (its text still contains `$out`). The binary is written
// to a temporary and moved into place, because `mv` within one filesystem is atomic: a run already
// executing the old file keeps its inode, and no one can ever observe the half-written one.
// Writing straight to the final path leaves a window where the file exists but is not yet
// executable — a concurrent run of a test that uses it then dies with EACCES ("Permission
// denied"), which is exactly how this surfaced in a full-matrix run of qmltc_Computed_dmd_check.
string guardedLink(string lock, string cmdWithOut, string output, string[] newerThan) {
    auto tmp = output ~ ".tmp$$";
    return guarded(lock, cmdWithOut.replace("$out", tmp) ~ " && mv -f " ~ tmp ~ " " ~ output,
                   null, output, newerThan);
}

// `winPs` is the SAME step said in PowerShell — a program and its arguments, which is what
// tools/win/guard.ps1 runs. The two dialects sit at the same call site on purpose: they are one
// decision, and a step whose two halves live apart is a step whose halves drift. Passing null
// keeps the sh form on Windows too, for a step not converted yet.
string guarded(string lock, string cmd, string winPs, string output, string[] newerThan) {
    version (Windows) {
        if (winPs.length) {
            auto g = [psExe(), "-NoProfile", "-NonInteractive", "-InputFormat", "None", "-ExecutionPolicy", "Bypass",
                      "-File", psTool(_psRoot, "guard.ps1"),
                      "-Lock", lock, "-Output", output];
            if (newerThan.length) g ~= ["-Newer", newerThan.join(",")];
            g ~= ["-Payload", psEncode(winPs)];
            return g.map!psArg.join(" ");
        }
    }
    auto test = newerThan.map!(d => "[ " ~ output ~ " -nt " ~ d ~ " ]").join(" && ");
    auto inner = (test.length ? "if " ~ test ~ "; then exit 0; fi; " : "") ~ cmd;
    auto esc = inner.replace("'", `'\''`);
    return posixCmd("mkdir -p " ~ dirName(lock) ~ " && flock " ~ lock ~ " sh -c '" ~ esc ~ "'");
}

// WHERE THIS MACHINE'S Qt IS, for the callers that need the installation itself rather than one
// module's flags. QtProbe is private; this is the one answer worth exporting.
string qtPrefix() { return QtProbe.prefix(); }

// WHICH PLATFORM THIS IS, for the checks whose answer is a property of the platform rather than of
// the code — a coverage baseline, first of all: an X11-only type is absent on Windows for a reason
// that is not a regression.
string hostPlatform() {
    version (Windows)      return "windows";
    else version (OSX)     return "macos";
    else version (linux)   return "linux";
    else                   return "posix";
}

// AN `sh` GATE THAT RUNS ONE OF OUR OWN Qt-LINKED TOOLS. There is no rpath on Windows, so such a
// tool finds Qt's DLLs through PATH or not at all — and "not at all" is a process that dies before
// main. Every one of these scripts then reported something else entirely, because each had already
// decided what a silent tool meant:
//
//     shadow-aot: … has no refused expression — nothing to AOT (the fixture must delegate)
//     optlevels:  the ENGINE dumps nothing for AListView.qml — unjudgeable, not compared
//
// while the diagnostics file held `qmltc-d: error while loading shared libraries: Qt6Core.dll`.
// The PATH goes in through sh, not through the command text: cmd.exe does not understand
// `VAR=value cmd`, which is the same trap the -time-/-render- families fell into.
//
// MSYS form, because this value ends up INSIDE a `:`-separated PATH — `C:/Qt/...` would split at
// the drive letter.
string shGate(string cmd, string[] mods) {
    version (Windows) {
        if (!mods.length) return cmd;
        return posixCmd("PATH=" ~ msysPath(buildPath(QtProbe.prefixOf(mods), "bin")) ~ ":$PATH "
                        ~ cmd);
    } else return cmd;
}

// The repo root, so the PowerShell halves can be found without threading it through every
// signature. Set once, from the reggaefile, before any target is built.
__gshared string _psRoot;
void setPsRoot(string root) { _psRoot = root; }

// -InputFormat None is not optional here. Detached from a terminal — which is how the record
// execution runs, `nohup … &` over ssh — PowerShell 5.1 reads stdin, finds the other end closed,
// and dies inside its own host with
//
//     Erro interno "Nao ha processo na outra ponta do pipe" … SetConsoleWindowTitle
//
// naming the script it was running rather than the pipe. Interactively the same command works,
// which is exactly how this stayed hidden until the full matrix ran.
string psExe()  { return "powershell"; }
string psTool(string root, string script) { return buildPath(root, "tools", "win", script); }

// One argument of a command STRING. cmd.exe splits on spaces and respects one level of double
// quotes, and a Windows path routinely contains a space (`C:\Program Files\…`).
string psArg(string a) {
    return (a.length && !a.canFind(' ')) ? a : `"` ~ a ~ `"`;
}

// `prog args > outRef` for a step whose OUTPUT PATH reggae substitutes. The arguments travel
// encoded (the binder would read them first) and the output path travels plain (reggae has to be
// able to substitute it) — each the only way it can go. `ok` lists the exit codes that count as
// success, for the steps where a non-zero one is the expected answer.
string psCapture(string root, string exe, string[] args, string outRef,
                 string ok = "0", bool sortOut = false, string[] mods = null) {
    import std.base64 : Base64;
    import std.conv : to;
    auto w = args.join("\n").to!wstring;
    auto cmd = [psExe(), "-NoProfile", "-NonInteractive", "-InputFormat", "None", "-ExecutionPolicy", "Bypass",
                "-File", psTool(_psRoot, "run-capture.ps1"),
                "-Exe", exe, "-Out", outRef, "-Ok", ok];
    if (args.length) cmd ~= ["-ArgsB64", Base64.encode(cast(ubyte[]) w.dup).idup];
    if (mods.length) cmd ~= ["-QtBin", buildPath(QtProbe.prefixOf(mods), "bin")];
    auto s = cmd.map!psArg.join(" ");
    return sortOut ? s ~ " -Sort" : s;
}

// A path for a PowerShell literal: forward slashes are accepted everywhere on Windows and cannot
// be mistaken for an escape.
string msysWinPath(string p) { return p.replace("\\", "/"); }

// One PowerShell literal string. Single quotes, `'` doubled.
string psQ(string a) { return `'` ~ a.replace("'", "''") ~ `'`; }

// Run a program and capture its stdout into a file, the way `prog args > file` does on POSIX.
//
// The output is written with [System.IO.File]::WriteAllText and explicit LF, NOT Set-Content or
// `>`: PowerShell 5.1's redirection writes UTF-16, Set-Content writes the ANSI code page, and both
// write CRLF — and these files are read back by our own C++ oracle and compared against a POSIX
// run. The bytes have to be the same ones the sh side produced.
//
// `allowFail` is the `;` in `prog … > f 2>/dev/null;` — that step is allowed to fail, the diff
// afterwards is what judges. Without it the step is an `&&`.
// `keepPrefix` is `| grep '^<prefix>'`: several differentials read ONE property out of a dump.
string psRedirect(string exe, string[] args, string outFile, bool sortOut = false,
                  bool allowFail = false, string keepPrefix = null) {
    auto argList = args.length ? "@(" ~ args.map!psQ.join(", ") ~ ")" : "@()";
    string s = "$rc = Invoke-Proc -Exe " ~ psQ(exe) ~ " -ProcArgs " ~ argList ~ " -Capture"
             ~ "\n$o = $script:ProcOut"
             // DROP THE TRAILING EMPTY ELEMENT. Splitting "a\nb\n" on newlines yields a final
             // empty string, and writing it back added a blank line the POSIX `>` never produced.
             // Not cosmetic: the objpaths file is READ BACK by the oracle, and a blank path means
             // the ROOT object — so it dumped everything a second time and the differential failed
             // with every line reported as missing from our side.
             // `-gt 1`, and the single-element case handled separately: with ONE element,
             // $o[0 .. ($o.Count - 2)] is $o[0 .. -1], and PowerShell reads that as the range
             // 0,-1 — elements [0] and [-1], which are the SAME element. The array grows instead
             // of shrinking and the loop never ends. That is the descending-range trap again, in
             // a second place: a step whose tool printed nothing hung for ever, and the target
             // was killed by the timeout with no output at all.
             ~ "\nwhile ($o.Count -gt 1 -and $o[$o.Count - 1] -eq '') { $o = $o[0 .. ($o.Count - 2)] }"
             ~ "\nif ($o.Count -eq 1 -and $o[0] -eq '') { $o = @() }";
    // `@(...)`, because a Where-Object that matches ONE line yields that line, not an array of
    // one — and the next step would then index into a string.
    if (keepPrefix.length)
        s ~= "\n$o = @($o | Where-Object { $_.StartsWith(" ~ psQ(keepPrefix) ~ ") })";
    if (sortOut) s ~= "\n$o = $o | Sort-Object";
    if (!allowFail) s ~= "\nif ($rc -ne 0) { exit $rc }";
    s ~= "\n[System.IO.File]::WriteAllText(" ~ psQ(outFile) ~ ", (($o -join \"`n\") + \"`n\"))";
    return s;
}

// `diff a b`: same verdict (0 same, 1 different) and the differing lines on stdout, so a failure
// says what differed rather than only that something did.
//
// ...and on SUCCESS it says what matched. A diff that agrees prints nothing, which makes "the
// comparison passed" and "the comparison never ran" identical in a log — and one of those was
// true of thirteen targets. `label` is what the target proved, with the line count.
string psDiff(string a, string b, string label) {
    return "$da = Get-Content -LiteralPath " ~ psQ(a) ~ "\n"
         ~ "$db = Get-Content -LiteralPath " ~ psQ(b) ~ "\n"
         ~ "$d  = Compare-Object $da $db\n"
         ~ "if ($d) { $d | ForEach-Object { Write-Output ($_.SideIndicator + ' ' + $_.InputObject) }; exit 1 }\n"
         ~ "Write-Output (" ~ psQ(label ~ ": ") ~ " + $da.Count + ' lines match')";
}

// `! diff -q a b`: the two files must DIFFER. Several differentials prove a value CHANGED — that
// the document is not frozen, that the key was seen — and for those the passing verdict is the
// opposite one. It says so on success for the same reason psDiff does: "they differed" and "the
// step never ran" must not read the same in a log.
string psDiffer(string a, string b, string label) {
    return "$da = Get-Content -LiteralPath " ~ psQ(a) ~ "\n"
         ~ "$db = Get-Content -LiteralPath " ~ psQ(b) ~ "\n"
         ~ "if (-not (Compare-Object $da $db)) { Write-Output " ~ psQ("IDENTICAL: " ~ label)
         ~ "; exit 1 }\n"
         ~ "Write-Output " ~ psQ(label);
}

// A COMPOUND STEP, WRITTEN OUT AS ITS OWN .ps1 — for the commands this build composes itself
// (run a tool into a file, run two sides, diff them) rather than the fixed steps in tools/win.
//
// A file, not an encoded blob and not a long -Command: the text is arbitrary PowerShell, it is
// easier to read in a failure than a base64 string, and it can be run by hand. It is only valid
// for a command with NO reggae substitution in it — every path must be known when the graph is
// built, which is true of these because reggae only substitutes $in/$out for a target's own
// inputs and outputs, and a phony has neither.
//
// The preamble is what makes a sequence behave like `&&`: PowerShell keeps going after a native
// program fails, so `Run` checks and stops. $ErrorActionPreference covers the cmdlets.
string psInline(string root, string name, string[] lines, string[] mods = null) {
    auto dir = buildPath(root, ".build", "ps");
    auto path = buildPath(dir, name ~ ".ps1");
    auto preamble = [
        "$ErrorActionPreference = 'Stop'",
        "$ProgressPreference    = 'SilentlyContinue'",
        "$env:QT_QPA_PLATFORM   = 'offscreen'",
        // ...AND THE BINDING'S OWN Qt ON PATH. There is no rpath on Windows, so a program started
        // from here finds its DLLs through PATH or not at all — and "not at all" is a process that
        // dies before main with no output, which then reads as a failure of whatever came after.
        // Third place this had to be said: run-exe, run-capture, and now the generated steps.
        mods.length ? "$env:PATH = '" ~ msysWinPath(buildPath(QtProbe.prefixOf(mods), "bin"))
                      ~ ";' + $env:PATH" : "",
        // Invoke-Proc, not `&`: the call operator resolves a program through PATHEXT and these
        // binaries have no extension, so `&` does not find them, does not raise a terminating
        // error, and leaves $LASTEXITCODE unset — which reads as success. See tools/win/proc.ps1.
        ". '" ~ psTool(root, "proc.ps1") ~ "'",
        "function Run { $e = $args[0]; $r = if ($args.Count -gt 1) { $args[1 .. ($args.Count - 1)] } else { @() };",
        "               $rc = Invoke-Proc -Exe $e -ProcArgs $r; if ($rc -ne 0) { exit $rc } }",
    ];
    writeIfChanged(path, (preamble.filter!(l => l.length).array ~ lines).join("\n") ~ "\n");
    return [psExe(), "-NoProfile", "-NonInteractive", "-InputFormat", "None", "-ExecutionPolicy", "Bypass", "-File", path]
           .map!psArg.join(" ");
}

// One `Run <exe> <args…>` line inside a psInline step: the program's output flows through and a
// non-zero exit stops the script, which is what `&&` did on the sh side. Use this when the step
// runs a program for its EFFECT (writing a PNG, comparing two of them) rather than its stdout;
// psRedirect is the one that captures.
string psRunLine(string exe, string[] args) {
    return (["Run", psQ(exe)] ~ args.map!psQ.array).join(" ");
}

// A PowerShell call to one of tools/win/*.ps1: `kv` alternates -Name and its VALUE, `switches`
// are the bare ones. The two are separate because guessing which is which does not work — the
// value of `-Cxx` is a flags string that starts with `-I…`, so a "does it start with a dash"
// rule left `-Cxx` with no argument and PowerShell said so:
//
//     Invoke-Expression : Falta um argumento para o parâmetro 'Cxx'
//
// Values are single-quoted, PowerShell's literal string, with `'` doubled to escape.
string psStep(string script, string[] kv, string[] switches = []) {
    auto q = (string a) => `'` ~ a.replace("'", "''") ~ `'`;
    string s = "& " ~ q(psTool(_psRoot, script));
    for (size_t i = 0; i + 1 < kv.length; i += 2) s ~= " " ~ kv[i] ~ " " ~ q(kv[i + 1]);
    foreach (sw; switches) s ~= " " ~ sw;
    return s;
}

// ...encoded, because handing the step over as trailing arguments lets PowerShell's parameter
// binder read it instead of the script: `-NoProfile` and the step's own names get matched against
// guard.ps1's parameters and the common ones, and the run died with `AmbiguousParameter`.
// Base64 of UTF-16LE is the encoding PowerShell's own -EncodedCommand speaks.
string psEncode(string script) {
    import std.base64 : Base64;
    import std.conv : to;
    auto w = script.to!wstring;
    return Base64.encode(cast(ubyte[]) w.dup);
}

// A COMMAND THIS BUILD WROTE, MADE SAFE TO HAND TO WHATEVER SHELL RUNS IT.
//
// reggae runs targets through std.process.executeShell, and on Windows that is cmd.exe — not by
// configuration but by construction: modern D takes the shell from `nativeShell`, a compile-time
// constant, so COMSPEC cannot redirect it. cmd.exe then parses `&&`, `|`, `>` and `^` before the
// inner program sees them, and a command written for sh is torn apart on the way in:
//
//     '/Users/caetano/qtest' is not recognized as an internal or external command
//
// Measured: cmd.exe DOES respect one level of double quotes, so `sh -c "<command>"` reaches sh
// whole, `&&` and all. Everything this build composes uses single quotes internally, so there is
// nothing to collide with the wrapper.
//
// On POSIX this is the identity — executeShell is already sh.
// The PowerShell that runs a build command, as an invocation prefix. `-File` rather than
// `-Command`/`-EncodedCommand` because only `-File` accepts trailing arguments, and a path reggae
// substitutes has to arrive as an argument: it is native and backslashed, and backslashes do not
// survive executeShell -> cmd.exe inside command TEXT.
string psRun(string root, string script) {
    return "powershell -NoProfile -NonInteractive -InputFormat None -ExecutionPolicy Bypass -File "
         ~ buildPath(root, "tools", "win", script);
}

// RUN A BUILT BINARY. POSIX runs it directly; Windows goes through tools/win/run-exe.ps1, which
// also puts the target's own Qt on PATH (no rpath there) and turns a relative path into one
// PowerShell will not mistake for a command name.
//
// `mods` names the Qt this binary needs — a property of the TARGET, not of the machine, so that a
// Qt5 binary in a dual-target build does not load Qt6's DLLs.
string runExe(string root, string binRef, string env = "", string extra = "", string[] mods = null) {
    version (Windows) {
        auto qtBin = mods.length ? QtProbe.prefixOf(mods) : "";
        string cmd = psRun(root, "run-exe.ps1");
        if (qtBin.length) cmd ~= ` -QtBin "` ~ buildPath(qtBin, "bin") ~ `"`;
        foreach (e; env.split) {
            if (e == "QT_QPA_PLATFORM=offscreen") { cmd ~= " -Platform offscreen"; continue; }
            cmd ~= ` -Env "` ~ e ~ `"`;
        }
        cmd ~= " -Exe " ~ binRef;
        if (extra.length) cmd ~= " " ~ extra;
        // ONE VISIBLE RETRY. Under a long run, powershell.exe occasionally does not start at all:
        // the target fails with a log containing nothing — not even the marker run-exe writes as
        // its first statement — while the identical command passes in isolation, attached,
        // detached and through cmd.exe, and it lands on a different target each time. The cause is
        // not established; the retry is a mitigation, and it announces itself so a run that needed
        // it is not mistaken for a clean one. `||` and `&` are cmd's, which is what parses this.
        return cmd ~ " || (echo run-exe: RETRY after a start failure & " ~ cmd ~ ")";
    } else
        return env ~ binRef ~ (extra.length ? " " ~ extra : "");
}

string runOffscreen(string root, string binRef, string extra = "", string[] mods = null) {
    return runExe(root, binRef, "QT_QPA_PLATFORM=offscreen ", extra, mods);
}

// A COMMAND WHOSE PATHS TRAVEL AS ARGUMENTS, for the same reason runOffscreen does it: a path
// reggae substitutes is native and backslashed, and backslashes do not survive
// executeShell -> cmd.exe -> sh inside command TEXT — `C:\Users\x\a.cpp` arrives as
// `C:Usersxa.cpp`. As positional arguments they arrive intact, so the text says $0, $1, … and the
// paths follow it. Same form on both platforms, so there is one behaviour to reason about.
string posixCmdArgv(string cmd, string[] paths) {
    return `sh -c '` ~ cmd.replace(`'`, `'\''`) ~ `' ` ~ paths.join(" ");
}

string posixCmd(string cmd) {
    version (Windows) {
        import std.string : replace, indexOf;
        // SINGLE QUOTES WHEN THE COMMAND ALLOWS IT, because inside them sh keeps backslashes.
        // reggae substitutes $in/$out with paths of its OWN making, which are native and therefore
        // backslashed — and inside double quotes sh ate them: the run command became
        // `.reggaeobjswraptest-ldc2.objswraptest-ldc2-bin: command not found`. Those paths are not
        // ours to normalise, so the quoting has to preserve them.
        //
        // Commands this build composes itself contain single quotes (guarded() wraps its body in
        // them) and cannot use that form; they carry only paths we built, which are already
        // forward-slashed, so double quotes are safe for them.
        if (cmd.indexOf('\'') < 0)
            return `sh -c '` ~ cmd ~ `'`;
        return `sh -c "` ~ cmd.replace(`"`, `\"`) ~ `"`;
    } else return cmd;
}

// reggaeBuild() runs on EVERY ./build (even --list), so an unconditional write here bumps the
// mtime of a file that other guards use as their freshness input — forcing a full libsample
// rebuild every time, and worse, doing it WHILE sibling targets link against the artifacts.
// Write only when the content actually differs.
void writeIfChanged(string path, string content) {
    if (exists(path) && readText(path) == content) return;
    // The directory may not exist yet. On a tree that has built before it always does, which is why
    // this went unnoticed until a FIRST build on Windows: graph construction writes several small
    // generated files (the revision stamp, the link manifest) into .build/<binding>/ before any
    // target has run, and the write failed with "cannot find the path" — during graph construction,
    // so the build could not even list its targets.
    mkdirRecurse(dirName(path));
    std.file.write(path, content);
}

// Build the `gen` + `shims` targets for a spec. `root` is the repo root; `spec` is the
// spec basename under generator/. `mods` are the pkg-config modules the binding needs.
QtdBinding qtdBinding(string root, string spec, string[] mods) {
    auto specPath = buildPath(root, "generator", spec);
    auto j = parseJSON(readText(specPath));
    auto genDir = buildNormalizedPath(dirName(specPath), j["out_dir"].str);
    // Unique per binding: the qt-x.y dir + the binding name (cxx-qtwidgets-wrap alone
    // collides between Qt5 and Qt6, which share a basename).
    auto bdir = buildPath(root, ".build", baseName(dirName(genDir)) ~ "-" ~ baseName(genDir));
    auto cflags = pkgCflags(mods);
    // -ffunction-sections/-fdata-sections put each shim (and each of the ~1500 exception
    // guards) in its own linker section, so the final link's --gc-sections drops the ones an
    // app doesn't call. Without this, libshims.a is one .o -> pulling any shim pulls ALL.
    auto cxx = cflags ~ " -std=c++17 " ~ cxxPic() ~ " -O2 -ffunction-sections -fdata-sections";
    // Extra include paths from the spec: private-header subdirs a private-API binding needs so the
    // aggregated shims (qtdctor/qtvirt/...) that reference private types (QQuickGradient etc.) compile.
    // A RELATIVE path in the spec is relative to the SPEC, not to whoever compiles: xiboca runs from
    // generator/, reggae from the repo root. Normalize so both resolve the same directory.
    // ...and a path that does not EXIST is dropped rather than passed. A spec's private-header
    // entries name one machine's Qt (`/usr/include/qt6/QtCore/6.11.1`); on another they are noise,
    // and the private header a corpus type includes is then not found at all:
    //     tests/qmltc/cpptypes/testprivateproperty.h: fatal error: 'private/qobject_p.h' not found
    // The ones that ARE there for this Qt come from the probe, below, and are added to every unit
    // rather than only to qtdmoc — a bound header may include a private one too.
    string[] specIncludes;
    if (auto ip = "include_paths" in j.object)
        foreach (p; ip.array) {
            auto d = isAbsolute(p.str) ? p.str : buildNormalizedPath(dirName(specPath), p.str);
            if (exists(d)) { specIncludes ~= d; cxx ~= " -I" ~ d; }
        }
    // qtdmoc.cpp needs the Qt private headers; the QML registration block is compiled in only
    // when this binding actually links Qt6Qml (else it would reference QQmlPrivate with no lib).
    // qtdmoc.cpp needs QtCore private (QMetaObjectBuilder) always, and — in a QML-enabled binding
    // — QtQml private too: attached-property lookup goes through QQmlMetaType, which is private.
    bool hasQml = mods.canFind("Qt6Qml") || mods.canFind("Qt5Qml");
    auto priv = mocPrivateFlags(cflags).join(" ")
        ~ (hasQml ? " " ~ modulePrivateFlags(pkgCflags([mods.canFind("Qt6Qml") ? "Qt6Qml" : "Qt5Qml"]), "QtQml").join(" ")
                    ~ " -DQTD_ENABLE_QML" : "");
    // The QtCore private directory goes to EVERY unit, not only qtdmoc: a bound header can include
    // `private/qobject_p.h` itself, and the spec's own entry for it names a Qt that is not here.
    // ...and every module's, for the same reason the derived spec gets them: a shim can reference
    // a private type of any module the binding covers (QQmlChangeSet, QHashedString in the quick
    // binding), and the spec's own entries for those name a Qt that is not on this machine.
    string[] privDirs;
    foreach (m; mods ~ ["Qt6Core"])
        foreach (f; modulePrivateFlags(cflags, QtProbe.moduleDirOf(m)))
            if (f.startsWith("-I") && !specIncludes.canFind(f[2 .. $]) && !privDirs.canFind(f[2 .. $]))
                privDirs ~= f[2 .. $];
    foreach (d; privDirs) cxx ~= " " ~ fwdSlash("-I" ~ d);

    // xiboca fully owns genDir: wipe it first so stale files from an earlier layout can't
    // linger (a flat qfoo.d beside the nested qt/pkg/qfoo.d would clash on the module).
    // The stamp lives in bdir, not genDir, so wiping genDir doesn't delete it.
    auto stamp = buildPath(bdir, "gen.stamp");
    auto xiboca = gendPath(root);

    // WHERE PKG-CONFIG IS ABSENT, THE BUILD ANSWERS FOR IT. The shipped specs name Qt modules
    // through `pkg_config`, which is the right thing to write down — it is a fact about the
    // binding, not about a machine. On Windows there is no pkg-config to resolve it, and xiboca
    // refuses rather than guessing. But the build already knows where Qt is, so it derives a spec
    // beside the binding with `cflags` and `libs` filled in from the probe. The shipped spec stays
    // platform-neutral; the platform knowledge stays in the build, which is the only place that
    // has it.
    auto useSpec = specPath;
    if (!havePkgConfigForBuild()) {
        auto derived = buildPath(bdir, "spec.win.json");
        auto jw = parseJSON(readText(specPath));
        // The derived spec lives somewhere else, so anything RELATIVE in it has to be resolved
        // first. out_dir is written relative to generator/; left alone it pointed at
        // .build/<binding>/../generated/... and the binding was written into a directory nothing
        // else looked at — measured: `qt/` appeared there and the shims went missing.
        jw.object["out_dir"] = JSONValue(genDir);
        // EVERY relative path in the spec, for the same reason. The derived spec lives in .build,
        // so a path written relative to generator/ points somewhere else once it is read from
        // there — `../tests/qmltc/cpptypes` became `.build/tests/…` and xiboca reported
        // `fatal error: 'typewithmanyproperties.h' file not found` about a header that is in the
        // repository. out_dir was the first of these; no reason to fix them one at a time.
        {
            auto specDir = dirName(specPath);
            string abs(string v) { return isAbsolute(v) ? v : buildNormalizedPath(specDir, v); }
            if (auto ip = "include_paths" in jw.object) {
                // A spec's private-header paths are written for ONE machine's Qt
                // (`/usr/include/qt6/QtCore/6.11.1`). They do not exist here, and xiboca then
                // reports `fatal error: 'private/qobject_p.h' file not found`. Drop what is not
                // there and add what the probe found for THIS Qt — the same private flags the
                // shims are compiled with, so the generator and the compiler agree.
                auto kept = ip.array.map!(e => abs(e.str)).filter!(d => exists(d)).array;
                // EVERY module's private directory, not just the two the shims happen to need. A
                // spec can name a private header of any module it binds — the quick binding asks
                // for `QtQuick/private/qquickrectangle_p.h` — and with only QtCore's and QtQml's
                // present the generator refused the whole binding.
                foreach (m; mods)
                    foreach (f; modulePrivateFlags(cflags, QtProbe.moduleDirOf(m)))
                        if (f.startsWith("-I") && exists(f[2 .. $]) && !kept.canFind(f[2 .. $]))
                            kept ~= f[2 .. $];
                foreach (f; priv.split)
                    if (f.startsWith("-I") && exists(f[2 .. $]) && !kept.canFind(f[2 .. $]))
                        kept ~= f[2 .. $];
                jw.object["include_paths"] = JSONValue(kept.map!(d => JSONValue(d)).array);
            }
            // typesystem_dir and docs_dir are written relative to the SPEC; source_filter is
            // written relative to the REPO ROOT, which is where xiboca runs. Resolving them the
            // same way pointed source_filter at generator/tests/... and the generator kept
            // nothing — `discovered 0 classes in your headers`, and then a D module that no
            // longer existed. Two conventions in one file, so two rules.
            foreach (k; ["typesystem_dir", "docs_dir"])
                if (auto v = k in jw.object)
                    if (v.type == JSONType.string) jw.object[k] = JSONValue(abs(v.str));
            if (auto v = "source_filter" in jw.object)
                if (v.type == JSONType.string && !isAbsolute(v.str))
                    jw.object["source_filter"] = JSONValue(buildNormalizedPath(root, v.str));
            // A header with a slash is NOT necessarily a path relative to the spec: it can be an
            // include-relative name that only the include path can resolve, like
            // `QtQuick/private/qquickrectangle_p.h`. Absolutising that produced
            //   fatal error: 'C:/.../generator/QtQuick/private/qquickrectangle_p.h' file not found
            // So a header is rewritten only when the rewritten path actually EXISTS; otherwise it
            // is left for the compiler to find, which is what it was always for.
            if (auto hs = "headers" in jw.object)
                jw.object["headers"] = JSONValue(hs.array.map!((e) {
                    auto a = abs(e.str);
                    return JSONValue(e.str.canFind('/') && exists(a) ? a : e.str);
                }).array);
            // The QML TYPE REGISTRY is written as absolute paths into one distribution's qml
            // directory (`/usr/lib/qt6/qml/QtQuick/plugins.qmltypes`). Nothing here resolved them,
            // and the damage was total but silent: qmlmap.tsv and every other QML table came out
            // EMPTY, so no QML name had a class, and qmltc-d answered
            //     root type 'Item' is not a bound Qt type ... skipped
            // for every fixture — 57 targets, none of which mentioned a registry.
            // Qt puts the same tree under `<prefix>/qml`, so the part after the LAST `/qml/` is
            // portable and the part before it is not. Rewritten unconditionally, even when the
            // result is absent: xiboca now names the file it could not find, and a path pointing
            // at THIS Qt is the one worth naming.
            if (auto qt = "qmltypes" in jw.object) {
                auto qmlRoot = buildPath(QtProbe.prefixOf(mods), "qml");
                jw.object["qmltypes"] = JSONValue(qt.array.map!((e) {
                    auto s = e.str.replace("\\", "/");
                    auto i = s.lastIndexOf("/qml/");
                    return JSONValue(i < 0 ? s : buildPath(qmlRoot, s[i + 5 .. $]));
                }).array);
            }
        }
        // ...and discovery needs to recognise THIS Qt. A marker in the spec describes a Linux
        // distribution's layout — `/qt6/`, or `/qt/` for the Qt5 specs — and Qt's own installer
        // puts the headers under the prefix instead. Leaving the spec's value in place was not a
        // conservative choice: `/qt/` does not match `C:/Qt/5.15.2/...` (the case differs), every
        // header was filtered out, and the run reported
        //
        //     discovered 0 classes in <QtWidgets>
        //
        // and exited 0. So the marker is REPLACED here, not merely defaulted: where we resolved
        // the installation ourselves we know exactly which headers are its, and that is a better
        // answer than a path fragment written for another platform. A headers-mode spec
        // (source_filter) is describing the user's own sources and is left alone.
        if ("source_filter" !in jw.object)
            jw.object["qt_marker"] = JSONValue(QtProbe.prefixOf(mods));
        jw.object["cflags"] = JSONValue(qtCflags(mods).split(" ").filter!(f => f.length).array
                                       .map!(f => JSONValue(f)).array);
        jw.object["libs"]   = JSONValue(qtLibsOf(mods).split(" ").filter!(f => f.length).array
                                       .map!(f => JSONValue(f)).array);
        writeIfChanged(derived, jw.toPrettyString);
        useSpec = derived;
    }
    // THE STAMP GOES FIRST. guarded() decides "already done" by comparing the stamp against the
    // inputs, so a run that wiped genDir and then FAILED leaves a stamp still newer than
    // everything — and from then on the gen step is skipped for ever while every consumer fails
    // somewhere else entirely (`Push-Location : PathNotFound`, about a directory nothing
    // regenerates). Removing it first means a failed run leaves no claim behind.
    auto genCmd = "rm -f " ~ stamp ~ " && rm -rf " ~ genDir ~ " && " ~ xiboca ~ " " ~ useSpec
                ~ " >/dev/null && touch " ~ stamp;
    // The generator COPIES these runtime sources verbatim into the binding (emit.d), so they are
    // build INPUTS. Without the edge, editing the runtime leaves every already-generated binding
    // on the old copy and the whole matrix goes green against code that is no longer in the tree —
    // which is exactly how a Qt5 build break stayed hidden.
    auto runtimeSrc = qtdRuntimeSources(root);
    auto gen = Target(stamp,
        // The guard watches the spec the generator is actually GIVEN. Watching the shipped one
        // while running a derived copy is the same shape as the install guard that could not see
        // the archives it copied: the derived spec changed, the stamp did not, and the step was
        // skipped while its output stayed wrong.
        guarded(bdir ~ "/gen.lock", genCmd,
                psStep("gen.ps1", ["-GenDir", genDir, "-Xiboca", xiboca, "-Spec", useSpec,
                                   "-Stamp", stamp]),
                stamp, [useSpec, xiboca] ~ runtimeSrc),
        // THE SPEC THE COMMAND ACTUALLY READS, which is the derived one where there is no
        // pkg-config. Declaring the original meant reggae never rescheduled the step when the
        // derived spec changed: the guard's own up-to-date check would have caught it, but the
        // guard only runs if the command is scheduled at all. A corrected spec sat next to a
        // binding generated from the broken one, and `xiboca` by hand found 23 classes where the
        // build still had none.
        [Target(useSpec), gendTarget(root)] ~ runtimeSrc.map!(f => Target(f)).array);

    // Compile every .cpp into libshims.a. qtdmoc.cpp additionally needs the Qt private
    // headers. Shims are C++ -> identical for ldc2/dmd, so this target is shared.
    auto shimsLib = buildPath(bdir, "libshims.a");
    // THE QML RUNTIME ONLY WHERE THERE IS QML (critics r13 #3, corrected by r14 #1/#2/#3).
    //
    // A binding without QtQml must not carry the QML runtime. The first answer GENERATED thin stubs
    // from the unit's signatures with a shell script, and the audit was right that it was the wrong
    // shape: inferring a return value from a return TYPE turned `qtd_context_prop_qs` — which always
    // returns `new QString()`, with or without QML — into one that returns nullptr, and the D side
    // dereferences it. A textual parser also cannot promise ABI parity; it only ever promised n > 0.
    //
    // The stub is now the SAME SOURCE compiled in the configuration that defines it. Every function
    // in qtdmoc_qml.cpp already carries its own `#else` body for the no-QML case — those bodies ARE
    // the stubs, written by whoever wrote the function. Compiling the file without QTD_ENABLE_QML
    // yields them, with the exports and the semantics right by construction rather than by a script
    // that has to be right about C++. Only the OBJECT NAME differs, which is what the composition
    // canary reads.
    auto stubObj = hasQml ? "" : "_stub";
    // The build RECORDS its own decision, so the composition canary reads a fact instead of
    // inferring one. The first version of that canary inferred "this binding has QML" from QQml
    // symbols in the archive and failed `webengine`, which references QQmlProperty because its OWN
    // bound API does — nothing to do with our runtime. An inference that has to be right about
    // someone else's API is the wrong shape for a gate.
    // The object directory is WIPED, not patched (critics r14 #3): `rm -f qtdmoc_qml*.o` left every
    // other stale object in the glob, so a .cpp the generator stopped emitting kept its symbols in
    // the archive for ever. The archive is rebuilt from exactly what this run compiled.
    auto shimsCmd = "rm -rf " ~ bdir ~ "/ocpp && mkdir -p " ~ bdir ~ "/ocpp && rm -f " ~ shimsLib
        ~ " && echo " ~ (hasQml ? "yes" : "no") ~ " > " ~ bdir ~ "/qml-enabled && "
        ~ "for c in " ~ genDir ~ "/*.cpp; do "
        ~ `b=$(basename "$c" .cpp); `
        // ...and the QML unit lands under a DIFFERENT name when this binding has no QtQml, compiled
        // from the same source with QTD_ENABLE_QML undefined: its own `#else` bodies are the stubs.
        ~ `if [ "$b" = qtdmoc_qml ]; then b=qtdmoc_qml` ~ stubObj ~ `; fi; `
        ~ `case "$b" in qtdmoc|qtdmoc_qml|qtdmoc_qml_stub) EX="` ~ priv ~ `";; *) EX=;; esac; `
        ~ "clang++ " ~ cxx ~ " $EX -c $c -o " ~ bdir ~ "/ocpp/$b" ~ objExt() ~ " || exit 1; done && "
        ~ arCmd(shimsLib, bdir ~ "/ocpp/*" ~ objExt());
    auto shims = Target(shimsLib,
        guarded(bdir ~ "/shims.lock", shimsCmd,
                psStep("shims.ps1", ["-GenDir", genDir, "-ObjDir", bdir ~ "/ocpp", "-Lib", shimsLib,
                                     "-Cxx", cxx, "-Priv", priv, "-QmlEnabled", hasQml ? "yes" : "no",
                                     "-StubSuffix", stubObj, "-ObjExt", objExt(),
                                     "-QmlFlag", bdir ~ "/qml-enabled"]),
                shimsLib, [stamp]),
        [gen]);

    // REGISTERED, so the composition canary gets its list from the GRAPH instead of a glob over
    // whatever happens to be in .build (critics r14 #4). A canary that walks existing artefacts
    // proves something about the artefacts that exist, which is not the claim it prints.
    _shimsRegistry ~= ShimsEntry(shimsLib, hasQml, shims, mods, qtdExpandLinkMods(mods), qtdQtRelease(mods));
    _genRegistry ~= gen;
    return QtdBinding(gen, shims, root, genDir, bdir, mods, spec);
}

// Per-compiler binding archive: compile every generated .d module to its own object
// (ldc2 needs -oq for fully-qualified object names; dmd names by module), archive them.
// THE RUNTIME SOURCES THE GENERATOR COPIES VERBATIM, in ONE place (critics r13 #1).
//
// They are build INPUTS: edit one and every binding must regenerate, or the matrix goes green
// against code that is no longer in the tree. The common builder had that edge; the libsample
// pipeline is a second, hand-written copy of the same steps and did NOT — so `sample_*` ran against
// a stale `qtdmoc.cpp` and printed ALL PASS. Measured by the audit and reproduced here: the
// libsample copies of qtdmoc.cpp and qtdmoc_qml.cpp hashed differently from the sources while the
// normal path's matched. Two pipelines may stay (they build different things); ONE list may not.
// EVERY GENERATOR THE PROVENANCE GATE MUST RUN AFTER, registered as they are created — never
// inferred from what is on disk (critics r14 #5). The first version of this asked
// `exists(gen.stamp)` at CONFIGURE time and returned nothing on a clean checkout, so the gate did
// not order the libsample generation, ran without the copies, and passed. `exists(output)` deciding
// the SHAPE of the graph is the bug: on the one run where a freshness gate matters most — the first
// — it removes the very edge that makes it mean anything.
__gshared Target[] _genRegistry;
Target[] qtdGenRegistry() { return _genRegistry; }

string[] qtdRuntimeSources(string root) {
    return ["qtmoc/qtdmoc.cpp", "qtmoc/qtdmoc_qml.cpp", "qtmoc/qtmoc.d",
            "holder/qtd_holder.cpp", "holder/holder.d"]
        .map!(f => buildPath(root, "runtime", f)).filter!(f => exists(f)).array;
}

// Every archive the graph builds, with the QML decision that produced it. Registered by
// qtdBinding/libsampleTargets as they are created (critics r14 #4).
// `mods` is the LINK MANIFEST, and it is here because round 15 #3 was right about what the
// product gate was doing: it grepped archives for `QQmlJS*`/`QQmlSA*`, which is the signature of
// ONE incident (the Qt Qml Compiler validator) and not a way to identify a module. Nothing detected
// the other entries at all, and a GPL-only module used through inline or template code leaves no
// undefined symbol to grep for. The graph already knows which pkg-config modules built each
// archive; recording that is the difference between checking a dependency and recognising a name.
// `mods` is what the SPEC asked for; `linkMods` is what the linker actually receives, and `qtRel`
// is the Qt release that produced this artifact. Round 18 #1 and #2 measured why the first is not
// enough: `Qt6WebEngineCore` is one name on the compile line and NINE libraries on the link line —
// `pkg-config --libs` adds Quick, OpenGL, Gui, WebChannel, Qml, Network, Positioning and Core — and
// two of those (Qt6WebChannel, Qt6Positioning) are in no matrix row, so a module that arrived by
// ordinary dependency resolution was invisible to a gate whose whole premise is "unknown is
// refused". And the release matters per artifact, not per run: this machine builds Qt5 archives with
// 5.15.19 while the matrix records 5.15.17, and the gate certified them after verifying only the
// Qt6 release it happened to query first.
struct ShimsEntry { string archive; bool hasQml; Target target; string[] mods; string[] linkMods; string qtRel; }

// The Qt* libraries a link against `mods` really pulls in, deduplicated. Asked of pkg-config rather
// than derived from the names, because transitive dependencies are exactly what a name does not say.
string[] qtdExpandLinkMods(string[] mods) {
    bool[string] seen;
    foreach (m; mods) {
        seen[m] = true;
        try {
            auto r = execute(["pkg-config", "--libs"] ~ mods);
            if (r.status != 0) continue;
            foreach (tok; r.output.split) {
                if (!tok.startsWith("-l")) continue;
                auto lib = tok[2 .. $];
                if (lib.startsWith("Qt")) seen[lib] = true;
            }
        } catch (Exception) { /* pkg-config absent: the spec list is all we can record */ }
    }
    return seen.keys.sort.array;
}

// ...and the release, per family, so a manifest line says which Qt produced that artifact.
string qtdQtRelease(string[] mods) {
    auto fam = mods.any!(m => m.startsWith("Qt5")) ? "Qt5Core" : "Qt6Core";
    try {
        auto v = qtModVersion(fam);
        if (v.length) return v;
    } catch (Exception) { }
    return "";
}
__gshared ShimsEntry[] _shimsRegistry;
ShimsEntry[] qtdShimsRegistry() { return _shimsRegistry; }

private __gshared Target[string] _libCache;
Target qtdBindLib(QtdBinding b, string dc) {
    auto key = b.bdir ~ "|" ~ dc;
    if (auto t = key in _libCache) return *t;
    auto oq = dc == "ldc2" ? "-oq " : "";
    auto od = b.bdir ~ "/od_" ~ dc;
    auto lib = buildPath(b.bdir, "libbinding_" ~ dc ~ ".a");
    auto stamp = buildPath(b.bdir, "gen.stamp");
    // NB: double-quoted "*.d" (the command is embedded in sh -c '…' by guarded()).
    auto cmd = "rm -rf " ~ od ~ " && mkdir -p " ~ od ~ " && cd " ~ b.genDir ~ " && "
        ~ dc ~ ` -c ` ~ oq ~ "-od=" ~ od ~ ` -I. $(find . -name "*.d") && `
        ~ arCmd(lib, od ~ "/*" ~ objExt());
    auto t = Target(lib,
        guarded(b.bdir ~ "/bind_" ~ dc ~ ".lock", cmd,
                psStep("dlib.ps1", ["-GenDir", b.genDir, "-ObjDir", od, "-Lib", lib, "-Dc", dc,
                                    "-ObjExt", objExt()], oq.length ? ["-Oq"] : []),
                lib, [stamp]),
        [b.gen]);
    _libCache[key] = t;
    return t;
}

// Link an app: <dc> app.d -I<genDir> --start-group libbinding libshims --end-group <libs>.
// The archives go in a group so cross-references between binding and shims resolve.
// `extra` is appended to the compile line (additional source modules / flags, e.g. a
// CTFE helper module + its `-I` and a `-J=` string-import path). Use `-J=path` (not
// `-J path`): dmd requires the `=` form, ldc2 accepts it too.
// Everything `extra` actually feeds the compiler: the .d sources listed on the command line and
// the files reachable through each -J=<dir> string-import root. These are real inputs, and
// leaving them out meant editing runtime/qrc/qrc.d, runtime/uic/uiform.d or any string-imported
// .ui/.qrc/.qml left the previous binary in place — the test then re-reported a stale verdict as
// if it were fresh. Measured: after reverting a deliberate one-byte bug in qrc.d, the ldc2 qrc
// test still ran the buggy binary and still failed.
private Target[] extraInputs(string extra) {
    Target[] ts;
    foreach (tok; extra.split(" ")) {
        if (tok.endsWith(".d") && exists(tok)) { ts ~= Target(tok); continue; }
        if (!tok.startsWith("-J")) continue;
        auto dir = tok[2 .. $];
        if (dir.startsWith("=")) dir = dir[1 .. $];
        if (!exists(dir) || !isDir(dir)) continue;
        foreach (e; dirEntries(dir, SpanMode.depth))
            if (e.isFile) ts ~= Target(e.name);
    }
    return ts;
}

Target qtdApp(string binName, string appMain, QtdBinding b, string dc, string extra = "",
              Target[] extraDeps = []) {
    auto lib = qtdBindLib(b, dc);
    auto libPath = buildPath(b.bdir, "libbinding_" ~ dc ~ ".a");
    auto shimsPath = buildPath(b.bdir, "libshims.a");
    // --gc-sections drops every unreferenced function/section (unused guards + unused binding
    // code -> the à-la-carte binary). --as-needed drops DT_NEEDED for a Qt .so the app never
    // touches (a QtCore-only program stops requiring Widgets/Gui just by being linked here).
    auto link = dc ~ " -of=$out" ~ dSupport(b.root) ~ " " ~ appMain ~ (extra.length ? " " ~ extra : "") ~ " -I" ~ b.genDir
        ~ " -L--gc-sections -L--as-needed -L--start-group -L=" ~ libPath ~ " -L=" ~ shimsPath
        ~ " -L--end-group " ~ pkgLibs(b.mods);
    // extraDeps carries inputs the STRING cannot: an object file another target produces has to
    // be a Target, not a path — as a path it links fine and is never built, which is the shape of
    // build node that goes green against a stale artifact.
    return Target(binName, link, [Target(appMain), lib, b.shims] ~ extraInputs(extra) ~ extraDeps);
}

// A test target: build the app, then run it headless. Building the phony runs the test.
// `$in` is the app binary's real path (wherever reggae placed the dependency's output).
Target qtdTest(string name, string appMain, QtdBinding b, string dc, string extra = "",
               Target[] extraDeps = []) {
    auto app = qtdApp(name ~ "-bin", appMain, b, dc, extra, extraDeps);
    return Target.phony(name, runOffscreen(b.root, "$in", "", b.mods), [app]);
}

// The shiboken libsample corner-case harness, ported to reggae. Needs a pyside-setup clone
// for the sample C++ library. Builds libsample.a, generates the "sample" cxx binding, and
// links+runs every cases/*.d + cornercases.d on ldc2 AND dmd. Returns [] if the clone is
// absent. Like the Qt bindings it links the whole binding archive (no closure BFS): the
// linker pulls only what each case references. The all-headers umbrella is written here at
// configure time (cleaner than the old shell sed pipeline).
Target[] libsampleTargets(string root, string pyside) {
    import std.file : mkdirRecurse;
    auto LS = buildPath(pyside, "sources", "shiboken6", "tests", "libsample");
    auto MIN = buildPath(pyside, "sources", "shiboken6", "tests", "libminimal");
    if (!exists(LS)) return [];
    auto here = buildPath(root, "tests", "libsample");
    auto bdir = buildPath(root, ".build", "libsample");
    auto build = buildPath(bdir, "src");    // libsample sources + libsample.a
    auto gen = buildPath(bdir, "gen");       // generated "sample" binding
    auto specPath = buildPath(bdir, "spec.json");
    mkdirRecurse(bdir);

    // all-headers umbrella (libsamplemacros first, then every sample header).
    auto hdrs = dirEntries(LS, "*.h", SpanMode.shallow).map!(e => baseName(e.name))
        .filter!(h => h != "libminimalmacros.h" && h != "libsamplemacros.h").array;
    hdrs.sort();
    writeIfChanged(buildPath(bdir, "sample_all.h"),
        `#include "libsamplemacros.h"` ~ "\n" ~ hdrs.map!(h => `#include "` ~ h ~ `"`).join("\n") ~ "\n");
    // discovery-mode spec (paths known at configure time).
    writeIfChanged(specPath,
        `{ "qt_version": "0", "pkg_config": "Qt6Core", "out_dir": "` ~ gen ~ `",`
        ~ ` "d_package": "sample", "abi": "cxx", "source_filter": "` ~ build ~ `",`
        ~ ` "include_paths": ["` ~ build ~ `"], "headers": ["` ~ buildPath(build, "sample_all.h") ~ `"] }`);

    auto cflags = pkgCflags(["Qt6Core"]);
    auto cxx = cflags ~ " -std=c++17 " ~ cxxPic() ~ " -O2";
    auto priv = mocPrivateFlags(cflags).join(" ");
    auto xiboca = gendPath(root);

    // 1) libsample.a from the external sources (+ the umbrella copied in for xiboca).
    auto lsa = buildPath(build, "libsample.a");
    auto lsaCmd = "rm -rf " ~ build ~ " && mkdir -p " ~ build ~ " && cp " ~ LS ~ "/*.h " ~ LS ~ "/*.cpp "
        ~ MIN ~ "/libminimalmacros.h " ~ buildPath(bdir, "sample_all.h") ~ " " ~ build ~ "/ && cd " ~ build
        ~ " && sed -i 's#../libminimal/libminimalmacros.h#libminimalmacros.h#' libsamplemacros.h"
        ~ ` && for c in *.cpp; do [ "$c" = main.cpp ] || clang++ -std=c++17 ` ~ cxxPic() ~ ` -DLIBSAMPLE_BUILD -I. -c "$c" -o "${c%.cpp}.o" 2>/dev/null; done`
        ~ " && " ~ arCmd("libsample.a", "*" ~ objExt());
    // freshness vs the umbrella (written at configure time): without it a second concurrent
    // scheduling would `rm -rf build` mid-link (empty newerThan == never skip).
    auto sampleLib = Target(lsa, guarded(bdir ~ "/lsa.lock", lsaCmd, null, lsa, [buildPath(bdir, "sample_all.h")]), []);

    // 2) generate the "sample" binding.
    auto stamp = buildPath(bdir, "gen.stamp");
    auto genCmd = "rm -f " ~ stamp ~ " && rm -rf " ~ gen ~ " && " ~ xiboca ~ " " ~ specPath
                ~ " >/dev/null 2>&1 && touch " ~ stamp;
    // ...with the runtime sources as inputs, exactly as the common builder has them (critics r13
    // #1): without this edge, editing the runtime leaves libsample testing the copy from before.
    auto lsRuntime = qtdRuntimeSources(root);
    auto genT = Target(stamp,
        guarded(bdir ~ "/gen.lock", genCmd, null, stamp, [lsa, xiboca] ~ lsRuntime),
        [sampleLib, gendTarget(root)] ~ lsRuntime.map!(f => Target(f)).array);

    // 3) shims (.cpp) -> libshims.a.
    auto shimsLib = buildPath(bdir, "libshims.a");
    // Same rule as the common builder (critics r13 #2/#3, r14 #1/#3): libsample has no QtQml, so
    // the QML unit is compiled from the SAME source with QTD_ENABLE_QML undefined and lands as
    // qtdmoc_qml_stub.o — its own `#else` bodies are the stubs. And ocpp is wiped, so an object the
    // generator stopped emitting cannot survive in the archive.
    auto shimsCmd = "rm -rf " ~ bdir ~ "/ocpp && mkdir -p " ~ bdir ~ "/ocpp && rm -f " ~ shimsLib
        ~ " && echo no > " ~ bdir ~ "/qml-enabled && for c in " ~ gen ~ "/*.cpp; do "
        ~ `b=$(basename "$c" .cpp); if [ "$b" = qtdmoc_qml ]; then b=qtdmoc_qml_stub; fi; `
        ~ `case "$b" in qtdmoc|qtdmoc_qml_stub) EX="` ~ priv ~ `";; *) EX=;; esac; `
        ~ "clang++ " ~ cxx ~ " $EX -c $c -o " ~ bdir ~ "/ocpp/$b" ~ objExt() ~ " || exit 1; done && "
        ~ arCmd(shimsLib, bdir ~ "/ocpp/*" ~ objExt());
    auto shimsT = Target(shimsLib, guarded(bdir ~ "/shims.lock", shimsCmd, null, shimsLib, [stamp]), [genT]);
    _shimsRegistry ~= ShimsEntry(shimsLib, false, shimsT, ["Qt6Core"], qtdExpandLinkMods(["Qt6Core"]), qtdQtRelease(["Qt6Core"]));   // libsample: no QtQml, QtCore only
    _genRegistry ~= genT;

    Target[] outs;
    foreach (dc; ["ldc2", "dmd"]) {
        auto oq = dc == "ldc2" ? "-oq " : "";
        auto od = bdir ~ "/od_" ~ dc;
        auto lib = buildPath(bdir, "libbinding_" ~ dc ~ ".a");
        auto libCmd = "rm -rf " ~ od ~ " && mkdir -p " ~ od ~ " && cd " ~ gen ~ " && "
            ~ dc ~ " -c " ~ oq ~ "-od=" ~ od ~ ` -I. $(find . -name "*.d") && `
            ~ arCmd(lib, od ~ "/*" ~ objExt());
        auto libT = Target(lib, guarded(bdir ~ "/bind_" ~ dc ~ ".lock", libCmd, null, lib, [stamp]), [genT]);
        // libsample.a + the shim archives have mutual refs -> a static --start/--end-group.
        auto grp = "-L--start-group -L=" ~ lib ~ " -L=" ~ shimsLib ~ " -L=" ~ lsa
            ~ " -L--end-group" ~ (cxxRuntimeLibs().length ? " -L-lstdc++" : "");
        auto cases = dirEntries(buildPath(here, "cases"), "*.d", SpanMode.shallow).map!(e => e.name).array
            ~ buildPath(here, "cornercases.d");
        cases.sort();
        foreach (c; cases) {
            auto n = "sample_" ~ baseName(c).stripExtension ~ "-" ~ dc;
            // sampleLib is NOT listed here: libT and shimsT already reach it through genT, and
            // naming it again adds one edge PER TEST APP. The binary backend materialises a
            // dependency once per EDGE, so 58 apps x 2 compilers announced libsample.a 116 times —
            // each a no-op behind its flock, and each still a process. The link line keeps the
            // archive (grp), which is what the mutual refs actually need; the dependency is the
            // transitive one. (critics r7 #8 / r8 #9)
            auto app = Target(n ~ "-bin", dc ~ " -of=$out" ~ dSupport(root) ~ " " ~ c ~ " -I" ~ gen ~ " " ~ grp,
                [Target(c), libT, shimsT]);
            outs ~= Target.phony(n, runOffscreen(root, "$in", "", ["Qt6Core"]), [app]);
        }
    }
    return outs;
}
