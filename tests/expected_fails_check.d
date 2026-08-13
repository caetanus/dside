// SPDX-FileCopyrightText: 2026 Marcelo A Caetano
// SPDX-License-Identifier: BSL-1.0
// expected-fails LINTER (critics r7 #4/#5). This is a strict schema linter, NOT an expected-fail
// RUNNER — it does not execute probes, evaluate remove_when, or detect unexpected pass/fail (that
// is a tracked follow-up). What it DOES, fail-closed: the schema value, the kind enum, and the
// field-by-kind rules are FIXED IN THIS PROGRAM (not taken from the document), IDs must be unique,
// required fields must be non-empty strings, and every `risk` probe_target must name a real build
// target from `./build --list`. A typo can't invent an accepted schema/kind.
//   expected_fails_check <expected-fails.json> <build-list.txt>
import std.stdio, std.json, std.file, std.string, std.algorithm, std.array, std.conv;

immutable string SCHEMA = "qt-dlang-gen expected-fails v2";
immutable string[] KINDS = ["permanent_exclusion", "known_gap", "risk"];
immutable string[] REQUIRED = ["id", "kind", "area", "reason", "since", "remove_when"];

void main(string[] args) {
    JSONValue j;
    try j = parseJSON(readText(args[1]));
    catch (Exception e) { stderr.writeln("expected-fails-lint FAIL: invalid JSON: ", e.msg); return exitFail(); }

    bool[string] targets;
    foreach (line; readText(args[2]).splitLines) {
        auto s = line.strip;
        if (s.startsWith("- ")) targets[s[2 .. $]] = true;
    }

    string[] errs;
    void nonEmptyStr(JSONValue o, string f, string ctx) {
        if (f !in o.object) { errs ~= ctx ~ ": missing `" ~ f ~ "`"; return; }
        if (o[f].type != JSONType.string || o[f].str.length == 0)
            errs ~= ctx ~ ": `" ~ f ~ "` must be a non-empty string";
    }

    // top-level: schema value + kinds array must MATCH the program's fixed values (not be trusted).
    if ("schema" !in j.object || j["schema"].str != SCHEMA)
        errs ~= "top-level `schema` must be exactly `" ~ SCHEMA ~ "`";
    if ("kinds" !in j.object || j["kinds"].array.map!(k => k.str).array != KINDS)
        errs ~= "top-level `kinds` must be exactly " ~ KINDS.to!string ~ " (the program is the authority)";
    if ("entries" !in j.object || j["entries"].type != JSONType.array)
        { errs ~= "missing `entries` array"; return report(errs); }

    bool[string] seenId;
    int nRisk, nProbe;
    foreach (i, e; j["entries"].array) {
        string id = ("id" in e.object && e["id"].type == JSONType.string) ? e["id"].str : "#" ~ i.to!string;
        foreach (f; REQUIRED) nonEmptyStr(e, f, id);
        if (id in seenId) errs ~= "duplicate id `" ~ id ~ "`";
        seenId[id] = true;

        if ("kind" in e.object && e["kind"].type == JSONType.string && e["kind"].str.length) {
            auto k = e["kind"].str;
            if (!KINDS.canFind(k))
                errs ~= id ~ ": kind `" ~ k ~ "` is not one of " ~ KINDS.to!string;
            // `gap_probes` is the OTHER direction (critics r13 #6): targets that must FAIL while the
            // gap is open, so the runner can report an UNEXPECTED PASS when it closes. Only a
            // known_gap may carry them — a `risk` claiming something must keep failing would be an
            // inventory of wishes.
            if ("gap_probes" in e.object) {
                if (k != "known_gap")
                    errs ~= id ~ ": `gap_probes` belongs to kind=known_gap, not `" ~ k ~ "`";
                if (e["gap_probes"].type != JSONType.array || e["gap_probes"].array.length == 0)
                    errs ~= id ~ ": `gap_probes` must be a non-empty array";
                // Each gap probe is an OBJECT with its failure signature (critics r14 #7):
                // {target, exit, match}. A bare target name would be an expected-fail that accepts
                // any failure, which is the shape the audit called out.
                else foreach (gp; e["gap_probes"].array) {
                    nProbe++;
                    if (gp.type != JSONType.object) {
                        errs ~= id ~ ": each gap_probe must be an object {target, exit, match}";
                        continue;
                    }
                    foreach (f; ["target", "exit", "match"])
                        if (f !in gp.object) errs ~= id ~ ": gap_probe is missing `" ~ f ~ "`";
                    if ("target" in gp.object
                            && (gp["target"].type != JSONType.string || gp["target"].str !in targets))
                        errs ~= id ~ ": gap_probe target `"
                            ~ (gp["target"].type == JSONType.string ? gp["target"].str : "?")
                            ~ "` is not a real build target (dangling)";
                    if ("exit" in gp.object && gp["exit"].type != JSONType.integer)
                        errs ~= id ~ ": gap_probe `exit` must be an integer";
                    if ("match" in gp.object
                            && (gp["match"].type != JSONType.string || gp["match"].str.length == 0))
                        errs ~= id ~ ": gap_probe `match` must be a non-empty string";
                }
            }
            else if (k == "risk") {
                nRisk++;
                if ("probe_targets" !in e.object || e["probe_targets"].type != JSONType.array
                        || e["probe_targets"].array.length == 0)
                    errs ~= id ~ ": kind=risk must list a non-empty `probe_targets` array";
                else foreach (pt; e["probe_targets"].array) {
                    nProbe++;
                    if (pt.type != JSONType.string || pt.str !in targets)
                        errs ~= id ~ ": probe_target `" ~ (pt.type == JSONType.string ? pt.str : "?")
                            ~ "` is not a real build target (dangling)";
                }
            } else if ("probe_targets" in e.object) {
                // A KNOWN GAP MAY CARRY PROBES, and the best ones do. The rule used to be "only a
                // risk has probes", on the assumption that a gap is by definition untested — but a
                // probe can assert that the gap is STILL REAL, and then the day somebody closes it
                // the probe fails and names the entry to delete. That is the unexpected-pass
                // detection this inventory has been missing since round 7, and it needs no new
                // field: `dangle-{ldc2,dmd}` asserts that a non-QObject whose owner died leaves a
                // wrapper that still believes it is alive.
                //
                // The other kinds keep the prohibition: a permanent_exclusion is not going to stop
                // being excluded, so a probe there would only rot.
                if (k != "known_gap")
                    errs ~= id ~ ": kind=" ~ k ~ " must NOT carry `probe_targets`";
                else foreach (pt; e["probe_targets"].array) {
                    nProbe++;
                    if (pt.type != JSONType.string || pt.str !in targets)
                        errs ~= id ~ ": probe_target `" ~ (pt.type == JSONType.string ? pt.str : "?")
                            ~ "` is not a real build target (dangling)";
                }
            }
        }
    }
    if (errs.length) return report(errs);
    writefln("expected-fails-lint OK: %d entries valid (strict); %d risk, %d probe targets exist",
        j["entries"].array.length, nRisk, nProbe);
}

void report(string[] errs) {
    stderr.writeln("expected-fails-lint FAIL:");
    foreach (x; errs) stderr.writeln("  ", x);
    exitFail();
}
void exitFail() { import core.stdc.stdlib : exit; exit(1); }
