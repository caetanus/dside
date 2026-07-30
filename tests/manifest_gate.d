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
Entry[string] parse(string content, out string[] dups, out string[] malformed, out string[] badFate) {
    Entry[string] m;
    foreach (i, line; content.splitLines) {
        if (!line.length || line.startsWith("#")) continue;
        auto c = line.split('\t');
        if (c.length != 4 || c[0].length == 0 || c[1].length == 0 || c[2].length == 0) {
            malformed ~= "line " ~ (i + 1).to!string ~ ": `" ~ line ~ "`";
            continue;
        }
        if (!validFate(c[3])) badFate ~= c[0] ~ "::" ~ c[1] ~ " fate=`" ~ c[3] ~ "`";
        auto key = c[0] ~ "\t" ~ c[2];                      // class + USR
        auto lbl = c[0] ~ "::" ~ c[1];
        if (key in m) dups ~= lbl;
        m[key] = Entry(c[3], lbl);
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
