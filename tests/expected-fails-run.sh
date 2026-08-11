#!/bin/sh
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
JSON="$1"; BUILD="$2"

targets=$(python3 - "$JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
l = d["entries"] if isinstance(d, dict) and "entries" in d else d
for e in l:
    for t in e.get("probe_targets", []):
        print("%s\t%s" % (e["id"], t))
PY
)

if [ -z "$targets" ]; then
  echo "expected-fails-run: no entry names a probe target — nothing to execute" >&2
  exit 1
fi

n=0; bad=0
echo "$targets" | while IFS="	" read -r id tgt; do
  [ -n "$tgt" ] || continue
  n=$((n + 1))
  if ! "$BUILD" "$tgt" >/dev/null 2>&1; then
    printf 'expected-fails-run: %s FAILED — it is the probe for `%s`, so that entry now describes a protection that is not there\n' \
           "$tgt" "$id" >&2
    bad=$((bad + 1))
  fi
  # The count has to survive the subshell the pipe creates, hence the file rather than a variable.
  printf '%s %s\n' "$n" "$bad" > "${TMPDIR:-/tmp}/qtd-efr.$$"
done

read -r n bad < "${TMPDIR:-/tmp}/qtd-efr.$$" || { n=0; bad=0; }
rm -f "${TMPDIR:-/tmp}/qtd-efr.$$"
[ "${bad:-0}" -eq 0 ] || exit 1
echo "expected-fails-run OK: $n probe target(s) executed, every documented risk still covered"
