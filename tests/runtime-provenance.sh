#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
# RUNTIME PROVENANCE GATE (critics r13 #1).
#
# The generator COPIES a handful of runtime sources verbatim into every binding it generates. That
# makes them build inputs, and a missing input edge does not fail — it goes GREEN against the copy
# from before. The audit reproduced exactly that: `sample_cornercases-ldc2` printed ALL PASS while
# `.build/libsample/gen/qtdmoc.cpp` differed from `runtime/qtmoc/qtdmoc.cpp`, and the target left the
# stale copy untouched.
#
# The dependency edge is the fix; this is the thing that notices when the fix is undone. A
# functional test cannot: it runs the wrong revision perfectly.
#
# Compares every copy found under generated/ and .build/*/gen with its origin, byte for byte.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$ROOT/runtime"

# THE DIRECTORIES THE BUILD SAYS IT WROTE, passed as arguments. Without them this compared
# whatever happened to be on disk: delete a producer's output and the gate counted fewer copies
# and still said OK — measured, 52 became 49 and stayed green. A check that shrinks silently is
# the same defect as a corpus gate that checks nothing, and this file exists to catch a build
# INPUT that is out of date, so it cannot also be the thing that quietly stops looking.
missing=0
for d in "$@"; do
    [ -d "$d" ] || {
        echo "runtime-provenance FAIL: $d does not exist" >&2
        echo "    the build says a generator writes there, so either it has not run in this tree" >&2
        echo "    or its output was removed; either way the copies it owns went unchecked." >&2
        missing=$((missing + 1))
    }
done

bad=0
checked=0
for origin in "$SRC"/qtmoc/qtdmoc.cpp "$SRC"/qtmoc/qtdmoc_qml.cpp "$SRC"/qtmoc/qtmoc.d \
              "$SRC"/holder/qtd_holder.cpp "$SRC"/holder/holder.d; do
    [ -f "$origin" ] || continue
    base=$(basename "$origin")
    # every place the generator may have put a copy
    for copy in "$ROOT"/generated/*/*/"$base" "$ROOT"/.build/*/gen/"$base"; do
        [ -f "$copy" ] || continue
        checked=$((checked + 1))
        if ! cmp -s "$origin" "$copy"; then
            echo "runtime-provenance FAIL: $copy is NOT the current $base" >&2
            echo "    a binding is being built from a runtime revision that is not in the tree;" >&2
            echo "    the copy is a build INPUT and something is missing its dependency edge." >&2
            bad=$((bad + 1))
        fi
    done
done

if [ "$checked" -eq 0 ]; then
    # NOT `exit 0`. "Nothing has been generated yet" is indistinguishable from "the generators
    # ran and wrote nothing", and this gate is the one that would notice the second.
    echo "runtime-provenance FAIL: no generated copies found at all" >&2
    echo "    nothing has been generated in this tree, so nothing was verified." >&2
    exit 1
fi
[ "$missing" -eq 0 ] || exit 1
[ "$bad" -eq 0 ] || exit 1
# THE COVERAGE IS PART OF THE VERDICT. `OK: 52` and `OK: 49` read the same to a person scanning a
# report, and the difference between them was a producer whose output had vanished. Saying how many
# directories were declared makes a shrinking check visible in the row itself.
echo "runtime-provenance OK: $checked verbatim copy(ies) in $# declared directory(ies) are byte-identical to their origin"
