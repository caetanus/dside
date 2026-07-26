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

string[string] load(string path) {
    string[string] m;   // "class\tsymbol" -> fate
    foreach (line; readText(path).splitLines) {
        if (!line.length || line.startsWith("#")) continue;
        auto c = line.split('\t');
        if (c.length >= 3) m[c[0] ~ "\t" ~ c[1]] = c[2];
    }
    return m;
}

void main(string[] args) {
    auto base = load(args[1]);
    auto cur  = load(args[2]);
    auto label = args.length > 3 ? args[3] : "";
    string[] disappeared, regressed, newDrops, newBound;
    foreach (k, f; base) {
        auto p = k in cur;
        if (p is null) disappeared ~= k;
        else if (rank(*p) < rank(f)) regressed ~= k.replace("\t", "::") ~ " (" ~ f ~ " -> " ~ *p ~ ")";
    }
    foreach (k, f; cur)
        if (k !in base) { if (isDrop(f)) newDrops ~= k.replace("\t", "::") ~ " (" ~ f ~ ")"; else newBound ~= k; }

    void dump(string title, string[] xs) {
        if (!xs.length) return;
        stderr.writefln("  %s (%d):", title, xs.length);
        foreach (x; xs[0 .. min($, 15)]) stderr.writeln("    ", x);
        if (xs.length > 15) stderr.writefln("    ... +%d more", xs.length - 15);
    }
    dump("DISAPPEARED", disappeared);
    dump("REGRESSED", regressed);
    dump("NEW DROPS", newDrops);
    if (newBound.length)
        stderr.writefln("  note: %d new bound symbol(s) (benign; regenerate the baseline to accept)", newBound.length);

    if (disappeared.length || regressed.length || newDrops.length) {
        stderr.writefln("manifest-gate FAIL [%s]: %d disappeared, %d regressed, %d new drops",
            label, disappeared.length, regressed.length, newDrops.length);
        import core.stdc.stdlib : exit; exit(1);
    }
    writefln("manifest-gate OK [%s]: %d symbols, no regression vs baseline (%d new bound)",
        label, cur.length, newBound.length);
}
