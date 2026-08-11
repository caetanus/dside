// qtd_build.d — shared reggae helpers for building qt-dlang-gen bindings and apps.
//
// The generator (`gend`) is a pure code generator: it emits a nested-layout binding
// (`<genDir>/qt/<pkg>/*.d` matching each `module` name, plus top-level cxxrt/holder/
// qtmoc and the C++ shim `.cpp`). reggae owns the whole build graph:
//
//   gen (run gend)  ->  shims.a (clang++ every .cpp)      \
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

// --- pkg-config ---------------------------------------------------------------

string pkgCflags(string[] mods) {
    return execute(["pkg-config", "--cflags"] ~ mods).output.strip;
}

// Linker flags for the D compiler: each `-lFoo`/`-L/path` token wrapped as `-L<tok>`
// (ldc2/dmd forward `-L…` to the C linker), plus libstdc++ for the C++ runtime.
string pkgLibs(string[] mods) {
    auto toks = execute(["pkg-config", "--libs"] ~ mods).output.strip.split ~ "-lstdc++";
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
                    return ["-I" ~ de.name, "-I" ~ buildPath(de.name, mod)];
    return [];
}
string[] mocPrivateFlags(string cflags) { return modulePrivateFlags(cflags, "QtCore"); }

// qmlcachegen (Qt's AOT QML bytecode compiler) lives under the Qt libexecdir. Returns "" if
// it isn't installed, so callers can skip the AOT targets on a system that lacks it.
string qmlcachegenPath() {
    auto le = execute(["pkg-config", "--variable=libexecdir", "Qt6Qml"]).output.strip;
    auto p = buildPath(le, "qmlcachegen");
    return exists(p) ? p : "";
}

// lrelease (Qt's .ts -> .qm compiler) — a user-facing tool, usually in bindir or PATH.
// Returns "" if absent so the translation round-trip test degrades to an identity-only check.
string lreleasePath() {
    auto bd = execute(["pkg-config", "--variable=bindir", "Qt6Core"]).output.strip;
    foreach (p; [buildPath(bd, "lrelease"), "/usr/bin/lrelease"])
        if (exists(p)) return p;
    return execute(["which", "lrelease"]).status == 0 ? "lrelease" : "";
}

// --- the binding graph --------------------------------------------------------

struct QtdBinding {
    Target gen;       // runs gend -> a stamp (the whole genDir is regenerated clean)
    Target shims;     // libshims.a (all .cpp, C++)
    string root;
    string genDir;    // pure generated sources (owned by gend, wiped on each regen)
    string bdir;      // reggae build artifacts (objects, archives) — kept out of genDir
    string[] mods;    // pkg-config modules (Qt6Widgets, …)
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
    auto r = execute(["pkg-config", "--modversion", pkgMod]);
    if (r.status != 0) return "";
    auto v = r.output.strip.split(".");
    return v.length >= 2 ? v[0] ~ "." ~ v[1] : "";
}

private string gendPath(string root) { return buildPath(root, "generator-d", "gend"); }

// The generator binary is an INPUT to every gen step, but it was only ever built by hand
// (`dub build` in generator-d/). Editing emit_cxx.d therefore changed nothing: the build kept
// running a months-old gend and re-emitted identical bindings, so a generator fix looked like it
// had no effect. Measured: after teaching the generator to keep C++ default member initializers,
// the regenerated color.d still said `bool m_null;` until gend was rebuilt by hand.
// Now it is a real target, rebuilt from its own sources before anything depends on it.
Target gendTarget(string root) {
    auto dir = buildPath(root, "generator-d");
    auto gend = gendPath(root);
    auto srcs = ["clang_c.d", "gen.d", "emit.d", "emit_cxx.d"].map!(f => buildPath(dir, f)).array;
    // dub decides itself whether a relink is needed; guarded() keeps concurrent gen steps from
    // racing into the same dub build, and skips it outright when gend is already newest.
    auto cmd = guarded(buildPath(dir, "gend.lock"),
        "cd " ~ dir ~ " && dub build --quiet", gend, srcs);
    return Target(gend, cmd, srcs.map!(f => Target(f)).array);
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
                   output, newerThan);
}

string guarded(string lock, string cmd, string output, string[] newerThan) {
    auto test = newerThan.map!(d => "[ " ~ output ~ " -nt " ~ d ~ " ]").join(" && ");
    auto inner = (test.length ? "if " ~ test ~ "; then exit 0; fi; " : "") ~ cmd;
    auto esc = inner.replace("'", `'\''`);
    return "mkdir -p " ~ dirName(lock) ~ " && flock " ~ lock ~ " sh -c '" ~ esc ~ "'";
}

// reggaeBuild() runs on EVERY ./build (even --list), so an unconditional write here bumps the
// mtime of a file that other guards use as their freshness input — forcing a full libsample
// rebuild every time, and worse, doing it WHILE sibling targets link against the artifacts.
// Write only when the content actually differs.
void writeIfChanged(string path, string content) {
    if (exists(path) && readText(path) == content) return;
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
    auto cxx = cflags ~ " -std=c++17 -fPIC -O2 -ffunction-sections -fdata-sections";
    // Extra include paths from the spec: private-header subdirs a private-API binding needs so the
    // aggregated shims (qtdctor/qtvirt/...) that reference private types (QQuickGradient etc.) compile.
    // A RELATIVE path in the spec is relative to the SPEC, not to whoever compiles: gend runs from
    // generator/, reggae from the repo root. Normalize so both resolve the same directory.
    if (auto ip = "include_paths" in j.object)
        foreach (p; ip.array)
            cxx ~= " -I" ~ (isAbsolute(p.str) ? p.str : buildNormalizedPath(dirName(specPath), p.str));
    // qtdmoc.cpp needs the Qt private headers; the QML registration block is compiled in only
    // when this binding actually links Qt6Qml (else it would reference QQmlPrivate with no lib).
    // qtdmoc.cpp needs QtCore private (QMetaObjectBuilder) always, and — in a QML-enabled binding
    // — QtQml private too: attached-property lookup goes through QQmlMetaType, which is private.
    bool hasQml = mods.canFind("Qt6Qml") || mods.canFind("Qt5Qml");
    auto priv = mocPrivateFlags(cflags).join(" ")
        ~ (hasQml ? " " ~ modulePrivateFlags(pkgCflags([mods.canFind("Qt6Qml") ? "Qt6Qml" : "Qt5Qml"]), "QtQml").join(" ")
                    ~ " -DQTD_ENABLE_QML" : "");

    // gend fully owns genDir: wipe it first so stale files from an earlier layout can't
    // linger (a flat qfoo.d beside the nested qt/pkg/qfoo.d would clash on the module).
    // The stamp lives in bdir, not genDir, so wiping genDir doesn't delete it.
    auto stamp = buildPath(bdir, "gen.stamp");
    auto gend = gendPath(root);
    auto genCmd = "rm -rf " ~ genDir ~ " && " ~ gend ~ " " ~ specPath ~ " >/dev/null && touch " ~ stamp;
    // The generator COPIES these runtime sources verbatim into the binding (emit.d), so they are
    // build INPUTS. Without the edge, editing the runtime leaves every already-generated binding
    // on the old copy and the whole matrix goes green against code that is no longer in the tree —
    // which is exactly how a Qt5 build break stayed hidden.
    auto runtimeSrc = ["qtmoc/qtdmoc.cpp", "qtmoc/qtmoc.d", "holder/qtd_holder.cpp", "holder/holder.d"]
        .map!(f => buildPath(root, "runtime", f)).filter!(f => exists(f)).array;
    auto gen = Target(stamp,
        guarded(bdir ~ "/gen.lock", genCmd, stamp, [specPath, gend] ~ runtimeSrc),
        [Target(specPath), gendTarget(root)] ~ runtimeSrc.map!(f => Target(f)).array);

    // Compile every .cpp into libshims.a. qtdmoc.cpp additionally needs the Qt private
    // headers. Shims are C++ -> identical for ldc2/dmd, so this target is shared.
    auto shimsLib = buildPath(bdir, "libshims.a");
    auto shimsCmd = "mkdir -p " ~ bdir ~ "/ocpp && for c in " ~ genDir ~ "/*.cpp; do "
        ~ `b=$(basename "$c" .cpp); if [ "$b" = qtdmoc ]; then EX="` ~ priv ~ `"; else EX=; fi; `
        ~ "clang++ " ~ cxx ~ " $EX -c $c -o " ~ bdir ~ "/ocpp/$b.o || exit 1; done && "
        ~ "ar rcs " ~ shimsLib ~ " " ~ bdir ~ "/ocpp/*.o";
    auto shims = Target(shimsLib,
        guarded(bdir ~ "/shims.lock", shimsCmd, shimsLib, [stamp]),
        [gen]);

    return QtdBinding(gen, shims, root, genDir, bdir, mods);
}

// Per-compiler binding archive: compile every generated .d module to its own object
// (ldc2 needs -oq for fully-qualified object names; dmd names by module), archive them.
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
        ~ "ar rcs " ~ lib ~ " " ~ od ~ "/*.o";
    auto t = Target(lib,
        guarded(b.bdir ~ "/bind_" ~ dc ~ ".lock", cmd, lib, [stamp]),
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
    auto link = dc ~ " -of=$out " ~ appMain ~ (extra.length ? " " ~ extra : "") ~ " -I" ~ b.genDir
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
    return Target.phony(name, "QT_QPA_PLATFORM=offscreen $in", [app]);
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
    auto cxx = cflags ~ " -std=c++17 -fPIC -O2";
    auto priv = mocPrivateFlags(cflags).join(" ");
    auto gend = gendPath(root);

    // 1) libsample.a from the external sources (+ the umbrella copied in for gend).
    auto lsa = buildPath(build, "libsample.a");
    auto lsaCmd = "rm -rf " ~ build ~ " && mkdir -p " ~ build ~ " && cp " ~ LS ~ "/*.h " ~ LS ~ "/*.cpp "
        ~ MIN ~ "/libminimalmacros.h " ~ buildPath(bdir, "sample_all.h") ~ " " ~ build ~ "/ && cd " ~ build
        ~ " && sed -i 's#../libminimal/libminimalmacros.h#libminimalmacros.h#' libsamplemacros.h"
        ~ ` && for c in *.cpp; do [ "$c" = main.cpp ] || clang++ -std=c++17 -fPIC -DLIBSAMPLE_BUILD -I. -c "$c" -o "${c%.cpp}.o" 2>/dev/null; done`
        ~ " && ar rcs libsample.a *.o";
    // freshness vs the umbrella (written at configure time): without it a second concurrent
    // scheduling would `rm -rf build` mid-link (empty newerThan == never skip).
    auto sampleLib = Target(lsa, guarded(bdir ~ "/lsa.lock", lsaCmd, lsa, [buildPath(bdir, "sample_all.h")]), []);

    // 2) generate the "sample" binding.
    auto stamp = buildPath(bdir, "gen.stamp");
    auto genCmd = "rm -rf " ~ gen ~ " && " ~ gend ~ " " ~ specPath ~ " >/dev/null 2>&1 && touch " ~ stamp;
    auto genT = Target(stamp, guarded(bdir ~ "/gen.lock", genCmd, stamp, [lsa, gend]), [sampleLib, gendTarget(root)]);

    // 3) shims (.cpp) -> libshims.a.
    auto shimsLib = buildPath(bdir, "libshims.a");
    auto shimsCmd = "mkdir -p " ~ bdir ~ "/ocpp && for c in " ~ gen ~ "/*.cpp; do "
        ~ `b=$(basename "$c" .cpp); if [ "$b" = qtdmoc ]; then EX="` ~ priv ~ `"; else EX=; fi; `
        ~ "clang++ " ~ cxx ~ " $EX -c $c -o " ~ bdir ~ "/ocpp/$b.o || exit 1; done && "
        ~ "ar rcs " ~ shimsLib ~ " " ~ bdir ~ "/ocpp/*.o";
    auto shimsT = Target(shimsLib, guarded(bdir ~ "/shims.lock", shimsCmd, shimsLib, [stamp]), [genT]);

    Target[] outs;
    foreach (dc; ["ldc2", "dmd"]) {
        auto oq = dc == "ldc2" ? "-oq " : "";
        auto od = bdir ~ "/od_" ~ dc;
        auto lib = buildPath(bdir, "libbinding_" ~ dc ~ ".a");
        auto libCmd = "rm -rf " ~ od ~ " && mkdir -p " ~ od ~ " && cd " ~ gen ~ " && "
            ~ dc ~ " -c " ~ oq ~ "-od=" ~ od ~ ` -I. $(find . -name "*.d") && `
            ~ "ar rcs " ~ lib ~ " " ~ od ~ "/*.o";
        auto libT = Target(lib, guarded(bdir ~ "/bind_" ~ dc ~ ".lock", libCmd, lib, [stamp]), [genT]);
        // libsample.a + the shim archives have mutual refs -> a static --start/--end-group.
        auto grp = "-L--start-group -L=" ~ lib ~ " -L=" ~ shimsLib ~ " -L=" ~ lsa
            ~ " -L--end-group -L-lstdc++";
        auto cases = dirEntries(buildPath(here, "cases"), "*.d", SpanMode.shallow).map!(e => e.name).array
            ~ buildPath(here, "cornercases.d");
        cases.sort();
        foreach (c; cases) {
            auto n = "sample_" ~ baseName(c).stripExtension ~ "-" ~ dc;
            auto app = Target(n ~ "-bin", dc ~ " -of=$out " ~ c ~ " -I" ~ gen ~ " " ~ grp,
                [Target(c), libT, shimsT, sampleLib]);
            outs ~= Target.phony(n, "QT_QPA_PLATFORM=offscreen $in", [app]);
        }
    }
    return outs;
}
