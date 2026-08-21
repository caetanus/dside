#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
# THE AUDITED LIST HAS TO STAY AUDITED.
#
# A class in the spec's `disposable` list is one the binding will DELETE when it still owns it. That
# is safe exactly as long as every API that could take ownership of it is declared — a transfer
# MISSING from the list leaves the binding deleting something Qt also deletes. The list was walked
# by hand against Qt's documentation once; this makes the walk a build step, so binding one more
# method that takes such a type cannot silently widen the surface.
#
# For every disposable class C, every generated method that takes a C must be classified:
#   transfer_in    Qt takes ownership       (spec "transfer_in")
#   transfer_out   we get it back           (spec "transfer_out")
#   no_transfer    it only reads/uses it    (spec "no_transfer" — the explicit "I checked" list)
# Anything else is reported and fails. `no_transfer` exists because "not a transfer" is a FINDING,
# not an absence: without it, an unclassified method and a checked-and-harmless one look identical.
#
#   ownership-gate.sh <spec.json> <generated dir>
set -eu
. "$(dirname -- "$0")/pybin.sh"          # $PY: the python that actually runs
SPEC="$1"; GEN="$2"

"$PY" - "$SPEC" "$GEN" <<'PY'
import json, re, sys, pathlib

spec = json.load(open(sys.argv[1]))
gen  = pathlib.Path(sys.argv[2])
disposable = set(spec.get("disposable", []))
if not disposable:
    print("ownership-gate: no disposable classes in %s — nothing can be wrongly deleted" % sys.argv[1])
    sys.exit(0)

declared = set(spec.get("transfer_in", [])) | set(spec.get("transfer_out", [])) \
         | set(spec.get("no_transfer", []))
ctor_parents = spec.get("ctor_parents", {})

# `final void addChild(QTreeWidgetItem a0) {` / `static X foo(...)` — the generated shape.
meth = re.compile(r'^\s+(?:final|static)\s+[\w.\[\]()]+\s+(\w+)\(([^)]*)\)')
unclassified = []
checked = 0

for f in sorted(gen.glob("qt/*/*.d")):
    cls = None
    for line in f.read_text().splitlines():
        m = re.match(r'^(?:final )?class (\w+)', line)
        if m:
            cls = m.group(1)
            continue
        if cls is None:
            continue
        m = meth.match(line)
        if not m:
            continue
        name, params = m.group(1), m.group(2)
        for i, p in enumerate(x.strip() for x in params.split(",") if x.strip()):
            ty = p.split()[0]
            if ty not in disposable:
                continue
            checked += 1
            key = "%s::%s/%d" % (cls, name, i)
            if key not in declared:
                unclassified.append(key)

# ...and the constructors of the disposable class itself, whose parent parameter adopts it. An
# EMPTY list is a valid answer — "checked: no constructor parameter adopts this" — and has to be
# written down for the same reason `no_transfer` does: an unanswered question and an answered one
# must not look the same. QTextStream is the case: nothing in the binding takes a QTextStream at
# all, so its transfer surface is empty and disposal carries no audit risk.
for c in disposable:
    if c not in ctor_parents:
        unclassified.append("%s::<ctor>  (no ctor_parents entry: does a parent argument adopt it? "
                            "write [] if none)" % c)

if unclassified:
    print("ownership-gate: %d parameter(s) of a DISPOSABLE type are unclassified." % len(unclassified),
          file=sys.stderr)
    print("Each must be listed in transfer_in, transfer_out or no_transfer in %s:" % sys.argv[1],
          file=sys.stderr)
    for k in unclassified:
        print("  " + k, file=sys.stderr)
    sys.exit(1)

print("ownership-gate OK: %d parameter(s) of %d disposable class(es), every one classified"
      % (checked, len(disposable)))
PY
