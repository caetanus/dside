// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
//
// THE APPLICATION CONSTRUCTOR, DERIVED RATHER THAN COPIED — and checked against the libraries
// that actually ship, which is the half that makes the derivation trustworthy.
//
// Reported from the outside (bugs.md #5): `tests/support/appctor.d` centralises the mangled
// STRING for QApplication and QCoreApplication and has no entry for QGuiApplication, so writing a
// QtQuick program — the direction this project targets — meant inventing a symbol that the one
// file created to prevent exactly that did not contain. The reporter derived
// `_ZN15QGuiApplicationC1ERiPPci` by analogy and confirmed it afterwards against `nm -D`. It was
// right; it was still a guess.
//
// So this proves two things a compile alone would not:
//
//   1. the mixin BUILDS AND RUNS an application object — it is a QCoreApplication here, because
//      that is the one class of the three that needs no display, and the point under test is the
//      constructor rather than the widget stack;
//   2. the derivation agrees with the SHIPPED LIBRARY for all three classes, read with the
//      platform's own symbol reader. A rule that produces a plausible string for a class nobody
//      links is worth nothing.
//
// The second check is what turns "derivable" from a claim into a measurement.
import cxxrt;
import qt.widgets.qcoreapplication;
import std.stdio, std.process, std.algorithm, std.string;

mixin(qtdApplication!"QCoreApplication");

// The rule, stated once here and once in cxxrt.d. If they ever disagree this file stops compiling,
// which is the cheapest possible way to notice.
static assert(qtdAppCtorSymbol("QApplication", false)    == "_ZN12QApplicationC1ERiPPci");
static assert(qtdAppCtorSymbol("QCoreApplication", false) == "_ZN16QCoreApplicationC1ERiPPci");
static assert(qtdAppCtorSymbol("QGuiApplication", false)  == "_ZN15QGuiApplicationC1ERiPPci");
static assert(qtdAppCtorSymbol("QApplication", true)      == "??0QApplication@@QEAA@AEAHPEAPEADH@Z");

// ...and the same names read off the library. `llvm-nm` is what the Windows half of this build
// already uses, and it reads ELF as happily as it reads COFF, so ONE reader serves both platforms
// — a check that used `nm` here and something else there would be two checks.
//
// The build hands over a DIRECTORY, because that is what it knows; finding `Qt6Widgets` inside it
// is this file's job and is not the same as guessing where Qt is. The name differs by platform
// (`libQt6Widgets.so.6` against `Qt6Widgets.lib`) so the match is on the stem.
string[] librariesFor(string dir, string stem) {
    import std.file : dirEntries, SpanMode, exists;
    import std.path : baseName;
    string[] found;
    if (!exists(dir)) return found;
    foreach (e; dirEntries(dir, SpanMode.shallow)) {
        auto b = baseName(e.name);
        if (b.canFind(stem) && (b.canFind(".so") || b.endsWith(".lib") || b.endsWith(".a")))
            found ~= e.name;
    }
    return found;
}

// BOTH SYMBOL TABLES, and the reason is that a shared library has its static one stripped:
//     llvm-nm --defined-only /usr/lib/libQt6Core.so   ->  "no symbols"
//     llvm-nm -D --defined-only  (the same file)      ->  the constructor
// An import library on Windows is the other way round. Asking for one table and reporting
// "defined by no Qt6Core" would have been a statement about nm, not about Qt.
bool symbolIn(string lib, string sym) {
    foreach (flags; [["llvm-nm", "-D", "--defined-only"], ["llvm-nm", "--defined-only"]]) {
        auto r = execute(flags ~ lib);
        if (r.status == 0 && r.output.splitter('\n').any!(l => l.canFind(sym))) return true;
    }
    return false;
}

void main(string[] args) {
    auto app = createApp("appmixin");
    if (app is null) { writeln("appmixin FAIL: createApp returned null"); return; }
    writeln("  CTOR      QCoreApplication built through mixin(qtdApplication!...)");

    // The libraries to read, given on the command line: the build knows where Qt is and this file
    // must not guess. No library named, no library check — the run still proves (1).
    // One class per library, because that is how Qt splits them — and a class whose library is
    // not installed is skipped rather than failed: the binding does not require all three.
    static immutable string[2][3] where = [["QApplication", "Qt6Widgets"],
                                           ["QGuiApplication", "Qt6Gui"],
                                           ["QCoreApplication", "Qt6Core"]];
    size_t checked, bad;
    foreach (dir; args[1 .. $])
        foreach (w; where) {
            version (Windows) auto sym = qtdAppCtorSymbol(w[0], true);
            else              auto sym = qtdAppCtorSymbol(w[0], false);
            auto libs = librariesFor(dir, w[1]);
            if (!libs.length) continue;                       // that module is not installed here
            if (libs.any!(l => symbolIn(l, sym))) {
                checked++;
                writeln("  SYM       ", w[0], " -> ", sym);
            } else {
                writeln("appmixin FAIL: ", sym, " is defined by no ", w[1], " in ", dir);
                bad++;
            }
        }
    if (args.length > 1 && checked == 0) {
        writeln("appmixin FAIL: none of the three constructors was found in ", args[1 .. $]);
        writeln("    the derivation produced strings no shipped library defines, which is the");
        writeln("    failure this test exists for — a plausible symbol is not a correct one.");
        bad++;
    }
    if (bad) return;
    writeln("appmixin OK: the ctor symbol is derived from the class name and ", checked,
            " of them are defined by the libraries in front of us");
}
