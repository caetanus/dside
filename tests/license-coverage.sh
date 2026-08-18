#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# WHAT TERMS DOES EVERY TRACKED FILE CARRY — asked of the FILE, never of a map.
#
# The previous versions answered this from `REUSE.toml`: a table of path globs with a precedence
# rule. That design produced four of the licensing defects this audit found, and every one of them
# was a property of the MAP rather than of any file:
#
#   * `precedence = "override"` over `tests/qmltc/cpptypes/**` assigned The Qt Company's copyright to
#     22 files written in this repository, and licensed our own work as GPL-3.0-only;
#   * first-match glob resolution licensed 47 `.ui` files of unestablished provenance as ours,
#     because `tests/uic/*.ui` is listed before `tests/uic/corpus/**` and a shell glob matches `/`;
#   * a `case` list inside this very script covered 27 files the TOML never mentioned — a second
#     database that had already drifted from the first;
#   * and round 16 #8: writing into `CBasic.qml` exactly the licence its own annotation gave it made
#     the gate FAIL, because the map said "this directory is third-party" while the map also said
#     "this file is ours". A contradiction the map could hold and a file cannot.
#
# So the map is gone. A file states its own terms, or — when its format has no comment syntax — a
# `<name>.license` sidecar next to it does, which is REUSE's own mechanism for exactly that case.
# There is no glob, no precedence, no first match, and no way for two answers to disagree: there is
# only ever one place to look.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1

if [ "$PUBLISH" -eq 0 ] && command -v reuse >/dev/null 2>&1; then
    echo "license-coverage: reuse is installed — deferring to the reference implementation"
    exec reuse lint
fi

[ -f LICENSE ] || { echo "license-coverage FAIL: no LICENSE" >&2; exit 1; }
[ -f LICENSES/BSL-1.0.txt ] || { echo "license-coverage FAIL: LICENSES/BSL-1.0.txt is missing" >&2; exit 1; }
[ -f REUSE.toml ] && { echo "license-coverage FAIL: REUSE.toml is back." >&2
    echo "    Terms belong in the file or in its own .license sidecar. A path map is the design" >&2
    echo "    that produced four defects in this audit; see the header of this script." >&2; exit 1; }

# A SIDECAR NOBODY ELSE HAS IS NOT A LICENCE STATEMENT. This gate reads the filesystem while the
# artifact it speaks for is the repository, and on the day the sidecars were written that difference
# was 107 files: they existed here, none was tracked, and the gate printed "0 silent". A fresh clone
# would have had 106 files stating nothing, and a source archive would have shipped without them.
# The set of tracked paths is collected once and a sidecar outside it does not count — so forgetting
# `git add` fails the build instead of passing it locally.
TRACKED=$(mktemp); trap 'rm -f "$TRACKED"' EXIT
git ls-files > "$TRACKED"

# A MENTION IS NOT A STATEMENT. This read the first `SPDX-License-Identifier` anywhere in the file,
# so a document that QUOTES an expression was classified by the quotation: docs/licensing-plan.md —
# this project's own plan — came out as `GPL-3.0-only` because it discusses the corpus's terms, and
# CRITICS.md was assigned a fragment of Portuguese prose. Both were then counted as "third-party
# with stated terms". A header is a header: it sits at the top and it is a comment, and anything
# further down is the file talking ABOUT licences rather than declaring its own.
#
# FIVE lines, not fifteen: the first attempt at this fix used a fifteen-line window and the synthetic
# battery immediately accepted a document whose quoted expression sat on line six. Every real header
# in this repository is written at the very top — lines 1-4, or 2-5 where an XML declaration comes
# first — so the window is the size of a header and not the size of an introduction.
_HEADER_LINES=5
expr_of() {   # the ONE place: the file's own header, else its TRACKED sidecar.
    _e=$(head -n "$_HEADER_LINES" "$1" 2>/dev/null |
         grep -m1 -oE "^[[:space:]]*([#*]|//|<!--|--|;)?[[:space:]]*SPDX-License-Identifier:.*" |
         sed 's/.*SPDX-License-Identifier: *//; s/[[:space:]]*$//; s/ *-->.*//' || true)
    [ -n "$_e" ] && { printf '%s' "$_e"; return 0; }
    [ -f "$1.license" ] || return 1
    grep -qxF "$1.license" "$TRACKED" || {
        echo "license-coverage FAIL: $1.license exists but is not tracked by git" >&2
        echo "    a licence statement that only exists on this machine is not one" >&2
        return 1
    }
    _e=$(grep -m1 -o "SPDX-License-Identifier:.*" "$1.license" 2>/dev/null |
         sed 's/SPDX-License-Identifier: *//; s/[[:space:]]*$//' || true)
    [ -n "$_e" ] || return 1
    printf '%s' "$_e"
}

# --- an EXPRESSION, not any string ---------------------------------------------------------------
# The gate treated every non-empty value as "terms stated": `banana-3.0` and
# `LicenseRef-Invented-By-Me` were both counted as "third-party as upstream states it", and
# `license-publishable` then announced "none with unestablished terms". A misspelled identifier —
# `BSL-1`, or `LGPL-3.0` without the `-only` — is the likeliest way this goes wrong and it was
# silent. Presence of a string standing in for correspondence, for the third time in this audit.
#
# The allowlist is not hand-maintained: an identifier is acceptable exactly when its text is in
# LICENSES/. That is REUSE's own rule, and it is the obligation this repository already met twice by
# hand — asserting GPL-3.0 and LGPL meant shipping their texts. A typo fails because no text answers
# to it, and a new licence can only arrive together with its terms.
unknown_id() {   # prints the first identifier in <expression> that has no text in LICENSES/
    printf '%s' "$1" |
      sed 's/[()]/ /g; s/ OR / /g; s/ AND / /g; s/ WITH / /g' |
      tr ' ' '\n' | grep -v '^$' |
      while read -r id; do
          # `GPL-2.0+` is valid SPDX for "or later", and what must be distributed is the BASE text —
          # there is no `GPL-2.0+.txt` and there should not be. Measured while probing the parser:
          # `BSL-1.0+` was refused, which would be an incomprehensible rejection the day somebody
          # vendors a file carrying an or-later expression. Rules close in both directions, and this
          # one only closed in the direction where refusing felt safe.
          id=${id%+}
          [ -f "LICENSES/$id.txt" ] || { printf '%s' "$id"; return 0; }
      done
}

own=0; third=0; unestablished=0; missing=0; bogus=0
unest_list=""
for f in $(git ls-files); do
    [ -f "$f" ] || continue
    case "$f" in *.license) continue ;; esac          # the sidecar is read WITH its file, not alone
    e=$(expr_of "$f" || true)
    case "$e" in
      "")            missing=$((missing + 1))
                     [ "$missing" -le 5 ] && echo "license-coverage FAIL: $f states no terms, and has no .license sidecar" >&2 ;;
      NOASSERTION*)  unestablished=$((unestablished + 1)); unest_list="$unest_list $f" ;;
      BSL-1.0)       own=$((own + 1)) ;;
      *)             _u=$(unknown_id "$e")
                     if [ -n "$_u" ]; then
                         bogus=$((bogus + 1))
                         [ "$bogus" -le 5 ] && echo "license-coverage FAIL: $f declares \`$e\`, and \`$_u\` has no text in LICENSES/" >&2
                     else
                         third=$((third + 1))
                     fi ;;
    esac
done

# ...and OURS must not be written on somebody else's work. This used to be "no BSL header anywhere
# under cpptypes", which was false in both directions: 22 files in that directory ARE ours, and the
# check would have rejected them for saying so. The population is now the files that carry an
# upstream statement — those, and only those, may not also carry ours.
wrong=0
for f in $(git ls-files); do
    [ -f "$f" ] || continue
    # A COPYRIGHT LINE, not the company's name in prose. The first version of this matched any
    # mention, and flagged docs/licensing-plan.md and this very script — both of which discuss Qt's
    # terms at length and are unambiguously ours. A check whose population is "files containing a
    # word" reports on vocabulary.
    grep -qE "^[^A-Za-z]*(SPDX-FileCopyrightText|Copyright \(C\))[^A-Za-z]*[0-9]{4} The Qt Company" "$f" 2>/dev/null || continue
    if grep -q "SPDX-License-Identifier: BSL-1.0" "$f" 2>/dev/null; then
        echo "license-coverage FAIL: $f carries an upstream copyright AND our licence header" >&2
        wrong=$((wrong + 1))
    fi
done

total=$((own + third + unestablished + missing + bogus))
[ "$missing" -eq 0 ] || echo "    ($missing file(s) with no terms at all)" >&2
[ "$missing" -eq 0 ] && [ "$wrong" -eq 0 ] && [ "$bogus" -eq 0 ] || exit 1

if [ "$PUBLISH" -eq 1 ]; then
    if [ "$unestablished" -gt 0 ]; then
        echo "license-publishable FAIL: $unestablished file(s) carry NOASSERTION, which is not a" >&2
        echo "    licence — it is the recorded absence of established terms. A source archive of" >&2
        echo "    this repository cannot be published while they are in it. Phase 1 of" >&2
        echo "    docs/licensing-plan.md is the work that removes them. First few:" >&2
        for f in $unest_list; do echo "      $f" >&2; done | head -5
        exit 1
    fi
    echo "license-publishable OK: $total tracked file(s), none with unestablished terms"
    exit 0
fi

echo "license-coverage OK (without \`reuse\`): $total tracked file(s), each answering for itself — $own ours (BSL-1.0), $third third-party as upstream states it, $unestablished NOASSERTION (terms NOT established; see license-publishable), 0 silent"
