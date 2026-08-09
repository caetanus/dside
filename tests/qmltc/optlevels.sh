#!/bin/sh
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
QT_QPA_PLATFORM=offscreen "$BDIR/qmlvalues" "$QMLFILE" --dumpall "$OUT/objs" 2>/dev/null \
  | sort > "$OUT/engine.txt"
if [ ! -s "$OUT/engine.txt" ]; then
  echo "optlevels: the ENGINE dumps nothing for $QMLFILE — nothing to compare against" >&2
  exit 1
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
  QT_QPA_PLATFORM=offscreen "$OUT/o$O.bin" --dumpall 2>"$OUT/o$O.err" | sort > "$OUT/o$O.txt"
  if ! diff -q "$OUT/engine.txt" "$OUT/o$O.txt" > /dev/null; then
    echo "optlevels: -O$O DISAGREES with the engine on $QMLFILE" >&2
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
