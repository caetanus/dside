#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
# EXECUTE THE INVENTORY, don't just validate its shape.
#
# `expected-fails-lint` checks schema, unique ids, known kinds and that every named probe target
# EXISTS in the graph. It has never run one. The audit has asked for a runner since round 7, and
# the cost of not having it is concrete: `virtual-container-return` sat in the inventory after the
# shim that closed it had landed, and the linter stayed green because "the entry is well-formed" and
# "the entry is still true" are different questions.
#
# This answers the second one for the entries that can answer it. A `risk` names the targets that
# COVER it; if one of them fails, the risk is no longer covered and the inventory is describing a
# protection that is not there. So: run them, require them to pass, and say which entry each belongs
# to — a bare target failure elsewhere in the matrix does not tell you a documented risk just became
# real.
#
# What it deliberately does NOT do yet, and the audit is right that it should: detect an UNEXPECTED
# PASS. That needs entries whose probe asserts a FAILURE, and the inventory has one
# (`qmltc-fixture-refusal-is-the-test`, whose probe is the fixture's own refusal). Encoding the
# direction per entry is the next step; claiming it now would be the same "well-formed means true"
# mistake one level up.
#
#   expected-fails-run.sh <expected-fails.json> <build>
set -eu
. "$(dirname -- "$0")/pybin.sh"          # $PY: the python that actually runs
JSON="$1"; BUILD="$2"
# ...and the nested builds inherit the caller's threading. `./build --single` serialises the top
# level and these invocations did not see it, so the one phase that launches builds of its own kept
# running them in parallel — which mattered on 2026-08-14, when a serial matrix was used to decide
# whether an intermittent failure could be deterministic and this phase quietly stayed parallel.
# An experiment that does not cover the thing it is measuring is worth what it costs to discover.
BUILD_FLAGS="${QTD_BUILD_FLAGS:-}"

targets=$("$PY" - "$JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
l = d["entries"] if isinstance(d, dict) and "entries" in d else d
for e in l:
    for t in e.get("probe_targets", []):
        print("keep\t%s\t%s\t\t" % (e["id"], t))
    # ...and the OTHER direction (critics r13 #6): a known_gap may name a target that must FAIL
    # today. When it starts passing, the gap is closed and the entry describes a world that no
    # longer exists — an UNEXPECTED PASS, which is the only way an inventory notices its own good
    # news. Without it the runner can only ever say "the protections still hold".
    for t in e.get("gap_probes", []):
        # A gap probe carries its FAILURE SIGNATURE (critics r14 #7): the exit code it must produce
        # and a string its diagnostic must contain. Without it, a missing tool, a broken import, a
        # crash or a CLI change all read as "the gap is still open" — an expected-fail with no
        # signature, which is the thing this file exists to stop being.
        # `unjudgeable_when`, when present: the fragment that says this MACHINE cannot ask the
        # question. A probe keyed to a Qt release the licence matrix records cannot be judged where
        # the installed release is not recorded — the gate there fails for a broader reason and
        # never reaches the artifacts the gap is about. Reported and counted, never silently passed.
        print("gap\t%s\t%s\t%s\t%s\t%s" % (e["id"], t["target"], t["exit"], t["match"],
                                             t.get("unjudgeable_when", "")))
PY
)

if [ -z "$targets" ]; then
  echo "expected-fails-run: no entry names a probe target — nothing to execute" >&2
  exit 1
fi

n=0; bad=0; unj=0
echo "$targets" | while IFS="	" read -r dir id tgt want_exit want_match no_judge; do
  [ -n "$tgt" ] || continue
  n=$((n + 1))
  if [ "$dir" = gap ]; then
    # `set -e` would kill the script on the very failure this branch exists to inspect, so the
    # substitution is part of an `||` list. The first version aborted silently here — a runner that
    # dies on the expected failure reports nothing at all, which looked like "no output, rc=1".
    out=$("$BUILD" $BUILD_FLAGS "$tgt" 2>&1) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
      printf 'expected-fails-run: %s PASSES — it is the GAP probe for `%s`, which claims this does not work. Remove the entry or narrow it.\n' "$tgt" "$id" >&2
      bad=$((bad + 1))
    elif [ "$rc" != "$want_exit" ]; then
      printf 'expected-fails-run: %s failed with exit %s, and `%s` contracts exit %s. It failed for the wrong reason.\n' "$tgt" "$rc" "$id" "$want_exit" >&2
      bad=$((bad + 1))
    elif [ -n "${no_judge:-}" ] && printf '%s' "$out" | grep -qF -- "$no_judge"; then
      printf 'expected-fails-run: %s is UNJUDGEABLE here — `%s` is keyed to a Qt release this\n' "$tgt" "$id" >&2
      printf '    machine does not have, and the gate stops earlier: %s\n' "$no_judge" >&2
      unj=$((unj + 1))
    elif ! printf '%s' "$out" | grep -qF -- "$want_match"; then
      printf 'expected-fails-run: %s failed as contracted but its diagnostic does not contain `%s` — `%s` describes a different failure.\n' "$tgt" "$want_match" "$id" >&2
      bad=$((bad + 1))
    fi
  elif ! "$BUILD" $BUILD_FLAGS "$tgt" >/dev/null 2>&1; then
    printf 'expected-fails-run: %s FAILED — it is the probe for `%s`, so that entry now describes a protection that is not there\n' \
           "$tgt" "$id" >&2
    bad=$((bad + 1))
  fi
  # The count has to survive the subshell the pipe creates, hence the file rather than a variable.
  printf '%s %s %s\n' "$n" "$bad" "$unj" > "${TMPDIR:-/tmp}/qtd-efr.$$"
done

read -r n bad unj < "${TMPDIR:-/tmp}/qtd-efr.$$" || { n=0; bad=0; unj=0; }
rm -f "${TMPDIR:-/tmp}/qtd-efr.$$"
[ "${bad:-0}" -eq 0 ] || exit 1
printf 'expected-fails-run OK: %s probe target(s) executed, every documented risk still covered, and every documented gap still open' "$n"
[ "${unj:-0}" -eq 0 ] && echo "" || printf ' (%s unjudgeable on this machine, named above)\n' "$unj"
