#!/bin/sh
# -O3 IS A PIPELINE, not a compiler flag: "compile everything that RENDERS THE SAME".
#
# The compiler cannot decide that alone — it does not render — so the check is here. Each document
# is compiled greedily, rendered, and compared with the engine's own frame. What matches stays
# compiled. What does not is DEMOTED to -O0, where Qt runs the document itself and the frame is the
# engine's by construction.
#
# That is the whole promise: not that everything compiles, but that everything renders the same.
# A document is only a failure when NO level renders the same — those are printed as UNPLACED and
# are the only thing standing between this and feature complete.
#
# The second argument is a Controls STYLE by name, or any DIRECTORY of .qml files. Qt's own styles
# are a narrow, disciplined dialect — `T.Something` roots, declared properties, almost no loose JS —
# and an application's QML is not that. Pointing this at a real app is the only way the promise
# means anything outside the framework's own documents.
#
#   o3.sh <scratch> <StyleName|/path/to/dir>
set -u
SP="$1"; ST="$2"
case "$ST" in
  /*) B="$ST"; ST=$(basename "$ST") ;;
   *) B=/usr/lib/qt6/qml/QtQuick/Controls/$ST ;;
esac
L=/home/caetano/lab/qt-dlang-gen/.build/qt-6.11-cxx-controls
G=/home/caetano/lab/qt-dlang-gen/generated/qt-6.11/cxx-controls
D="$SP/o3_$ST"; mkdir -p "$D"
ROOT=/home/caetano/lab/qt-dlang-gen
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

for f in $(find "$B" -name '*.qml' -not -path '*/node_modules/*' | sort); do
  n=$(basename "$f" .qml)
  if ! timeout 30 "$L/qmlrender" "$f" "$D/$n.eng.png" >/dev/null 2>&1 </dev/null || [ ! -s "$D/$n.eng.png" ]; then
    echo "$n UNJUDGEABLE (the engine renders no frame for it standalone)" >> "$OUT"; continue
  fi
  if build_at -Ox ox "$n" "$f" && cmp -s "$D/${n}_ox.png" "$D/$n.eng.png"; then
    # ...and the VALUE axis beside the frame. Two frames can match while a property does not: the
    # frame is offscreen software rendering at the implicit size, and a control that draws small
    # hides a lot. Every property of every named object is compared here, which is the axis that
    # found the deferred transitions, the gradients and every ordering defect on record.
    "$L/qmltc-d" --objpaths "$f" "I$n" --qmlmap "$G/qmlmap.tsv" -I "$B" > "$D/$n.objs" 2>/dev/null
    if timeout 30 "$D/${n}_ox.bin" --dumpall 2>/dev/null | sort > "$D/$n.dall" \
       && timeout 30 "$L/qmlvalues" "$f" --dumpall "$D/$n.objs" 2>/dev/null | sort > "$D/$n.qall" \
       && [ -s "$D/$n.qall" ]; then
      # Through the CENSUS, not a raw diff: a path the oracle marks `<missing>` is not a
      # disagreement, it is a path it cannot walk — Qt defers a Transition's animations, so at rest
      # the engine has none and we have ours. Counting those would report six Fusion documents as
      # wrong when this project's own tooling says they are not.
      cp "$D/$n.dall" "$D/$n.dall.s"; cp "$D/$n.qall" "$D/$n.qall.s"
      real=$(python3 "$ROOT/tools/qmltc-value-census.py" "$D" 2>/dev/null | awk '
        $1=="value-diff"||$1=="only-ours"||$1=="only-engine" {t+=$2} END {print t+0}')
      rm -f "$D/$n.dall.s" "$D/$n.qall.s"
      if [ "${real:-0}" -eq 0 ]; then echo "$n COMPILED" >> "$OUT"
      else echo "$n COMPILED values-differ ($real)" >> "$OUT"; fi
    else
      echo "$n COMPILED values-unmeasured" >> "$OUT"
    fi
    continue
  fi
  # ...it did not render the same, so it does not get into -O3. Down to the floor.
  if build_at -O0 o0 "$n" "$f" && cmp -s "$D/${n}_o0.png" "$D/$n.eng.png"; then
    echo "$n DEMOTED to -O0" >> "$OUT"; continue
  fi
  echo "$n UNPLACED (no level renders the engine's frame)" >> "$OUT"
done
echo DONE >> "$OUT"
printf '%-10s compiled=%s demoted=%s UNPLACED=%s unjudgeable=%s values-differ=%s\n' "$ST" \
  "$(grep -c ' COMPILED' "$OUT")" "$(grep -c ' DEMOTED' "$OUT")" \
  "$(grep -c ' UNPLACED' "$OUT")" "$(grep -c ' UNJUDGEABLE' "$OUT")" \
  "$(grep -c ' COMPILED values-differ' "$OUT")"
