#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# THE PACKAGE GATE, ATTACKED (docs/licensing-plan.md; round 15 #4).
#
#   license-package-mutations.sh <package-dir>
#
# `license-package` is only worth its green line if it refuses defective packages, and until now the
# evidence for that was one probe that deleted LICENSE — a branch that already worked — plus nine
# mutations I planted by hand and then deleted, whose proof lived in a transcript. The auditor took
# the same gate, renamed `dub.json` and dropped a GPL-licensed source into it, and got `OK` twice.
#
# So the proof is a table, it runs every build, and each row must be refused FOR ITS OWN REASON. A
# mutation that fails with somebody else's message is reported as a failure here: that is how the
# first version of this gate hid a broken provenance check behind a `find | head -1`.
#
# Adding a check to license-package means adding its mutation here. That is the deal.
set -eu
[ $# -ge 3 ] || { echo "usage: license-package-mutations.sh <package-dir> <archives> <builddir>" >&2; exit 2; }
PKG=$1
ARCHIVES=$2
BDIR=${3:-}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GATE="$ROOT/tests/license-package.sh"

[ -d "$PKG" ] || { echo "license-package-mutations FAIL: $PKG does not exist" >&2; exit 1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# name | expected message fragment | mutation (runs with $P as the package copy)
run_mutation() {
    name=$1; want=$2; shift 2
    P="$WORK/$name"
    rm -rf "$P"; cp -r "$PKG" "$P"
    ( P="$P"; eval "$*" )
    out=$(sh "$GATE" "$P" "$ARCHIVES" "$BDIR" 2>&1) && {
        echo "license-package-mutations FAIL: \`$name\` was ACCEPTED by license-package." >&2
        echo "    A package with this defect must be refused; the gate returned 0." >&2
        bad=$((bad + 1)); rm -rf "$P"; return 0
    }
    if ! printf '%s' "$out" | grep -q "$want"; then
        echo "license-package-mutations FAIL: \`$name\` was refused for the WRONG reason." >&2
        echo "    expected a message containing: $want" >&2
        echo "    got: $(printf '%s' "$out" | grep FAIL | head -1)" >&2
        bad=$((bad + 1)); rm -rf "$P"; return 0
    fi
    n=$((n + 1)); rm -rf "$P"
}

# THE ROW COUNT IS DECLARED, not merely reported. Every battery here printed the number IT had
# counted, incremented only on success, and nobody compared it to anything: a row that silently
# stopped running — a scaffold that failed, a helper renamed — would lower the number and still say
# OK. A smaller number was not a failure for anyone. Same shape as "0 archive(s)" and "0 shadow
# document(s)", found the same day, in the batteries written to catch exactly that.
EXPECT_ROWS=35
bad=0; n=0

# Defined BEFORE any row uses it: the first version sat further down, next to the mutations that
# needed it, and the shell had not seen it yet when an earlier row called it.
remanifest() {
    ( cd "$1" && find . -type f ! -name MANIFEST.sha256 | sed 's|^\./||' | LC_ALL=C sort |
      while IFS= read -r f; do
          printf '%s\t%s\t%s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(wc -c < "$f" | tr -d ' ')" "$f"
      done ) > "$1/MANIFEST.sha256"
}

# THE BASE MUST PASS FIRST. Without this the whole table is worthless in the one case that matters:
# if the real package were already defective, EVERY mutant would be refused, and the "refused for the
# wrong reason" check would not notice — a broken base ADDS messages rather than removing them, so
# the expected fragment is still there. Twenty-seven greens would then certify a gate that refuses
# everything, which is the same shape as a test that passes on emptiness.
if ! sh "$GATE" "$PKG" "$ARCHIVES" "$BDIR" > /dev/null 2>&1; then
    echo "license-package-mutations FAIL: the UNMUTATED package is already refused." >&2
    echo "    Every mutation below would be 'refused' for that reason and this table would read" >&2
    echo "    green while proving nothing. Fix the package first:" >&2
    sh "$GATE" "$PKG" "$ARCHIVES" "$BDIR" 2>&1 | head -4 | sed 's/^/      /' >&2
    exit 1
fi

# --- the licence statement itself ---
run_mutation no-license          "no LICENSE in the package"            'rm -f "$P/LICENSE"'
run_mutation no-license-text     "no LICENSES/BSL-1.0.txt"              'rm -f "$P/LICENSES/BSL-1.0.txt"'
run_mutation no-notice           "no NOTICE in the package"             'rm -f "$P/NOTICE"'
run_mutation notice-no-qt-terms  "does not mention Qt"                  'sed -i "s/LGPLv3/REDACTED/" "$P/NOTICE"'

# --- the manifests, which used to be optional (#4) ---
run_mutation no-dubjson          "no dub.json in the package"           'rm -f "$P/dub.json"'
run_mutation no-buildtxt         "no qtd-build.txt in the package"      'rm -f "$P/qtd-build.txt"'
run_mutation no-verbatim         "no verbatim.txt in the package"       'rm -f "$P/verbatim.txt"'
run_mutation no-manifest         "no MANIFEST.sha256 in the package"    'rm -f "$P/MANIFEST.sha256"'
run_mutation dubjson-no-license  "dub.json has no license field"        'python3 -c "import json,sys;d=json.load(open(sys.argv[1]));d.pop(\"license\",None);json.dump(d,open(sys.argv[1],\"w\"))" "$P/dub.json"'

# --- the closed set, and the manifest read as data rather than as text (round 16 #1 and #2) ---
# These four are the auditor's own counterexamples plus the two they imply. The first two are the
# ones that were ACCEPTED before the manifest existed: an opaque undeclared archive, and a package
# whose machine-readable licence contradicted its own LICENSE file.
run_mutation undeclared-archive  "which the manifest does not list" \
    'cp "$P/lib/libshims.a" "$P/lib/libundeclared.a"'
# ...and the SAME archive with the manifest regenerated. The closed set cannot catch this — every
# digest matches, because whoever adds a file can add its digest. Only the expectation passed in
# from the build graph can, which is why that argument is required rather than optional.
run_mutation undeclared-archive-remanifested "the build graph says it should hold" \
    'cp "$P/lib/libshims.a" "$P/lib/libundeclared.a"; remanifest "$P"'
# ROUND 18 #5 and #6, the two the auditor reproduced on the real package.
run_mutation substituted-archive "is not the archive the build produced" \
    'other=$(ls /usr/lib/lib*.a 2>/dev/null | head -1); cp -f "$other" "$P/lib/libshims.a"; remanifest "$P"'
run_mutation late-spdx           "carries no SPDX identifier" \
    'f="$P/source/qtdctor.cpp"; grep -v "SPDX-License-Identifier" "$f" > "$f.t" && mv "$f.t" "$f"; echo "// SPDX-License-Identifier: BSL-1.0" >> "$f"; remanifest "$P"'
run_mutation dubjson-gpl         "declares \`GPL-3.0-only\`" \
    'sed -i "s/\"license\": \"BSL-1.0\"/\"license\": \"GPL-3.0-only\"/" "$P/dub.json"'
run_mutation dubjson-not-json    "dub.json is not valid JSON"           'echo "{" > "$P/dub.json"'
run_mutation dubjson-not-string  "license field is not a string" \
    'sed -i "s/\"license\": \"BSL-1.0\"/\"license\": 7/" "$P/dub.json"'
# Same length on purpose: appending a byte changes the SIZE too, and the size check runs first, so
# the mutation would be refused with the size message and prove nothing about the digest. The battery
# caught that when the size check was added — which is what "refused for its own reason" is for.
run_mutation tampered-file       "does not match its manifest digest" \
    'sed -i "1s/./X/" "$P/source/qtmoc.d"'
run_mutation manifest-missing-file "which is not in the package" \
    'f=$(find "$P/source/qt" -name "*.d" | head -1); rm -f "$f"'

# --- the four that survived a REGENERATED manifest (round 16 #5) ---------------------------------
# These mutate and then rebuild MANIFEST.sha256, exactly as whoever produces the package would. The
# digests therefore all match, and what has to catch them is the SEMANTICS of the declarations —
# which is the half a checksum cannot speak to.
run_mutation dubjson-duplicate-key "declares the same key twice" \
    'sed -i "s/\"license\": \"BSL-1.0\",/\"license\": \"GPL-3.0-only\", \"license\": \"BSL-1.0\",/" "$P/dub.json"; remanifest "$P"'
run_mutation split-revision       "different generator revisions" \
    'f=$(find "$P/source/qt" -name "*.d" | sort | tail -1); sed -i "s/generator=[^ ]*/generator=deadbee/" "$f"; remanifest "$P"'
run_mutation invented-origin      "which does not exist" \
    'f="$P/source/qt/widgets/qwidget.d"; grep -v "^// provenance:" "$f" > "$f.t" && mv "$f.t" "$f"; echo "source/qwidget.d <- runtime/no-such-file.d @ deadbee" >> "$P/verbatim.txt"; remanifest "$P"'
run_mutation false-size           "the manifest says 999999" \
    'remanifest "$P"; sed -i "s/\t[0-9]*\tLICENSE$/\t999999\tLICENSE/" "$P/MANIFEST.sha256"'
run_mutation origin-outside-runtime "claims an origin outside runtime/" \
    'f="$P/source/qt/widgets/qwidget.d"; grep -v "^// provenance:" "$f" > "$f.t" && mv "$f.t" "$f"; echo "source/qwidget.d <- /etc/passwd @ x" >> "$P/verbatim.txt"; remanifest "$P"'
run_mutation buildtxt-no-modules "qtd-build.txt has no \`modules=\`"    'grep -v "^modules=" "$P/qtd-build.txt" > "$P/t" && mv "$P/t" "$P/qtd-build.txt"'

# --- the licence of the CONTENT, which the auditor walked straight past (#4) ---
run_mutation gpl-payload         "licensed \`GPL-3.0-only\`" \
    'printf "// SPDX-License-Identifier: GPL-3.0-only\n// provenance: generator=x qt=6.11 spec=y\n" > "$P/source/payload.cpp"'
run_mutation agpl-payload        "licensed \`AGPL-3.0-only\`" \
    'printf "// SPDX-License-Identifier: AGPL-3.0-only\n// provenance: generator=x qt=6.11 spec=y\n" > "$P/source/payload.cpp"'
run_mutation noassertion-payload "licensed \`NOASSERTION\`" \
    'printf "// SPDX-License-Identifier: NOASSERTION\n// provenance: generator=x qt=6.11 spec=y\n" > "$P/source/payload.cpp"'

# --- provenance ---
run_mutation no-spdx             "carries no SPDX identifier" \
    'f=$(find "$P/source/qt" -name "*.d" | head -1); grep -v "SPDX-License-Identifier" "$f" > "$f.t" && mv "$f.t" "$f"'
run_mutation no-provenance       "has no provenance line" \
    'f=$(find "$P/source/qt" -name "*.d" | head -1); grep -v "^// provenance:" "$f" > "$f.t" && mv "$f.t" "$f"'
run_mutation provenance-mismatch "and the sources say generator=" \
    'sed -i "s/^generator=.*/generator=deadbee/" "$P/qtd-build.txt"'
run_mutation false-verbatim      "claims to be a verbatim copy" \
    'echo "// changed" >> "$P/source/qtmoc.d"'

# --- material that must not travel ---
run_mutation gpl-corpus          'contains `cpptypes`'                  'mkdir -p "$P/source/cpptypes" && touch "$P/source/cpptypes/x.h"'
run_mutation stray-object        "objects, tests and fixtures"          'touch "$P/lib/stray.o"'
run_mutation abs-path            "contains the absolute build path"     'echo "built in '"$ROOT"'" >> "$P/NOTICE"'
run_mutation abs-path-binary     "contains the absolute build path"     'printf "%s" "'"$ROOT"'/generated" >> "$P/lib/libshims.a"'

if [ "$n" -ne "$EXPECT_ROWS" ]; then
    echo "license-package-mutations FAIL: $n row(s) ran, and this table declares $EXPECT_ROWS." >&2
    echo "    A row that stops running lowers a number nobody compares; that is why it is compared." >&2
    bad=$((bad + 1))
fi
[ "$bad" -eq 0 ] || exit 1
echo "license-package-mutations OK: $n defective package(s) built and refused, each for its own stated reason"
