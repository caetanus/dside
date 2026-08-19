#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# THE OUTPUT GATE, ATTACKED.
#
#   license-generated-output-mutations.sh <real qmltc-d> <qml> <qmlmap> <incdir> <generated .d>
#
# `license-generated-output` was rewritten after three of its answers were measured by hand: a tool
# that did not exist passed, a tool that printed a perfect header and exited 3 passed, and "0 shadow
# document(s) carry the notice" was reported as success. Each fix is worth exactly as much as the
# evidence that it holds, and that evidence was a transcript — the same mistake this audit has
# already charged twice.
#
# So the gate is now run against FAKE compilers that reproduce each defect. A real one cannot be
# made to emit `generator=unknown` on demand, and asking it to would mean building a second broken
# compiler; a five-line stand-in that emits exactly the wrong header is the honest way to ask "what
# does the gate DO when it sees this?".
#
# Every row must be refused for its own stated reason. A row refused with somebody else's message is
# a failure here: that is how a vacuous drift check hid behind an unrelated one for a whole round.
set -eu
[ $# -ge 5 ] || { echo "usage: $0 <tool> <qml> <qmlmap> <incdir> <generated.d>" >&2; exit 2; }
REAL=$1; QML=$2; QMLMAP=$3; INCDIR=$4; GEND=$5
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GATE="$ROOT/tests/license-generated-output.sh"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# THE ROW COUNT IS DECLARED, not merely reported. Every battery here printed the number IT had
# counted, incremented only on success, and nobody compared it to anything: a row that silently
# stopped running — a scaffold that failed, a helper renamed — would lower the number and still say
# OK. A smaller number was not a failure for anyone. Same shape as "0 archive(s)" and "0 shadow
# document(s)", found the same day, in the batteries written to catch exactly that.
EXPECT_ROWS=9
bad=0; n=0

# A stand-in compiler. It copies the REAL tool's output and then breaks exactly one thing, so every
# row differs from a passing run in one property and nothing else.
make_fake() {   # make_fake <name> <sed-expr on the header> <exit code> <shadows: yes|no>
    fname="$WORK/$1.sh"
    # When this stand-in must produce NO shadows, it strips `--shadow-dir`/`--shadow-url` from the
    # arguments instead of skipping an invocation: the real compiler writes the shadow files as a
    # side effect of the SAME call whose stdout is being filtered, so "don't run it again" left them
    # on disk and the row was accepted. The fake has to ask for a document without shadows, not
    # pretend afterwards that it did.
    cat > "$fname" <<FAKE
#!/bin/sh
set -- \$(for a in "\$@"; do echo "\$a"; done | awk '
    /^--shadow-(dir|url)\$/ { skip = ("$4" == "no") ? 2 : 0 }
    { if (skip > 0) { skip--; next } print }')
"$REAL" "\$@" 2>/dev/null | sed '$2'
exit $3
FAKE
    chmod +x "$fname"
    printf '%s' "$fname"
}

run_case() {   # run_case <name> <tool> <expected fragment; empty = must pass>
    name=$1; tool=$2; want=$3
    out=$(sh "$GATE" "$tool" "$QML" "$QMLMAP" "$INCDIR" "$GEND" 2>&1) && rc=0 || rc=$?
    if [ -z "$want" ]; then
        if [ "$rc" -ne 0 ]; then
            echo "license-generated-output-mutations FAIL: \`$name\` should have PASSED." >&2
            printf '%s\n' "$out" | head -3 | sed 's/^/      /' >&2; bad=$((bad + 1)); return 0
        fi
    else
        if [ "$rc" -eq 0 ]; then
            echo "license-generated-output-mutations FAIL: \`$name\` was ACCEPTED and must not be." >&2
            bad=$((bad + 1)); return 0
        fi
        if ! printf '%s' "$out" | grep -q "$want"; then
            echo "license-generated-output-mutations FAIL: \`$name\` refused for the WRONG reason." >&2
            echo "    expected: $want" >&2
            echo "    got: $(printf '%s' "$out" | grep FAIL | head -1)" >&2
            bad=$((bad + 1)); return 0
        fi
    fi
    n=$((n + 1))
}

# 0. the real compiler must pass, or every refusal below could be for the same unrelated reason
run_case real "$REAL" ""

# 1. the tool is not there at all — this used to print "not built" and return 0
run_case missing-tool "$WORK/no-such-compiler" "is not built"

# 2. a perfect header and a non-zero exit — this used to be swallowed by `|| true`
run_case nonzero-exit "$(make_fake nonzero 's/$//' 3 yes)" "exited non-zero"

# 3. no shadows written — "0 shadow document(s) carry the notice" used to be success
run_case no-shadows "$(make_fake noshadow 's/$//' 0 no)" "expected 2"

# 4. a revision that came from wherever the tool was run (round 16 #4)
run_case unknown-revision "$(make_fake unknownrev 's/generator=[^ ]*/generator=unknown/' 0 yes)" \
    "records generator=unknown"

# 5. the grant text drifting away from xiboca's
run_case drifted-grant "$(make_fake drift 's/grants no rights in the Qt/grants ALL rights in the Qt/' 0 yes)" \
    "carries no grant/boundary statement"

# 5b. drift in ONE MODE ONLY — the row that distinguishes "the three agree" from "I checked one and
# assumed the rest". Every other mutation here breaks the header in all modes at once, so none of
# them could tell those two apart.
cat > "$WORK/onemode.sh" <<ONEMODE
#!/bin/sh
if [ "\$1" = "--delegate-doc" ]; then
    "$REAL" "\$@" 2>/dev/null | sed 's/grants no rights in the Qt/grants SOME rights in the Qt/'
else
    "$REAL" "\$@" 2>/dev/null
fi
ONEMODE
chmod +x "$WORK/onemode.sh"
run_case drift-in-delegated-only "$WORK/onemode.sh" "does not carry xiboca's grant text"

# 6. no SPDX identifier at all
run_case no-spdx "$(make_fake nospdx '/SPDX-License-Identifier/d' 0 yes)" "carries no SPDX identifier"

# 7. an input digest that is not one
run_case bad-digest "$(make_fake baddigest 's/inputsha256=[0-9a-f]*/inputsha256=x/' 0 yes)" \
    "no 12-hex input digest"

if [ "$n" -ne "$EXPECT_ROWS" ]; then
    echo "license-generated-output-mutations FAIL: $n row(s) ran, and this table declares $EXPECT_ROWS." >&2
    echo "    A row that stops running lowers a number nobody compares; that is why it is compared." >&2
    bad=$((bad + 1))
fi
[ "$bad" -eq 0 ] || exit 1
echo "license-generated-output-mutations OK: $n case(s) judged as contracted — including a missing tool, a compiler that exits non-zero with a perfect header, and one that writes no shadows at all"
