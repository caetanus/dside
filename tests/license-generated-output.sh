#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# EVERY GENERATOR'S OUTPUT CARRIES THE NOTICE (docs/licensing-plan.md Phase 3; rounds 15 #5, 16 #7).
#
#   license-generated-output.sh <qmltc-d> <shadow-producing .qml> <qmlmap.tsv> <-I dir> <generated .d>
#
# Phase 3 was marked done with "every emitted `.d` and `.cpp`" while only xiboca implemented it;
# qmltc-d — whose output a user compiles into their OWN program, outside any package this project
# builds — opened with a single `// GENERATED` line. That is fixed. What follows is the gate, and
# the gate itself had to be rewritten after three of its own answers were measured:
#
#   * pointed at a tool that DOES NOT EXIST it printed "not built" and returned 0 — a green line
#     for a proof that never ran;
#   * given a tool that prints a perfect header and EXITS 3 it returned 0, because both invocations
#     ended in `|| true`. The final sentence asserted properties of a compiler that had failed;
#   * and it reported "0 shadow document(s) carry the SPDX header" as success. Zero is a quantity
#     every claim is true of, which is the passes-on-emptiness shape this repository hunts elsewhere.
#
# So: the tool must exist, every invocation's exit status is contracted, the shadow count is compared
# against the number this fixture is known to produce, the fully-delegated path is exercised (it is a
# separate call in a separate function and was never run), and the notice block is compared to
# xiboca's BOTH ways instead of by three chosen substrings.
set -eu
[ $# -ge 5 ] || { echo "usage: license-generated-output.sh <tool> <qml> <qmlmap> <incdir> <generated.d>" >&2; exit 2; }
TOOL=$1; QML=$2; QMLMAP=$3; INCDIR=$4; GEND=$5
EXPECT_SHADOWS=${EXPECT_SHADOWS:-2}

# NOT a skip. This target's dependencies build the tool, so its absence is a build defect and
# "nothing to check" is the one answer that cannot be right.
if [ ! -x "$TOOL" ]; then
    echo "license-generated-output FAIL: $TOOL is not built" >&2
    echo "    it is a dependency of this target; a missing tool is a defect, not an empty check." >&2
    exit 1
fi

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
bad=0
fail() { echo "license-generated-output FAIL: $1" >&2; [ -n "${2:-}" ] && echo "    $2" >&2; bad=$((bad + 1)); }

check_file() {
    _label=$1; _f=$2
    [ -s "$_f" ] || { fail "$_label produced no output"; return; }
    grep -q "SPDX-License-Identifier: BSL-1.0" "$_f" || \
        fail "$_label carries no SPDX identifier" "this file travels into someone else's program"
    grep -q "grants no rights in the Qt" "$_f" || \
        fail "$_label carries no grant/boundary statement" \
             "BSL over our text is only half of it; the other half is what it does NOT cover"
    # VALUES, not just keys. `generator=unknown` satisfied "has a provenance line" for as long as the
    # revision came from the caller's working directory (round 16 #4).
    _p=$(grep -m1 "^// provenance:" "$_f" || true)
    [ -n "$_p" ] || { fail "$_label carries no provenance line"; return; }
    case "$_p" in
      *"generator=unknown"*) fail "$_label records generator=unknown" \
          "the revision must come from the build that produced the tool, not from where it is run" ;;
    esac
    _sha=$(printf '%s' "$_p" | sed -n 's/.*inputsha256=\([0-9a-f]*\).*/\1/p')
    [ ${#_sha} -eq 12 ] || fail "$_label has no 12-hex input digest (got '${_sha}')" \
        "a revision alone does not say WHICH document this came from"
    case "$_p" in
      *"notice=v1"*) : ;;
      *) fail "$_label does not record the notice version" ;;
    esac
    case "$_p" in
      *"input=/"*) fail "$_label records an absolute input path" \
          "that publishes the directory layout of the machine that ran the tool" ;;
    esac
}

# The canonical block: everything from the grant's first line to its last. Compared as a block and
# in BOTH directions — the previous check asked only whether three chosen substrings from
# xiboca appeared in qmltc-d, so deleting a line from the reference disabled the obligation.
# `|| true`: an EMPTY block is a finding, not a reason to die. Under `set -e` the trailing `grep`
# returning "no lines" killed the script before it could report anything — rc=1, no output, which is
# the least useful way a gate can fail.
notice_block() { sed -n '/generator-authored portions/,/See LICENSE and docs\/licensing.md/p' "$1" |
                 sed 's/^[/ *<!-]*//; s/[[:space:]]*$//' | grep -v '^$' || true; }

cls=$(basename "$QML" .qml)

# 1. compiled document
if ! "$TOOL" "$QML" "$cls" --qmlmap "$QMLMAP" -I "$INCDIR" > "$WORK/compiled.d" 2>"$WORK/c.err"; then
    fail "the compiler exited non-zero writing the compiled document" "$(head -1 "$WORK/c.err")"
fi
check_file "the compiled document" "$WORK/compiled.d"
grep -q "compiled to D" "$WORK/compiled.d" || fail "the compiled document does not say what it is"

# 2. fully delegated document — a separate call, in a separate function, never exercised before
if ! "$TOOL" --delegate-doc "$QML" "$cls" --qmlmap "$QMLMAP" -I "$INCDIR" > "$WORK/deleg.d" 2>"$WORK/d.err"; then
    fail "the compiler exited non-zero writing the delegated document" "$(head -1 "$WORK/d.err")"
fi
check_file "the delegated document" "$WORK/deleg.d"
grep -q "DELEGATED to the engine" "$WORK/deleg.d" || \
    fail "the delegated document does not say it was delegated"

# 3. shadows, and HOW MANY. This fixture exists to refuse an expression; if it stops producing
# shadows the mode is no longer covered and the gate must say so instead of reporting zero as clean.
mkdir -p "$WORK/sh"
if ! "$TOOL" "$QML" "$cls" --qmlmap "$QMLMAP" -I "$INCDIR" --shadow-dir "$WORK/sh" \
        --shadow-url "qrc:/qtdshadow/" > /dev/null 2>"$WORK/s.err"; then
    fail "the compiler exited non-zero writing shadows" "$(head -1 "$WORK/s.err")"
fi
found=0
for s in "$WORK"/sh/*.qml; do [ -f "$s" ] || continue; found=$((found + 1)); check_file "shadow $(basename "$s")" "$s"; done
[ "$found" -eq "$EXPECT_SHADOWS" ] || \
    fail "$found shadow document(s), expected $EXPECT_SHADOWS" \
         "zero would make every claim about shadows vacuously true; a change here means the fixture stopped covering this mode"

# 4. the two generators must emit the SAME grant, line for line, both ways.
if [ -f "$GEND" ]; then
    notice_block "$GEND" > "$WORK/ref.txt"
    [ -s "$WORK/ref.txt" ] || fail "no notice block found in the xiboca sample" \
        "the reference side of this comparison is empty, so it would compare nothing"
    # ALL THREE OUTPUTS, not the compiled one. The message claimed "the grant block is byte-identical
    # to xiboca's" while comparing a single document; measured, all three do match today, and
    # the reason is structural — one `qtdEmitNotice` writes them. Structural is not the same as
    # verified: the two GENERATORS also "obviously" agreed until their texts were compared, and the
    # drift would be in the legal wording.
    for _o in "$WORK/compiled.d" "$WORK/deleg.d" "$WORK"/sh/*.qml; do
        [ -f "$_o" ] || continue
        notice_block "$_o" > "$WORK/got.txt"
        if ! diff -q "$WORK/ref.txt" "$WORK/got.txt" >/dev/null; then
            fail "$(basename "$_o") does not carry xiboca's grant text"
            diff "$WORK/ref.txt" "$WORK/got.txt" | head -6 | sed 's/^/      /' >&2
        fi
    done
else
    fail "no generated-d sample given — the drift check between the two generators did not run"
fi

[ "$bad" -eq 0 ] || exit 1
echo "license-generated-output OK: compiled, delegated and $found shadow document(s) each carry the SPDX header, the grant and a provenance line with a build-supplied revision, a 12-hex input digest and no absolute path; the grant block is byte-identical to xiboca's"
