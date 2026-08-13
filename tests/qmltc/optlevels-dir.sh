#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
# THE CERTAINTY LEVELS, OVER QT'S OWN CORPUS — where until now there was only a COUNT.
#
# The README says -O1 compiles 111 of Qt's 329 Controls documents and that nothing crosses untyped
# at that level. The first half was measured; the second was not. `qmltc-optlevels-*` checks -O1 and
# -O2 against the engine, but only over the application corpus, and the o3 gate checks -Ox — which
# is DIFFERENT CODE, so a green there says nothing about the code -O1 emits.
#
# So this runs the same per-document check over a style. A document the level hands to the engine is
# skipped: it agrees by construction, and running it would inflate the number with tautologies. What
# is reported is how many were genuinely COMPILED at that level and then matched property for
# property.
#
#   optlevels-dir.sh <qmltc-d> <qmlmap.tsv> <style dir> <outdir> <builddir> <gendir> <dc> <libs...>
set -u
TOOL="$1"; QMLMAP="$2"; DIR="$3"; OUT="$4"; BDIR="$5"; GDIR="$6"; DC="$7"
shift 7
LIBS="$*"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

mkdir -p "$OUT"
# Documents already KNOWN to break the level's promise, by name and with the reason. Named rather
# than skipped: the gate still fails on anything new, and the list can only shrink by fixing
# something. See optlevels-known.txt.
KNOWN="$HERE/optlevels-known.txt"
checked=0; skipped=0; bad=0; known=0; unjudgeable=0
for f in $(find "$DIR" -name '*.qml' | sort); do
  n=$(basename "$f" .qml)
  # Does -O1 actually compile it? If it hands the document over, there is nothing of ours to judge.
  "$TOOL" --dump -O1 "$f" "I$n" --qmlmap "$QMLMAP" -I "$DIR" >/dev/null 2>"$OUT/$n.probe" || true
  if grep -q "handing the DOCUMENT to the engine" "$OUT/$n.probe"; then
    skipped=$((skipped + 1)); continue
  fi
  sh "$HERE/optlevels.sh" "$TOOL" "$QMLMAP" "$f" "I$n" "$OUT/$n" "$BDIR" "$GDIR" "$DC" $LIBS \
     > "$OUT/$n.log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    checked=$((checked + 1))
  elif [ "$rc" -eq 2 ]; then
    # The engine builds nothing for it standalone. That is the o3 gate's UNJUDGEABLE column, and
    # not a verdict about us in either direction.
    unjudgeable=$((unjudgeable + 1))
  elif [ -f "$KNOWN" ] && grep -qE "^$(basename "$DIR")/$n[[:space:]]" "$KNOWN"; then
    known=$((known + 1))
    echo "optlevels-dir: $n disagrees, and is a KNOWN broken promise (optlevels-known.txt)" >&2
  else
    bad=$((bad + 1))
    echo "optlevels-dir: $n DISAGREES — $(grep -m1 optlevels: "$OUT/$n.log" || echo 'see' "$OUT/$n.log")" >&2
  fi
done

[ "$bad" -eq 0 ] || { echo "optlevels-dir: $bad document(s) compiled at a certainty level and did not match" >&2; exit 1; }
[ "$checked" -gt 0 ] || { echo "optlevels-dir: NOTHING was checked in $DIR — every document was handed over, which makes this gate vacuous" >&2; exit 1; }
echo "optlevels-dir OK ($(basename "$DIR")): $checked document(s) compiled at -O1/-O2 agree with the engine on every property; $skipped handed over; $unjudgeable unjudgeable; $known known broken promise(s)"
