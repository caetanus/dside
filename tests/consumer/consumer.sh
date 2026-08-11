#!/bin/sh
# CAN SOMEBODY ELSE USE THIS? Every other target in the matrix builds from inside the checkout,
# with paths reggae already knows — which proves the binding compiles and proves nothing about
# consuming it. CRITICS round 12 #6: "um exemplo consumidor em diretorio temporario deve depender
# apenas de um artefato instalado/empacotado ... sem acessar generated/ ou .build/ do checkout".
#
# This is the first half of that: the sources are COPIED OUT to a temporary directory, and the only
# things pointed back at the checkout are the two artifacts a packaged binding would install — the
# import path and the archives. Nothing else from the tree is reachable, and the build runs with
# the temporary directory as its working directory, so a relative path into the repo cannot work by
# accident.
#
# What it still does NOT prove, and the reason the audit's finding stays open: those artifacts are
# not installed anywhere. A real consumer would name a package, not a build directory.
#
#   consumer.sh <gen dir> <build dir> <dc> <libs...>
set -eu
GEN="$1"; BDIR="$2"; DC="$3"; shift 3
LIBS="$*"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/qtd-consumer-XXXXXX")
trap 'rm -rf "$TMP"' EXIT
cp "$HERE"/*.d "$TMP/"

# Absolute, because the consumer's working directory is NOT the checkout.
GEN=$(CDPATH= cd -- "$GEN" && pwd)
BDIR=$(CDPATH= cd -- "$BDIR" && pwd)

cd "$TMP"
# shellcheck disable=SC2086
"$DC" -of=hello hello.d -I"$GEN" \
      -L--start-group -L="$BDIR/libbinding_$DC.a" -L="$BDIR/libshims.a" -L--end-group $LIBS

# ...and the binary must not need the checkout at run time either.
QT_QPA_PLATFORM=offscreen ./hello
echo "consumer-smoke OK ($DC): built and ran outside the checkout, from the import path and the archives alone"
