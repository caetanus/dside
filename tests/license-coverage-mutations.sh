#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# THE TREE GATE, ATTACKED.
#
# `license-package` has a table of 32 defective packages and refuses every one of them for its own
# reason. `license-coverage` — which decides what the terms of 551 tracked files are — had no such
# table, and in one afternoon it produced two defects of exactly the kind a table catches:
#
#   * it read the first `SPDX-License-Identifier` ANYWHERE in a file, so a document that QUOTED an
#     expression was classified by the quotation. This project's own licensing plan came out as
#     `GPL-3.0-only`; CRITICS.md was assigned a fragment of Portuguese prose; both were counted as
#     "third-party with stated terms".
#   * it accepted a `.license` sidecar that existed only on this machine. On the day the sidecars
#     were written that was 107 files: the gate printed "0 silent" while a fresh clone would have
#     had 106 files stating nothing.
#
# Neither is exotic and neither was caught by reading the code — both were found by looking at what
# the gate ANSWERED for a specific file. So the answers are pinned here.
#
# It runs against a SYNTHETIC repository, not this one: the gate's unit is "a git tree", the whole
# point is to control what is in it, and mutating the real tree to test a gate is how a green build
# comes to describe a repository nobody has.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GATE="$ROOT/tests/license-coverage.sh"
command -v git >/dev/null 2>&1 || { echo "license-coverage-mutations: no git" >&2; exit 0; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# THE ROW COUNT IS DECLARED, not merely reported. Every battery here printed the number IT had
# counted, incremented only on success, and nobody compared it to anything: a row that silently
# stopped running — a scaffold that failed, a helper renamed — would lower the number and still say
# OK. A smaller number was not a failure for anyone. Same shape as "0 archive(s)" and "0 shadow
# document(s)", found the same day, in the batteries written to catch exactly that.
EXPECT_ROWS=12
bad=0; n=0

# build a minimal tree that PASSES, then mutate one thing at a time
scaffold() {
    T="$WORK/$1"; rm -rf "$T"; mkdir -p "$T/tests" "$T/LICENSES"
    cp "$GATE" "$T/tests/license-coverage.sh"
    printf 'the project licence, in prose\n' > "$T/LICENSE"
    printf 'SPDX-FileCopyrightText: 2026 X\nSPDX-License-Identifier: BSL-1.0\n' > "$T/LICENSE.license"
    printf 'text of BSL\n' > "$T/LICENSES/BSL-1.0.txt"
    printf 'SPDX-FileCopyrightText: 2026 X\nSPDX-License-Identifier: BSL-1.0\n' > "$T/LICENSES/BSL-1.0.txt.license"
    printf '// SPDX-FileCopyrightText: 2026 X\n// SPDX-License-Identifier: BSL-1.0\nmodule a;\n' > "$T/a.d"
    printf '{"k":1}\n' > "$T/b.json"
    printf 'SPDX-FileCopyrightText: 2026 X\nSPDX-License-Identifier: BSL-1.0\n' > "$T/b.json.license"
    ( cd "$T" && git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -qm t )
}

expect() {   # expect <name> <pass|fail> <fragment> ; mutation already applied to $T
    name=$1; want=$2; frag=$3
    out=$(sh "$T/tests/license-coverage.sh" 2>&1) && rc=0 || rc=$?
    if [ "$want" = pass ] && [ "$rc" -ne 0 ]; then
        echo "license-coverage-mutations FAIL: \`$name\` should have PASSED and did not." >&2
        printf '%s\n' "$out" | head -3 | sed 's/^/      /' >&2; bad=$((bad + 1)); return 0
    fi
    if [ "$want" = fail ]; then
        if [ "$rc" -eq 0 ]; then
            echo "license-coverage-mutations FAIL: \`$name\` was ACCEPTED and must not be." >&2
            bad=$((bad + 1)); return 0
        fi
        if ! printf '%s' "$out" | grep -q "$frag"; then
            echo "license-coverage-mutations FAIL: \`$name\` was refused for the WRONG reason." >&2
            echo "    expected: $frag" >&2
            echo "    got: $(printf '%s' "$out" | grep FAIL | head -1)" >&2
            bad=$((bad + 1)); return 0
        fi
    fi
    n=$((n + 1))
}

# 0. the baseline must pass, or nothing below means anything (the lesson from the package battery)
scaffold base
expect base pass ""

# 1. a file with no terms at all
scaffold no-terms
printf 'module c;\n' > "$T/c.d"; ( cd "$T" && git add -A && git -c user.email=t@t -c user.name=t commit -qm m )
expect no-terms fail "states no terms"

# 2. A MENTION IS NOT A STATEMENT — the defect that classified our own plan as GPL
scaffold quoted-spdx
printf '# a document\n\nit discusses terms\n\n```\nSPDX-License-Identifier: GPL-3.0-only\n```\n' > "$T/doc.md"
( cd "$T" && git add -A && git -c user.email=t@t -c user.name=t commit -qm m )
expect quoted-spdx fail "states no terms"

# 3. a sidecar that only exists locally — the 107-file defect
scaffold untracked-sidecar
printf '{"k":2}\n' > "$T/d.json"
printf 'SPDX-License-Identifier: BSL-1.0\n' > "$T/d.json.license"
( cd "$T" && git add d.json && git -c user.email=t@t -c user.name=t commit -qm m )
expect untracked-sidecar fail "is not tracked by git"

# 4. our licence written onto somebody else's work
scaffold wrong-attribution
printf '// Copyright (C) 2021 The Qt Company Ltd.\n// SPDX-License-Identifier: BSL-1.0\n' > "$T/e.h"
( cd "$T" && git add -A && git -c user.email=t@t -c user.name=t commit -qm m )
expect wrong-attribution fail "upstream copyright AND our licence header"

# 5. the map coming back
scaffold map-returns
printf 'version = 1\n' > "$T/REUSE.toml"
( cd "$T" && git add -A && git -c user.email=t@t -c user.name=t commit -qm m )
expect map-returns fail "REUSE.toml is back"

# 6b. an expression nobody can point at a licence text — a typo is the likeliest form of this
scaffold invented-expression
printf '// SPDX-License-Identifier: banana-3.0\nint x;\n' > "$T/x.cpp"
( cd "$T" && git add -A && git -c user.email=t@t -c user.name=t commit -qm m )
expect invented-expression fail "has no text in LICENSES/"

# 6c. the plausible typo: a real family, the wrong identifier
scaffold typo-expression
printf '// SPDX-License-Identifier: BSL-1\nint x;\n' > "$T/x.cpp"
( cd "$T" && git add -A && git -c user.email=t@t -c user.name=t commit -qm m )
expect typo-expression fail "has no text in LICENSES/"

# 6d. a LicenseRef with no text beside it — this project created one on 2026-08-14 and would not
# have noticed had it been misspelled
scaffold licenseref-without-text
printf '// SPDX-License-Identifier: LicenseRef-Something OR BSL-1.0\nint x;\n' > "$T/x.cpp"
( cd "$T" && git add -A && git -c user.email=t@t -c user.name=t commit -qm m )
expect licenseref-without-text fail "LicenseRef-Something\` has no text"

# 6e. ...and a rule closes in BOTH directions. `+` means "or later"; the text to ship is the base
# one, so this must PASS. Nearly every row in this table demands a refusal, which is exactly how a
# rule comes to be over-strict without anyone noticing.
scaffold or-later-passes
printf '// SPDX-License-Identifier: BSL-1.0+\nint x;\n' > "$T/x.cpp"
( cd "$T" && git add -A && git -c user.email=t@t -c user.name=t commit -qm m )
expect or-later-passes pass ""

# 6. inventory tolerates NOASSERTION; publication does not
scaffold noassertion
printf 'binary\n' > "$T/f.bin"
printf 'SPDX-License-Identifier: NOASSERTION\n' > "$T/f.bin.license"
( cd "$T" && git add -A && git -c user.email=t@t -c user.name=t commit -qm m )
expect noassertion pass ""
if sh "$T/tests/license-coverage.sh" --publish >/dev/null 2>&1; then
    echo "license-coverage-mutations FAIL: --publish accepted a tree containing NOASSERTION." >&2
    bad=$((bad + 1))
else
    n=$((n + 1))
fi

if [ "$n" -ne "$EXPECT_ROWS" ]; then
    echo "license-coverage-mutations FAIL: $n row(s) ran, and this table declares $EXPECT_ROWS." >&2
    echo "    A row that stops running lowers a number nobody compares; that is why it is compared." >&2
    bad=$((bad + 1))
fi
[ "$bad" -eq 0 ] || exit 1
echo "license-coverage-mutations OK: $n synthetic tree(s) judged as contracted — including a quoted expression refused as a statement, a sidecar that exists only locally, and NOASSERTION separating inventory from publication"
