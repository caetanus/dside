#!/bin/sh
. "$(dirname -- "$0")/../pybin.sh"          # $PY: the python that actually runs
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
# THE LEVELS MUST AGREE. -O is a degree of CERTAINTY, not of speed:
#
#   -O1  statically typed translation only
#   -O2  ...and QVariant where the type is only known at run time
#
# These two are the CERTAINTY levels: neither emits containment, delegation or a document with a
# skipped member, so each must agree with the engine unconditionally, and with the other. A
# disagreement here is a false positive by definition — the level promised something it did not
# deliver.
#
# -O3 is deliberately NOT here. It is not a compiler verdict but a pipeline: it compiles greedily
# and then DEMOTES whatever does not match, so "-O3 disagrees" is its normal, correct intermediate
# state rather than a defect. Asserting agreement on it made this script fail on ASignalCross for
# two real -Ox gaps the o3 gate had already caught and demoted. That gate is where -O3 is judged.
#
# A document below its level's bar is handed to the engine WHOLE, which is not a failure: it is the
# level choosing certainty. The comparison still applies, because that is the one form guaranteed to
# behave like the engine.
#
#   optlevels.sh <qmltc-d> <qmlmap.tsv> <file.qml> <ClassName> <outdir> <builddir> <gendir> <dc> <libs...>
set -e
TOOL="$1"; QMLMAP="$2"; QMLFILE="$3"; CLS="$4"; OUT="$5"; BDIR="$6"; GDIR="$7"; DC="$8"
shift 8
LIBS="$*"

mkdir -p "$OUT"
# The STRONG protocol, `--objpaths` + `--dumpall`: both sides enumerate every property of every
# object named. The label protocol cannot be used here — a document handed to the engine whole has
# no labels of ours to list, and comparing on labels would silently compare nothing.
# `|| true`: exit 3 is PARTIAL, a verdict about the document and not a failure of this call — and
# under `set -e` it aborted the whole script with no message at all. Every document in the
# application corpus that skips a member reached this line and reported nothing.
"$TOOL" --objpaths "$QMLFILE" "$CLS" --qmlmap "$QMLMAP" -I "$(dirname "$QMLFILE")" \
        > "$OUT/objs" 2>/dev/null || true
# 2>/dev/null used to swallow the one message that mattered. A qmlvalues that cannot START — no Qt
# DLLs on PATH, which is the normal shape of a Windows failure — produces an empty dump, and the
# check below then called the DOCUMENT unjudgeable. Keep the stderr and look at it first.
QT_QPA_PLATFORM=offscreen "$BDIR/qmlvalues" "$QMLFILE" --dumpall "$OUT/objs" 2>"$OUT/engine.diag" \
  | sort > "$OUT/engine.txt"
if [ ! -s "$OUT/engine.txt" ] \
   && grep -q "error while loading shared libraries\|is not recognized\|cannot execute" \
             "$OUT/engine.diag" 2>/dev/null; then
  echo "optlevels: the engine binary did not run at all:" >&2
  sed 's/^/    /' "$OUT/engine.diag" >&2
  exit 1
fi
if [ ! -s "$OUT/engine.txt" ]; then
  # UNJUDGEABLE, not failed. The o3 gate has always given a document the engine cannot build
  # standalone its own column; this script called it a disagreement, and so reported Fusion's
  # TextFieldBackground as a broken promise when there is nothing to compare against at all. Exit 2
  # so a caller can tell "nothing to judge" from "judged, and wrong".
  echo "optlevels: the ENGINE dumps nothing for $QMLFILE — unjudgeable, not compared" >&2
  exit 2
fi

for O in 1 2; do
  "$TOOL" --dump "-O$O" "$QMLFILE" "$CLS" --qmlmap "$QMLMAP" -I "$(dirname "$QMLFILE")" \
          > "$OUT/o$O.d" 2>"$OUT/o$O.diag" || true
  # shellcheck disable=SC2086
  # ...and the RENDER helper when the binding has one. An Item root emits `--render`/`--click`/
  # `--run` unconditionally, so a document with a visual root does not link without it — which is
  # every document in the application corpus and none in the QtQml-only one this script was written
  # against.
  [ -f "$BDIR/qtd_render.o" ] && RENDER="$BDIR/qtd_render.o" || RENDER=""
  # shellcheck disable=SC2086
  "$DC" -of="$OUT/o$O.bin" "$OUT/o$O.d" "$BDIR/qtd_qmltc_app.o" $RENDER -I"$GDIR" \
        -L--start-group -L="$BDIR/libbinding_$DC.a" -L="$BDIR/libshims.a" -L--end-group $LIBS \
        > "$OUT/o$O.link" 2>&1 \
    || { echo "optlevels: -O$O does not link" >&2; sed -n '1,5p' "$OUT/o$O.link" >&2; exit 1; }
  # OUR BINARY'S FAILURE IS NOT A DISAGREEMENT. Piping straight into `sort` threw away its exit
  # status, and `o$O.err` was written and never read — so when it crashed, stdout was empty, the
  # census saw every engine property as `only-engine`, and this script reported
  # "DISAGREES with the engine (N real difference(s))" while the actual error sat unread in a file
  # beside it. That is why the intermittency observed under parallel load stayed uncharacterised for
  # three sightings: the message pointed at semantics, and the cause was a process that died.
  # (The engine's own empty dump is already handled above, as unjudgeable.)
  QT_QPA_PLATFORM=offscreen "$OUT/o$O.bin" --dumpall > "$OUT/o$O.raw" 2>"$OUT/o$O.err"
  rc=$?
  sort "$OUT/o$O.raw" > "$OUT/o$O.txt"
  if [ "$rc" -ne 0 ] || [ ! -s "$OUT/o$O.txt" ]; then
    echo "optlevels: -O$O produced no dump for $QMLFILE (exit $rc) — OUR binary, not the engine" >&2
    sed -n '1,5p' "$OUT/o$O.err" >&2
    exit 1
  fi
  # THROUGH THE CENSUS, like the o3 gate, and not a raw diff. A path the oracle marks `<missing>`
  # is one it cannot walk, not a disagreement: Qt defers a Transition's animations, so at rest the
  # engine has none and we have ours. A raw diff called five Basic documents wrong on that alone —
  # the harness reporting itself, which is exactly what the census was written to stop. Named
  # non-reproducible properties are dropped too, for the reason in unreproducible.txt.
  RT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
  rm -rf "$OUT/cen$O"; mkdir -p "$OUT/cen$O"
  cp "$OUT/o$O.txt" "$OUT/cen$O/d.dall.s"; cp "$OUT/engine.txt" "$OUT/cen$O/d.qall.s"
  if [ -f "$RT/tests/qmltc/unreproducible.txt" ]; then
    awk 'NF && $1 !~ /^#/ {print $1}' "$RT/tests/qmltc/unreproducible.txt" | sort -u > "$OUT/named"
    for side in "$OUT/cen$O/d.dall.s" "$OUT/cen$O/d.qall.s"; do
      awk -F'\t' 'NR==FNR{n[$1];next} { p=$1; sub(/^.*\./, "", p); if (!(p in n)) print }' \
          "$OUT/named" "$side" > "$side.f" && mv "$side.f" "$side"
    done
  fi
  real=$("$PY" "$RT/tools/qmltc-value-census.py" "$OUT/cen$O" 2>/dev/null | awk '
    $1=="value-diff"||$1=="only-ours"||$1=="only-engine" {t+=$2} END {print t+0}')
  if [ "${real:-0}" -ne 0 ]; then
    echo "optlevels: -O$O DISAGREES with the engine on $QMLFILE ($real real difference(s))" >&2
    diff "$OUT/engine.txt" "$OUT/o$O.txt" >&2 || true
    exit 1
  fi
done

# ...and with each other, which is the stronger statement: the scale is only meaningful if moving
# along it changes how much is compiled and nothing else.
diff -q "$OUT/o1.txt" "$OUT/o2.txt" > /dev/null || { echo "optlevels: -O1 and -O2 disagree" >&2; exit 1; }

o1=$(grep -c "handing the DOCUMENT to the engine" "$OUT/o1.diag" 2>/dev/null || true)
o2=$(grep -c "handing the DOCUMENT to the engine" "$OUT/o2.diag" 2>/dev/null || true)
echo "optlevels OK: $(basename "$QMLFILE") agrees with the engine at -O1 and -O2" \
     "(-O1 delegated the document: $o1, -O2: $o2)"
