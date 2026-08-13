# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
set -u
set -o pipefail   # else `| sort` hides our binary dying
# Style and outdir are parameters for the same reason values_corpus.sh and render_corpus.sh take
# them: a reactivity defect only Fusion's indicators have is invisible to a Basic-only sweep.
#   bash tests/qmltc/react_corpus.sh <scratchdir> <prop=value> [Style] [outdir-under-scratch]
SP=$1; MUT=$2; STYLE=${3:-Basic}; OUT=${4:-cr}
B=/usr/lib/qt6/qml/QtQuick/Controls/$STYLE; L=/home/caetano/lab/qt-dlang-gen/.build/qt-6.11-cxx-controls
G=/home/caetano/lab/qt-dlang-gen/generated/qt-6.11/cxx-controls
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software
: > "$SP/react_$STYLE.txt"
for f in $B/*.qml; do
  n=$(basename "$f" .qml)
  [ -x "$SP/$OUT/i$n.bin" ] || continue
  [ -s "$SP/$OUT/$n.objs" ] || continue
  # Only where the mutated property EXISTS on the root: Action/ButtonGroup are not Items, and
  # writing `width` to one is a harness error, not a compiler difference. Our side reports the
  # failed write by throwing (which is right); the oracle silently ignores it, so comparing the
  # two would blame the compiler for the test's own bad input.
  grep -q "^${MUT%%=*}	" "$SP/$OUT/$n.dall.s" || continue
  # ...and only where it is WRITABLE. `mirrored` is readable and read-only (Qt derives it from
  # LayoutMirroring), so the mutation is the test's own bad input: our side reports the failed write
  # by throwing, the oracle ignores it, and comparing them would blame the compiler. Told apart from
  # a real crash by the message, and COUNTED — a skip nobody sees is how an axis quietly measures
  # less than it claims.
  if ! timeout 30 "$SP/$OUT/i$n.bin" "--set:$MUT" --dumpall 2>"$SP/$OUT/$n.rerr" </dev/null | sort > "$SP/$OUT/$n.rd"; then
    if grep -q "no writable property" "$SP/$OUT/$n.rerr"; then echo "$n skip-readonly" >> "$SP/react_$STYLE.txt"
    else echo "$n ours-died" >> "$SP/react_$STYLE.txt"; fi
    continue
  fi
  timeout 30 "$L/qmlvalues" "$f" "$MUT" --dumpall "$SP/$OUT/$n.objs" 2>/dev/null </dev/null | sort > "$SP/$OUT/$n.rq" || { echo "$n oracle-died" >> "$SP/react_$STYLE.txt"; continue; }
  [ -s "$SP/$OUT/$n.rq" ] || { echo "$n oracle-empty" >> "$SP/react_$STYLE.txt"; continue; }
  d=$(diff "$SP/$OUT/$n.rd" "$SP/$OUT/$n.rq" | grep -c '^[<>]')
  tot=$(wc -l < "$SP/$OUT/$n.rd")
  if [ "$d" -eq 0 ]; then echo "$n MATCH $tot" >> "$SP/react_$STYLE.txt"; else echo "$n differ $((d/2))/$tot" >> "$SP/react_$STYLE.txt"; fi
done
echo DONE >> "$SP/react_$STYLE.txt"
