# The RENDER half of the criterion, over Qt's own Basic controls: put each document in a window and
# compare the PNGs byte for byte. A property dump can match while the frame does not — and a
# document with no Item root (a Popup) renders on NEITHER side, which this reports rather than
# hiding. Usage: bash tests/qmltc/render_corpus.sh <scratchdir-with-cr/>
set -u
SP=$1; B=/usr/lib/qt6/qml/QtQuick/Controls/Basic; L=/home/caetano/lab/qt-dlang-gen/.build/qt-6.11-cxx-controls
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software
mkdir -p "$SP/rnd"; : > "$SP/render.txt"
for f in $B/*.qml; do
  n=$(basename "$f" .qml)
  [ -x "$SP/cr/i$n.bin" ] || continue
  timeout 30 "$SP/cr/i$n.bin" --render "$SP/rnd/$n.d.png" >/dev/null 2>&1 </dev/null || { echo "$n ours-failed" >> "$SP/render.txt"; continue; }
  timeout 30 "$L/qmlrender" "$f" "$SP/rnd/$n.q.png" >/dev/null 2>&1 </dev/null || { echo "$n engine-failed" >> "$SP/render.txt"; continue; }
  [ -s "$SP/rnd/$n.d.png" ] && [ -s "$SP/rnd/$n.q.png" ] || { echo "$n no-image" >> "$SP/render.txt"; continue; }
  if cmp -s "$SP/rnd/$n.d.png" "$SP/rnd/$n.q.png"; then echo "$n SAME $(stat -c%s "$SP/rnd/$n.d.png")" >> "$SP/render.txt"
  else echo "$n differ $(stat -c%s "$SP/rnd/$n.d.png")/$(stat -c%s "$SP/rnd/$n.q.png")" >> "$SP/render.txt"; fi
done
echo DONE >> "$SP/render.txt"
