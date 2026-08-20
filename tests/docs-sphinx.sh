#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# THE MANUAL BUILDS, WITH WARNINGS AS ERRORS.
#
#   docs-sphinx.sh <output dir>
#
# `-W` is the whole point. Without it Sphinx cheerfully produces a site containing
# a broken cross-reference, a page that is in no table of contents and therefore
# unreachable, or a malformed table that swallows a column — and every one of those
# renders as a page that looks finished. With it, they are build failures.
#
# `-n` (nitpicky) is set in conf.py so an unresolvable reference target counts too.
#
# The manual is reStructuredText and the stock theme on purpose: this machine has
# Sphinx but not myst-parser and not a third-party theme, and a documentation gate
# that needs a dependency nobody installed is a gate that gets disabled.
#   docs-sphinx.sh <output dir> [generated api dir]
#
# The API reference is GENERATED (by xiboca, from the binding it just emitted) and therefore is not
# in the repository. So the source tree is assembled here rather than built in place: the committed
# manual is copied, the generated pages are dropped in beside it, and the root toctree gains one
# line. The committed manual stays buildable on its own — a fresh checkout with no binding built yet
# must still be able to check its own prose.
set -eu
OUT="${1:?docs-sphinx.sh <output dir> [api dir]}"
API="${2:-}"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$ROOT/docs/manual"

command -v sphinx-build >/dev/null || {
    echo "docs-sphinx FAIL: sphinx-build not found" >&2
    echo "    the manual under docs/manual/ cannot be verified without it" >&2
    exit 1
}

[ -f "$SRC/conf.py" ] || { echo "docs-sphinx FAIL: no conf.py under $SRC" >&2; exit 1; }

rm -rf "$OUT"
log=$(mktemp); work=$(mktemp -d); trap 'rm -f "$log"; rm -rf "$work"' EXIT

cp -r "$SRC" "$work/src"
api_pages=0
if [ -n "$API" ] && [ -f "$API/index.rst" ]; then
    cp -r "$API" "$work/src/api"
    # A toctree BLOCK, not a line appended to the previous one: the root index ends in prose, so a
    # bare indented entry there is "unexpected indentation" plus an orphan page — which is exactly
    # what -W caught on the first attempt. A page not in any toctree is a build failure, and that is
    # the point: the reference cannot be added and then silently left unreachable.
    printf '\n.. toctree::\n   :maxdepth: 1\n   :caption: API reference (generated)\n\n   api/index\n' \
        >> "$work/src/index.rst"
    api_pages=$(find "$work/src/api" -name '*.rst' | wc -l)
fi

if ! sphinx-build -W -b html "$work/src" "$OUT" > "$log" 2>&1; then
    echo "docs-sphinx FAIL: the manual did not build" >&2
    grep -E "WARNING|ERROR" "$log" | head -10 | sed 's/^/    /' >&2 || tail -10 "$log" >&2
    exit 1
fi

# A build that produced nothing is not a passing build. Sphinx exits 0 on an empty
# source tree, which would make this gate report success over a manual that had been
# deleted — the same shape as an empty binding exiting 0, which xiboca now refuses.
pages=$(find "$OUT" -name '*.html' | wc -l)
[ "$pages" -ge 5 ] || {
    echo "docs-sphinx FAIL: only $pages page(s) were produced" >&2
    echo "    a manual that built to almost nothing is not a manual that built" >&2
    exit 1
}

if [ "$api_pages" -gt 0 ]; then
    echo "docs-sphinx OK: $pages page(s) with warnings as errors, including $api_pages generated API page(s)"
else
    echo "docs-sphinx OK: $pages page(s) built from docs/manual with warnings as errors (no generated API reference)"
fi
