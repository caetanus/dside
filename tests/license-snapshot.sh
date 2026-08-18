#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# THE GATES, RUN AGAINST WHAT WOULD ACTUALLY BE PUBLISHED (round 17 #4).
#
# `license-coverage` asks git which files exist, so it answers about the INDEX of the machine it runs
# on. Measured on 2026-08-14: the working tree was green while five files carried no terms at all —
# the GPL, LGPL-2.1, LGPL-3.0 and Qt-Commercial records, and the Qt licence matrix. Every one of them
# is load-bearing for the policy, and every one was invisible because it was untracked. "Green for
# whoever has my uncommitted files" is not a property anyone else can use.
#
# So the unit under test is a SNAPSHOT: tracked files plus untracked-not-ignored ones, unpacked into
# a fresh repository, which is what a first push would carry. The gates then run there. A file that
# exists only in someone's working copy cannot make this pass.
#
# It deliberately re-runs the tree gates rather than reasoning about them: the whole finding is that
# the same script gives different answers in different trees, so the answer that matters is the one
# it gives in this one.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

command -v git >/dev/null 2>&1 || { echo "license-snapshot: no git" >&2; exit 1; }

SNAP=$(mktemp -d); trap 'rm -rf "$SNAP"' EXIT
# THE INDEX, not the working tree (round 18 #4). This took NAMES from `git ls-files -c -o` and then
# handed them to `tar`, which reads BYTES from the working tree — and threw in every untracked file
# for good measure. Neither is what a push carries: a push carries commits, and a commit carries the
# index. Reproduced by the auditor and by me: stage a file with its SPDX header REMOVED, restore the
# header in the working tree only, and this gate answered `OK ... publishability agrees (pass)`
# while `git show :a.d | grep SPDX` found nothing. The gate asserted the opposite of the object it
# claimed to test.
#
# `git archive` of a tree written from the index is the candidate commit, exactly. Untracked files
# are reported separately below rather than mixed in, because "not yet added" and "about to be
# published" are different facts and calling their union "what would be published" was the defect.
tree=$(git write-tree) || { echo "license-snapshot FAIL: cannot write a tree from the index" >&2; exit 1; }
git archive "$tree" | tar -xf - -C "$SNAP"
n=$(git ls-files -c | grep -c . || true)
[ "${n:-0}" -gt 0 ] || { echo "license-snapshot FAIL: the index is empty" >&2; exit 1; }

# ...and the files that exist only in the working tree, named as such. A licence gate that silently
# folded these in is how five untracked licence texts once made a tree look complete.
untracked=$(git ls-files -o --exclude-standard | grep -c . || true)
( cd "$SNAP" && git init -q . && git add -A &&
  git -c user.email=snapshot@local -c user.name=snapshot commit -qm "snapshot under test" )

bad=0
run_in_snapshot() {   # run_in_snapshot <label> <script> [args...]
    _label=$1; shift
    [ -f "$SNAP/$1" ] || { echo "license-snapshot FAIL: $1 is not in the snapshot" >&2
                           echo "    a gate that is not published cannot check what is" >&2
                           bad=$((bad + 1)); return 0; }
    if ! ( cd "$SNAP" && sh "$@" ) > "$SNAP/.out" 2>&1; then
        echo "license-snapshot FAIL: $_label fails inside the snapshot, though it passes here." >&2
        head -5 "$SNAP/.out" | sed 's/^/      /' >&2
        bad=$((bad + 1))
    fi
}

run_in_snapshot "license-coverage" tests/license-coverage.sh
run_in_snapshot "license-coverage-mutations" tests/license-coverage-mutations.sh

# ...and the publication verdict is REPORTED from the snapshot, not from here. It is expected to be
# red while any file's terms are unestablished; what must not happen is the two trees disagreeing
# about it, because then the answer depends on whose checkout was asked.
if ( cd "$SNAP" && sh tests/license-coverage.sh --publish ) >/dev/null 2>&1; then
    snap_pub=pass
else
    snap_pub=refuse
fi
if sh tests/license-coverage.sh --publish >/dev/null 2>&1; then here_pub=pass; else here_pub=refuse; fi
if [ "$snap_pub" != "$here_pub" ]; then
    echo "license-snapshot FAIL: publishability differs — snapshot says $snap_pub, this tree says $here_pub" >&2
    echo "    the two answers cannot both be about the same project" >&2
    bad=$((bad + 1))
fi

[ "$bad" -eq 0 ] || exit 1
echo "license-snapshot OK: $n file(s) from the INDEX unpacked into a fresh repository (${untracked:-0} untracked file(s) exist and are deliberately NOT part of it) — the tree gates give the same answers there as here, and publishability agrees ($snap_pub)"
