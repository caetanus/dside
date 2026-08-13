# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
# The VALUE differential over a Controls style: every property of every object our side can name,
# compared against the engine's answer for the same object paths. Usage:
#   bash tests/qmltc/values_corpus.sh <scratchdir> <style> <outdir-under-scratch>
# e.g. ... /tmp/scratch Basic cr   — reads <outdir>/i<Name>.bin built by the corpus script and
# writes <outdir>/<Name>.dall.s and .qall.s for tools/qmltc-diff-census.py to read.
set -u
SP=$1; STYLE=${2:-Basic}; OUT=${3:-cr}
B=/usr/lib/qt6/qml/QtQuick/Controls/$STYLE
L=/home/caetano/lab/qt-dlang-gen/.build/qt-6.11-cxx-controls
G=/home/caetano/lab/qt-dlang-gen/generated/qt-6.11/cxx-controls
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software
: > "$SP/values_$STYLE.txt"
for f in $B/*.qml; do
  n=$(basename "$f" .qml)
  [ -x "$SP/$OUT/i$n.bin" ] || continue
  "$L/qmltc-d" --objpaths "$f" "I$n" --qmlmap "$G/qmlmap.tsv" -I "$B" > "$SP/$OUT/$n.objs" 2>/dev/null
  timeout 30 "$SP/$OUT/i$n.bin" --dumpall > "$SP/$OUT/$n.dall" 2>/dev/null </dev/null || { echo "$n ours-died" >> "$SP/values_$STYLE.txt"; continue; }
  timeout 30 "$L/qmlvalues" "$f" --dumpall "$SP/$OUT/$n.objs" > "$SP/$OUT/$n.qall" 2>/dev/null </dev/null || { echo "$n oracle-died" >> "$SP/values_$STYLE.txt"; continue; }
  sort "$SP/$OUT/$n.dall" > "$SP/$OUT/$n.dall.s"; sort "$SP/$OUT/$n.qall" > "$SP/$OUT/$n.qall.s"
  d=$(diff "$SP/$OUT/$n.dall.s" "$SP/$OUT/$n.qall.s" | grep -c '^[<>]')
  tot=$(wc -l < "$SP/$OUT/$n.dall.s")
  if [ "$d" -eq 0 ]; then echo "$n MATCH $tot" >> "$SP/values_$STYLE.txt"; else echo "$n differ $((d/2))/$tot" >> "$SP/values_$STYLE.txt"; fi
done
echo DONE >> "$SP/values_$STYLE.txt"
