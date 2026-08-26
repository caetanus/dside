#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
# Compile-clean is not the bar: "renders and behaves like the interpreted version" is, and the
# first step of that is that the object can be BUILT AT ALL. This gate takes Qt's own shipped
# QtQuick/Controls/Basic/*.qml -- QML nobody here wrote -- generates, links and CONSTRUCTS each
# one, and fails if any file that emits a root dies at construction.
#
# Every defect it was written for compiles cleanly and only shows up here: an unbound child type
# built as a bare object (no such property), no QQmlContext (a view segfaults in
# componentComplete), a dependency connected to a null `parent`, a refused property still
# connected to by a child, a declared-but-valueless property emitting an undefined identifier.
#
# A floor on the count is part of the gate: without it, refusing every root would pass.
set -u
TOOL=$1; QMLMAP=$2; DIR=$3; OUT=$4; DC=$5; GENDIR=$6; APPCPP=$7; RENDERCPP=$8; LIBBIND=$9
. "$(dirname "$0")/../shplatform.sh"
shift 9
LIBSHIMS=$1; shift
CXXFLAGS=$1; shift
LIBS="$*"
FLOOR=50

[ -d "$DIR" ] || { echo "controls-runtime: $DIR is not present -- nothing to check"; exit 0; }
mkdir -p "$OUT" || exit 1
# Compiled HERE rather than borrowed from the differential suite's build nodes: a target that does
# not depend on its real inputs re-reports a stale verdict, and these two .cpp are real inputs.
APPOBJ=$OUT/app.o; RENDEROBJ=$OUT/render.o
clang++ $CXXFLAGS -std=c++17 $QTD_PIC $QTD_FP -O2 -c "$APPCPP" -o "$APPOBJ" || exit 1
clang++ $CXXFLAGS -std=c++17 $QTD_PIC $QTD_FP -O2 -c "$RENDERCPP" -o "$RENDEROBJ" || exit 1
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software

built=0; failed=0
for f in "$DIR"/*.qml; do
    n=$(basename "$f" .qml)
    # 0 = clean, 3 = partial (members skipped, reported on stderr). ANYTHING else is the compiler
    # itself failing -- it aborted on three of Qt's files (npos + 18) and the suite never saw it,
    # because a crash and a partial are both "non-zero".
    "$TOOL" --dump "$f" "Rt$n" --qmlmap "$QMLMAP" -I "$DIR" > "$OUT/rt_$n.d" 2>"$OUT/rt_$n.diag"
    rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
        echo "controls-runtime: qmltc-d CRASHED on $n (exit $rc):"; tail -2 "$OUT/rt_$n.diag"
        failed=$((failed + 1)); continue
    fi
    # A refused root emits no main on purpose, so there is nothing to run: that is reported by the
    # tool on stderr and is not a failure here. Anything else that will not link IS one.
    if ! $DC -of="$OUT/rt_$n.bin" "$OUT/rt_$n.d" "$APPOBJ" "$RENDEROBJ" -I"$GENDIR" \
            -L--start-group -L="$LIBBIND" -L="$LIBSHIMS" -L--end-group $LIBS \
            > "$OUT/rt_$n.link" 2>&1 < /dev/null; then
        # A LINKER'S PROSE IS NOT PORTABLE, and on Windows it is not even in English: the same
        # "there is no main" that GNU ld writes as `undefined reference to \`main\'` is
        # `LNK1561: pontos de entrada devem ser definidos` from MSVC's link.exe on a pt-BR machine.
        # Match the CODE, which is the same everywhere, and the two prose forms beside it. Without
        # this, seven of Qt's controls whose root the compiler refuses — ApplicationWindow, the
        # whole Calendar family, SpinBox — were counted as build failures.
        # ...and a THIRD spelling, because lld-link does not name main at all: with no entry point
        # it cannot infer the subsystem and says `subsystem must be defined`. Same fact, three
        # linkers, three sentences — which is why the codes and the distinctive phrases are matched
        # rather than one of them.
        if grep -qE "undefined reference to .main.|LNK1561|subsystem must be defined|undefined symbol: _?(main|WinMain)" \
                "$OUT/rt_$n.link"; then continue; fi
        echo "controls-runtime: $n DOES NOT BUILD:"; head -5 "$OUT/rt_$n.link"; failed=$((failed + 1))
        continue
    fi
    built=$((built + 1))
    if ! timeout 60 "$OUT/rt_$n.bin" > /dev/null 2> "$OUT/rt_$n.err" < /dev/null; then
        echo "controls-runtime: $n BUILT BUT DIED AT CONSTRUCTION:"; head -3 "$OUT/rt_$n.err"
        failed=$((failed + 1))
    fi
done

echo "controls-runtime: $built of Qt's Basic controls produce an object, $failed failed"
[ "$failed" -eq 0 ] || exit 1
[ "$built" -ge "$FLOOR" ] || { echo "controls-runtime: only $built built, floor is $FLOOR"; exit 1; }
