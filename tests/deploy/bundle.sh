#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# A BUNDLE THAT RUNS WITHOUT THE SYSTEM'S QT, proved by where its libraries came from.
#
# The question a deployment tool has to answer is not "did it copy files" — that is easy and it is
# what every version of this check would pass. It is whether the copied tree RESOLVES: whether the
# application, started from the bundle, loads the bundled libraries or quietly falls back to the
# ones the build machine happens to have. Those two outcomes look identical here and differ on the
# user's disk, which is the whole failure mode this test exists to make visible.
#
# So the assertion is made against the loader itself. `LD_DEBUG=libs` prints every file it opens
# and where it found it, and the test fails if any library outside the deployment policy came from
# anywhere but the bundle. `libfreetype.so.6` is the one to watch: it carries no run path of its
# own, so it is found only because the executable's DT_RPATH is inherited by the search made on
# behalf of libfontconfig — and if that inheritance is ever traded for DT_RUNPATH, this line is
# where it shows up.
set -eu

DC="$1"; GENDIR="$2"; BDIR="$3"; QTLIBS="$4"; WORK="$5"; ROOT="$6"; APPSRC="$7"; QMLFILE="${8:-}"

# WITH A QML DOCUMENT THIS IS A DIFFERENT TEST, and the harder one. A widgets program needs the
# libraries and the platform plugin; a QML program needs those plus the module directories the
# engine resolves at run time, the plugin inside each of them, and the Qt modules that arrive
# through THOSE plugins. Measured while writing this: shipping the style `QtQuick/Controls/qmldir`
# calls `default import` produced a program that started, loaded no root object and printed
# nothing at all — the style is chosen by QQuickStyle at run time, and on this machine it is Fusion
# while the qmldir says Basic.
APPNAME=$(basename "$APPSRC" .d)
EXPECT="deployapp OK"
[ -n "$QMLFILE" ] && EXPECT="deployqml OK"

rm -rf "$WORK"; mkdir -p "$WORK"

fail() { echo "deploy-bundle FAIL: $1" >&2; [ $# -gt 1 ] && echo "    $2" >&2; exit 1; }

"$DC" -of="$WORK/qtd-deploy" "$ROOT/tools/deploy/qtd_deploy.d" "$ROOT/tools/deploy/binfmt.d" \
    2>"$WORK/tool.err" || fail "qtd-deploy did not build" "$(head -5 "$WORK/tool.err")"

# THE LINK IS NOT THE SAME QUESTION ON BOTH PLATFORMS, and pretending it is would make one of them
# vacuous. On ELF, `--disable-new-dtags` asks for DT_RPATH rather than DT_RUNPATH: the deprecated
# tag is the correct one here, because it is inherited by every library loaded beneath the
# executable and the distribution libraries in the bundle carry no run path of their own. A PE
# image has no such entry to ask for — a DLL is looked for beside the loading executable — so there
# is nothing to pass and nothing for the tool to rewrite.
#
# ...and the EXECUTABLE'S NAME is a third one. ldc2 and dmd append `.exe` when `-of` has no
# extension, so the file the link produces and the file this script then names were different on
# Windows: `env: '…/out/bin/app.exe': No such file or directory`, about a bundle that had been
# built around a path with no extension. One variable, used at all four sites.
#
# The C++ runtime is the same question with the same answer: `-lstdc++` is a POSIX library and MSVC
# links its own, so asking for it there produced
#     LINK : fatal error LNK1181: cannot open input file 'stdc++.lib'
# and took all four deploy targets with it. (`--start-group`/`--end-group` survive: link.exe warns
# LNK4044 and ignores them, which is why the rest of the build passes them unconditionally.)
# This is `cxxRuntimeFlag()` from reggae/qtd_build.d, in the one place that writes its own link
# line instead of going through qtdApp.
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) PLATFORM=windows; RPATHFLAGS=""; CXXLIB=""; EXE=".exe" ;;
  *)                    PLATFORM=posix;   RPATHFLAGS="-L-rpath=\$ORIGIN/../lib -L--disable-new-dtags"
                        CXXLIB="-L-lstdc++"; EXE="" ;;
esac

# shellcheck disable=SC2086
"$DC" -of="$WORK/app$EXE" "$APPSRC" \
    -I"$GENDIR" -I"$ROOT/tests/support" \
    -L--start-group -L="$BDIR/libbinding_$DC.a" -L="$BDIR/libshims.a" -L--end-group \
    $QTLIBS $CXXLIB $RPATHFLAGS \
    2>"$WORK/link.err" || fail "the test application did not link" "$(head -5 "$WORK/link.err")"

QMLARG=""
if [ -n "$QMLFILE" ]; then QMLARG="--qml $QMLFILE"; fi

# WHERE QT IS, WHEN NOTHING CAN BE ASKED. qtd-deploy finds Qt by running `qmake -query`, which is
# how a user's machine answers and how this passes on Linux. On Windows Qt is an installation the
# build was POINTED at rather than one on PATH, so the tool refused:
#     qtd-deploy: no Qt found. Pass --qt-prefix; qmake was not on PATH
# The build already knows the answer — it is what QTDIR6 says — so it is handed over rather than
# discovered. Empty on a machine where qmake IS on PATH, which leaves the discovery path exercised.
QTARG=""
for d in "${QTDIR6:-}" "${QTDIR:-}"; do
    if [ -n "$d" ] && [ -d "$d/include/QtCore" ]; then QTARG="--qt-prefix $d"; break; fi
done
# shellcheck disable=SC2086
"$WORK/qtd-deploy" bundle "$WORK/app$EXE" --out "$WORK/out" $QMLARG $QTARG \
    --plugins platforms,imageformats,iconengines,platformthemes,platforminputcontexts,styles \
    >"$WORK/bundle.out" 2>&1 || fail "qtd-deploy bundle failed" "$(tail -5 "$WORK/bundle.out")"
if [ -n "$QMLFILE" ]; then
    cp "$QMLFILE" "$WORK/out/bin/doc.qml"
    APPARG="$WORK/out/bin/doc.qml"
else
    APPARG=""
fi

[ -f "$WORK/out/bin/qt.conf" ] || fail "no qt.conf beside the executable" \
    "without it Qt looks for its plugins in the build machine's prefix"

# WHAT EACH PLATFORM CAN PROVE, said plainly, because the two proofs are not equally strong and a
# green row that hides the difference is worse than the weaker check.
#
# On ELF the loader can be asked directly: LD_DEBUG=libs prints every file it opened and where it
# found it, so "the bundle resolves" is a measurement rather than an inference. `libfreetype.so.6`
# is the one to watch — it carries no run path of its own and is found only because the
# executable's DT_RPATH is inherited by the search made on behalf of libfontconfig. If that
# inheritance is ever traded for DT_RUNPATH, this is the line that goes red.
#
# On Windows there is no equivalent trace, so the proof is the one the platform allows: run the
# bundled executable with the Qt directories taken out of PATH. If the tool missed a DLL or a
# plugin, nothing is left to fall back to and the process fails to start.
if [ "$PLATFORM" = posix ]; then
    ( cd / && env -u LD_LIBRARY_PATH -u QT_PLUGIN_PATH -u QT_QPA_PLATFORM_PLUGIN_PATH \
          QT_QPA_PLATFORM=offscreen LD_DEBUG=libs "$WORK/out/bin/app$EXE" $APPARG \
          >"$WORK/run.out" 2>"$WORK/run.err" ) \
        || fail "the bundled application did not run" "$(tail -5 "$WORK/run.err")"

    POLICY='/lib\(c\|m\|dl\|pthread\|rt\|gcc_s\|stdc++\|X11\|Xext\|Xrender\|Xau\|Xdmcp\|xcb\|GL\|GLX\|GLdispatch\|EGL\|OpenGL\|wayland\|udev\|drm\|gbm\)[.-]\|ld-linux\|/ld\.so'
    LEAKS=$(grep -o '=> /[^ ]*' "$WORK/run.err" | sed 's/^=> //' | sort -u \
            | grep -v "^$WORK/out" | grep -v "$POLICY" || true)
    [ -z "$LEAKS" ] || fail "the bundle fell back to the machine's libraries" "$(echo "$LEAKS" | head -5)"

    grep -q "$WORK/out/.*platforms/libqoffscreen" "$WORK/run.err" \
        || fail "the platform plugin did not come from the bundle" \
                "$(grep -o '/[^ ]*platforms/[^ ]*' "$WORK/run.err" | sort -u | head -3)"
    PROOF="0 libraries from the system, and its platform plugin came out of the bundle"
else
    # Only the system directories stay in PATH; anything Qt has to come from beside the executable.
    SYSPATH="/c/Windows/System32:/c/Windows"
    # OPTIONS BEFORE ASSIGNMENTS. `env FOO=1 -u BAR cmd` is not a thing: everything after the
    # first assignment is the command and its arguments, so `-u` arrived as a program name —
    # `env: '-u': No such file or directory`, which reads like a missing binary.
    ( cd / && env -u QT_PLUGIN_PATH -u QT_QPA_PLATFORM_PLUGIN_PATH \
          PATH="$SYSPATH" QT_QPA_PLATFORM=offscreen \
          "$WORK/out/bin/app$EXE" $APPARG >"$WORK/run.out" 2>"$WORK/run.err" ) \
        || fail "the bundled application did not run with Qt out of PATH" \
                "$(tail -5 "$WORK/run.err")"
    [ -f "$WORK/out/bin/Qt6Core.dll" ] || fail "Qt6Core.dll is not beside the executable" \
        "a PE image has no run path, so that is the only place the loader will look"
    PROOF="Qt taken out of PATH, so every library and plugin it loaded came from beside it"
fi

grep -q "$EXPECT" "$WORK/run.out" || fail "the application ran and printed something else" \
    "$(head -3 "$WORK/run.out")"

# ...and for a QML program, that the engine's own plugin came out of the bundle. It is loaded by
# name from a directory the engine resolved, so nothing in the link recorded it.
if [ -n "$QMLFILE" ] && [ "$PLATFORM" = posix ]; then
    grep -q "$WORK/out/.*/qml/.*\.so" "$WORK/run.err" \
        || fail "no QML module plugin was loaded from the bundle" \
                "$(grep -o '/[^ ]*/qml/[^ ]*\.so' "$WORK/run.err" | sort -u | head -3)"
fi

echo "deploy-bundle OK ($APPNAME): the bundled application ran with $PROOF"
