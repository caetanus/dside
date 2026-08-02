# The BEHAVIOUR half of the render criterion: click the middle of each document and compare the
# FRAME afterwards, byte for byte. The plain render compares a document at rest and the value
# differential compares it after a MUTATION written from outside; neither sees what a control looks
# like once it has been PRESSED, which is the half a user actually touches. Nothing here picks a
# property, so nothing chooses what counts as behaviour.
#
# Usage: bash tests/qmltc/click_corpus.sh <scratchdir> [Style] [outdir-under-scratch]
# Needs render_corpus.sh to have run first: the click point is the centre of the ENGINE's frame,
# which is the only place the document's real size is already written down.
#
# A document that reads `Window.active` is UNMEASURABLE here, and the two sides cannot be made to
# agree about it: under the offscreen platform a bare QQuickWindow (ours) becomes active on
# requestActivate and a QQuickView (the engine's) does not. Measured both ways — activating only
# ours took Fusion from 28 identical to 25, and activating BOTH gave the same 25. Qt's Fusion
# Switch dims its highlight by half when the window is inactive, which is why SwitchDelegate stays
# in the differing list. Left as a difference rather than papered over.
#
# The corpus binaries LINK qtd_render.o: after any change to it they must be relinked before this
# script means anything. Re-running only the comparison once reported three extra regressions that
# were nothing but stale binaries.
set -u
SP=$1; STYLE=${2:-Basic}; OUT=${3:-cr}
B=/usr/lib/qt6/qml/QtQuick/Controls/$STYLE; L=/home/caetano/lab/qt-dlang-gen/.build/qt-6.11-cxx-controls
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software
mkdir -p "$SP/clk_$STYLE"; : > "$SP/click_$STYLE.txt"
for f in $B/*.qml; do
  n=$(basename "$f" .qml)
  [ -x "$SP/$OUT/i$n.bin" ] || continue
  # Only documents whose frame BOTH sides already produce: a click on something neither can draw
  # measures the harness, not the compiler.
  [ -s "$SP/rnd_$STYLE/$n.q.png" ] && [ -s "$SP/rnd_$STYLE/$n.d.png" ] || continue
  cmp -s "$SP/rnd_$STYLE/$n.d.png" "$SP/rnd_$STYLE/$n.q.png" || { echo "$n differs-at-rest" >> "$SP/click_$STYLE.txt"; continue; }
  # The PNG header carries the size; the centre of it is the click point.
  xy=$(python3 -c "
import struct,sys
d=open('$SP/rnd_$STYLE/$n.q.png','rb').read(24)
w,h=struct.unpack('>II', d[16:24])
print(w//2, h//2)
") || { echo "$n no-size" >> "$SP/click_$STYLE.txt"; continue; }
  x=${xy%% *}; y=${xy##* }
  [ "$x" -gt 0 ] && [ "$y" -gt 0 ] || { echo "$n zero-size" >> "$SP/click_$STYLE.txt"; continue; }
  # --run before --render: both sides let the click SETTLE for the same 400ms, so a document with
  # a `Behavior` is compared at its END state instead of at whatever phase each side's stopwatch
  # happened to reach. The transient is genuinely unmeasurable this way and is not pretended away:
  # a document that never settles would show up as a difference here just the same.
  timeout 30 "$SP/$OUT/i$n.bin" --click "$x" "$y" --run 400 --render "$SP/clk_$STYLE/$n.d.png" >/dev/null 2>&1 </dev/null \
    || { echo "$n ours-failed" >> "$SP/click_$STYLE.txt"; continue; }
  timeout 30 "$L/qmlrender" --clickrender "$f" "$x" "$y" "$SP/clk_$STYLE/$n.q.png" >/dev/null 2>&1 </dev/null \
    || { echo "$n engine-failed" >> "$SP/click_$STYLE.txt"; continue; }
  [ -s "$SP/clk_$STYLE/$n.d.png" ] && [ -s "$SP/clk_$STYLE/$n.q.png" ] || { echo "$n no-image" >> "$SP/click_$STYLE.txt"; continue; }
  if cmp -s "$SP/clk_$STYLE/$n.d.png" "$SP/clk_$STYLE/$n.q.png"; then echo "$n SAME $(stat -c%s "$SP/clk_$STYLE/$n.d.png")" >> "$SP/click_$STYLE.txt"
  else echo "$n differ $(stat -c%s "$SP/clk_$STYLE/$n.d.png")/$(stat -c%s "$SP/clk_$STYLE/$n.q.png")" >> "$SP/click_$STYLE.txt"; fi
done
echo DONE >> "$SP/click_$STYLE.txt"
