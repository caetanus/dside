#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
# -O3 IS A PIPELINE, not a compiler flag: "compile everything that BEHAVES THE SAME".
#
# The compiler cannot decide that alone — it does not render and it does not run — so the check is
# here. Each document is compiled greedily, then judged on TWO axes: the rendered frame must equal
# the engine's, and every property of every named object must equal the engine's. A document that
# fails EITHER axis is DEMOTED to -O0, where Qt runs the document itself and both axes hold by
# construction.
#
# The two axes are not redundant. The frame is offscreen software rendering at the implicit size,
# and a control that draws small hides a great deal; the value axis is what found the deferred
# transitions, the gradients and every ordering defect on record. Judging on the frame alone let 21
# documents into -O3 while a property disagreed — a false positive of exactly the kind this scale
# exists to prevent, so the value axis now DEMOTES rather than annotates.
#
# That is the whole promise: not that everything compiles, but that everything behaves the same.
# A document is only a failure when NO level does — those are printed as UNPLACED and are the only
# thing standing between this and feature complete.
#
# The second argument is a Controls STYLE by name, or any DIRECTORY of .qml files. Qt's own styles
# are a narrow, disciplined dialect — `T.Something` roots, declared properties, almost no loose JS —
# and an application's QML is not that. Pointing this at a real app is the only way the promise
# means anything outside the framework's own documents.
#
#   o3.sh <scratch> <StyleName|/path/to/dir> [builddir] [gendir]
set -u
SP="$1"; ST="$2"

# ...from the SCRIPT's own location and from Qt itself, never from an absolute path. A gate wired to
# one workstation does not fail elsewhere — `o3GateTargets` emits nothing when the style directory
# is missing, so the strongest check in the repo would silently vanish from another machine's graph
# instead of going red.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
L=${3:-${QTD_BUILD:-$ROOT/.build/qt-6.11-cxx-controls}}
G=${4:-${QTD_GEN:-$ROOT/generated/qt-6.11/cxx-controls}}
QMLDIR=${QTD_QML_DIR:-$(qtpaths6 --query QT_INSTALL_QML 2>/dev/null \
                     || qtpaths --query QT_INSTALL_QML 2>/dev/null || echo /usr/lib/qt6/qml)}
case "$ST" in
  /*) B="$ST"; ST=$(basename "$ST") ;;
   *) B=$QMLDIR/QtQuick/Controls/$ST ;;
esac
D="$SP/o3_$ST"; mkdir -p "$D"
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software
OUT="$SP/o3_$ST.txt"; : > "$OUT"

# A DOCUMENT NEVER TAKES THIS LONG; a loaded machine does. At 30s the gate reported Material's
# SearchField as UNPLACED during a full build and placed it in every run before and after — the
# -O0 render simply expired while the rest of the matrix compiled beside it. Standalone that same
# document builds, renders and matches the engine byte for byte. A gate whose verdict depends on
# machine load is not a gate, and a false red on the strongest check here costs more than the wait.
TMO=${QTD_GATE_TIMEOUT:-180}

build_at() {  # build_at <levelflag> <tag> <name> <file>  -> $D/<name>_<tag>.png
              # The TAG is separate from the flag because a D module name cannot carry `.-Ox.`:
              # ldc2 refuses "non-identifier characters in filename", which is how the first run of
              # this script reported every document as uncompilable.
  "$L/qmltc-d" --dump "$1" "$4" "I$3" --qmlmap "$G/qmlmap.tsv" -I "$B" > "$D/${3}_$2.d" 2>"$D/${3}_$2.diag" || true
  ldc2 -of="$D/${3}_$2.bin" "$D/${3}_$2.d" "$L/qtd_qmltc_app.o" "$L/qtd_render.o" -I"$G" \
    -L--start-group -L="$L/libbinding_ldc2.a" -L="$L/libshims.a" -L--end-group \
    -L-lQt6QuickControls2Impl -L-lQt6QuickTemplates2 -L-lQt6Quick -L-lQt6OpenGL -L-lQt6QmlModels \
    -L-lQt6Qml -L-lQt6Network -L-lQt6Gui -L-lQt6Core -L-lstdc++ > "$D/${3}_$2.link" 2>&1 </dev/null || return 1
  # A CRASH IS NOT A LINK FAILURE, and saying "does not build or run" for both is how five of them
  # hid in plain sight: every green run printed five `Segmentation fault` lines from this line and
  # placed the documents at -O0, so the gate passed and the behaviour was the engine's. They were
  # all Material, all `layer.effect`, and all one cause (a QQmlComponent with no creation context —
  # see qtd_make_component). Exit 2 is a crash, exit 1 is anything else, and the caller says which.
  timeout "$TMO" "$D/${3}_$2.bin" --render "$D/${3}_$2.png" >/dev/null 2>&1 </dev/null
  rc=$?
  [ "$rc" -ge 128 ] && return 2
  [ "$rc" -eq 0 ] || return 1
  [ -s "$D/${3}_$2.png" ] || return 1
  return 0
}

# judge <tag> <name> <file> -> 0 both axes agree | 1 frame differs | 2 values unmeasurable | N>2 values differ
# `values unmeasurable` is NOT an accepted outcome: a level that cannot be measured has not been
# proven, and the level below it can be. It demotes like a disagreement.
judge() {
  cmp -s "$D/${2}_$1.png" "$D/$2.eng.png" || return 1
  "$L/qmltc-d" --objpaths "$3" "I$2" --qmlmap "$G/qmlmap.tsv" -I "$B" > "$D/$2.objs" 2>/dev/null
  rm -rf "$D/cen"; mkdir -p "$D/cen"
  timeout "$TMO" "$D/${2}_$1.bin" --dumpall 2>/dev/null | sort > "$D/cen/$2.dall.s" || return 2
  timeout "$TMO" "$L/qmlvalues" "$3" --dumpall "$D/$2.objs" 2>/dev/null | sort > "$D/cen/$2.qall.s" || return 2
  [ -s "$D/cen/$2.qall.s" ] || return 2
  # ...AND EVERY ACCUSATION IS RE-VERIFIED AGAINST A FRESH ENGINE RUN. A path the engine cannot
  # reproduce cannot be a verdict about us: Material's SpinBox background carries
  # `placeholderTextHAlign`, a private property Qt reads out of uninitialised memory, and three
  # consecutive engine runs answered 1154029312, 1895307008 and -1856497920.
  #
  # Sampling the engine twice UP FRONT is not enough, and the way that failed is worth keeping: two
  # samples of a random value can AGREE by chance, the path then counts as measurable, it
  # legitimately differs from ours, and Material's SearchField comes out UNPLACED in one run and
  # placed in the next. A probabilistic filter under a gate that must not produce false positives
  # is the same defect one level up.
  #
  # So the loop verifies rather than pre-screens: census, and while it accuses anything, ask the
  # engine again and drop every path where it now contradicts its own earlier answer. A document
  # that really differs costs one extra engine run and still reports; a document accused by
  # uninitialised memory converges to zero. Bounded, because a genuine difference never clears.
  flaky=0
  # NAMED first, sampled second. A property Qt reads out of uninitialised memory is often 0, so
  # repeated engine runs can agree by chance — see tests/qmltc/unreproducible.txt, which exists
  # because that let the same document be UNPLACED in one build and placed in the next.
  : > "$D/$2.flaky"
  if [ -f "$ROOT/tests/qmltc/unreproducible.txt" ]; then
    awk 'NF && $1 !~ /^#/ {print $1}' "$ROOT/tests/qmltc/unreproducible.txt" | sort -u > "$D/$2.named"
    awk -F'\t' 'NR==FNR{n[$1];next} { p=$1; sub(/^.*\./, "", p); if (p in n) print $1 }' \
        "$D/$2.named" "$D/cen/$2.qall.s" | sort -u >> "$D/$2.flaky"
    awk -F'\t' 'NR==FNR{n[$1];next} { p=$1; sub(/^.*\./, "", p); if (p in n) print $1 }' \
        "$D/$2.named" "$D/cen/$2.dall.s" | sort -u >> "$D/$2.flaky"
    sort -u "$D/$2.flaky" -o "$D/$2.flaky"
    flaky=$(wc -l < "$D/$2.flaky")
    if [ "$flaky" -gt 0 ]; then
      for side in "$D/cen/$2.qall.s" "$D/cen/$2.dall.s"; do
        awk -F'\t' 'NR==FNR{f[$1];next} !($1 in f)' "$D/$2.flaky" "$side" > "$side.f" && mv "$side.f" "$side"
      done
    fi
  fi
  round=0
  while : ; do
    real=$(python3 "$ROOT/tools/qmltc-value-census.py" "$D/cen" 2>/dev/null | awk '
      $1=="value-diff"||$1=="only-ours"||$1=="only-engine" {t+=$2} END {print t+0}')
    [ "${real:-0}" -eq 0 ] && return 0
    round=$((round + 1))
    [ "$round" -gt 4 ] && break
    timeout "$TMO" "$L/qmlvalues" "$3" --dumpall "$D/$2.objs" 2>/dev/null | sort > "$D/$2.qall$round" || return 2
    awk -F'\t' 'NR==FNR{a[$1]=$2;next} ($1 in a) && a[$1]!=$2 {print $1}' \
        "$D/cen/$2.qall.s" "$D/$2.qall$round" | sort -u >> "$D/$2.flaky"
    sort -u "$D/$2.flaky" -o "$D/$2.flaky"
    # NOT `n`: that is the document name in the loop below, and sh has no locals. Naming the
    # counter `n` inside this function renamed the document being judged to a line count, and the
    # gate reported a document called "0".
    nflaky=$(wc -l < "$D/$2.flaky")
    [ "$nflaky" -eq "$flaky" ] && break   # the fresh run agrees with itself: the difference is ours
    flaky=$nflaky
    for side in "$D/cen/$2.qall.s" "$D/cen/$2.dall.s"; do
      awk -F'\t' 'NR==FNR{f[$1];next} !($1 in f)' "$D/$2.flaky" "$side" > "$side.f" && mv "$side.f" "$side"
    done
  done
  return $(( real > 250 ? 250 : real + 2 ))
}

for f in $(find "$B" -name '*.qml' -not -path '*/node_modules/*' | sort); do
  n=$(basename "$f" .qml)
  if ! timeout "$TMO" "$L/qmlrender" "$f" "$D/$n.eng.png" >/dev/null 2>&1 </dev/null || [ ! -s "$D/$n.eng.png" ]; then
    echo "$n UNJUDGEABLE (the engine renders no frame for it standalone)" >> "$OUT"; continue
  fi
  why=frame
  build_at -Ox ox "$n" "$f"; brc=$?
  if [ "$brc" -eq 0 ]; then
    judge ox "$n" "$f"; r=$?
    case $r in
      0) if [ "${flaky:-0}" -gt 0 ]; then
           echo "$n COMPILED ($flaky path(s) the engine does not reproduce, dropped)" >> "$OUT"
         else echo "$n COMPILED" >> "$OUT"; fi
         continue ;;
      1) why="the frame differs" ;;
      2) why="the values cannot be measured" ;;
      *) why="$(( r - 2 )) value(s) differ" ;;
    esac
  elif [ "$brc" -eq 2 ]; then
    # SAID OUT LOUD. A document that CRASHES is still placed at -O0 and still behaves like the
    # engine, so the gate stays green — but the state file now names it, because five of these hid
    # behind "does not build or run" for the whole life of this gate.
    why="it CRASHES"
  else
    why="it does not build or run"
  fi
  # ...it did not behave the same, so it does not get into -O3. Down to the floor, judged the same
  # way — Qt builds the document there, so both axes are the engine's by construction, and a
  # disagreement at -O0 means the HARNESS is wrong rather than the compiler.
  if build_at -O0 o0 "$n" "$f" && judge o0 "$n" "$f"; then
    echo "$n DEMOTED to -O0 ($why at -Ox)" >> "$OUT"; continue
  fi
  echo "$n UNPLACED (no level matches the engine; at -Ox $why)" >> "$OUT"
done
echo DONE >> "$OUT"
printf '%-10s compiled=%s demoted=%s UNPLACED=%s unjudgeable=%s\n' "$ST" \
  "$(grep -c ' COMPILED' "$OUT")" "$(grep -c ' DEMOTED' "$OUT")" \
  "$(grep -c ' UNPLACED' "$OUT")" "$(grep -c ' UNJUDGEABLE' "$OUT")"
