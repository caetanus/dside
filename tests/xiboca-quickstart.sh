#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# THE QUICKSTART, PROVEN — generate a binding for a C++ library that is not Qt and
# not part of this repository's Qt bindings, then COMPILE it, LINK it, RUN it, and
# compare its output byte for byte against examples/userlib/expected.txt.
#
#   xiboca-quickstart.sh <xiboca binary> <workdir>
#
# It exists because docs/xiboca/generating-a-wrapper.md tells a reader this works,
# and on 2026-08-18 the example that documentation pointed at did NOT: the shipped
# generator/spec_userlib.json had no "abi": "cxx", so xiboca discovered 2 classes,
# emitted 0, and exited 0. Both READMEs cited it. A documented example that nothing
# runs is a claim, and this repository does not keep claims.
#
# It proves more than emission. A binding can emit cleanly and still fail to link
# (a declaration whose definition is absent) or link and produce wrong values (a
# container conversion that drops entries), and neither shows up in a generator
# that only writes files. The golden comparison is what closes that.
set -eu
. "$(dirname -- "$0")/pybin.sh"          # $PY: the python that actually runs
XIBOCA="$1"; WORK="$2"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SPEC="$ROOT/generator/spec_userlib.json"
EXPECT="$ROOT/examples/userlib/expected.txt"

fail() { echo "xiboca-quickstart FAIL: $1" >&2; [ $# -gt 1 ] && echo "    $2" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK/gen"

# Qt6's moc, NOT whatever `moc` is on PATH. Measured on this machine: PATH's moc is
# Qt 5.15.19 and refuses Qt6 headers with an #error, which is a confusing failure to
# hit from inside a Qt6 build.
LIBEXEC=$(pkg-config --variable=libexecdir Qt6Core 2>/dev/null || true)
MOC=""
for cand in "$LIBEXEC/moc" /usr/lib/qt6/moc /usr/lib64/qt6/moc /usr/lib/qt6/libexec/moc; do
    [ -x "$cand" ] && { MOC="$cand"; break; }
done
[ -n "$MOC" ] || fail "no Qt6 moc found" "looked in libexecdir=$LIBEXEC and the usual qt6 paths"

INC=$(pkg-config --variable=includedir Qt6Core)
VER=$(pkg-config --modversion Qt6Core)
CFLAGS="$(pkg-config --cflags Qt6Core) -I$INC/QtCore/$VER -I$INC/QtCore/$VER/QtCore"

# The spec, with out_dir redirected into the work directory. Everything else — the
# headers, the filter, the package name — is the spec a reader is shown, unedited.
"$PY" - "$SPEC" "$WORK/spec.json" "$WORK/gen" <<'PY'
import json, sys, os
spec = json.load(open(sys.argv[1]))
src = os.path.dirname(os.path.abspath(sys.argv[1]))
for k in ("include_paths",):
    if k in spec:
        spec[k] = [p if os.path.isabs(p) else os.path.normpath(os.path.join(src, p)) for p in spec[k]]
spec["out_dir"] = os.path.abspath(sys.argv[3])
json.dump(spec, open(sys.argv[2], "w"), indent=2)
PY

"$XIBOCA" "$WORK/spec.json" > "$WORK/gen.log" 2>&1 \
    || fail "xiboca refused the quickstart spec" "$(tail -3 "$WORK/gen.log")"

# An empty binding must not read as success — the exact failure this test was
# written after.
emitted=$(sed -n 's/.*done: \([0-9]*\) classes emitted.*/\1/p' "$WORK/gen.log")
[ "${emitted:-0}" -ge 2 ] || fail "expected at least 2 classes, got ${emitted:-0}" \
    "$(grep -a 'skipped\|done:' "$WORK/gen.log" | head -3)"

cd "$WORK"
"$MOC" "$ROOT/examples/userlib/shape.h" -o moc_shape.cpp \
    || fail "moc failed on shape.h"

# Your code, moc's output, and the generated shims.
clang++ -std=c++17 -fPIC -c "$ROOT/examples/userlib/shape.cpp" -I"$ROOT/examples/userlib" $CFLAGS \
    || fail "your own C++ did not compile"
clang++ -std=c++17 -fPIC -c moc_shape.cpp -I"$ROOT/examples/userlib" $CFLAGS \
    || fail "the moc output did not compile"
# -I the project too: the emitted shims `#include "shape.h"`, because a shim that
# calls your constructor has to see your declaration.
for f in gen/*.cpp; do
    clang++ -std=c++17 -fPIC -c "$f" -I. -I"$ROOT/examples/userlib" $CFLAGS 2>"$WORK/cxx.err" \
        || fail "generated $(basename "$f") did not compile" "$(head -3 "$WORK/cxx.err")"
done

# The D side: every emitted module, the runtime, and the example program.
ldc2 -c -I gen -od=dobj gen/userlib/*.d gen/cxxrt.d gen/qtmoc.d "$ROOT/examples/userlib/app.d" \
    2>"$WORK/d.err" || fail "the emitted D did not compile" "$(head -5 "$WORK/d.err")"

QTLIBS=$(pkg-config --libs Qt6Core | sed 's/-l/-L-l/g; s/-L-L/-L-L/g')
ldc2 -of=app dobj/*.o ./*.o -L-lstdc++ $QTLIBS 2>"$WORK/link.err" \
    || fail "the binding did not link" "$(grep -m3 'undefined' "$WORK/link.err" || head -3 "$WORK/link.err")"

./app > out.txt 2>&1 || fail "the example crashed" "$(tail -3 out.txt)"

if ! diff -u "$EXPECT" out.txt > diff.txt; then
    fail "the example ran and printed something else" "$(head -12 diff.txt)"
fi

echo "xiboca-quickstart OK: $emitted class(es) generated from examples/userlib, compiled, linked, and printing what expected.txt says"
