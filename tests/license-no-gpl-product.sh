#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# NO UNESTABLISHED QT DEPENDENCY IN A PRODUCT ARTIFACT (docs/licensing-plan.md, Phase 4/5).
#
#   license-no-gpl-product.sh <link-manifest.tsv>
#
# Round 15 killed the previous design in two places and was right in both.
#
# #2 — IT WAS A DENYLIST. A list of GPL-only module names cannot be correct: it refuses only what
# someone remembered to write down, it ages out with every Qt minor, and a module introduced
# tomorrow passes by existing. Measured on this machine: six of the names it carried
# (Qt6Canvas3D, Qt6Mqtt, Qt6VirtualKeyboard, Qt6HttpServer, Qt6Grpc, Qt6Coap) are not even present
# in the installed Qt, while the auditor's fixture requesting an unlisted module was waved through
# with an `OK` that asserted the opposite.
#
# So the polarity is inverted. `docs/qt-license-matrix.tsv` lists the modules whose open-source
# licence is ESTABLISHED, with the source of each statement, and a product may request only those.
# GPL-only, unknown, misspelled and brand-new all fail the same way, which is the only behaviour
# that survives a version bump. The matrix also declares which Qt versions it was verified against,
# and this REFUSES TO JUDGE an unverified version rather than applying another version's answer.
#
# #3 — `nm -u` DID NOT IDENTIFY A MODULE. It grepped for `QQmlJS*`/`QQmlSA*`, the namespaces of the
# one incident that motivated the gate. No other entry had a detector, and code from a GPL-only
# module's headers can be inline or template and leave no undefined symbol at all. The list of
# modules that built each archive now comes from the BUILD GRAPH (the link manifest passed in), so
# the check is against a recorded dependency instead of a recognised name. The symbol scan stays as
# a second opinion — it can catch a module reaching an archive that the manifest does not mention —
# but it is no longer the proof.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST=${1:-}
MATRIX="$ROOT/docs/qt-license-matrix.tsv"

[ -f "$MATRIX" ] || { echo "license-no-gpl-product FAIL: no $MATRIX" >&2; exit 1; }

# --- 0. is this Qt version one the matrix actually speaks about? ---------------------------------
# THE EXACT RELEASE, because that is what the message claims (round 16 #6). This cut 6.11.1 down to
# 6.11, matched `verified-for 6.11`, and then printed "Qt 6.11.1 is a version the matrix was verified
# against" — which the table did not say. The plan and docs/distributing-qt.md both tell the reader
# to consult the licensing page and SBOM for the EXACT release; a gate that rounds the version off
# proves that somebody wrote a minor number down.
QTVER=$(pkg-config --modversion Qt6Core 2>/dev/null || pkg-config --modversion Qt5Core 2>/dev/null || echo "")
if [ -z "$QTVER" ]; then
    echo "license-no-gpl-product FAIL: no Qt found — cannot establish which licence matrix applies" >&2
    exit 1
fi
if ! awk -F'\t' -v v="$QTVER" '$1 == "verified-for" && $2 == v { f=1 } END { exit !f }' "$MATRIX"; then
    echo "license-no-gpl-product FAIL: Qt $QTVER is not a release this licence matrix was verified" >&2
    echo "    against (docs/qt-license-matrix.tsv lists: $(awk -F'\t' '$1=="verified-for"{printf "%s ", $2}' "$MATRIX"))." >&2
    echo "    Patch releases are not interchangeable for this question and this gate will not round" >&2
    echo "    the version off: re-read Qt's licensing page and SBOM for $QTVER and record it." >&2
    exit 1
fi

# LITERAL FIELD EQUALITY, not a pattern (round 16 #5). These were `grep "^$1<TAB>"`, so the module
# name — which arrives from spec JSON and from the link manifest — was interpolated into the PATTERN.
# Measured: looking up the literal name `Qt6.*` returns `Qt6Core lgpl`. A module that does not exist
# inherited the licence of the first line its own name happened to match, and the property this gate
# announces — "unknown is refused" — silently stopped holding. Third instance of the same family in
# this audit: data reaching a tool's pattern instead of its text.
# KEYED BY (RELEASE, MODULE) — round 18 #2. A module-only key let one verified release certify
# artifacts built with another: this machine's manifest carries Qt5 archives built with 5.15.19
# while the matrix records 5.15.17, and the gate printed "Qt 6.11.1 is the exact release the matrix
# records as verified" and signed for both. `any` is the one wildcard, and it exists for stdc++,
# which is not a Qt module and has no Qt release.
licence_of() { awk -F'\t' -v r="$1" -v n="$2" \
    '($1 == r || $1 == "any") && $2 == n { print $3; exit }' "$MATRIX" 2>/dev/null; }
reason_of()  { awk -F'\t' -v r="$1" -v n="$2" \
    '($1 == r || $1 == "any") && $2 == n { print $4; exit }' "$MATRIX" 2>/dev/null; }
release_recorded() { awk -F'\t' -v v="$1" '$1 == "verified-for" && $2 == v { f=1 } END { exit !f }' "$MATRIX"; }

bad=0
refuse() {
    _m=$1; _where=$2; _rel=${3:-$QTVER}
    _l=$(licence_of "$_rel" "$_m")
    case "${_l:-unknown}" in
      gpl-only) echo "license-no-gpl-product FAIL: $_where requests $_m, which is GPL-only." >&2
                echo "    $(reason_of "$_rel" "$_m")" >&2 ;;
      unknown)  echo "license-no-gpl-product FAIL: $_where requests $_m, whose open-source licence" >&2
                echo "    is NOT ESTABLISHED in docs/qt-license-matrix.tsv for Qt $_rel. Unknown is refused on" >&2
                echo "    purpose: a module this build has never been told about is exactly the" >&2
                echo "    case a denylist waved through." >&2 ;;
      *)        return 0 ;;
    esac
    bad=$((bad + 1))
}

# --- 1. build metadata: what a product spec asks for ---------------------------------------------
specs=0
for spec in "$ROOT"/generator/spec_cxx_*.json; do
    [ -f "$spec" ] || continue
    specs=$((specs + 1))
    pk=$(sed -n 's/.*"pkg_config"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$spec")
    # THE SPEC'S OWN FAMILY decides which release judges it. Judging a Qt5 spec against the Qt6
    # release found first is the same error as certifying a Qt5 archive with a Qt6 verification —
    # it just fails in the opposite direction, refusing modules that ARE recorded for their own Qt.
    case "$pk" in
      *Qt5*) srel=$(pkg-config --modversion Qt5Core 2>/dev/null || echo "") ;;
      *)     srel=$QTVER ;;
    esac
    if [ -z "$srel" ] || ! release_recorded "$srel"; then
        echo "license-no-gpl-product FAIL: $(basename "$spec") targets Qt ${srel:-unknown}, which this" >&2
        echo "    matrix does not record." >&2
        bad=$((bad + 1))
        continue
    fi
    for m in $pk; do refuse "$m" "$(basename "$spec")" "$srel"; done
done

# --- 2. the link manifest: what actually built each archive --------------------------------------
# PER ARTIFACT, WITH ITS OWN RELEASE. The manifest now carries three columns — path, the Qt release
# that produced that artifact, and the EXPANDED link line — because one release verified globally
# certified everything (round 18 #2) and one module name on the compile line is nine libraries on
# the link line (round 18 #1). `pkg-config --libs Qt6WebEngineCore` returns nine here, two of which
# (Qt6WebChannel, Qt6Positioning) were in no matrix row: a module that arrived through ordinary
# dependency resolution was invisible to a gate whose premise is "unknown is refused".
archives=0
if [ -n "$MANIFEST" ] && [ -f "$MANIFEST" ]; then
    while IFS="	" read -r archive arel mods; do
        [ -n "$archive" ] || continue
        archives=$((archives + 1))
        _art="$(basename "$(dirname "$archive")")/$(basename "$archive")"
        if [ -z "$arel" ] || ! release_recorded "$arel"; then
            echo "license-no-gpl-product FAIL: $_art was built with Qt ${arel:-unknown}, which this" >&2
            echo "    matrix does not record. Verifying a DIFFERENT release does not certify this" >&2
            echo "    artifact: every line is judged against the release that produced it." >&2
            bad=$((bad + 1))
            continue
        fi
        for m in $(printf '%s' "$mods" | tr ',' ' '); do
            refuse "$m" "$_art" "$arel"
        done
    done < "$MANIFEST"
else
    echo "license-no-gpl-product FAIL: no link manifest given — the archive half of this check" >&2
    echo "    cannot run, and skipping it silently is what made the previous version pass." >&2
    bad=$((bad + 1))
fi

# --- 3. second opinion: symbols that name a module the manifest did not ---------------------------
# Kept because it is cheap and it looks at the artefact rather than at the graph's description of
# it. It is NOT the proof — see the header — and it can only add findings, never remove them.
syms=0
for a in "$ROOT"/.build/*/libshims.a "$ROOT"/.build/*/libbinding_*.a; do
    [ -f "$a" ] || continue
    syms=$((syms + 1))
    if nm -uC "$a" 2>/dev/null | grep -qE '\bQQmlJS[A-Z]|\bQQmlSA'; then
        echo "license-no-gpl-product FAIL: $(basename "$(dirname "$a")")/$(basename "$a") references" >&2
        echo "    the Qt Qml Compiler (QQmlJS*/QQmlSA*), which is GPL-only, and this is a product" >&2
        echo "    archive." >&2
        bad=$((bad + 1))
    fi
done

# ZERO IS NOT CONFORMANCE. An empty link manifest — which is what a defect in the graph produces —
# made this print "0 archive(s) … request only modules with an established open-source licence" and
# exit 0, because every claim is true of an empty set. There was a guard for a MISSING manifest and
# none for an empty one: the door was locked and the window left open. Same shape as "0 shadow
# document(s)" in the output gate, found the same afternoon.
if [ "$specs" -eq 0 ]; then
    echo "license-no-gpl-product FAIL: no product spec was inspected" >&2
    echo "    generator/spec_cxx_*.json matched nothing; a gate that examines nothing cannot" >&2
    echo "    conclude that everything is in order." >&2
    bad=$((bad + 1))
fi
if [ "$archives" -eq 0 ]; then
    echo "license-no-gpl-product FAIL: the link manifest lists no archive" >&2
    echo "    it is produced by the build graph, so an empty one is a graph defect — and the" >&2
    echo "    sentence below would otherwise certify the empty set." >&2
    bad=$((bad + 1))
fi

[ "$bad" -eq 0 ] || exit 1
echo "license-no-gpl-product OK: Qt $QTVER is the exact release the matrix records as verified; $specs product spec(s) and $archives archive(s) from the build graph request only modules with an established open-source licence; $syms archive(s) also scanned for Qt Qml Compiler symbols"
