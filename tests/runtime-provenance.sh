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
    echo "runtime-provenance: no generated copies found — nothing has been generated yet" >&2
    exit 0
fi
[ "$bad" -eq 0 ] || exit 1
echo "runtime-provenance OK: $checked verbatim copy(ies) are byte-identical to their origin"
