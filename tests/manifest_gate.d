// Manifest gate: diff a freshly generated coverage-manifest.tsv against a checked-in baseline
// and FAIL on regression — turning the manifest from inventory into a contract (round-5 #3).
// A regression is: a symbol that DISAPPEARED, one whose fate got WORSE (e.g. bound -> unmapped),
// or a NEW symbol that landed as a drop (unmapped-type/inline-failed). New well-bound symbols are
// reported, not failed (accept them by regenerating the baseline).
//   manifest_gate <baseline.tsv> <current.tsv> <label>
import std.stdio, std.file, std.string, std.array, std.algorithm, std.conv;

// fate quality (higher = better binding); a move to a lower rank is a regression.
int rank(string f) {
    switch (f) {
        case "bound":         return 6;
        case "shimmed":       return 5;
        case "signal":        return 5;
        case "inherited":     return 4;
        case "pure-virtual":  return 3;
        case "inline-failed": return 1;
        case "unmapped-type": return 1;
        default:              return 2;
    }
}
bool isDrop(string f) { return f == "unmapped-type" || f == "inline-failed"; }

struct Entry { string fate; string label; }   // fate + a human "class::symbol" for reporting

// Compare two keyed manifests. A key = class+USR, so overloads are distinct entries.
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

// The regression the class+name key MISSED (critics r6 #2): two overloads of A::f share a class+name
// but have distinct USRs. Dropping or regressing ONE must be caught now that the key includes USR.
unittest {
    Entry[string] base = ["A\tusr1": Entry("bound", "A::f"), "A\tusr2": Entry("bound", "A::f")];
    string[] d, r, nd, nb;
    classify(base, ["A\tusr1": Entry("bound", "A::f")], d, r, nd, nb);   // usr2 overload dropped
    assert(d.length == 1 && r.length == 0, "a dropped overload must be DISAPPEARED");
    d = r = nd = nb = null;
    classify(base, ["A\tusr1": Entry("unmapped-type", "A::f"), "A\tusr2": Entry("bound", "A::f")], d, r, nd, nb);
    assert(r.length == 1 && d.length == 0, "a regressed overload (bound->unmapped) must be REGRESSED");
}

// Key = cppClass + USR (the clang canonical identity, which INCLUDES the signature) so overloads
// are DISTINCT rows — the class+name key collapsed them and let a regressed/vanished overload pass.
// `dups` collects any key seen twice within one file (a collision the USR should make impossible).
Entry[string] load(string path, out string[] dups) {
    Entry[string] m;
    foreach (line; readText(path).splitLines) {
        if (!line.length || line.startsWith("#")) continue;
        auto c = line.split('\t');
        if (c.length < 4) continue;                         // cppClass \t symbol \t usr \t fate
        auto key = c[0] ~ "\t" ~ c[2];                      // class + USR
        auto lbl = c[0] ~ "::" ~ c[1];
        if (key in m) dups ~= lbl;
        m[key] = Entry(c[3], lbl);
    }
    return m;
}

void main(string[] args) {
    string[] baseDups, curDups;
    auto base = load(args[1], baseDups);
    auto cur  = load(args[2], curDups);
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
    dump("DUPLICATE KEYS in current (USR collision — a bug)", curDups);
    if (newBound.length)
        stderr.writefln("  note: %d new bound symbol(s) (benign; regenerate the baseline to accept)", newBound.length);

    if (disappeared.length || regressed.length || newDrops.length || curDups.length) {
        stderr.writefln("manifest-gate FAIL [%s]: %d disappeared, %d regressed, %d new drops, %d dup-keys",
            label, disappeared.length, regressed.length, newDrops.length, curDups.length);
        import core.stdc.stdlib : exit; exit(1);
    }
    writefln("manifest-gate OK [%s]: %d symbols (class+USR keys), no regression vs baseline (%d new bound)",
        label, cur.length, newBound.length);
}
