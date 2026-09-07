#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# ONE WAIT, TWO RUNTIMES — and the test says so only if BOTH sides move.
#
# vibe-core owns the loop and its event driver is Qt: every descriptor vibe cares about is a
# QSocketNotifier, and the wait is `QCoreApplication::processEvents`. So the claim has two halves,
# and a test that checked one of them would pass on a program that had quietly stopped being the
# other. vibe's half is a timer chain and a TCP round trip; Qt's half is a QTimer of its own firing
# while vibe's loop runs.
#
# The project is written HERE rather than committed, because a dub.json for it needs absolute paths
# to this checkout's generated binding and archives, and a committed one would be a path that is
# right on one machine.
set -eu
DC="$1"; GENDIR="$2"; BDIR="$3"; WORK="$4"; ROOT="$5"; MODS="$6"

# vibe-core is not a dependency of this project and must not become one: it is what a USER brings.
# Absent, the target reports that and passes — the same shape the libsample harness has for its
# clone. Present, the check is real.
if ! ls -d "$HOME"/.dub/packages/vibe-core* >/dev/null 2>&1; then
    echo "vibe-driver SKIP: no vibe-core in ~/.dub/packages — nothing to integrate with"
    exit 0
fi

rm -rf "$WORK"; mkdir -p "$WORK/source"
cp "$ROOT/tests/vibe/vibeqt.d" "$WORK/source/app.d"
# The binding's OWN modules, handed over by the build: a widgets binding needs Qt6Widgets and
# Qt6Gui that a QML one does not, and guessing wrong shows up as hundreds of undefined vtables.
QTLIBS=$(pkg-config --libs-only-l $MODS | sed 's/-l//g')
LIBS=""
for l in $QTLIBS; do LIBS="$LIBS\"$l\", "; done

cat > "$WORK/dub.json" <<JSON
{
  "name": "vibeqt",
  "targetType": "executable",
  "dependencies": { "vibe-core": "~>2.0" },
  "versions": ["EventcoreQtDriver"],
  "importPaths": ["source", "$ROOT/runtime/eventcore", "$GENDIR", "$ROOT/tests/support"],
  "sourcePaths": ["source", "$ROOT/runtime/eventcore"],
  "libs": [${LIBS}"stdc++"],
  "lflags": ["--gc-sections", "--as-needed", "--start-group", "$BDIR/libbinding_$DC.a", "$BDIR/libshims.a", "--end-group"]
}
JSON

# `--override-config` is not a convenience: every vibe-core configuration pins eventcore to one of
# its own drivers, so the GENERIC one — the only build in which `setupEventDriver()` exists and a
# driver can be installed at run time — has to be asked for from outside. Upstream's own answer to
# this is a configuration pair (eventcore `cfrunloop` + vibe-core `cfrunloop`); a `qt` pair is what
# this would become there, and until then the flag is what a user passes.
( cd "$WORK" && dub build --compiler="$DC" --override-config=eventcore/generic ) >"$WORK/build.log" 2>&1 || {
    echo "vibe-driver FAIL: the integration did not build" >&2
    tail -20 "$WORK/build.log" >&2
    exit 1
}

out=$("$WORK/vibeqt" 2>&1) || { echo "vibe-driver FAIL: it did not run" >&2; echo "$out" >&2; exit 1; }
echo "$out" | tail -2
echo "$out" | grep -q "QT IS EVENTCORE'S EVENT LOOP" || {
    echo "vibe-driver FAIL: one of the two halves did not move" >&2
    exit 1
}
echo "vibe-driver OK: vibe-core's loop ran on Qt's wait — vibe timers, a vibe TCP round trip and a Qt timer, all on one wait"
