// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// Manifest gate: diff a freshly generated coverage-manifest.tsv against a checked-in baseline and
// FAIL on regression — the manifest as a contract. FAIL-CLOSED (critics r7 #4): a malformed line, a
// duplicate class+USR key (in EITHER file), or a fate outside the fixed enum is a hard failure, not
// a silent skip. A regression is a symbol that DISAPPEARED, whose fate got WORSE, or a NEW drop.
//   manifest_gate <baseline.tsv> <current.tsv> <label>
import std.stdio, std.file, std.string, std.array, std.algorithm, std.conv;

// The fate vocabulary is FIXED IN THIS PROGRAM (not taken from the data) — a typo'd fate must fail,
// not invent an accepted category. rank: higher = better binding; a move to a lower rank regresses.
immutable string[] FATES = ["bound", "shimmed", "signal", "inherited", "pure-virtual",
                            "unmapped-type", "inline-failed"];
bool validFate(string f) { return FATES.canFind(f); }
int rank(string f) {
    switch (f) {
        case "bound":         return 6;
        // `shimmed` ranks EQUAL to `bound`: both mean the binding can call the method, which is what
        // this gate is for. The distinction is the call path, and since a VIRTUAL method MUST go
        // through the C++ trampoline (pragma(mangle) on the declaring class's symbol bypasses the
        // override), a bound -> shimmed move is often a correctness FIX, not a loss.
        case "shimmed":       return 6;
        case "signal":        return 5;
        case "inherited":     return 4;
        case "pure-virtual":  return 3;
        case "inline-failed": return 1;
        case "unmapped-type": return 1;
        default:              return 0;   // unreachable (validFate gates it) — lowest, never "benign"
    }
}
bool isDrop(string f) { return f == "unmapped-type" || f == "inline-failed"; }

struct Entry { string fate; string label; }

// Parse manifest CONTENT (a string, so it's unittestable through the real parser). Fail-closed:
// records malformed lines, duplicate keys, and out-of-enum fates for the caller to reject.
// COLUMNS ARE READ BY NAME, from the `# cppClass<TAB>symbol<TAB>usr<TAB>...<TAB>fate` header,
// because the manifest's schema is allowed to grow and this gate must not care. It did care: the
// arity was pinned at 4 and the fate read from index 3, so adding a `why` column on 2026-08-19 —
// which changed no key and no fate — made EVERY line malformed and the controls gate report 20602
// issues under the heading "regression OR corrupt manifest". A schema change looked exactly like a
// catastrophic regression, and the honest fix is not to regenerate the baselines (that would hide
// any real regression riding along in the same commit) but to stop pinning the shape. Baselines
// written with the old four columns and a current file with five now compare correctly, because
// what is compared — class, USR, fate — is found by name in both.
Entry[string] parse(string content, out string[] dups, out string[] malformed, out string[] badFate) {
    Entry[string] m;
    size_t iCls = 0, iSym = 1, iUsr = 2, iFate = 3;   // the historical layout, if there is no header
    size_t want = 4;
    // The header is the `#` line that NAMES COLUMNS — not merely the first `#` line. These files
    // open with an SPDX comment, and taking that for the header set the expected arity to 1 and
    // made every real line malformed: 11246 issues instead of 20602, which is progress in the wrong
    // direction and would have been read as "the fix helped a bit".
    foreach (line; content.splitLines) {
        if (!line.startsWith("#") || !line.canFind("cppClass")) continue;
        auto h = line[1 .. $].strip.split('\t');
        foreach (j, name; h) {
            switch (name.strip) {
                case "cppClass": iCls = j; break;
                case "symbol":   iSym = j; break;
                case "usr":      iUsr = j; break;
                case "fate":     iFate = j; break;
                default: break;
            }
        }
        want = h.length;
        break;
    }
    foreach (i, line; content.splitLines) {
        if (!line.length || line.startsWith("#")) continue;
        auto c = line.split('\t');
        if (c.length != want || c[iCls].length == 0 || c[iSym].length == 0 || c[iUsr].length == 0) {
            malformed ~= "line " ~ (i + 1).to!string ~ ": `" ~ line ~ "`";
            continue;
        }
        if (!validFate(c[iFate])) badFate ~= c[iCls] ~ "::" ~ c[iSym] ~ " fate=`" ~ c[iFate] ~ "`";
        auto key = c[iCls] ~ "\t" ~ c[iUsr];                // class + USR
        auto lbl = c[iCls] ~ "::" ~ c[iSym];
        if (key in m) dups ~= lbl;
        m[key] = Entry(c[iFate], lbl);
    }
    return m;
}

void classify(Entry[string] base, Entry[string] cur,
              ref string[] disappeared, ref string[] regressed, ref string[] newDrops, ref string[] newBound) {
    foreach (k, e; base) {
        auto p = k in cur;
        if (p is null) disappeared ~= e.label;
        else if (rank(p.fate) < rank(e.fate)) regressed ~= e.label ~ " (" ~ e.fate ~ " -> " ~ p.fate ~ ")";
    }
    foreach (k, e; cur)
        if (k !in base) { if (isDrop(e.fate)) newDrops ~= e.label ~ " (" ~ e.fate ~ ")"; else newBound ~= e.label; }
}

// A dropped/regressed overload is caught (class+USR distinguishes overloads).
unittest {
    Entry[string] base = ["A\tusr1": Entry("bound", "A::f"), "A\tusr2": Entry("bound", "A::f")];
    string[] d, r, nd, nb;
    classify(base, ["A\tusr1": Entry("bound", "A::f")], d, r, nd, nb);
    assert(d.length == 1 && r.length == 0, "a dropped overload must be DISAPPEARED");
    d = r = nd = nb = null;
    classify(base, ["A\tusr1": Entry("unmapped-type", "A::f"), "A\tusr2": Entry("bound", "A::f")], d, r, nd, nb);
    assert(r.length == 1 && d.length == 0, "a regressed overload must be REGRESSED");
}
// Fail-closed: the three r7 #4 false-greens must be flagged BY THE PARSER, not silently accepted.
unittest {
    string[] dups, mal, bad;
    parse("A\tf\tusr1\tbound\nA\tg\tusr1\tbound\nA\th\tusr2\ttypo-fate\nbroken\tline\n", dups, mal, bad);
    assert(dups.length == 1, "duplicate class+USR key must be flagged");
    assert(bad.length == 1, "a fate outside the fixed enum (typo-fate) must be flagged");
    assert(mal.length == 1, "a malformed (<4-col) line must be flagged");
}

void main(string[] args) {
    string[] bDups, cDups, bMal, cMal, bBad, cBad;
    auto base = parse(readText(args[1]), bDups, bMal, bBad);
    auto cur  = parse(readText(args[2]), cDups, cMal, cBad);
    auto label = args.length > 3 ? args[3] : "";
    string[] disappeared, regressed, newDrops, newBound;
    classify(base, cur, disappeared, regressed, newDrops, newBound);

    void dump(string title, string[] xs) {
        if (!xs.length) return;
        stderr.writefln("  %s (%d):", title, xs.length);
        foreach (x; xs[0 .. min($, 15)]) stderr.writeln("    ", x);
        if (xs.length > 15) stderr.writefln("    ... +%d more", xs.length - 15);
    }
    dump("DISAPPEARED", disappeared);
    dump("REGRESSED", regressed);
    dump("NEW DROPS", newDrops);
    dump("DUPLICATE KEYS (baseline)", bDups);
    dump("DUPLICATE KEYS (current)", cDups);
    dump("MALFORMED LINES (baseline)", bMal);
    dump("MALFORMED LINES (current)", cMal);
    dump("INVALID FATE (baseline)", bBad);
    dump("INVALID FATE (current)", cBad);
    if (newBound.length)
        stderr.writefln("  note: %d new bound symbol(s) (benign; regenerate the baseline to accept)", newBound.length);

    auto bad = disappeared.length + regressed.length + newDrops.length
             + bDups.length + cDups.length + bMal.length + cMal.length + bBad.length + cBad.length;
    if (bad) {
        stderr.writefln("manifest-gate FAIL [%s]: %d issue(s) (regression OR corrupt manifest)", label, bad);
        import core.stdc.stdlib : exit; exit(1);
    }
    writefln("manifest-gate OK [%s]: %d symbols (class+USR), no regression, manifest well-formed (%d new bound)",
        label, cur.length, newBound.length);
}
