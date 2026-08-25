#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# THE PACKAGE, INSPECTED (docs/licensing-plan.md, gate `license-package`).
#
# Every other licensing check in this repository looks at the SOURCE TREE. This one looks at the
# thing a consumer actually receives, because those are different objects and the difference is
# exactly where compliance goes wrong: a repository can be immaculate while the package it produces
# carries a GPL test corpus, an absolute build path from someone's home directory, or no licence at
# all. It found both of those on its first two runs.
#
# The plan asks four things of it, and each maps to a question a consumer or a lawyer will ask:
#
#   * can I tell what this is licensed as, from the package alone?   -> LICENSE, LICENSES/, NOTICE
#   * can I tell what produced it?                                   -> SPDX + provenance, ALL files
#   * does it carry anything it should not?                          -> tests, corpora, validators
#   * does it leak the machine it was built on?                      -> absolute paths, TEXT OR NOT
#
# NOTE ON `set -e` AND THE MESSAGE CAP: this file deliberately uses `if …; then …; fi` and never
# `[ cond ] && cmd` as the last command of a loop body or of a `{ }` group. The first version used
# the short form to cap the number of messages, and under `set -e` a false test at the end of the
# body is a non-zero exit status for the whole body: with five missing SPDX headers the script
# printed three and DIED, so the corpus, absolute-path and licence-file checks never ran at all. The
# verdict was still 1, which is why it looked fine. A gate that stops checking after the fourth
# finding is a gate that reports on its own patience.
set -eu
. "$(dirname -- "$0")/pybin.sh"          # $PY: the python that actually runs
[ $# -ge 2 ] || { echo "usage: license-package.sh <package-dir> <allowed archives, comma-separated>" >&2
                 echo "    The archive list comes from the BUILD GRAPH. It is required because the" >&2
                 echo "    package's own MANIFEST.sha256 is self-attested: adding an opaque .a AND" >&2
                 echo "    regenerating the manifest passed, since every digest then matched. A" >&2
                 echo "    closed set proves internal consistency; only an expectation from outside" >&2
                 echo "    the package proves it is the package the build produced." >&2; exit 2; }
PKG=$1
ARCHIVES=$2
BDIR=${3:-}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# NOT `exit 0`. An absent package used to pass, on the reasoning that there was nothing to check —
# which is the "silently degrades to a weaker check" shape this repository condemns in writing three
# files away. The build target depends on the install stamp, so if the package is not here the
# question is not "nothing to check", it is "the thing that was supposed to produce it did not".
if [ ! -d "$PKG" ]; then
    echo "license-package FAIL: $PKG does not exist" >&2
    echo "    the install step is a dependency of this gate; a missing package is a build defect," >&2
    echo "    not an empty check." >&2
    exit 1
fi

# THE SAME HEADER RULE AS THE TREE GATE (round 18 #6). `license-coverage` learned that a mention is
# not a header and limits the declaration to the first five lines; this gate kept `grep -q` over the
# whole file and `grep -rho` over the whole package. Measured on the real package: the header was
# removed from `source/qtdctor.cpp`, `// SPDX-License-Identifier: BSL-1.0` was appended to the END of
# the file, the manifest line regenerated — and this gate answered OK, counting it among "829 source
# file(s) all SPDX-headed". It is not headed. The identical defect that classified this project's
# licensing plan by a quotation, surviving in the artifact the consumer receives.
_HEADER_LINES=5
header_expr() {   # the SPDX expression a file DECLARES, or empty
    head -n "$_HEADER_LINES" "$1" 2>/dev/null |
      grep -m1 -oE "^[[:space:]]*([#*]|//|<!--|--|;)?[[:space:]]*SPDX-License-Identifier:.*" |
      sed 's/.*SPDX-License-Identifier: *//; s/[[:space:]]*$//; s/ *-->.*//' || true
}

# THE SAME TWO QUESTIONS, ASKED ONCE FOR ALL THE FILES INSTEAD OF SIX PROCESSES EACH.
#
# header_expr is head+grep+sed — three processes — and the source walk adds two more per file for
# the provenance line and the manifest lookup. Over 829 files that is some five thousand processes
# per pass, and a process is expensive on MSYS: ONE pass of this gate takes 196 s on Windows
# against 320 s for the whole 35-mutation battery on Linux. The battery therefore could not finish
# at all there — killed at 2400 s, twice.
#
# The questions are unchanged: which SPDX expression does the header declare (same pattern, same
# `_HEADER_LINES` window, same trimming), and does the file carry a `// provenance:` line.
scan_files() {   # $@ = files -> "<path>\t<spdx>\t<0|1 provenance>"
    [ $# -gt 0 ] || return 0
    awk -v hdr="$_HEADER_LINES" '
      function emit() { if (f != "") printf "%s\t%s\t%d\n", f, spdx, prov }
      FNR == 1 { emit(); f = FILENAME; spdx = ""; prov = 0 }
      FNR <= hdr && spdx == "" {
          if (match($0, /^[ \t]*([#*]|\/\/|<!--|--|;)?[ \t]*SPDX-License-Identifier:/)) {
              s = substr($0, RSTART + RLENGTH)
              sub(/^[ \t]*/, "", s); sub(/[ \t]*-->.*$/, "", s); sub(/[ \t]+$/, "", s)
              spdx = s
          }
      }
      /^\/\/ provenance:/ { prov = 1 }
      END { emit() }
    ' "$@"
}

bad=0
fail() {
    echo "license-package FAIL: $1" >&2
    if [ -n "${2:-}" ]; then echo "    $2" >&2; fi
    bad=$((bad + 1))
}

# --- 1. can a consumer tell what this is licensed as? ------------------------------------------
if [ ! -f "$PKG/LICENSE" ]; then
    fail "no LICENSE in the package" "the consumer has the code and no statement of what may be done with it"
fi
if [ ! -f "$PKG/LICENSES/BSL-1.0.txt" ]; then
    fail "no LICENSES/BSL-1.0.txt in the package" \
         "an SPDX identifier without its text is a reference to something the consumer does not have"
fi
if [ ! -f "$PKG/NOTICE" ]; then
    fail "no NOTICE in the package"
else
    if ! grep -q "LGPL" "$PKG/NOTICE"; then
        fail "NOTICE does not mention Qt's terms" \
             "the whole point of it is that linking this package does not discharge them"
    fi
    # …and it must not send the reader somewhere that does not answer the question. The NOTICE named
    # the Qt modules via `${qlibs_human:-see qtd-build.txt}`, a variable defined nowhere in the
    # repository, so every package ever built took the fallback — and qtd-build.txt did not list the
    # modules either. A dead cross-reference, in the one field that decides whether the consumer's
    # obligation is LGPL or GPL.
    if grep -q "see qtd-build.txt" "$PKG/NOTICE" && ! grep -q "^modules=" "$PKG/qtd-build.txt" 2>/dev/null; then
        fail "NOTICE refers the reader to qtd-build.txt for the Qt module list, which does not list them" \
             "that field is what tells the consumer whether LGPL or GPL obligations apply"
    fi
fi
# THE MANIFESTS ARE MANDATORY, not "checked if present". Round 15 #4 renamed `dub.json` in a copy
# of the real package and this gate returned OK — including the words "licence … present" — because
# every manifest check was written as `if [ -f … ]`. A conditional check is an invitation: the
# cheapest way to satisfy it is to delete the file it reads.
for m in dub.json qtd-build.txt verbatim.txt MANIFEST.sha256; do
    [ -f "$PKG/$m" ] || fail "no $m in the package" \
        "this file is part of the package's contract, and a missing one used to be silently skipped"
done
# THE VALUE, not the key (round 16 #1). This asked whether a `"license"` key existed and never read
# what it said, so a package whose dub.json declared `GPL-3.0-only` — the one line DUB and the
# registry show a consumer — passed with a message asserting the package was clean. Two answers
# about the same package, both accepted. Parsed as JSON rather than grepped, because a malformed
# manifest, a non-string value or a duplicated key are all ways to satisfy a regex and not a reader.
if [ -f "$PKG/dub.json" ]; then
    dubl=$("$PY" - "$PKG/dub.json" <<'PY' 2>/dev/null || echo "__ERR__"
import json, sys
# DUPLICATE KEYS ARE A FINDING, not a parse detail. `json.load` keeps the LAST occurrence in
# silence, so `"license": "GPL-3.0-only", "license": "BSL-1.0"` reads as BSL while a different
# reader, or a human, may take the first. Round 16 #5 walked straight through this, and the
# comment above claimed duplicates were tested when they were not.
def no_dupes(pairs):
    seen = set()
    for k, _ in pairs:
        if k in seen: raise ValueError("duplicate key: " + k)
        seen.add(k)
    return dict(pairs)
try:
    d = json.load(open(sys.argv[1]), object_pairs_hook=no_dupes)
except ValueError as e:
    print("__DUPKEY__" if "duplicate key" in str(e) else "__INVALID__"); raise SystemExit(0)
except Exception:
    print("__INVALID__"); raise SystemExit(0)
v = d.get("license")
print(v if isinstance(v, str) else ("__MISSING__" if v is None else "__NOTSTR__"))
PY
)
    case "$dubl" in
      "BSL-1.0")   : ;;
      "__INVALID__"|"__ERR__")
          fail "dub.json is not valid JSON" "the file a consumer's tooling parses must parse" ;;
      "__DUPKEY__")
          fail "dub.json declares the same key twice" \
               "readers disagree about which wins, so the package has two answers again" ;;
      "__MISSING__")
          fail "dub.json has no license field" \
               "the registry and every downstream tool read this, not the LICENSE file" ;;
      "__NOTSTR__")
          fail "dub.json's license field is not a string" ;;
      *)  fail "dub.json declares \`$dubl\`, and this package is BSL-1.0" \
              "that field is what DUB and the registry show; it cannot disagree with LICENSE" ;;
    esac
fi

# --- 1b2. the archives the BUILD says exist, checked against the ones present --------------------
# The manifest cannot answer this: whoever adds a file can add its digest too. This list is passed
# in by the target that installed the package, so an extra archive is refused even when the package
# is perfectly self-consistent about it.
# ...AND THE BYTES, not only the names (round 18 #5). The name list closed the "extra archive"
# hole and nothing else: `lib/libshims.a` was replaced with `/usr/lib/libanl.a`, the one manifest
# line recalculated, and this gate answered OK — a proprietary, GPL, stale or simply foreign archive
# passes as long as it occupies one of three known names. The manifest is self-attested for bytes
# and the name list was self-attested for names; the two halves never met. They meet here: each
# archive in the package must be byte-identical to the one the BUILD GRAPH produced.
if [ -n "$BDIR" ] && [ -d "$BDIR" ]; then
    for _a in $(printf '%s' "$ARCHIVES" | tr ',' ' '); do
        [ -f "$PKG/lib/$_a" ] || continue
        if [ ! -f "$BDIR/$_a" ]; then
            fail "the build directory has no $_a to compare against" \
                 "the gate cannot authenticate what the graph did not produce"
        elif ! cmp -s "$PKG/lib/$_a" "$BDIR/$_a"; then
            fail "lib/$_a is not the archive the build produced" \
                 "same name, different bytes — which is exactly what a substituted archive looks like"
        fi
    done
else
    fail "no build directory given — archive bytes cannot be authenticated" \
         "a name list proves a name; only the graph's own output proves the archive"
fi

have=$(ls "$PKG/lib" 2>/dev/null | grep '\.a$' | LC_ALL=C sort | tr '\n' ',' | sed 's/,$//')
want=$(printf '%s' "$ARCHIVES" | tr ',' '\n' | LC_ALL=C sort | tr '\n' ',' | sed 's/,$//')
if [ "$have" != "$want" ]; then
    fail "lib/ holds [$have] and the build graph says it should hold [$want]" \
         "an archive nobody declared has proven nothing about its licence, and regenerating the package's own manifest cannot make it declared"
fi

# --- 1c. the CLOSED SET: every file accounted for, and nothing else present ----------------------
# Round 16 #2 copied an archive to `lib/libgpl_payload.a` and the gate said OK, because it inspected
# the categories it knew (sources, known-bad paths, `*.o`) and an opaque unlisted binary matched
# none of them. Recognition cannot be complete; a closed manifest can. Both directions are checked —
# a file present but unlisted, and a file listed but altered or absent — because either alone leaves
# a way to change what the consumer receives without changing what the gate reads.
if [ -f "$PKG/MANIFEST.sha256" ]; then
    listed=$(mktemp); actual=$(mktemp)
    cut -f3 "$PKG/MANIFEST.sha256" | LC_ALL=C sort > "$listed"
    ( cd "$PKG" && find . -type f ! -name MANIFEST.sha256 | sed 's|^\./||' | LC_ALL=C sort ) > "$actual"
    extra=$(comm -13 "$listed" "$actual" | head -5)
    gone=$(comm -23 "$listed" "$actual" | head -5)
    for f in $extra; do
        fail "the package contains \`$f\`, which the manifest does not list" \
             "an undeclared file has proven nothing about its licence, and this is how one arrives"
    done
    for f in $gone; do
        fail "the manifest lists \`$f\`, which is not in the package"
    done
    tampered=0
    while IFS="	" read -r want size path; do
        [ -f "$PKG/$path" ] || continue
        got=$(sha256sum "$PKG/$path" | cut -d' ' -f1)
        # ...and the SIZE, which was parsed and then ignored — round 16 #5 wrote 999999 for LICENSE
        # and nothing noticed. A column that is never compared is decoration, in a file whose whole
        # purpose is to be compared.
        gotsz=$(wc -c < "$PKG/$path" | tr -d ' ')
        if [ "$gotsz" != "$size" ]; then
            tampered=$((tampered + 1))
            [ "$tampered" -le 3 ] && fail "\`$path\` is $gotsz bytes and the manifest says $size"
            continue
        fi
        [ "$got" = "$want" ] && continue
        tampered=$((tampered + 1))
        [ "$tampered" -le 3 ] && fail "\`$path\` does not match its manifest digest" \
            "the package's own record of itself is measurably false"
    done < "$PKG/MANIFEST.sha256"
    nman=$(wc -l < "$PKG/MANIFEST.sha256")
    rm -f "$listed" "$actual"
fi
for k in qt generator packaged-at generated-from modules; do
    if [ -f "$PKG/qtd-build.txt" ] && ! grep -q "^$k=" "$PKG/qtd-build.txt"; then
        fail "qtd-build.txt has no \`$k=\` line" "the manifest is checked for structure, not presence"
    fi
done

# --- 1b. what licences does the CONTENT actually carry? ------------------------------------------
# The old check asked whether the string "SPDX-License-Identifier" appeared. Round 15 #4 dropped a
# `source/gpl_payload.cpp` carrying `GPL-3.0-only`, a valid provenance line and a name matching none
# of the known-bad paths; the gate counted it, accepted it, and concluded "no test-only or GPL
# material". Presence of an identifier is not the same question as which licence it names, and
# `AGPL-3.0-only`, `LicenseRef-Proprietary` and `NOASSERTION` all passed the same way.
#
# So every expression in the package is extracted and compared against what this product is allowed
# to be. The allowlist is short on purpose: this is OUR artifact, and anything else in it is either
# a mistake or a licensing event that must be decided deliberately, not absorbed by a gate.
_SCAN=$(scan_files $(find "$PKG" -type f 2>/dev/null) 2>/dev/null || true)
badexpr=$(printf '%s\n' "$_SCAN" | cut -f2 | grep -v '^$' | sort -u | grep -v '^BSL-1.0$' || true)
if [ -n "$badexpr" ]; then
    for e in $badexpr; do
        fail "the package contains a file licensed \`$e\`" \
             "this artifact is BSL-1.0; anything else in it is a licensing decision, not a detail"
    done
fi

# --- 2. can a consumer tell what produced it? ---------------------------------------------------
# EVERY source, and BOTH languages. Two earlier versions of this check were narrower and both were
# wrong: the first read `find … | head -1`, and find's order is not stable, so planting an unrelated
# violation changed which file was inspected and the gate reported a provenance failure for a
# package whose provenance was intact; the second swept only `.d`, while Phase 3 of the plan grants
# and requires the notice on every emitted `.d` AND `.cpp` — the eight shipped `.cpp` were simply
# never looked at.
#
# Two populations live under source/ and they are held to different rules. What the generator emits
# must say what produced it. What is COPIED there verbatim from runtime/ is hand-written project
# code that no generator produced — it carries our SPDX header, and a provenance line on it would be
# a lie. The two are told apart by CONTENT (byte-identical to a file under runtime/), never by name.
nsrc=0; ncopy=0; nospdx=0; noprov=0
# The header and the provenance line come from the ONE scan above (see scan_files); the loop below
# asks the same two questions of that table instead of opening five processes per file. `verbatim.txt`
# is read once for the same reason.
_VERB=$(cat "$PKG/verbatim.txt" 2>/dev/null || true)
for _row in $(printf '%s\n' "$_SCAN" | awk -F'\t' '$1 ~ /\/source\/.*\.(d|cpp|h)$/ { print $1 "|" $2 "|" $3 }'); do
    f=${_row%%|*}; _rest=${_row#*|}; _spdx=${_rest%%|*}; _prov=${_rest##*|}
    nsrc=$((nsrc + 1))
    if [ -z "$_spdx" ]; then
        nospdx=$((nospdx + 1))
        if [ "$nospdx" -le 3 ]; then fail "$(basename "$f") carries no SPDX identifier"; fi
    fi
    if [ "$_prov" = 1 ]; then continue; fi
    # The exemption is read from the package's OWN manifest, not from `runtime/` in the repository.
    # Consulting the repo made the gate pass a package that failed Phase 3's exit criterion — "the
    # consumer can determine licence and provenance using only the installed package" — because the
    # five unstamped files were excusable only by looking at a directory the consumer never gets. It
    # also resolved the origin with `find … | head -1`, which is correct only for as long as no two
    # files under runtime/ share a basename (measured: none do today, so it worked by luck of the
    # naming). The manifest names the exact origin path, so both problems go away together.
    #
    # And the manifest is CONFRONTED, not believed: install.sh writes it and this reads it, so on
    # its own it is a note the package hands itself. Where the named origin exists — it does in the
    # build, it will not in a consumer's unpacked copy — the bytes must match it.
    claim=$(printf '%s\n' "$_VERB" | grep "^source/$(basename "$f") <- " | head -1 || true)
    if [ -n "$claim" ]; then
        origin=${claim#* <- }; origin=${origin%% @ *}
        # AN ORIGIN THAT DOES NOT EXIST IS NOT AN EXEMPTION. `cmp` ran only when the named file was
        # present, so a missing origin skipped the comparison and the exemption was granted anyway:
        # a nonexistent path was TRUSTED MORE than a real one, and typo, stale path and invention
        # shared the cheapest route to a free pass (round 16 #3).
        case "$origin" in
          runtime/*) : ;;
          *) fail "$(basename "$f") claims an origin outside runtime/: $origin" \
                  "the exemption exists for verbatim copies of this project's runtime, nothing else" ;;
        esac
        if [ ! -e "$ROOT/$origin" ]; then
            fail "$(basename "$f") claims to be a verbatim copy of $origin, which does not exist" \
                 "an unverifiable claim cannot be the reason a file needs no provenance"
        elif ! cmp -s "$ROOT/$origin" "$f"; then
            fail "$(basename "$f") claims to be a verbatim copy of $origin and differs from it" \
                 "the manifest is the package's own statement; here it is measurably false"
        fi
        ncopy=$((ncopy + 1)); continue
    fi
    noprov=$((noprov + 1))
    if [ "$noprov" -le 3 ]; then
        fail "$(basename "$f") has no provenance line and is not a verbatim runtime copy" \
             "a file that travels alone must say what produced it"
    fi
done
# THE TWO CHANNELS MUST AGREE. A package answers "what produced this?" twice — once per file, once
# in qtd-build.txt — and it used to answer differently: the manifest said `a0b3b94` while every one
# of the 824 generated files said `fa680f9`, one commit apart. Requiring the sentence to EXIST and
# never comparing it to the sentence beside it is the same mistake in a smaller frame, and it is the
# third time in one day that "it is present" stood in for "it is true".
if [ -f "$PKG/qtd-build.txt" ]; then
    declared=$(sed -n 's/^generator=//p' "$PKG/qtd-build.txt" | head -1)
    # THE WHOLE SET, not the first match. This compared qtd-build.txt against `grep -rhm1 … | head -1`,
    # so 823 of the 824 generated sources could name a different revision without changing the
    # verdict — round 16 #3 changed one that was not the first and the gate said OK. A single sample
    # answers a question about a single file.
    revs=$(grep -rho "^// provenance: generator=[^ ]*" "$PKG/source" 2>/dev/null | sed 's/.*generator=//' | sort -u)
    nrev=$(printf '%s\n' "$revs" | grep -c . || true)
    if [ "${nrev:-0}" -gt 1 ]; then
        fail "the generated sources declare $nrev different generator revisions: $(printf '%s ' $revs)" \
             "one package is the output of one generation; more than one revision is a mixed tree"
    fi
    insrc=$(printf '%s' "$revs" | head -1)
    if [ -n "$declared" ] && [ -n "$insrc" ] && [ "$declared" != "$insrc" ]; then
        fail "qtd-build.txt says generator=$declared and the sources say generator=$insrc" \
             "one package, two answers to what produced it; at most one of them is true"
    fi
fi

if [ "$nospdx" -gt 3 ]; then echo "    …and $((nospdx - 3)) more without an SPDX identifier" >&2; fi
if [ "$noprov" -gt 3 ]; then echo "    …and $((noprov - 3)) more without provenance" >&2; fi
if [ "$nsrc" -eq 0 ]; then fail "no source file in the package"; fi

# --- 3. does it carry anything it should not? ---------------------------------------------------
# The GPL-3.0-only corpus and the GPL validator are the two named risks; `tests/` and object files
# are the accidental ones. Checked by presence, not by intention.
for pat in "cpptypes" "uic/corpus" "qmltypes_check"; do
    if find "$PKG" -path "*$pat*" -print -quit 2>/dev/null | grep -q .; then
        fail "the package contains \`$pat\`" \
             "that path is test-only material and must not reach a distributed artifact"
    fi
done
for pat in "*.o" "*_test*" "*.qml"; do
    hit=$(find "$PKG" -name "$pat" -print -quit 2>/dev/null || true)
    if [ -n "$hit" ]; then
        fail "the package contains ${hit#"$PKG"/}" "objects, tests and fixtures are not product"
    fi
done

# --- 4. does it leak the machine it was built on? -----------------------------------------------
# An absolute path from the build machine is both a privacy leak and a package that only works here.
# `grep -a`, NOT `grep -I`: the package ships three static archives, and -I skips binaries by
# definition. They are clean today — measured: zero occurrences, no `/` in any member name, no debug
# sections — but nothing was ENFORCING that, and turning on `-g` would bury the builder's home
# directory inside a 19 MB archive where the previous version of this check could not look.
# `-a` also covers the archive's member-name table, which is plain text inside the file.
leaks=$(grep -arl "$ROOT" "$PKG" 2>/dev/null || true)
for f in $leaks; do
    fail "${f#"$PKG"/} contains the absolute build path" \
         "it names the machine it was built on and will not resolve anywhere else"
done

if [ "$bad" -ne 0 ]; then exit 1; fi
echo "license-package OK: $(basename "$PKG") — $nsrc source file(s) all SPDX-headed, $((nsrc - ncopy)) carrying a provenance line and $ncopy verbatim runtime copies exempt; licence, notices and module list present; no test-only or GPL material; no absolute build path in any file, text or binary"
