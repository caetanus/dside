#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
# PHASE 2 END TO END: a refused expression compiled to BYTECODE, not interpreted from a string.
#
# qmltc-d writes one shadow document per expression it cannot turn into D; qmlcachegen turns each
# into a C++ unit plus one loader that serves them under `qrc:/qtdshadow/`; the generated D links
# against both and asks for them by that url. A `qrc:` url can only be answered by the loader, and
# the check below MOVES the .qml files away before running, so nothing can have read them.
#
# The verdict is the ordinary one: the value dump must equal the engine's.
#
#   shadow_aot.sh <qmltc-d> <qmlmap.tsv> <file.qml> <ClassName> <outdir> <builddir> <gendir> <dc> <cachegen> <cflags...>
set -e
. "$(dirname "$0")/../shplatform.sh"
TOOL="$1"; QMLMAP="$2"; QMLFILE="$3"; CLS="$4"; OUT="$5"; BDIR="$6"; GDIR="$7"; DC="$8"; CACHEGEN="$9"
shift 9
# The compile flags as ONE argument, then the link libraries. They used to be one blob and the link
# line carried `-L-lQt6Quick … -L-lstdc++` written by hand — the Linux spelling, which on Windows is
# `could not open 'Qt6Core.lib'` for every one of them and `stdc++.lib` for a library that does not
# exist there at all. The build already answers this per platform (pkgLibs + cxxRuntimeLibs); it
# just was not being asked.
CFLAGS="$1"; shift
LIBS="$*"

rm -rf "$OUT"; mkdir -p "$OUT/sh" "$OUT/ld"
# `|| true` because a REFUSED expression is the point and the tool exits non-zero for it. But a
# tool that could not START also exits non-zero, and the check below then blamed the fixture:
# `has no refused expression — nothing to AOT` while gen.diag held
#   qmltc-d: error while loading shared libraries: Qt6Core.dll: cannot open shared object file
# So the two are told apart before anything is concluded about the document.
"$TOOL" --dump --shadow-dir "$OUT/sh" --shadow-url "qrc:/qtdshadow/" "$QMLFILE" "$CLS" \
        --qmlmap "$QMLMAP" > "$OUT/gen.d" 2>"$OUT/gen.diag" || true

if grep -q "error while loading shared libraries\|is not recognized\|cannot execute" "$OUT/gen.diag" 2>/dev/null; then
  echo "shadow-aot: the compiler did not run at all:" >&2
  sed 's/^/    /' "$OUT/gen.diag" >&2
  exit 1
fi

n=$(ls "$OUT/sh" 2>/dev/null | wc -l)
if [ "$n" -eq 0 ]; then
  echo "shadow-aot: $QMLFILE has no refused expression — nothing to AOT (the fixture must delegate)" >&2
  sed 's/^/    diag: /' "$OUT/gen.diag" >&2
  exit 1
fi

# The .qrc, and one bytecode unit per shadow. Every path is passed to the loader as its OWN
# argument: collapsed into one, qmlcachegen mangles them into a single symbol nothing defines.
printf '<RCC><qresource prefix="/qtdshadow">\n' > "$OUT/shadows.qrc"
: > "$OUT/all_units.cpp"
set --
for f in "$OUT"/sh/*.qml; do
  b=$(basename "$f")
  printf '  <file>%s</file>\n' "$b" >> "$OUT/shadows.qrc"
  "$CACHEGEN" --resource-path "/qtdshadow/$b" -o "$OUT/unit_$b.cpp" "$f"
  printf '#include "unit_%s.cpp"\n' "$b" >> "$OUT/all_units.cpp"
  set -- "$@" "/qtdshadow/$b"
done
printf '</qresource></RCC>\n' >> "$OUT/shadows.qrc"
# The loader's output MUST be named qmlcache_loader.cpp — that is how qmlcachegen switches modes.
(cd "$OUT" && "$CACHEGEN" --resource-name qmlcache_qtdshadow -o ld/qmlcache_loader.cpp \
                          --resource shadows.qrc "$@")

clang++ $CFLAGS -std=c++17 $QTD_PIC $QTD_FP -O2 -c "$OUT/all_units.cpp" -o "$OUT/units.o"
clang++ $CFLAGS -std=c++17 $QTD_PIC $QTD_FP -O2 -c "$OUT/ld/qmlcache_loader.cpp" -o "$OUT/loader.o"

"$DC" -of="$OUT/app" "$OUT/gen.d" "$OUT/units.o" "$OUT/loader.o" \
      "$BDIR/qtd_qmltc_app.o" "$BDIR/qtd_render.o" -I"$GDIR" \
      -L--start-group -L="$BDIR/libbinding_$DC.a" -L="$BDIR/libshims.a" -L--end-group \
      $LIBS

# ...and NOTHING may read the source. A qrc: url cannot reach these files anyway; moving them is
# the belt-and-braces half, because a test that would also pass by reading the .qml proves nothing
# about the bytecode.
mkdir -p "$OUT/away" && mv "$OUT"/sh/*.qml "$OUT/away/"

"$TOOL" --labels "$QMLFILE" "$CLS" --qmlmap "$QMLMAP" > "$OUT/props" 2>/dev/null
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software "$OUT/app" > "$OUT/ours" 2>"$OUT/run.err"
QT_QPA_PLATFORM=offscreen "$BDIR/qmlvalues" "$QMLFILE" --props "$OUT/props" > "$OUT/eng" 2>/dev/null
sort "$OUT/ours" > "$OUT/ours.s"; sort "$OUT/eng" > "$OUT/eng.s"

# `QThreadStorage: entry N destroyed before end of thread` is not the run speaking: the harness
# creates a DELIBERATELY LEAKED, process-lifetime QGuiApplication (tests/qmltc/qtd_qmltc_app.cpp
# says so), and on Windows Qt's thread-data teardown notices the entries that are still set. Linux
# says nothing about the same object. Measured: a pure C++ Qt program built here is silent, so the
# line belongs to that decision and not to Qt — which is why it is named here rather than filtered
# by a pattern broad enough to hide a real one.
grep -v "^QThreadStorage: entry .* destroyed before end of thread" "$OUT/run.err" > "$OUT/run.err.real" || true
if [ -s "$OUT/run.err.real" ]; then
  echo "shadow-aot: the run was not silent:" >&2; head -5 "$OUT/run.err.real" >&2; exit 1
fi
diff "$OUT/eng.s" "$OUT/ours.s"
echo "shadow-aot OK: $n shadow(s) as BYTECODE (no .qml readable), values match the engine"
