# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
# The RENDER half of the criterion, over one of Qt's own Controls styles: put each document in a
# window and compare the PNGs byte for byte. A property dump can match while the frame does not —
# and a document with no Item root (a Popup) renders on NEITHER side, which this reports rather than
# hiding. Usage:
#   bash tests/qmltc/render_corpus.sh <scratchdir> [Style] [outdir-under-scratch]
# e.g. ... /tmp/scratch Fusion fu   — reads <outdir>/i<Name>.bin built by the corpus script.
# Style and outdir are parameters for the same reason values_corpus.sh takes them: a gradient that
# only Fusion draws is invisible to a Basic-only render pass.
set -u
SP=$1; STYLE=${2:-Basic}; OUT=${3:-cr}
B=/usr/lib/qt6/qml/QtQuick/Controls/$STYLE; L=/home/caetano/lab/qt-dlang-gen/.build/qt-6.11-cxx-controls
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software
mkdir -p "$SP/rnd_$STYLE"; : > "$SP/render_$STYLE.txt"
for f in $B/*.qml; do
  n=$(basename "$f" .qml)
  [ -x "$SP/$OUT/i$n.bin" ] || continue
  timeout 30 "$SP/$OUT/i$n.bin" --render "$SP/rnd_$STYLE/$n.d.png" >/dev/null 2>&1 </dev/null || { echo "$n ours-failed" >> "$SP/render_$STYLE.txt"; continue; }
  timeout 30 "$L/qmlrender" "$f" "$SP/rnd_$STYLE/$n.q.png" >/dev/null 2>&1 </dev/null || { echo "$n engine-failed" >> "$SP/render_$STYLE.txt"; continue; }
  [ -s "$SP/rnd_$STYLE/$n.d.png" ] && [ -s "$SP/rnd_$STYLE/$n.q.png" ] || { echo "$n no-image" >> "$SP/render_$STYLE.txt"; continue; }
  if cmp -s "$SP/rnd_$STYLE/$n.d.png" "$SP/rnd_$STYLE/$n.q.png"; then echo "$n SAME $(stat -c%s "$SP/rnd_$STYLE/$n.d.png")" >> "$SP/render_$STYLE.txt"
  else echo "$n differ $(stat -c%s "$SP/rnd_$STYLE/$n.d.png")/$(stat -c%s "$SP/rnd_$STYLE/$n.q.png")" >> "$SP/render_$STYLE.txt"; fi
done
echo DONE >> "$SP/render_$STYLE.txt"
