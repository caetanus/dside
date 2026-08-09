#!/bin/sh
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

build_at() {  # build_at <levelflag> <tag> <name> <file>  -> $D/<name>_<tag>.png
              # The TAG is separate from the flag because a D module name cannot carry `.-Ox.`:
              # ldc2 refuses "non-identifier characters in filename", which is how the first run of
              # this script reported every document as uncompilable.
  "$L/qmltc-d" --dump "$1" "$4" "I$3" --qmlmap "$G/qmlmap.tsv" -I "$B" > "$D/${3}_$2.d" 2>"$D/${3}_$2.diag" || true
  ldc2 -of="$D/${3}_$2.bin" "$D/${3}_$2.d" "$L/qtd_qmltc_app.o" "$L/qtd_render.o" -I"$G" \
    -L--start-group -L="$L/libbinding_ldc2.a" -L="$L/libshims.a" -L--end-group \
    -L-lQt6QuickControls2Impl -L-lQt6QuickTemplates2 -L-lQt6Quick -L-lQt6OpenGL -L-lQt6QmlModels \
    -L-lQt6Qml -L-lQt6Network -L-lQt6Gui -L-lQt6Core -L-lstdc++ > "$D/${3}_$2.link" 2>&1 </dev/null || return 1
  timeout 30 "$D/${3}_$2.bin" --render "$D/${3}_$2.png" >/dev/null 2>&1 </dev/null || return 1
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
  timeout 30 "$D/${2}_$1.bin" --dumpall 2>/dev/null | sort > "$D/cen/$2.dall.s" || return 2
  timeout 30 "$L/qmlvalues" "$3" --dumpall "$D/$2.objs" 2>/dev/null | sort > "$D/cen/$2.qall.s" || return 2
  [ -s "$D/cen/$2.qall.s" ] || return 2
  # ...AND THE ENGINE AGAINST ITSELF. A path the engine cannot reproduce cannot be a verdict about
  # us: Material's SpinBox background carries `placeholderTextHAlign`, a private property Qt reads
  # out of uninitialised memory, and three consecutive engine runs answered 1154029312, 1895307008
  # and -1856497920. Judged against a single engine dump, that document was unplaceable at EVERY
  # level — the harness reporting a defect the compiler does not have. So the engine is asked
  # twice and every path where it contradicts itself is dropped from both sides.
  timeout 30 "$L/qmlvalues" "$3" --dumpall "$D/$2.objs" 2>/dev/null | sort > "$D/$2.qall2" || return 2
  awk -F'\t' 'NR==FNR{a[$1]=$2;next} ($1 in a) && a[$1]!=$2 {print $1}' \
      "$D/cen/$2.qall.s" "$D/$2.qall2" | sort -u > "$D/$2.flaky"
  flaky=$(wc -l < "$D/$2.flaky")
  if [ "$flaky" -gt 0 ]; then
    for side in "$D/cen/$2.qall.s" "$D/cen/$2.dall.s"; do
      awk -F'\t' 'NR==FNR{f[$1];next} !($1 in f)' "$D/$2.flaky" "$side" > "$side.f" && mv "$side.f" "$side"
    done
  fi
  # Through the CENSUS, not a raw diff: a path the oracle marks `<missing>` is not a disagreement,
  # it is a path it cannot walk — Qt defers a Transition's animations, so at rest the engine has
  # none and we have ours. Counting those would report six Fusion documents as wrong when this
  # project's own tooling says they are not.
  real=$(python3 "$ROOT/tools/qmltc-value-census.py" "$D/cen" 2>/dev/null | awk '
    $1=="value-diff"||$1=="only-ours"||$1=="only-engine" {t+=$2} END {print t+0}')
  [ "${real:-0}" -eq 0 ] && return 0
  return $(( real > 250 ? 250 : real + 2 ))
}

for f in $(find "$B" -name '*.qml' -not -path '*/node_modules/*' | sort); do
  n=$(basename "$f" .qml)
  if ! timeout 30 "$L/qmlrender" "$f" "$D/$n.eng.png" >/dev/null 2>&1 </dev/null || [ ! -s "$D/$n.eng.png" ]; then
    echo "$n UNJUDGEABLE (the engine renders no frame for it standalone)" >> "$OUT"; continue
  fi
  why=frame
  if build_at -Ox ox "$n" "$f"; then
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
