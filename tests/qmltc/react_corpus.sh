set -u
set -o pipefail   # else `| sort` hides our binary dying
SP=$1; MUT=$2; B=/usr/lib/qt6/qml/QtQuick/Controls/Basic; L=/home/caetano/lab/qt-dlang-gen/.build/qt-6.11-cxx-controls
G=/home/caetano/lab/qt-dlang-gen/generated/qt-6.11/cxx-controls
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software
: > "$SP/react.txt"
for f in $B/*.qml; do
  n=$(basename "$f" .qml)
  [ -x "$SP/cr/i$n.bin" ] || continue
  [ -s "$SP/cr/$n.objs" ] || continue
  # Only where the mutated property EXISTS on the root: Action/ButtonGroup are not Items, and
  # writing `width` to one is a harness error, not a compiler difference. Our side reports the
  # failed write by throwing (which is right); the oracle silently ignores it, so comparing the
  # two would blame the compiler for the test's own bad input.
  grep -q "^${MUT%%=*}	" "$SP/cr/$n.dall.s" || continue
  # ...and only where it is WRITABLE. `mirrored` is readable and read-only (Qt derives it from
  # LayoutMirroring), so the mutation is the test's own bad input: our side reports the failed write
  # by throwing, the oracle ignores it, and comparing them would blame the compiler. Told apart from
  # a real crash by the message, and COUNTED — a skip nobody sees is how an axis quietly measures
  # less than it claims.
  if ! timeout 30 "$SP/cr/i$n.bin" "--set:$MUT" --dumpall 2>"$SP/cr/$n.rerr" </dev/null | sort > "$SP/cr/$n.rd"; then
    if grep -q "no writable property" "$SP/cr/$n.rerr"; then echo "$n skip-readonly" >> "$SP/react.txt"
    else echo "$n ours-died" >> "$SP/react.txt"; fi
    continue
  fi
  timeout 30 "$L/qmlvalues" "$f" "$MUT" --dumpall "$SP/cr/$n.objs" 2>/dev/null </dev/null | sort > "$SP/cr/$n.rq" || { echo "$n oracle-died" >> "$SP/react.txt"; continue; }
  [ -s "$SP/cr/$n.rq" ] || { echo "$n oracle-empty" >> "$SP/react.txt"; continue; }
  d=$(diff "$SP/cr/$n.rd" "$SP/cr/$n.rq" | grep -c '^[<>]')
  tot=$(wc -l < "$SP/cr/$n.rd")
  if [ "$d" -eq 0 ]; then echo "$n MATCH $tot" >> "$SP/react.txt"; else echo "$n differ $((d/2))/$tot" >> "$SP/react.txt"; fi
done
echo DONE >> "$SP/react.txt"
