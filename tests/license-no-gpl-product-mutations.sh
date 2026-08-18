#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# THE QT MODULE GATE, ATTACKED.
#
# `license-no-gpl-product` decides whether a module may be linked into a product. Its refusals were
# proven by hand — the auditor's own `Qt6CanvasPainter` fixture, a GPL-only module, an archive whose
# manifest declared Qt MQTT, and an unrecorded Qt release — and every one of those proofs then lived
# in a transcript. That is the mistake this audit has charged three times, and the gate is the one
# whose failure mode is a licence violation rather than a wrong number.
#
# It runs against a SYNTHETIC root: its own matrix, its own specs, its own link manifest. That is not
# a convenience — the matrix is keyed by the EXACT installed Qt release, so the only way to ask "what
# does it do when the release is not recorded?" is to control the matrix, and the only way to ask
# about a GPL-only module is to write a spec that requests one. Doing either in the real tree would
# mean shipping a fixture that requests Qt Charts.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GATE="$ROOT/tests/license-no-gpl-product.sh"
QTVER=$(pkg-config --modversion Qt6Core 2>/dev/null || echo "")
[ -n "$QTVER" ] || { echo "license-no-gpl-product-mutations: no Qt6 here" >&2; exit 0; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# THE ROW COUNT IS DECLARED, not merely reported. Every battery here printed the number IT had
# counted, incremented only on success, and nobody compared it to anything: a row that silently
# stopped running — a scaffold that failed, a helper renamed — would lower the number and still say
# OK. A smaller number was not a failure for anyone. Same shape as "0 archive(s)" and "0 shadow
# document(s)", found the same day, in the batteries written to catch exactly that.
EXPECT_ROWS=8
bad=0; n=0

scaffold() {   # scaffold <name> [omit-release]
    T="$WORK/$1"; rm -rf "$T"; mkdir -p "$T/tests" "$T/docs" "$T/generator"
    cp "$GATE" "$T/tests/license-no-gpl-product.sh"
    {
        [ "${2:-}" = omit-release ] || printf 'verified-for\t%s\tsynthetic fixture\n' "$QTVER"
        printf '%s\tQt6Core\tlgpl\tfixture\n' "$QTVER"
        printf '%s\tQt6Gui\tlgpl\tfixture\n' "$QTVER"
        printf '%s\tQt6Charts\tgpl-only\tfixture: GPLv3 for open-source use\n' "$QTVER"
    } > "$T/docs/qt-license-matrix.tsv"
    printf '{"qt_version":"6","pkg_config":"Qt6Core Qt6Gui","out_dir":"/tmp/x","d_package":"x","abi":"cxx"}\n' \
        > "$T/generator/spec_cxx_ok.json"
    printf '%s/lib/libshims.a\t%s\tQt6Core,Qt6Gui\n' "$T" "$QTVER" > "$T/manifest.tsv"
}

expect() {   # expect <name> <fragment; empty = must pass> [manifest path]
    name=$1; frag=$2; man=${3:-$T/manifest.tsv}
    out=$(sh "$T/tests/license-no-gpl-product.sh" "$man" 2>&1) && rc=0 || rc=$?
    if [ -z "$frag" ]; then
        if [ "$rc" -ne 0 ]; then
            echo "license-no-gpl-product-mutations FAIL: \`$name\` should have PASSED." >&2
            printf '%s\n' "$out" | head -3 | sed 's/^/      /' >&2; bad=$((bad + 1)); return 0
        fi
    else
        if [ "$rc" -eq 0 ]; then
            echo "license-no-gpl-product-mutations FAIL: \`$name\` was ACCEPTED and must not be." >&2
            bad=$((bad + 1)); return 0
        fi
        if ! printf '%s' "$out" | grep -q "$frag"; then
            echo "license-no-gpl-product-mutations FAIL: \`$name\` refused for the WRONG reason." >&2
            echo "    expected: $frag" >&2
            echo "    got: $(printf '%s' "$out" | grep FAIL | head -1)" >&2
            bad=$((bad + 1)); return 0
        fi
    fi
    n=$((n + 1))
}

# 0. a product that only requests established modules
scaffold base
expect base ""

# 1. the auditor's fixture: a module nobody established. It passed the old denylist by not being on it.
scaffold unknown-module
printf '{"qt_version":"6","pkg_config":"Qt6CanvasPainter Qt6Core","out_dir":"/tmp/x","d_package":"x","abi":"cxx"}\n' \
    > "$T/generator/spec_cxx_audit.json"
expect unknown-module "NOT ESTABLISHED"

# 2. a module the matrix records as GPL-only — refused WITH the reason, not just "unknown"
scaffold gpl-module
printf '{"qt_version":"6","pkg_config":"Qt6Charts Qt6Core","out_dir":"/tmp/x","d_package":"x","abi":"cxx"}\n' \
    > "$T/generator/spec_cxx_audit.json"
expect gpl-module "which is GPL-only"

# 3. the ARCHIVE side: the graph says this archive linked a module nobody established. Symbol
#    scanning could never have found this — the whole point of round 16 #3.
scaffold archive-module
printf '%s/lib/libshims.a\t%s\tQt6Mqtt,Qt6Core\n' "$T" "$QTVER" > "$T/manifest.tsv"
expect archive-module "NOT ESTABLISHED"

# 4. a Qt release the matrix does not record: refuse to judge rather than apply another one's rows
scaffold unrecorded-release omit-release
expect unrecorded-release "not a release this licence matrix was verified"

# 5. no manifest at all — the archive half cannot run, and skipping it silently is what made the
#    previous version pass
scaffold no-manifest
expect no-manifest "no link manifest given" "$T/does-not-exist.tsv"

# 6. a module name that is a REGEX. `grep "^$1\t"` matched the first Qt6 row and licensed it (round
#    16 #5); with literal field equality it is simply not found.
scaffold regex-module
printf '{"qt_version":"6","pkg_config":"Qt6.* Qt6Core","out_dir":"/tmp/x","d_package":"x","abi":"cxx"}\n' \
    > "$T/generator/spec_cxx_audit.json"
expect regex-module "NOT ESTABLISHED"

# 7. rows written while reading ANOTHER release. This is round 18 #2 as a defective input: the
#    matrix says it was verified for the installed release, and every module row belongs to a
#    different one. Under module-only keys this passed, because a row answered for a module rather
#    than for a release — which is how adding `verified-for 6.4.2` would have silently inherited
#    every decision taken while reading 6.11.1. The refusal must name the release it was judging
#    for, not fall back to the rows it happens to have.
scaffold rows-from-another-release
{
    printf 'verified-for\t%s\tsynthetic fixture\n' "$QTVER"
    printf '9.9.9\tQt6Core\tlgpl\tfixture read against a release nobody installed\n'
    printf '9.9.9\tQt6Gui\tlgpl\tfixture read against a release nobody installed\n'
} > "$T/docs/qt-license-matrix.tsv"
expect rows-from-another-release "NOT ESTABLISHED"

if [ "$n" -ne "$EXPECT_ROWS" ]; then
    echo "license-no-gpl-product-mutations FAIL: $n row(s) ran, and this table declares $EXPECT_ROWS." >&2
    echo "    A row that stops running lowers a number nobody compares; that is why it is compared." >&2
    bad=$((bad + 1))
fi
[ "$bad" -eq 0 ] || exit 1
echo "license-no-gpl-product-mutations OK: $n synthetic product(s) judged as contracted — including an unestablished module, a GPL-only one, an archive whose link manifest declares one, a regex-shaped name, and a Qt release the matrix does not record"
