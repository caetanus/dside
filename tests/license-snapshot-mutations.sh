#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# THE SNAPSHOT GATE, ATTACKED.
#
# `license-snapshot` is the gate that checks the other gates: it unpacks what a first push would
# carry into a fresh repository and re-runs the tree checks there. It was proven once, by hand, with
# an orphan file — and then that proof lived in a transcript, which is the failure this audit has
# charged three times.
#
# The rows below are the three ways the difference between "here" and "what would be published"
# actually shows up. All of them are invisible to `license-coverage` run in the working tree, which
# is the entire reason this gate exists: `git ls-files` answers about the index of one machine.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SNAPGATE="$ROOT/tests/license-snapshot.sh"
COVGATE="$ROOT/tests/license-coverage.sh"
COVMUT="$ROOT/tests/license-coverage-mutations.sh"
command -v git >/dev/null 2>&1 || { echo "license-snapshot-mutations: no git" >&2; exit 0; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# THE ROW COUNT IS DECLARED, not merely reported. Every battery here printed the number IT had
# counted, incremented only on success, and nobody compared it to anything: a row that silently
# stopped running — a scaffold that failed, a helper renamed — would lower the number and still say
# OK. A smaller number was not a failure for anyone. Same shape as "0 archive(s)" and "0 shadow
# document(s)", found the same day, in the batteries written to catch exactly that.
EXPECT_ROWS=6
bad=0; n=0

scaffold() {
    T="$WORK/$1"; rm -rf "$T"; mkdir -p "$T/tests" "$T/LICENSES"
    cp "$SNAPGATE" "$T/tests/license-snapshot.sh"
    cp "$COVGATE"  "$T/tests/license-coverage.sh"
    cp "$COVMUT"   "$T/tests/license-coverage-mutations.sh"
    printf 'the project licence, in prose\n' > "$T/LICENSE"
    printf 'SPDX-License-Identifier: BSL-1.0\n' > "$T/LICENSE.license"
    printf 'text of BSL\n' > "$T/LICENSES/BSL-1.0.txt"
    printf 'SPDX-License-Identifier: BSL-1.0\n' > "$T/LICENSES/BSL-1.0.txt.license"
    printf '// SPDX-License-Identifier: BSL-1.0\nmodule a;\n' > "$T/a.d"
    ( cd "$T" && git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -qm t )
}

expect() {   # expect <name> <fragment; empty = must pass>
    name=$1; frag=$2
    out=$(sh "$T/tests/license-snapshot.sh" 2>&1) && rc=0 || rc=$?
    if [ -z "$frag" ]; then
        if [ "$rc" -ne 0 ]; then
            echo "license-snapshot-mutations FAIL: \`$name\` should have PASSED." >&2
            printf '%s\n' "$out" | head -4 | sed 's/^/      /' >&2; bad=$((bad + 1)); return 0
        fi
    else
        if [ "$rc" -eq 0 ]; then
            echo "license-snapshot-mutations FAIL: \`$name\` was ACCEPTED and must not be." >&2
            bad=$((bad + 1)); return 0
        fi
        if ! printf '%s' "$out" | grep -q "$frag"; then
            echo "license-snapshot-mutations FAIL: \`$name\` refused for the WRONG reason." >&2
            echo "    expected: $frag" >&2
            echo "    got: $(printf '%s' "$out" | grep FAIL | head -1)" >&2
            bad=$((bad + 1)); return 0
        fi
    fi
    n=$((n + 1))
}

# 0. a coherent tree
scaffold base
expect base ""

# 1. AN UNTRACKED FILE IS NOT THE CANDIDATE, and must not fail the gate. This row asserted the
#    opposite until round 18 #4: the snapshot used to fold untracked files in and the mutation was
#    written to match, so the table REINFORCED the wrong semantics. A commit carries the index; an
#    untracked file is not in it. The gate reports how many exist and does not judge them.
scaffold untracked-orphan-not-published
printf 'no terms anywhere\n' > "$T/orphan.txt"
expect untracked-orphan-not-published ""

# 1b. ...but a STAGED file with no terms IS the candidate.
scaffold staged-orphan
printf 'no terms anywhere\n' > "$T/orphan.txt"
( cd "$T" && git add orphan.txt )
expect staged-orphan "states no terms"

# 2. PUBLISHABILITY THAT DISAGREES. Stage a NOASSERTION sidecar and then fix the working tree: the
#    index is not publishable and this tree is. Two answers about the same project, and the gate's
#    job is to refuse precisely that rather than pick one.
scaffold publish-disagrees
printf 'binary-ish\n' > "$T/thing.bin"
printf 'SPDX-License-Identifier: NOASSERTION\n' > "$T/thing.bin.license"
( cd "$T" && git add thing.bin thing.bin.license &&
  printf 'SPDX-License-Identifier: BSL-1.0\n' > thing.bin.license )
expect publish-disagrees "publishability differs"

# 2b. STAGED BAD, WORKTREE GOOD — round 18 #4, the reproduction that showed this gate was testing
# the wrong object entirely. The index is the commit candidate; the working tree is not. Before the
# fix, `tar` took names from git and bytes from the worktree, so a file staged WITHOUT its header and
# restored in the worktree passed, and `git show :a.d | grep SPDX` found nothing.
scaffold staged-bad-worktree-good
( cd "$T" && printf 'module a;\n' > a.d && git add a.d &&
  printf '// SPDX-License-Identifier: BSL-1.0\nmodule a;\n' > a.d )
expect staged-bad-worktree-good "states no terms"

# 3. A GATE THAT IS NOT PUBLISHED. If the check itself is missing from the snapshot, the snapshot is
#    unverifiable by whoever receives it — and a green here would be about a script they do not have.
scaffold gate-not-shipped
( cd "$T" && git rm -q --cached tests/license-coverage.sh && printf 'tests/license-coverage.sh\n' > .gitignore &&
  git add .gitignore && git -c user.email=t@t -c user.name=t commit -qm m )
expect gate-not-shipped "is not in the snapshot"

if [ "$n" -ne "$EXPECT_ROWS" ]; then
    echo "license-snapshot-mutations FAIL: $n row(s) ran, and this table declares $EXPECT_ROWS." >&2
    echo "    A row that stops running lowers a number nobody compares; that is why it is compared." >&2
    bad=$((bad + 1))
fi
[ "$bad" -eq 0 ] || exit 1
echo "license-snapshot-mutations OK: $n case(s) judged as contracted — the INDEX is the candidate (a staged file without terms fails, an untracked one does not), publishability may not differ between index and tree, and a gate missing from the candidate is a finding"
