#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# RECORD A COVERAGE BASELINE FOR THE PAIRING IN FRONT OF US.
#
#   tools/record-coverage-baseline.sh <generated manifest> <label> [prefix]
#
# The manifest gate holds a binding to a per-symbol contract, and that contract is a property of
# ONE (platform, Qt release) pairing: an X11-only type or a 6.11 addition is absent elsewhere for
# reasons that are not a regression. Every comment around the gate has said "regenerate the
# baseline" for months without saying HOW, so the one baseline that existed was the one somebody
# had produced by hand — on Linux — and every other platform got NOT COMPARABLE and no contract.
#
# The output name carries the platform when it is not the historical one:
#     tests/coverage/<label>.manifest.tsv            linux, the file that already existed
#     tests/coverage/<label>.windows.manifest.tsv    anything else
# which is exactly what baselineName() in reggaefile.d looks for.
#
# The generated manifest has five columns (cppClass symbol usr why fate); a baseline keeps four.
# `why` is the generator's explanation of a fate — useful to a person reading a diff, and noise in
# a contract, because rewording it would read as a coverage change.
set -eu

MAN="$1"; LABEL="$2"; PREFIX="${3:-}"
[ -f "$MAN" ] || { echo "record-coverage-baseline: no manifest at $MAN" >&2; exit 1; }

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/tests/shplatform.sh"

case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
  Darwin)               PLATFORM=macos ;;
  Linux)                PLATFORM=linux ;;
  *)                    PLATFORM=posix ;;
esac

# THE Qt RELEASE, ASKED THE SAME WAY THE BUILD ASKS IT. pkg-config where there is one, the prefix
# where there is not — a baseline stamped `qt=none` would be a pairing nothing can ever match.
QT=$(pkg-config --modversion Qt6Core 2>/dev/null || qt_release_from_prefix "${PREFIX:-${QTDIR6:-${QTDIR:-}}}" || echo "")
[ -n "$QT" ] || { echo "record-coverage-baseline: cannot tell which Qt this is; pass the prefix" >&2; exit 1; }

if [ "$PLATFORM" = linux ]; then OUT="$ROOT/tests/coverage/$LABEL.manifest.tsv"
else                            OUT="$ROOT/tests/coverage/$LABEL.$PLATFORM.manifest.tsv"; fi

{
    echo "# SPDX-FileCopyrightText: 2026 Marcelo A Caetano"
    echo "# SPDX-License-Identifier: BSL-1.0"
    echo "# baseline-for: platform=$PLATFORM qt=$QT"
    printf '# cppClass\tsymbol\tusr\tfate\n'
    # Drop the generated header and the `why` column, and sort: the generator's order is its own
    # traversal, and a baseline that reorders on every run makes a diff unreadable.
    grep -v '^#' "$MAN" | cut -f1,2,3,5 | LC_ALL=C sort
} > "$OUT"

echo "record-coverage-baseline: $(grep -vc '^#' "$OUT") symbol(s) -> $OUT"
echo "  pairing: platform=$PLATFORM qt=$QT"
