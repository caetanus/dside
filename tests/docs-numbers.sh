#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# THE DOCUMENTED NUMBERS ARE THE MEASURED ONES.
#
#   docs-numbers.sh <dir holding counts_<style>.tsv and optlevels_<style>.tsv>
#
# On 2026-08-14 every coverage figure in README.md and docs/qmltc-d.md was wrong, in four different
# ways at once:
#
#   * the `-O3` column read 329 — the count of documents HANDLED — under a heading that says "what
#     each level actually compiles". What compiles AND is proven equivalent is 248; 36 are demoted
#     to the engine and 45 cannot be judged. Merging them turned "handed over safely" into
#     "compiled", which is the distinction the whole -O ladder exists to make;
#   * a second table was three documents stale (245/39 against a measured 248/36);
#   * the paragraph above that table said "49 reach it as -O0" while the table said 39;
#   * and `-O1` read 111, with Fusion at 38, where the gate reports 110 and 37.
#
# None of that was a defect in the compiler. It was four numbers typed by hand from a run, and then
# the run changed. So the gates now WRITE what they counted, and this compares the documents against
# those files. Correcting the figures without this would have been the same work again in a month.
set -eu
[ $# -ge 1 ] || { echo "usage: docs-numbers.sh <build dir>" >&2; exit 2; }
# TWO DIRECTORIES, because the two gates write where each of them already had a scratch area: the
# o3 gate into `<bdir>/o3gate`, the optlevels gate into `<bdir>`. Passing one and hoping is how a
# check comes to read half of what it claims — so both are derived here and both must be populated.
BDIR=$1
CDIR="$BDIR/o3gate"
ODIR="$BDIR"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$(dirname -- "$0")/shplatform.sh"

# THESE NUMBERS ARE A PAIRING, like a coverage baseline. They count Qt's OWN Controls documents, so
# they are a property of the Qt that is installed: 6.10.3 ships a different corpus from 6.11.1 and
# legitimately gives different totals (measured: 106 at -O1 against the documented 110). Comparing
# across releases is not a stricter check, it is a different question — the same conclusion the
# manifest gates reached about coverage.
#
# The document says which release it was measured against; where that is not the release in front
# of us, the gate says NOT COMPARABLE and stops, rather than accusing a correct document.
# ...AND THE PLATFORM, for the same reason and measured the same way. With both machines on Qt
# 6.11.1 the release stopped telling them apart and the figures still differed: `TextField` is
# DEMOTED on Linux ("1 value(s) differ at -Ox") and COMPILED on Windows, in Imagine and in Material
# alike, so the totals read 248/36 there and 250/34 here. That is one document behaving differently
# on two platforms, not a stale table — and accusing the table of being wrong would be the fourth
# time in this repository that a (platform, Qt) number was written down as if it were universal.
DOC_PAIR=$(sed -n 's/^<!-- measured-against: \(.*\) -->$/\1/p' "$ROOT/docs/qmltc-d.md" | head -1)
DOC_QT=$(printf '%s' "$DOC_PAIR" | sed -n 's/.*qt=\([0-9.]*\).*/\1/p')
DOC_PLAT=$(printf '%s' "$DOC_PAIR" | sed -n 's/.*platform=\([a-z]*\).*/\1/p')
HAVE_QT=$(pkg-config --modversion Qt6Core 2>/dev/null \
          || qt_release_from_prefix "${QTDIR6:-}" || qt_release_from_prefix "${QTDIR:-}" || echo "")
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) HAVE_PLAT=windows ;;
  Darwin)               HAVE_PLAT=macos ;;
  Linux)                HAVE_PLAT=linux ;;
  *)                    HAVE_PLAT=posix ;;
esac
notcomparable() {
    echo "docs-numbers NOT COMPARABLE: the figures were measured on $1 and this is $2."
    echo "    They count Qt's own Controls documents compiled by this compiler, so both halves of"
    echo "    the pairing decide the corpus. Re-measure here to compare here."
    exit 0
}
[ -n "$DOC_QT" ] && [ -n "$HAVE_QT" ] && [ "$DOC_QT" != "$HAVE_QT" ] \
    && notcomparable "Qt $DOC_QT" "Qt $HAVE_QT"
[ -n "$DOC_PLAT" ] && [ "$DOC_PLAT" != "$HAVE_PLAT" ] \
    && notcomparable "$DOC_PLAT" "$HAVE_PLAT"

bad=0
fail() { echo "docs-numbers FAIL: $1" >&2; [ -n "${2:-}" ] && echo "    $2" >&2; bad=$((bad + 1)); }

# The styles the gates recorded in this build. Missing files are not "nothing to check": the o3 gate
# runs per style and a style whose counts are absent did not run, which is exactly the silent
# disappearance the qmltcc family suffered.
styles=""
for f in "$CDIR"/counts_*.tsv; do
    [ -f "$f" ] || continue
    st=$(basename "$f" .tsv); st=${st#counts_}
    styles="$styles $st"
done
[ -n "$styles" ] && [ "$(printf '%s' "$styles" | wc -w)" -ge 5 ] || {
    echo "docs-numbers FAIL: counts for fewer than five styles were recorded ($styles)" >&2
    echo "    the o3 gate writes one file per style; a missing one means that style did not run." >&2
    exit 1
}

# ONLY THE STYLES THE TABLES ARE ABOUT. The o3 gate also judges `app` — this project's own
# application QML, a different corpus — and summing it into these totals would have made the gate
# report 255 against a README that correctly says 248, i.e. accuse a document of being wrong for
# containing the right number. Caught before the gate first ran; the whole point of it is that a
# figure and its source describe the same population.
# THE TOTALS COME FROM THE GATES, NOT FROM A DOCUMENT. This loop used to skip any style whose row
# was absent from README.md, which made that file the SELECTOR for what gets verified at all: move
# the tables out of it and every total silently becomes 0, after which the gate accuses the OTHER
# document — the correct one — of disagreeing with a count of nothing. A document must not decide
# what is checked about it. Now every style the build recorded is summed, and each document is
# checked for the rows it actually carries.
tot_c=0; tot_d=0; tot_u=0; tot_o1=0; counted=""; docs_with_tables=0
for st in $styles; do
    # ...EXCEPT `app`, and this exclusion is now STATED rather than implied. The o3 gate also judges
    # this project's own application QML, a different corpus, and summing it in makes the totals 255
    # and 47 against documents that correctly say 248 and 36. The old selector excluded it as a side
    # effect of the README not having a row for it — which worked, and hid the reason. Measured when
    # this loop first stopped consulting the README: exactly the 255-vs-248 the comment above
    # predicted.
    [ "$st" = app ] && continue
    counted="$counted $st"
    IFS='	' read -r _ c d _ u < "$CDIR/counts_$st.tsv"
    tot_c=$((tot_c + c)); tot_d=$((tot_d + d)); tot_u=$((tot_u + u))
    o1=0
    [ -f "$ODIR/optlevels_$st.tsv" ] && { IFS='	' read -r _ o1 < "$ODIR/optlevels_$st.tsv"; }
    tot_o1=$((tot_o1 + o1))

    # the row for this style, in either document: `| Basic | 70 | 39 | 39 | 54 | 5 | 11 |`
    for doc in README.md docs/qmltc-d.md; do
        row=$(grep -E "^\| $st \| [0-9]+ \|" "$ROOT/$doc" 2>/dev/null | head -1 || true)
        [ -n "$row" ] || continue
        docs_with_tables=$((docs_with_tables + 1))
        got_o1=$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$4); print $4}')
        got_c=$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$6); print $6}')
        got_d=$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$7); print $7}')
        got_u=$(printf '%s' "$row" | awk -F'|' '{gsub(/ /,"",$8); print $8}')
        [ "$got_c" = "$c" ] || fail "$doc says $st compiles $got_c at -O3; the gate counted $c"
        [ "$got_d" = "$d" ] || fail "$doc says $st demotes $got_d; the gate counted $d"
        [ "$got_u" = "$u" ] || fail "$doc says $st has $got_u unjudgeable; the gate counted $u"
        [ "$got_o1" = "$o1" ] || fail "$doc says $st compiles $got_o1 at -O1; the gate counted $o1"
    done
done

# ...and the CORPUS SUMMARY rows, which this gate did not look at. An adversarial review found
# docs/qmltc-d.md still carrying `329 | 245 | 39` and `14 | 2 | 12` — three documents and a whole
# corpus stale — while this script reported OK, because it only recognised rows labelled with one of
# the five style names plus `**total**`. A gate that checks the tables it happens to parse says
# nothing about the ones it does not, and the sentence it prints ("README.md and docs/qmltc-d.md
# agree with what the gates counted") claimed both files entire. Same defect this whole audit is
# about, in the gate written to prevent it.
appc=0; appd=0; appu=0
if [ -f "$CDIR/counts_app.tsv" ]; then
    IFS='	' read -r _ appc appd _ appu < "$CDIR/counts_app.tsv"
fi
for doc in README.md docs/qmltc-d.md; do
    crow=$(grep -E "^\| Qt's Controls" "$ROOT/$doc" 2>/dev/null | head -1 || true)
    if [ -n "$crow" ]; then
        c1=$(printf '%s' "$crow" | awk -F'|' '{gsub(/[* ]/,"",$4); print $4}')
        c2=$(printf '%s' "$crow" | awk -F'|' '{gsub(/[* ]/,"",$5); print $5}')
        [ "$c1" = "$tot_c" ] || fail "$doc's corpus row says $c1 compiled; the gates counted $tot_c"
        [ "$c2" = "$tot_d" ] || fail "$doc's corpus row says $c2 at -O0; the gates counted $tot_d"
    fi
    arow=$(grep -E "^\| application-shaped" "$ROOT/$doc" 2>/dev/null | head -1 || true)
    if [ -n "$arow" ] && [ "$appc" != 0 ]; then
        a1=$(printf '%s' "$arow" | awk -F'|' '{gsub(/[* ]/,"",$3); print $3}')
        a2=$(printf '%s' "$arow" | awk -F'|' '{gsub(/[* ]/,"",$4); print $4}')
        a3=$(printf '%s' "$arow" | awk -F'|' '{gsub(/[* ]/,"",$5); print $5}')
        [ "$a1" = "$((appc + appd + appu))" ] ||             fail "$doc says the application corpus has $a1 documents; the gate saw $((appc + appd + appu))"
        [ "$a2" = "$appc" ] || fail "$doc says $a2 application documents compile; the gate counted $appc"
        [ "$a3" = "$appd" ] || fail "$doc says $a3 application documents at -O0; the gate counted $appd"
    fi
done

# ...and the totals, which are what a reader quotes.
for doc in README.md docs/qmltc-d.md; do
    trow=$(grep -E "^\| \*\*total\*\* \|" "$ROOT/$doc" 2>/dev/null | head -1 || true)
    [ -n "$trow" ] || continue
    t_o1=$(printf '%s' "$trow" | awk -F'|' '{gsub(/[* ]/,"",$4); print $4}')
    t_c=$(printf '%s' "$trow" | awk -F'|' '{gsub(/[* ]/,"",$6); print $6}')
    [ "$t_c" = "$tot_c" ] || fail "$doc totals $t_c compiled at -O3; the gates counted $tot_c"
    [ "$t_o1" = "$tot_o1" ] || fail "$doc totals $t_o1 at -O1; the gates counted $tot_o1"
done

[ "$bad" -eq 0 ] || exit 1
# ...and SOMEBODY has to carry the tables. Every check above is guarded by "if the row is there",
# so deleting the tables from both documents would leave a gate that verifies nothing and says OK —
# the vacuous pass this project keeps finding. One document may drop them; both may not.
[ "$docs_with_tables" -gt 0 ] || fail "neither README.md nor docs/qmltc-d.md carries a per-style table" \
    "every check here is conditional on the row existing, so with no tables this gate proves nothing"

[ "$bad" -eq 0 ] || exit 1
echo "docs-numbers OK: README.md and docs/qmltc-d.md agree with what the gates counted this build — $tot_c compiled at -O3, $tot_d demoted, $tot_u unjudgeable, $tot_o1 at -O1, across the $(printf '%s' "$counted" | wc -w) style(s) those tables describe (the gate also judged:$(printf '%s' "$styles"))"
