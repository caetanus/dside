#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
# A CONSUMER THAT NAMES A DEPENDENCY, not a path into somebody else's build tree.
#
# The sibling `consumer.sh` proves the application can be built outside the checkout; this proves
# the binding can be DEPENDED ON — dub resolves the package, finds its import path and its
# archives, and the application never mentions either. That is the difference CRITICS round 12 #6
# is about, and it is the reason this script exists beside one that looks almost the same.
#
# The application source is the same file both use. If a change makes the binding unconsumable, the
# two fail for visibly different reasons: consumer.sh at the compiler, this one at resolution.
#
#   dub-consumer.sh <installed prefix> <pkg name> <dc>
set -eu
PREFIX="$1"; PKG="$2"; DC="$3"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PREFIX=$(CDPATH= cd -- "$PREFIX" && pwd)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/qtd-dubapp-XXXXXX")
trap 'rm -rf "$TMP"' EXIT
cp "$HERE/hello.d" "$TMP/app.d"
# ...and appctor.d with it: it holds the mangled QApplication constructor for the ABI in front of
# us, which no binding exports, so a real consumer carries the same three lines. See the same copy
# in consumer.sh — pointing dub at tests/support instead would reach back into the checkout.
cp "$HERE/../support/appctor.d" "$TMP/appctor.d"

cat > "$TMP/dub.json" <<EOF
{
  "name": "hello-qtd",
  "targetType": "executable",
  "mainSourceFile": "app.d",
  "sourceFiles": ["app.d", "appctor.d"],
  "dependencies": { "$PKG": { "path": "$PREFIX" } }
}
EOF

# THE QT THE PACKAGE WAS BUILT AGAINST must be the Qt that is here now. A binding generated from
# 6.11's headers and linked against a different minor is undefined behaviour that shows up as a
# crash inside Qt, not as a link error — the symbols mangle the same. Two numbers and a comparison
# is the whole check, and nothing in the artifact carried the first one until now.
if [ -f "$PREFIX/qtd-build.txt" ]; then
  built=$(sed -n 's/^qt=//p' "$PREFIX/qtd-build.txt")
  have=$(pkg-config --modversion Qt6Core 2>/dev/null || echo unknown)
  if [ "$built" != "$have" ]; then
    echo "dub-consumer: the package was generated against Qt $built and this machine has Qt $have." >&2
    echo "Regenerate the binding — the symbols mangle the same and the mismatch would surface as a" >&2
    echo "crash inside Qt rather than as a link error." >&2
    exit 1
  fi
fi

cd "$TMP"
# --skip-registry: this must resolve LOCALLY. Without it a typo in the package name reaches the
# network and the failure reads like a connectivity problem instead of a packaging one.
dub build --compiler="$DC" --skip-registry=all >/dev/null
QT_QPA_PLATFORM=offscreen ./hello-qtd
echo "dub-consumer OK ($DC): resolved $PKG as a dependency and ran it"
