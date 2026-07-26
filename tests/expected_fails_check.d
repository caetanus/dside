// expected_fails_check — the CONSUMER for tests/expected-fails.json (critics r6 #3). Until now the
// file was an inventory nothing read; docs claimed it "blocks regression" — false. This validates:
//   - schema: every entry has id / kind / area / reason / since / remove_when;
//   - kind is one of the declared kinds;
//   - `risk` entries carry `probe_targets`, and EVERY probe target NAMES A REAL build target
//     (from `./build --list`) — so a probe can't rot into a dangling name.
// Exits non-zero (and lists the violations) on any problem. Usage:
//   expected_fails_check <expected-fails.json> <build-list.txt>
import std.stdio, std.json, std.file, std.string, std.algorithm, std.array, std.conv;

void main(string[] args) {
    auto j = parseJSON(readText(args[1]));
    bool[string] targets;   // the real reggae targets, from `./build --list`
    foreach (line; readText(args[2]).splitLines) {
        auto s = line.strip;
        if (s.startsWith("- ")) targets[s[2 .. $]] = true;
    }

    string[] kinds;
    foreach (k; j["kinds"].array) kinds ~= k.str;
    bool isKind(string k) { return kinds.canFind(k); }

    string[] errs;
    int nRisk, nProbe;
    foreach (i, e; j["entries"].array) {
        string id = ("id" in e.object) ? e["id"].str : "#" ~ i.to!string;
        void need(string f) { if (f !in e.object) errs ~= id ~ ": missing required field `" ~ f ~ "`"; }
        foreach (f; ["id", "kind", "area", "reason", "since", "remove_when"]) need(f);
        if ("kind" in e.object && !isKind(e["kind"].str))
            errs ~= id ~ ": unknown kind `" ~ e["kind"].str ~ "` (allowed: " ~ kinds.join(", ") ~ ")";
        if ("kind" in e.object && e["kind"].str == "risk") {
            nRisk++;
            if ("probe_targets" !in e.object || e["probe_targets"].array.length == 0)
                errs ~= id ~ ": kind=risk must list non-empty `probe_targets`";
            else foreach (pt; e["probe_targets"].array) {
                nProbe++;
                if (pt.str !in targets)
                    errs ~= id ~ ": probe_target `" ~ pt.str ~ "` is not a real build target (dangling)";
            }
        }
    }
    if (errs.length) {
        stderr.writeln("expected-fails-check FAIL:");
        foreach (x; errs) stderr.writeln("  ", x);
        import core.stdc.stdlib : exit; exit(1);
    }
    writefln("expected-fails-check OK: %d entries valid; %d risk entries, %d probe targets all exist",
        j["entries"].array.length, nRisk, nProbe);
}
