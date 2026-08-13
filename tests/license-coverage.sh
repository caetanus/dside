#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# EVERY TRACKED FILE HAS KNOWN TERMS (docs/licensing-plan.md, gate `license-reuse`).
#
# The plan says to run `reuse lint`. When that tool is installed this defers to it, because it is
# the reference implementation of the specification and it will find things a shell script will not.
# When it is not installed the check still runs, in the narrower form that matters most here: a
# tracked file must be covered either by its own SPDX header or by a REUSE.toml annotation, and a
# file covered by neither is a file whose terms nobody can state.
#
# The difference is reported, not hidden. A gate that silently degrades to a weaker check is the
# shape this repository has been caught by more than once.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if command -v reuse >/dev/null 2>&1; then
    echo "license-coverage: reuse is installed — deferring to the reference implementation"
    exec reuse lint
fi

# The REUSE.toml globs, reduced to path prefixes/suffixes this can match. Kept deliberately simple:
# if a pattern here stops matching what REUSE.toml means, the answer is to fail, not to guess.
covered_by_toml() {
    case "$1" in
      *.json|*.tsv|*.txt|*.set|*.qrc|*.baseline) return 0 ;;
      *.md|*.ts|*.yml|*.gitignore|*qmldir|*logo.png) return 0 ;;
      tests/qmltc/*.qml|tests/qmltc/*/*.qml|tests/qml/*.qml|tests/qml/*/*.qml) return 0 ;;
      tests/uic/*.ui|tests/qrc/*) return 0 ;;
      tests/qmltc/cpptypes/*) return 0 ;;
      tests/uic/corpus/*) return 0 ;;
    esac
    return 1
}

[ -f REUSE.toml ] || { echo "license-coverage FAIL: no REUSE.toml" >&2; exit 1; }
[ -f LICENSE ] || { echo "license-coverage FAIL: no LICENSE" >&2; exit 1; }
[ -f LICENSES/BSL-1.0.txt ] || { echo "license-coverage FAIL: LICENSES/BSL-1.0.txt is missing" >&2; exit 1; }

missing=0
n=0
for f in $(git ls-files); do
    [ -f "$f" ] || continue
    n=$((n + 1))
    grep -q "SPDX-License-Identifier" "$f" 2>/dev/null && continue
    covered_by_toml "$f" && continue
    echo "license-coverage FAIL: $f has no SPDX header and no REUSE.toml annotation" >&2
    missing=$((missing + 1))
done

# ...and the third-party paths must NOT have been given ours by accident. This is the direction that
# a coverage count cannot see: a file can be 100% covered and covered WRONG.
wrong=0
for f in $(git ls-files tests/qmltc/cpptypes tests/uic/corpus); do
    [ -f "$f" ] || continue
    if grep -q "SPDX-License-Identifier: BSL-1.0" "$f" 2>/dev/null; then
        echo "license-coverage FAIL: $f is third-party and carries OUR license header" >&2
        wrong=$((wrong + 1))
    fi
done

[ "$missing" -eq 0 ] && [ "$wrong" -eq 0 ] || exit 1
echo "license-coverage OK (without \`reuse\`): $n tracked file(s) covered by an SPDX header or REUSE.toml, and no third-party file carries ours"
