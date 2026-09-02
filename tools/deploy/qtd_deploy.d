// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
//
// WHAT AN INSTALLER HAS TO CARRY, and where each piece came from.
//
// A Qt application does not tell you what it needs. Half of it is in the binary — the shared
// libraries, which `qtd-deploy` reads out of PT_DYNAMIC or the PE import table — and the other half
// is invisible there, because plugins are opened by NAME at run time: nothing links libqxcb.so, and
// an application without it dies with `no Qt platform plugin could be initialized`. That half is
// not guessed here either. Qt installs a machine-readable description of which plugins belong to
// which module (`lib/cmake/Qt6Gui/Qt6QXcbIntegrationPluginTargets-*.cmake`, and the Qt5 spelling of
// the same thing), so the answer is READ from the Qt in front of us, for the modules the binary
// actually links. A table written here would be a table about the Qt I happened to look at.
//
// THE GEOMETRY IS MEASURED TOO, and that is what removes the need to patch anything. Qt's own
// libraries carry `RUNPATH=$ORIGIN` and its plugins carry `RUNPATH=$ORIGIN/../../../`: they already
// know how to find each other, but only if the distance between them is preserved. So `bundle`
// mirrors the prefix's relative shape — `lib/` and `lib/qt6/plugins/` on a distro that spells it
// that way, `lib/` and `plugins/` on one that does not — instead of imposing a layout and then
// rewriting every RUNPATH to make the new layout work. `qmake -query` is asked where things are;
// nothing in this file assumes an answer.
//
// What is left over is the application's own executable, which has no reason to know where its
// libraries went. That one is reported rather than silently patched: growing a RUNPATH in place is
// only possible when the new string fits in the old one, and a tool that quietly does nothing when
// it does not fit would produce a bundle that works on the build machine and nowhere else.
module qtd_deploy;

import std.algorithm;
import std.array;
import std.conv : to;
import std.file;
import std.path;
import std.process : execute, environment;
import std.stdio;
import std.string;

import binfmt;

// --- what we found -----------------------------------------------------------------------------
enum Class { qt, thirdParty, system, missing }

struct Item {
    string kind;    /// lib | plugin | qml | exe
    string name;    /// soname / plugin relative path / module name
    string source;  /// absolute path on this machine, or "" when missing
    Class cls;
    string note;    /// who asked for it
}

struct Qt {
    string prefix, libs, plugins, qml, bins;
    int major;
    bool ok;
}

__gshared Item[] g_items;
__gshared bool[string] g_seenLib;

void add(string kind, string name, string source, Class cls, string note) {
    g_items ~= Item(kind, name, source, cls, note);
}

// --- Qt, as this machine has it ----------------------------------------------------------------
string qmakeQuery(string exe, string var) {
    try {
        auto r = execute([exe, "-query", var]);
        if (r.status == 0) return r.output.strip;
    } catch (Exception) { }
    return "";
}

Qt findQt(string forced) {
    Qt q;
    // The caller's word beats the search, because cross-mapping a Windows tree from Linux is a
    // thing this tool is meant to do and there is no qmake in that tree to ask.
    if (forced.length) {
        q.prefix = forced;
        foreach (cand; ["lib", "lib64"]) if (exists(buildPath(forced, cand))) { q.libs = buildPath(forced, cand); break; }
        if (!q.libs.length) q.libs = buildPath(forced, "lib");
        foreach (cand; [buildPath(q.libs, "qt6", "plugins"), buildPath(forced, "plugins"),
                        buildPath(q.libs, "qt5", "plugins")])
            if (exists(cand)) { q.plugins = cand; break; }
        foreach (cand; [buildPath(q.libs, "qt6", "qml"), buildPath(forced, "qml"),
                        buildPath(q.libs, "qt5", "qml")])
            if (exists(cand)) { q.qml = cand; break; }
        q.bins = buildPath(forced, "bin");
        q.major = q.plugins.canFind("qt5") ? 5 : 6;
        q.ok = q.libs.length > 0;
        return q;
    }
    foreach (exe; ["qmake6", "qmake-qt6", "qmake", "qmake-qt5"]) {
        auto p = qmakeQuery(exe, "QT_INSTALL_PREFIX");
        if (!p.length) continue;
        q.prefix  = p;
        q.libs    = qmakeQuery(exe, "QT_INSTALL_LIBS");
        q.plugins = qmakeQuery(exe, "QT_INSTALL_PLUGINS");
        q.qml     = qmakeQuery(exe, "QT_INSTALL_QML");
        q.bins    = qmakeQuery(exe, "QT_INSTALL_BINS");
        q.major   = qmakeQuery(exe, "QT_VERSION").startsWith("5") ? 5 : 6;
        q.ok      = q.libs.length > 0;
        return q;
    }
    return q;
}

// --- the deployment policy ---------------------------------------------------------------------
__gshared string[] g_systemPrefixes;

void loadPolicy(string file) {
    if (!exists(file)) {
        stderr.writeln("qtd-deploy: no policy file at ", file,
                       "\n    the list of libraries a bundle must not carry is not something to",
                       "\n    default to empty: without it every bundle would ship a private libc.");
        throw new Exception("missing policy file");
    }
    foreach (l; readText(file).lineSplitter) {
        auto s = l.strip;
        if (!s.length || s.startsWith("#")) continue;
        g_systemPrefixes ~= s;
    }
}

/// A soname belongs to the machine when it starts with a policy entry followed by `.` or `-`.
/// Prefix-matching on the bare name is what lets one entry cover `libc.so.6` and `libc-2.38.so`
/// without also covering `libcurl`.
bool isSystemLib(string soname) {
    auto n = baseName(soname);
    foreach (p; g_systemPrefixes) {
        if (!n.startsWith(p)) continue;
        if (n.length == p.length) return true;
        auto c = n[p.length];
        if (c == '.' || c == '-' || c == '_') return true;
    }
    return false;
}

// --- resolving a NEEDED name -------------------------------------------------------------------
__gshared string[] g_searchDirs;   /// --search, then the system's own configured directories

string[] defaultSearchDirs() {
    string[] dirs;
    void readConf(string f) {
        if (!exists(f)) return;
        foreach (l; readText(f).lineSplitter) {
            auto s = l.strip;
            if (!s.length || s.startsWith("#")) continue;
            if (s.startsWith("include ")) {
                auto pat = s["include ".length .. $].strip;
                // The glob is relative to /etc when it has no root.
                if (!isAbsolute(pat)) pat = buildPath("/etc", pat);
                try foreach (e; dirEntries(dirName(pat), baseName(pat), SpanMode.shallow)) readConf(e.name);
                catch (Exception) { }
            } else if (isAbsolute(s)) dirs ~= s;
        }
    }
    readConf("/etc/ld.so.conf");
    foreach (d; ["/lib64", "/usr/lib64", "/lib", "/usr/lib"]) if (exists(d) && !dirs.canFind(d)) dirs ~= d;
    return dirs;
}

string expandOrigin(string p, string referrerDir) {
    return p.replace("${ORIGIN}", referrerDir).replace("$ORIGIN", referrerDir)
            .replace("${LIB}", "lib").replace("$LIB", "lib");
}

/// Where the loader would find `name` when `referrer` asks for it. RUNPATH first, exactly as the
/// loader does it, so a bundle-shaped tree resolves the way it will at run time.
///
/// A CANDIDATE HAS TO BE THE RIGHT ARCHITECTURE, and being first in the search path does not make
/// it so. Measured on this machine: `/etc/ld.so.conf` lists `/usr/lib32` and the by-name answer for
/// `libfreetype.so.6` was the 32-bit file, for a 64-bit application — a bundle that copies that is
/// broken in a way nothing reports until the user runs it.
string resolveNeeded(string name, string referrer, const(string)[] runpath, ubyte klass, ushort machine) {
    bool fits(string p) {
        if (!exists(p) || !isFile(p)) return false;
        auto i = readBinary(p);
        return i.ok && i.klass == klass && (machine == 0 || i.machine == machine);
    }
    if (name.canFind('/') && fits(name)) return name;
    auto dir = dirName(absolutePath(referrer));
    foreach (rp; runpath) {
        auto cand = buildPath(expandOrigin(rp, dir), name);
        if (fits(cand)) return buildNormalizedPath(cand);
    }
    foreach (d; g_searchDirs) {
        auto cand = buildPath(d, name);
        if (fits(cand)) return buildNormalizedPath(cand);
    }
    return "";
}

// --- the closure -------------------------------------------------------------------------------
__gshared string[] g_qtModules;   /// "Gui", "Widgets", ... as found in the closure

void noteQtModule(string soname) {
    // libQt6Gui.so.6 -> Gui ; Qt6Gui.dll -> Gui ; libQt5Gui.so.5 -> Gui
    auto n = baseName(soname);
    if (n.startsWith("lib")) n = n[3 .. $];
    if (!n.startsWith("Qt")) return;
    auto rest = n[2 .. $];
    if (!rest.length) return;
    if (rest[0] >= '0' && rest[0] <= '9') rest = rest[1 .. $];
    auto cut = rest.indexOfAny(".");
    if (cut >= 0) rest = rest[0 .. cut];
    if (rest.length && !g_qtModules.canFind(rest)) g_qtModules ~= rest;
}

/// Qt or not, decided by WHAT THE FILE IS rather than by where the path happens to start.
/// The first spelling of this compared against the prefix and against the library directory, and
/// got both answers wrong on an ordinary distribution: `/lib64` is a symbolic link to `/usr/lib`,
/// so every Qt library came back "third-party", while `/usr/lib` is a string prefix of
/// `/usr/lib32`, so every 32-bit stray came back "qt". The distinction is not cosmetic — the
/// manifest doubles as the licence inventory that docs/distributing-qt.md asks for, and it has to
/// name which files are Qt's.
Class classify(string soname, string path, Qt q) {
    auto n = baseName(soname);
    if (n.startsWith("lib")) n = n[3 .. $];
    if (n.startsWith("Qt")) return Class.qt;
    // ...and anything that came out of Qt's own plugin or QML tree, whatever it is called. Compared
    // with the links resolved, since /lib64 and /usr/lib are the same directory here.
    foreach (root; [q.plugins, q.qml])
        if (root.length && sameTree(path, root)) return Class.qt;
    return Class.thirdParty;
}

/// `path` is inside `root`, with the boundary respected and symbolic links resolved on both sides.
bool sameTree(string path, string root) {
    string r(string p) {
        version (Posix) {
            import core.sys.posix.stdlib : realpath;
            import core.stdc.stdlib : free;
            import std.string : toStringz, fromStringz;
            auto c = realpath(p.toStringz, null);
            if (c is null) return buildNormalizedPath(absolutePath(p));
            scope (exit) free(c);
            return cast(string) c.fromStringz.idup;
        } else return buildNormalizedPath(absolutePath(p));
    }
    auto a = r(path), b = r(root);
    return a.length > b.length && a.startsWith(b) && a[b.length] == dirSeparator[0];
}

void walk(string path, Qt q, string askedBy) {
    auto key = baseName(path);
    if (key in g_seenLib) return;
    g_seenLib[key] = true;

    auto info = readBinary(path);
    if (!info.ok) {
        add("lib", key, path, Class.missing, "unreadable: " ~ info.why);
        return;
    }
    if (askedBy.length) {
        add("lib", key, path, classify(key, path, q), "needed by " ~ askedBy);
        noteQtModule(key);
    }
    foreach (n; info.needed) {
        if (baseName(n) in g_seenLib) continue;
        if (isSystemLib(n)) {
            g_seenLib[baseName(n)] = true;
            add("lib", baseName(n), "", Class.system, "excluded by policy, asked by " ~ key);
            continue;
        }
        auto r = resolveNeeded(n, path, info.runpath, info.klass, info.machine);
        if (!r.length) {
            g_seenLib[baseName(n)] = true;
            add("lib", baseName(n), "", Class.missing, "not found, asked by " ~ key);
            continue;
        }
        walk(r, q, key);
    }
}

// --- plugins, read out of Qt's own description ---------------------------------------------------
/// Qt6: `Qt6<Anything>PluginTargets-<config>.cmake` under `cmake/Qt6<Module>/`, each naming its
/// file with an absolute `IMPORTED_LOCATION_* "${_IMPORT_PREFIX}/..."`.
/// Qt5: `Qt5<Module>_<Name>Plugin.cmake`, naming a path RELATIVE to the plugins directory.
/// Categories a desktop installer has no use for, by the directory Qt files the plugin under.
/// `--plugins all` turns this off and `--plugins <a,b>` replaces it with an allow-list.
///
/// A FALSE POSITIVE COSTS MEGABYTES AND A FALSE NEGATIVE COSTS A CRASH, so the default errs
/// inclusive: everything Qt associates with a linked module ships, minus the families that only
/// exist for embedded boot paths this application cannot be taking (it links a desktop windowing
/// stack, or it would not have got as far as needing a bundle).
__gshared string[] g_dropCategories = ["egldeviceintegrations", "kms", "linuxfb", "vc4"];
__gshared string[] g_keepCategories;   /// non-empty = allow-list from --plugins

__gshared bool[string] g_seenPlugin;

bool wantPlugin(string rel) {
    if (rel in g_seenPlugin) return false;   // asked again on a later pass; it is already recorded
    g_seenPlugin[rel] = true;
    auto cat = rel.canFind(dirSeparator) ? rel[0 .. rel.indexOf(dirSeparator)] : "";
    if (g_keepCategories.length) return g_keepCategories.canFind(cat);
    return !g_dropCategories.canFind(cat);
}

void collectPlugins(Qt q) {
    foreach (mod; g_qtModules) {
        auto dir6 = buildPath(q.libs, "cmake", "Qt6" ~ mod);
        auto dir5 = buildPath(q.libs, "cmake", "Qt5" ~ mod);
        if (q.major >= 6 && exists(dir6)) {
            foreach (e; dirEntries(dir6, "*.cmake", SpanMode.shallow)) {
                if (!baseName(e.name).canFind("Plugin")) continue;
                foreach (l; readText(e.name).lineSplitter) {
                    auto s = l.strip;
                    if (!s.startsWith("IMPORTED_LOCATION")) continue;
                    auto a = s.indexOf('"'); if (a < 0) continue;
                    auto b = s.lastIndexOf('"'); if (b <= a) continue;
                    auto p = s[a + 1 .. b].replace("${_IMPORT_PREFIX}", q.prefix);
                    if (!exists(p)) continue;
                    auto rel = relativePath(buildNormalizedPath(p), q.plugins);
                    if (!wantPlugin(rel)) continue;
                    add("plugin", rel, p, Class.qt, "Qt6" ~ mod);
                }
            }
        } else if (exists(dir5)) {
            foreach (e; dirEntries(dir5, "*Plugin.cmake", SpanMode.shallow)) {
                foreach (l; readText(e.name).lineSplitter) {
                    auto s = l.strip;
                    if (!s.canFind("_plugin_properties(")) continue;
                    auto a = s.indexOf('"'); if (a < 0) continue;
                    auto b = s.indexOf('"', a + 1); if (b <= a) continue;
                    auto rel = s[a + 1 .. b];
                    auto p = buildPath(q.plugins, rel);
                    if (!exists(p) || !wantPlugin(rel)) continue;
                    add("plugin", rel, p, Class.qt, "Qt5" ~ mod);
                }
            }
        }
    }
}

// --- QML modules, read out of the application's own sources ---------------------------------------
/// Styles a `qmldir` marks `optional import`. Qt Quick Controls ships five beside the default, an
/// application uses exactly one, and shipping all six looks like waste — which is why the first
/// version of this shipped only the one the qmldir calls `default import`.
///
/// THAT WAS WRONG, AND THE FILE THAT SAYS `default` IS NOT WHO DECIDES. The style is resolved at
/// run time by QQuickStyle, from QT_QUICK_CONTROLS_STYLE or from a `qtquickcontrols2.conf` compiled
/// into the plugin as a Qt resource — neither of which is readable from the module directory. On
/// the machine this was measured on, `QtQuick/Controls/qmldir` says `default import
/// QtQuick.Controls.Basic auto` and the style actually loaded is **Fusion**; a bundle carrying the
/// qmldir's answer produced a program that started, loaded no root object, and printed nothing.
///
/// So every declared style ships by default and `--qml-style` NARROWS it, which is the same
/// direction the plugin policy runs in: a false positive costs megabytes, a false negative costs a
/// window that never appears. The five styles are about 7 MB against a bundle of 150.
__gshared string[] g_extraStyles;   /// --qml-style: when non-empty, the ONLY optional styles kept

void collectQml(Qt q, string[] qmlDirs) {
    if (!qmlDirs.length || !q.qml.length) return;
    bool[string] want;

    // AN IMPORT INSIDE QT'S OWN QML IS STILL AN IMPORT. `QtQuick.Controls.impl` appears in no
    // qmldir at all — the Basic style's .qml files import it — and `QtQuick.Templates` arrives the
    // same way. Scanning only the application's sources found seven modules for a Controls program
    // and left it unable to instantiate a Button.
    void scanFile(string f) {
        string text;
        try text = readText(f);
        catch (Exception) return;   // a .qml that is not valid UTF-8 is not ours to complain about
        foreach (l; text.lineSplitter) {
            auto s2 = l.strip;
            if (!s2.startsWith("import ")) continue;
            auto rest = s2["import ".length .. $].strip;
            // `import QtQuick 2.15`, `import QtQuick.Controls as C` — a dotted identifier is a
            // module; `import "./local"` is a directory inside the application itself.
            if (rest.startsWith("\"")) continue;
            auto name = rest.splitter(' ').front.strip;
            if (name.length) want[name] = true;
        }
    }
    void scanTree(string d) {
        if (isFile(d)) { scanFile(d); return; }
        try foreach (e; dirEntries(d, "*.qml", SpanMode.shallow)) scanFile(e.name);
        catch (Exception) { }
    }

    foreach (d; qmlDirs) {
        if (isFile(d)) { scanFile(d); continue; }
        foreach (e; dirEntries(d, "*.qml", SpanMode.depth)) scanFile(e.name);
    }

    bool[string] done;
    while (true) {
        string next;
        foreach (k, _; want) if (k !in done) { next = k; break; }
        if (!next.length) break;
        done[next] = true;
        auto dir = buildPath(q.qml, next.replace(".", dirSeparator));
        if (!exists(dir)) { add("qml", next, "", Class.missing, "no such module under " ~ q.qml); continue; }
        add("qml", next, dir, Class.qt, "imported");

        // ...and what the module itself says it needs. The directive forms are `depends X [auto]`,
        // `import X [auto]`, `optional import X auto` and `default import X auto`; reading only the
        // first two missed every Qt Quick Controls style, including the default one, because the
        // word that begins those lines is `default`.
        auto qmldir = buildPath(dir, "qmldir");
        if (exists(qmldir))
            foreach (l; readText(qmldir).lineSplitter) {
                auto parts = l.strip.splitter(' ').filter!(a => a.length).array;
                if (parts.length < 2) continue;
                string mod; bool optional;
                if (parts[0] == "depends" || parts[0] == "import") mod = parts[1];
                else if (parts.length >= 3 && parts[1] == "import") {
                    mod = parts[2];
                    optional = parts[0] == "optional";
                    if (parts[0] != "optional" && parts[0] != "default") continue;
                }
                if (!mod.length || mod == "auto") continue;
                if (optional && g_extraStyles.length
                        && !g_extraStyles.any!(sName => mod == sName || mod.endsWith("." ~ sName)))
                    continue;
                want[mod] = true;
            }

        // ...and the imports written inside the module's own QML, which is where the pieces that
        // no qmldir mentions live.
        scanTree(dir);
    }
}

/// Walk the dependencies of everything that is loaded rather than linked. Iterates over a snapshot
/// because `walk` appends to the same list.
void closeOverLoadables(Qt q) {
    for (size_t pass = 0; pass < 8; ++pass) {
        auto before = g_items.length;
        auto snapshot = g_items.dup;
        foreach (i; snapshot) {
            if (i.source.length == 0) continue;
            if (i.kind == "plugin") {
                auto info = readBinary(i.source);
                if (!info.ok) continue;
                foreach (n; info.needed) followOne(n, i.source, info, q, baseName(i.name));
            } else if (i.kind == "qml") {
                foreach (e; dirEntries(i.source, SpanMode.shallow)) {
                    if (!e.isFile) continue;
                    auto info = readBinary(e.name);
                    if (!info.ok || info.soname.length == 0 && !e.name.endsWith(".so") && !e.name.endsWith(".dll")) continue;
                    foreach (n; info.needed) followOne(n, e.name, info, q, i.name);
                }
            }
        }
        if (g_items.length == before) break;
    }
}

void followOne(string n, string referrer, BinInfo info, Qt q, string who) {
    if (baseName(n) in g_seenLib) return;
    if (isSystemLib(n)) {
        g_seenLib[baseName(n)] = true;
        add("lib", baseName(n), "", Class.system, "excluded by policy, asked by " ~ who);
        return;
    }
    auto r = resolveNeeded(n, referrer, info.runpath, info.klass, info.machine);
    if (!r.length) {
        g_seenLib[baseName(n)] = true;
        add("lib", baseName(n), "", Class.missing, "not found, asked by " ~ who);
        return;
    }
    walk(r, q, who);
}

// --- output ---------------------------------------------------------------------------------------
string clsName(Class c) {
    final switch (c) {
        case Class.qt: return "qt";
        case Class.thirdParty: return "third-party";
        case Class.system: return "system";
        case Class.missing: return "missing";
    }
}

void printTsv() {
    writeln("kind\tname\tsource\tclass\tnote");
    foreach (i; g_items) writeln(i.kind, "\t", i.name, "\t", i.source.length ? i.source : "-",
                                 "\t", clsName(i.cls), "\t", i.note);
}

void printJson() {
    string esc(string s) { return s.replace("\\", "\\\\").replace("\"", "\\\""); }
    writeln("[");
    foreach (n, i; g_items)
        writeln("  {\"kind\":\"", esc(i.kind), "\",\"name\":\"", esc(i.name), "\",\"source\":\"",
                esc(i.source), "\",\"class\":\"", clsName(i.cls), "\",\"note\":\"", esc(i.note), "\"}",
                n + 1 < g_items.length ? "," : "");
    writeln("]");
}

// --- bundling -------------------------------------------------------------------------------------
void copyInto(string src, string dst) {
    mkdirRecurse(dirName(dst));
    copy(src, dst);
    // The executable bit is not carried by std.file.copy, and a plugin that is not readable-
    // executable is a plugin the loader declines without saying why.
    version (Posix) {
        import core.sys.posix.sys.stat : chmod, stat_t, stat;
        stat_t st;
        if (stat(src.toStringz, &st) == 0) chmod(dst.toStringz, st.st_mode);
    }
}

/// Copy a QML module's own files, and STOP at any subdirectory that is a module in its own right.
///
/// A plain recursive copy of `QtQuick/Controls` carries Basic, Fusion, Imagine, Material,
/// Universal and FluentWinUI3 with it — every style, including the five the manifest deliberately
/// left out. The bundle was then larger than the manifest described, which is worse than being
/// large: the manifest is also the notice inventory docs/distributing-qt.md asks for, and one that
/// does not list what shipped is not an inventory. A submodule that IS wanted has its own row and
/// is copied by that row.
void copyDir(string src, string dstRoot, string rel) {
    foreach (e; dirEntries(src, SpanMode.breadth)) {
        if (e.isDir) continue;
        auto sub = relativePath(e.name, src);
        auto d = dirName(sub);
        if (d != "." && exists(buildPath(src, d, "qmldir"))) continue;   // its own module
        copyInto(e.name, buildPath(dstRoot, rel, sub));
    }
}

int bundle(string exePath, Qt q, string outDir) {
    // THE LAYOUT FOLLOWS THE FORMAT, not the machine running this: a PE tree can be mapped from
    // Linux, and it would be laid out wrong if the choice came from `version (Windows)`.
    //
    // ELF: mirror the prefix. The RUNPATHs Qt shipped encode the distance between lib/ and
    // plugins/, and reproducing that distance is what makes them come out right.
    // PE: there is no run path at all — a DLL is looked for beside the executable that loaded it —
    // so the libraries go INTO the executable's directory. Mirroring `lib/` there would produce a
    // tree in which nothing resolves and no entry in any file could be edited to fix it.
    const pe = readBinary(exePath).ok && !readBinary(exePath).elf;
    auto libRel    = pe ? "bin" : relativePath(buildNormalizedPath(q.libs), buildNormalizedPath(q.prefix));
    auto pluginRel = q.plugins.length
                   ? (pe ? buildPath("bin", "plugins")
                         : relativePath(buildNormalizedPath(q.plugins), buildNormalizedPath(q.prefix)))
                   : "";
    auto qmlRel    = q.qml.length
                   ? (pe ? buildPath("bin", "qml")
                         : relativePath(buildNormalizedPath(q.qml), buildNormalizedPath(q.prefix)))
                   : "";

    mkdirRecurse(buildPath(outDir, "bin"));
    copyInto(exePath, buildPath(outDir, "bin", baseName(exePath)));

    size_t libs, plugins, qmls;
    foreach (i; g_items) {
        if (i.source.length == 0) continue;
        final switch (i.kind) {
            case "lib":
                if (i.cls != Class.qt && i.cls != Class.thirdParty) break;
                copyInto(i.source, buildPath(outDir, libRel, baseName(i.source)));
                ++libs;
                break;
            case "plugin":
                copyInto(i.source, buildPath(outDir, pluginRel, i.name));
                ++plugins;
                break;
            case "qml":
                copyDir(i.source, outDir, buildPath(qmlRel, i.name.replace(".", dirSeparator)));
                ++qmls;
                break;
            case "exe": break;
        }
    }

    // qt.conf, with the paths MEASURED off the prefix rather than assumed. Qt reads it from beside
    // the executable, so `Prefix` is written relative to that directory and the bundle is
    // relocatable — which is the whole point of it existing.
    auto conf = "[Paths]\nPrefix = " ~ relativePath(outDir, buildPath(outDir, "bin")).replace("\\", "/")
              ~ "\nLibraries = " ~ libRel.replace("\\", "/")
              ~ (pluginRel.length ? "\nPlugins = " ~ pluginRel.replace("\\", "/") : "")
              ~ (qmlRel.length ? "\nQml2Imports = " ~ qmlRel.replace("\\", "/") : "")
              ~ "\n";
    std.file.write(buildPath(outDir, "bin", "qt.conf"), conf);

    stderr.writeln("qtd-deploy: bundled ", libs, " librar(ies), ", plugins, " plugin(s), ",
                   qmls, " QML module(s) into ", outDir);
    stderr.writeln("            layout mirrors ", q.prefix, ": bin/, ", libRel,
                   pluginRel.length ? ", " ~ pluginRel : "", qmlRel.length ? ", " ~ qmlRel : "");

    // AND NOW THE LINKS, and the measurement that decides how many have to change: 103 of the 118
    // libraries this bundle copies carry no run path at all, because distributions do not ship one.
    // DT_RUNPATH would have to be ADDED to every one of them — it applies only to the object that
    // carries it — and a .dynstr entry cannot grow in place, so that route ends at rebuilding 103
    // files. DT_RPATH on the EXECUTABLE is inherited by everything loaded beneath it and covers all
    // 103 at once. That is the one entry this reaches for, and it is why the bundle needs no
    // patchelf: the geometry answers for Qt's own files, inheritance answers for the rest.
    //
    // What still gets rewritten is the auditwheel case — a library whose run path names a directory
    // on the machine it was built on. Left alone, that path either does not exist on the user's
    // disk or, worse, exists and holds something else. Those are shortened to $ORIGIN, which always
    // fits, because an absolute build path is never shorter.
    if (pe) {
        stderr.writeln("qtd-deploy: links — nothing to rewrite: a PE image carries no run path, and",
                       " every DLL\n            was placed beside the executable, which is where the",
                       " loader looks for it.");
        return 0;
    }
    auto libAbs = buildNormalizedPath(buildPath(outDir, libRel));
    auto exeAbs = buildPath(outDir, "bin", baseName(exePath));
    size_t fixed, already, inherited;
    string[] refusals;

    string wantFor(string file) {
        auto here = dirName(buildNormalizedPath(absolutePath(file)));
        auto rel = relativePath(libAbs, here);
        return rel == "." ? "$ORIGIN" : "$ORIGIN" ~ dirSeparator ~ rel;
    }
    bool alreadyGood(string file, BinInfo info) {
        auto here = dirName(buildNormalizedPath(absolutePath(file)));
        foreach (rp; info.runpath)
            if (buildNormalizedPath(expandOrigin(rp, here)) == libAbs) return true;
        return false;
    }

    // The executable first, and with the inherited tag.
    {
        auto info = readBinary(exeAbs);
        auto want = wantFor(exeAbs);
        if (!info.ok || !info.elf) { }
        else if (info.runpath.length && alreadyGood(exeAbs, info) && info.runpathIsRpath) ++already;
        else {
            auto r = setRunpath(exeAbs, want, true);
            if (r.changed) ++fixed;
            else refusals ~= "    bin/" ~ baseName(exePath) ~ ": " ~ r.why
                           ~ "\n        Relink it with:  -L-rpath=" ~ want ~ " -L--disable-new-dtags"
                           ~ "\n        (--disable-new-dtags asks for DT_RPATH, which the libraries"
                           ~ " loaded beneath it inherit;\n         DT_RUNPATH would cover the"
                           ~ " executable alone and leave every one of them searching the system.)";
        }
    }

    // Then anything whose own run path points OUT of the bundle.
    foreach (i2; g_items) {
        if (i2.source.length == 0) continue;
        string file;
        if (i2.kind == "lib" && (i2.cls == Class.qt || i2.cls == Class.thirdParty))
            file = buildPath(outDir, libRel, baseName(i2.source));
        else if (i2.kind == "plugin") file = buildPath(outDir, pluginRel, i2.name);
        else continue;
        auto info = readBinary(file);
        if (!info.ok || !info.elf) continue;
        if (!info.runpath.length) { ++inherited; continue; }   // covered by the executable's RPATH
        if (alreadyGood(file, info)) { ++already; continue; }
        auto r = setRunpath(file, wantFor(file));
        if (r.changed) ++fixed;
        else if (r.ok) ++already;
        else refusals ~= "    " ~ relativePath(file, outDir) ~ ": run path `"
                       ~ info.runpath.join(":") ~ "` points outside the bundle and " ~ r.why;
    }

    stderr.writeln("qtd-deploy: links — ", already, " already relative, ", fixed,
                   " rewritten to $ORIGIN, ", inherited,
                   " with no run path (covered by the executable's inherited DT_RPATH)");
    foreach (l; refusals) stderr.writeln(l);
    return 0;
}

// --- main -------------------------------------------------------------------------------------
int usage() {
    stderr.writeln(
`qtd-deploy — what an installer has to carry, read out of the binary and out of Qt itself.

  qtd-deploy map    <binary> [options]           write the manifest to stdout
  qtd-deploy bundle <binary> --out <dir> [opts]  copy it, mirroring the prefix's geometry

Options:
  --qt-prefix <dir>   use this Qt instead of asking qmake (needed to map a foreign tree)
  --qml <dir|file>    scan these QML sources for imports (repeatable)
  --search <dir>      look here for libraries too (repeatable)
  --policy <file>     the do-not-bundle list (default: beside this tool, system-libs.txt)
  --qml-style <list>  keep ONLY these optional Qt Quick Controls styles (Fusion, Material, ...).
                      By default every declared style ships, because which one loads is decided at
                      run time and not by anything readable in the module directory.
  --plugins <list>    plugin categories to ship: 'all', or a comma-separated allow-list
                      (default: everything the linked modules claim, minus embedded-only families)
  --json              emit JSON instead of TSV`);
    return 2;
}

int main(string[] args) {
    if (args.length < 3) return usage();
    auto cmd = args[1];
    auto target = args[2];
    string qtPrefix, outDir, policy;
    string[] qmlDirs;
    bool json;
    for (size_t i = 3; i < args.length; ++i) {
        switch (args[i]) {
            case "--qt-prefix": if (++i >= args.length) return usage(); qtPrefix = args[i]; break;
            case "--out":       if (++i >= args.length) return usage(); outDir = args[i]; break;
            case "--qml":       if (++i >= args.length) return usage(); qmlDirs ~= args[i]; break;
            case "--search":    if (++i >= args.length) return usage(); g_searchDirs ~= args[i]; break;
            case "--policy":    if (++i >= args.length) return usage(); policy = args[i]; break;
            case "--plugins":   if (++i >= args.length) return usage();
                                if (args[i] == "all") g_dropCategories = [];
                                else g_keepCategories = args[i].split(",").map!(a => a.strip).array;
                                break;
            case "--qml-style": if (++i >= args.length) return usage();
                                g_extraStyles ~= args[i].split(",").map!(a => a.strip).array;
                                break;
            case "--json":      json = true; break;
            default: stderr.writeln("qtd-deploy: unknown option ", args[i]); return usage();
        }
    }
    if (cmd != "map" && cmd != "bundle") return usage();
    if (cmd == "bundle" && !outDir.length) { stderr.writeln("qtd-deploy: bundle needs --out"); return usage(); }
    if (!exists(target)) { stderr.writeln("qtd-deploy: no such file: ", target); return 1; }

    if (!policy.length) policy = buildPath(dirName(absolutePath(args[0])), "system-libs.txt");
    if (!exists(policy)) policy = buildPath(dirName(__FILE_FULL_PATH__), "system-libs.txt");
    try loadPolicy(policy);
    catch (Exception) return 1;

    auto q = findQt(qtPrefix);
    if (!q.ok) {
        stderr.writeln("qtd-deploy: no Qt found. Pass --qt-prefix; qmake was not on PATH and there is",
                       "\n    nothing to read the plugin descriptions out of without it.");
        return 1;
    }
    g_searchDirs ~= defaultSearchDirs();

    add("exe", baseName(target), absolutePath(target), Class.thirdParty, "the application");
    walk(absolutePath(target), q, "");
    collectPlugins(q);
    collectQml(q, qmlDirs);
    // A PLUGIN IS A BINARY TOO, and so is the shared object inside a QML module. Both are chosen
    // by name at run time rather than linked, which is why they needed finding at all — and it is
    // also why their own DT_NEEDED never appeared in the executable's closure. Copying libqxcb.so
    // without libQt6XcbQpa.so produces a bundle that starts and then dies telling the user that no
    // platform plugin could be initialized, which is the same symptom as not copying it.
    closeOverLoadables(q);
    // ...AND THEN ASK FOR PLUGINS AGAIN, because that walk discovers MODULES. Qt6QuickControls2 and
    // Qt6QuickTemplates2 arrive through libqtquickcontrols2plugin.so, not through the executable,
    // so on the first pass they were not in the module list and nothing looked for their plugins.
    // Repeats until the answer stops changing rather than a fixed number of times: each new plugin
    // can pull in another module, which can have plugins of its own.
    for (size_t pass = 0; pass < 8; ++pass) {
        auto before = g_items.length;
        collectPlugins(q);
        closeOverLoadables(q);
        if (g_items.length == before) break;
    }

    if (cmd == "map") { if (json) printJson(); else printTsv(); return 0; }
    return bundle(absolutePath(target), q, outDir);
}
