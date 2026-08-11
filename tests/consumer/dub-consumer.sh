#!/bin/sh
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

cat > "$TMP/dub.json" <<EOF
{
  "name": "hello-qtd",
  "targetType": "executable",
  "mainSourceFile": "app.d",
  "sourceFiles": ["app.d"],
  "dependencies": { "$PKG": { "path": "$PREFIX" } }
}
EOF

cd "$TMP"
# --skip-registry: this must resolve LOCALLY. Without it a typo in the package name reaches the
# network and the failure reads like a connectivity problem instead of a packaging one.
dub build --compiler="$DC" --skip-registry=all >/dev/null
QT_QPA_PLATFORM=offscreen ./hello-qtd
echo "dub-consumer OK ($DC): resolved $PKG as a dependency and ran it"
