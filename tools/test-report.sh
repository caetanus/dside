#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
# Structured test report (critics r6 #4). Emits a TSV over the reggae targets with EXPLICIT
# environment metadata (commit, dirty, platform, exact Qt5/Qt6 + dmd/ldc2 + tool versions) and,
# per target: category, compiler, qt, optional-capability, status (pass|fail|skip), duration, and
# — on failure — a saved log path. Axes come from the naming convention (the project's contract:
# `-ldc2`/`-dmd`, `-qt5`; unsuffixed Qt-linked targets are Qt6); version-agnostic targets get `-`.
#
#   tools/test-report.sh [glob] > report.tsv
set -uo pipefail

# `build` on POSIX, `build.exe` on Windows — the same graph either way.
BUILD=./build
[ -x ./build.exe ] && BUILD=./build.exe

cd "$(dirname "$0")/.."
selftest=no; [ "${1:-}" = "--self-test" ] && { selftest=yes; shift; }
# THE FILTER, FROM ARGV OR FROM THE ENVIRONMENT. argv is how a person runs this; the environment
# is how a LAUNCHER does, because a filter with several patterns cannot survive the trip otherwise:
# PowerShell's Start-Process joins its ArgumentList with spaces and no quoting, and the MSYS
# runtime then splits and glob-expands what arrives. Measured on the Windows job — an 11-pattern
# filter reached the script as $1="wraptest*" and ten arguments nobody read, and exactly the
# wraptest family ran. An environment variable is not touched by either.
filter="${1:-${QTD_FILTER:-*}}"
logdir=".build/report-logs"; mkdir -p "$logdir"

commit=$(git rev-parse --short HEAD 2>/dev/null || echo '?')
# --porcelain also counts UNTRACKED files (a plain `git diff` misses them), so a report run
# against a tree with stray generated/edited files is honestly flagged DIRTY (r8 #8).
dirty=$([ -z "$(git status --porcelain 2>/dev/null)" ] && echo clean || echo DIRTY)
# WITHOUT pkg-config, ASK THE PREFIX — the build already does, and a header that says `Qt6=none`
# on a machine with two Qt installations describes the probe, not the machine. The version is the
# directory Qt puts its private headers under, which is the same thing QtProbe.modversion reads.
qtver() {  # $1 = QTDIR-style prefix
    [ -n "${1:-}" ] || { echo none; return; }
    for d in "$1"/include/QtCore/[0-9]*; do
        [ -d "$d" ] && { basename "$d"; return; }
    done
    echo none
}
# ...AND `${QTDIR6:-$QTDIR}` IS NOT THE SAME AS `${QTDIR6:-${QTDIR:-}}` UNDER `set -u`. On a
# machine that exports neither — the ssh environment on the Windows VM, where user variables are
# not inherited — the inner `$QTDIR` is itself unbound and the whole header aborted with
#     tools/test-report.sh: line 36: QTDIR: unbound variable
# three times over, on the one line whose job is to say which Qt this is.
qt6v=$(pkg-config --modversion Qt6Core 2>/dev/null || qtver "${QTDIR6:-${QTDIR:-}}")
qt5v=$(pkg-config --modversion Qt5Core 2>/dev/null || qtver "${QTDIR5:-}")
dmdv=$(dmd --version 2>/dev/null | head -1 | grep -oE 'v[0-9.]+' || echo none)
ldcv=$(ldc2 --version 2>/dev/null | grep -oE 'LDC.*\([0-9.]+\)' | head -1 || echo none)
# ...and the same for a tool: it is `qmlcachegen.exe` under a Qt prefix on Windows, which is why
# this said `qmlcachegen=n` on a machine that has it.
have() { command -v "$1" >/dev/null 2>&1 || command -v "$1.exe" >/dev/null 2>&1 \
         || [ -x "/usr/lib/qt6/$1" ] || [ -x "/usr/lib/qt6/bin/$1" ] \
         || [ -x "${QTDIR6:-${QTDIR:-}}/bin/$1" ] || [ -x "${QTDIR6:-${QTDIR:-}}/bin/$1.exe" ]; }
haveqtlib() {  # a Qt module, by pkg-config or by its import library under the prefix
    pkg-config --exists "$1" 2>/dev/null && return 0
    [ -f "${QTDIR6:-${QTDIR:-}}/lib/$1.lib" ] || [ -f "${QTDIR6:-${QTDIR:-}}/lib/lib$1.so" ]; }
caps="qmlcachegen=$(have qmlcachegen && echo y || echo n) Qt6QmlCompiler=$(haveqtlib Qt6QmlCompiler && echo y || echo n) lrelease=$(have lrelease && echo y || echo n)"

if [ "$selftest" = no ]; then
printf '# qt-dlang-gen report — commit %s (%s) — %s\n' "$commit" "$dirty" "$(uname -sm)"
printf '# Qt6=%s Qt5=%s | dmd=%s ldc2=%s | caps: %s\n' "$qt6v" "$qt5v" "$dmdv" "$ldcv" "$caps"
printf 'target\tcategory\tcompiler\tqt\toptional\tstatus\tms\tlog\n'
fi

category() {
  case "$1" in
    sample_*) echo libsample ;;
    # ...but a GATE named after a family goes to `gate`, and it has to be said BEFORE the family
    # (critics r13 #5): `ownership*` used to swallow `ownership-gate-*`, so the report filed a
    # governance gate under `lifetime` and the self-test still said "0 unclassified". Classified
    # must mean the RIGHT class, not merely a non-empty one — hence the canary below.
    manifest-gate-*|registry-gate-*|ownership-gate-*|expected-fails-lint|expected-fails-run|ctor-guard) echo gate ;;
    wraptest*|widget_test*|moc_test*|moclife_widget*|ownership*|noqml_helpers*) echo lifetime ;;
    cannon*) echo moc ;;
    uic-*|dialog-*|tabs-*|mainwin-*|hello-*|egroup-*|combo-*|spacer-*|icon-*|uicheck*|corpus-check*) echo uic ;;
    # The transpiler families, which are 472 of the 667 targets. `qml-*` never matched them (no
    # hyphen after `qml`), so the report called the MAJORITY of what it ran `other` — the run was
    # right and the artifact told a wrong story about it. Kept ahead of the qml rule, since
    # `qmltc*` would otherwise have to out-specific it.
    qmltc-*|qmltc5-*|qmltcq-*|qmltcc-*|qmltcd-*|leaf-lifetime-*) echo qmltc ;;
    # The AGGREGATES answer a question ("is the generator healthy?", "is the compiler healthy?")
    # rather than testing a unit. They run their members, so counting them as tests would count
    # every member twice — they are their own category on purpose.
    binding-core|qmltc-smoke|qmltc-corpus) echo aggregate ;;
    qml-*|qmlreg-*|qmlaot-*|shadowaot-*|qmltc-o3-gate-*|qmltypes-*|moclife-*|qmltwo-*|homonym-*|homocollide-*|metacast-*|metacontract-*|boom-*|metathread-*) echo qml ;;
    reglife-*|valuetypeprop-*|subclasscast-*) echo qml ;;
    slotoverload-*) echo moc ;;
    # ...and the ratchets/probes that answer the long-lived structural findings (r4 #9, r9 #2,
    # r11 #5/#6). They are gates: they fail the build, they take no compiler and no Qt version of
    # their own except abi-layout-qt5, which the qtaxis below marks.
    qtmoc-probe-*|report-selftest|runtime-boundary|compiler-context|abi-layout|abi-layout-qt5|runtime-provenance|archive-composition|license-coverage|license-no-gpl-product|license-package|license-package-mutations|license-publishable|license-generated-output|license-coverage-mutations|license-generated-output-mutations|license-snapshot|license-publishable|license-no-gpl-product-mutations|license-snapshot-mutations|docs-numbers) echo gate ;;
    tr-*|lupdate-check) echo i18n ;;
    manifest-gate-*|registry-gate-*|expected-fails-lint|expected-fails-run|ctor-guard|ownership-gate-*) echo gate ;;
    qrc-*|container_*|qlist*|holder_test*|webengine-*) echo misc ;;
    # xiboca-quickstart is a gate for the same reason the consumer smokes are: it builds
    # something from OUTSIDE the binding's own graph — the documented quickstart for wrapping
    # a library that is not Qt — and refuses the build when the documentation stops being true.
    consumer-smoke-*|dub-consumer-*|xiboca-quickstart|docs-sphinx|docs-spec-keys) echo gate ;;
    # Wrapper LIFETIME, which is neither moc nor qml: who owns a pointer, and who may delete it.
    borrowed-*|ownership-*|wraptest-*|moclife*|thread_test*|threadguard-*|nonqobject-*|dangle-*) echo lifetime ;;
    # The application constructor's symbol, derived and then read back off the library that
    # defines it. A gate: it fails the build the day the derivation and the shipped Qt disagree,
    # which is the whole reason it is not just a compile.
    appmixin-*) echo gate ;;
    # Deployment: what an installer has to carry, and whether the copied tree RESOLVES. Its own
    # category rather than `gate`, because unlike a gate it exercises a shipped TOOL end to end —
    # map the binary, bundle it, start it with the machine's Qt out of reach.
    deploy-bundle-*|deploy-qml-*) echo deploy ;;
    # The DELIVERABLE: the generated D, both archives, dub.json, licences and manifest, laid out as
    # a dub package. Its own category because it is not a test — it is what the build is for.
    wrapper-package) echo package ;;
    *) echo other ;;
  esac
}
# shadowaot needs qmlcachegen, exactly as qmlaot does — absent, the target is not generated at all.
optional() { case "$1" in qmlaot-*|shadowaot-*|qmltypes-*|lupdate-check|tr-*) echo yes ;; *) echo no ;; esac ; }
compiler() { case "$1" in *-ldc2*) echo ldc2 ;; *-dmd*) echo dmd ;; *) echo - ;; esac ; }
# qt axis: -qt5 => qt5; version-agnostic targets => -; everything else Qt-linked => qt6.
qtaxis() {
  case "$1" in
    *-qt5*) echo qt5 ;;
    # The Qt5 transpiler suite spells its version in the FAMILY, not as a `-qt5` suffix, so 122
    # Qt5 targets were being reported as Qt6 — the one axis the report exists to get right.
    qmltc5-*|qtmoc-probe-qml5|abi-layout-qt5) echo qt5 ;;
    # docs-spec-keys reads the generator's source and the reference page and nothing else — no
    # Qt, no compiler. docs-sphinx is NOT here on purpose: it assembles the manual with the
    # API reference emitted by the qt6 qtwidgets generation, so qt6 is the honest axis.
    manifest-gate-*|registry-gate-*|expected-fails-lint|lupdate-check|holder_test*|sample_*|report-selftest|docs-spec-keys) echo - ;;
    *) echo qt6 ;;
  esac
}

# --self-test: the axes are derived from NAMES by a second system, so they can silently stop
# describing what the build actually runs — the report called 472 of 667 targets `other` and 122
# Qt5 targets Qt6 while every one of them executed correctly. Canaries pin one real target name per
# family, and the last check is the invariant that matters: NOTHING may fall through to `other`.
if [ "$selftest" = yes ]; then
  st_fail=0
  ck() {   # name expected-category expected-qt expected-compiler
    local c q x; c=$(category "$1"); q=$(qtaxis "$1"); x=$(compiler "$1")
    if [ "$c" != "$2" ] || [ "$q" != "$3" ] || [ "$x" != "$4" ]; then
      printf 'self-test FAIL %s -> %s/%s/%s (want %s/%s/%s)\n' "$1" "$c" "$q" "$x" "$2" "$3" "$4"
      st_fail=1
    fi
  }
  ck qmltc-AliasBare-ldc2            qmltc     qt6 ldc2
  ck qmltc5-AliasProp-dmd            qmltc     qt5 dmd
  ck qmltcq-QAnim-render-ldc2        qmltc     qt6 ldc2
  ck qmltcc-CButton-ldc2             qmltc     qt6 ldc2
  ck qmltcd-DProp-dmd                qmltc     qt6 dmd
  ck qmltc-controls-runtime-ldc2     qmltc     qt6 ldc2
  ck uicheck-ldc2                    uic       qt6 ldc2
  ck qml-ldc2                        qml       qt6 ldc2
  ck reglife-ldc2                    qml       qt6 ldc2
  ck valuetypeprop-ldc2              qml       qt6 ldc2
  ck slotoverload-dmd                moc       qt6 dmd
  ck cannon-ldc2                     moc       qt6 ldc2
  ck widget_test-ldc2-qt5            lifetime  qt5 ldc2
  ck sample_cornercases-ldc2         libsample -   ldc2
  ck qtmoc-probe-noqml               gate      qt6 -
  ck qtmoc-probe-qml5                gate      qt5 -
  ck manifest-gate-qml               gate      -   -
  ck ownership-gate-qtwidgets        gate      qt6 -
  ck ctor-guard                      gate      qt6 -
  ck report-selftest                 gate      -   -
  ck runtime-boundary                gate      qt6 -
  ck runtime-provenance              gate      qt6 -
  ck compiler-context                gate      qt6 -
  ck abi-layout                      gate      qt6 -
  ck abi-layout-qt5                  gate      qt5 -
  ck wrapper-package                 package   qt6 -
  ck deploy-bundle-ldc2              deploy    qt6 ldc2
  ck deploy-qml-dmd                  deploy    qt6 dmd
  ck tr-ldc2                         i18n      qt6 ldc2
  ck qrc-ldc2                        misc      qt6 ldc2
  ck xiboca-quickstart               gate      qt6 -
  ck docs-sphinx                     gate      qt6 -
  ck docs-spec-keys                  gate      -   -
  # ...and no target the build actually offers may be unclassified.
  # The ` (optional)` suffix is part of the LISTING, not of the name. Glob-matched families never
  # noticed; `binding-core` is matched exactly and came back unclassified the day it became optional.
  if list=$("$BUILD" --list 2>/dev/null | sed -e 's/^- //' -e 's/ (optional)$//' | grep -v '^List'); then
    n_other=0
    while read -r t; do [ -n "$t" ] && [ "$(category "$t")" = other ] && {
      printf 'self-test FAIL unclassified target: %s\n' "$t"; n_other=$((n_other+1)); }
    done <<< "$list"
    [ "$n_other" -eq 0 ] || st_fail=1
    printf 'report self-test: %s targets classified, %s unclassified\n' "$(wc -l <<< "$list")" "$n_other"
  else
    printf 'report self-test: canaries only (%s --list unavailable)\n' "$BUILD"

  fi
  [ "$st_fail" -eq 0 ] && printf 'report self-test: OK\n'
  exit "$st_fail"
fi


pass=0 fail=0 skip=0
# ...AND IT MUST ALREADY BE CURRENT WHEN THE FIRST TARGET RUNS. The stamp check further down
# catches an input edited DURING the run; this catches the opposite, which is worse because it is
# silent: a build binary that is older than its own description regenerates itself on the first
# `$BUILD <target>` — and on Windows it cannot, because the binary being relinked is the one
# running:
#     LINK : fatal error LNK1168: cannot open C:/…/build.exe for writing
# Every target in the run then "failed", 137 of 137, and the report said `fail` 137 times without
# one word about why. Measured 2026-08-26, after a commit that touched reggae/qtd_build.d.
#
# POSIX never showed this — there a relink unlinks and replaces, so the running image survives and
# the next invocation picks up the new one. That is precisely why it had to be found on Windows.
newer_inputs=$(find reggaefile.d reggae -name '*.d' -newer "$BUILD" -print -quit 2>/dev/null || true)
if [ -n "$newer_inputs" ]; then
    echo "# $BUILD is older than $newer_inputs — regenerating before the run" >&2
    # Regenerated by `reggae` DIRECTLY, never by $BUILD: asking the stale binary to rebuild itself
    # is the deadlock above. The arguments are the ones $BUILD prints when it tries this itself.
    if ! command -v reggae >/dev/null 2>&1 && ! command -v reggae.exe >/dev/null 2>&1; then
        echo "# ERROR: $BUILD is stale and \`reggae\` is not on PATH to regenerate it. Every" >&2
        echo "# target would be reported as a failure of the build binary, not of itself." >&2
        exit 2
    fi
    reggae -b binary . --reggaefile-import-path "$PWD/reggae" >&2 || {
        echo "# ERROR: regenerating $BUILD failed; refusing to report on a stale build graph." >&2
        exit 2; }
fi
# Only the DEFAULT (mandatory) targets: `- name`. Optional targets print as `- name (optional)`
# (the manifest gates, r8 #1) and are advisory, so they're excluded from the gated record here.
mapfile -t targets < <("$BUILD" --list 2>/dev/null | grep -oE '^- [^ ]+$' | sed 's/^- //')
if [ "${#targets[@]}" -eq 0 ]; then echo "# ERROR: "$BUILD" --list produced no default targets" >&2; exit 2; fi
# THE BUILD MUST NOT CHANGE UNDER THE REPORT. Editing a build input mid-run makes the next
# `./build <target>` rebuild the build binary itself and exit without running the target — which
# lands in the report as a failure of whatever target happened to be next. It has produced false
# rows three times; a record execution that can be invalidated silently is not a record.
buildstamp() { stat -c %Y "$BUILD" 2>/dev/null || echo 0; }
stamp0=$(buildstamp)

# ONE INVOCATION PER TARGET IS 8 SECONDS OF STARTUP, 1200 TIMES.
#
# Measured on a completed run: 1200 targets, 212 minutes, 10.6 s average — and a `$BUILD <target>`
# with NOTHING to do costs 7.9 s, because the binary rebuilds its description of a 1200-target
# graph before deciding there is nothing to do. `-n` does not help (7.6-8.0 s: the rerun check is
# not the cost). Five targets in ONE invocation cost 7.6 s — the same as one.
#
# It is also what breaks the run outright on Windows. MSYS's emulated `fork` stops working after a
# few thousand children:
#     dofork: child -1 - forked process died unexpectedly, exit code 0xC0000142, errno 11
#     fork: retry: Resource temporarily unavailable
# and three full matrices ended at 1063, 1109 and 1120 rows with no totals line and nothing in the
# error file — a report that was killed looks exactly like one that finished.
#
# So targets run in BATCHES, and each row is still decided from that target's OWN output: with
# `-s` the backend runs them one at a time and announces each with
#     [build] Shell command generating <target>
# which is where a batch log is cut. Anything the batch does not answer cleanly — a non-zero exit,
# a target with no announcement — sends the WHOLE batch back through one-target-at-a-time, so a
# failure is always attributed by the same evidence as before.
#
# `BATCH=1` restores the old shape exactly, which is what to use when the `ms` column has to be
# per-target: inside a batch it is the batch's own elapsed time, and the header says so.
BATCH="${BATCH:-20}"
[ "$BATCH" -ge 1 ] 2>/dev/null || BATCH=20

# The subset this run will actually visit, after the filter.
#
# SEVERAL PATTERNS, SEPARATED BY SPACES. `case "$t" in $filter)` uses the expansion as ONE pattern:
# `case`'s alternation is syntactic and is not re-parsed out of a variable, so a filter written as
# `wraptest*|uic*` matches a target literally called that and nothing else. The Windows job was
# refused twice for exactly this — once with commas, once with pipes — and the refusal was right
# both times. Space separation is what a shell caller writes anyway, and `$filter` unquoted here is
# already word-split by the shell.
# ...AND SPLIT WITHOUT GLOBBING. `for pat in $filter` performs PATHNAME EXPANSION on the value,
# so the default filter `*` became the list of files in the repository root and selected 0 of 1218
# targets — the same defect the paragraph below records, reintroduced one commit later in a new
# place. `read -ra` splits on IFS and expands nothing. The pattern stays unquoted inside `case`,
# which is where it must be a pattern and where no pathname expansion happens.
read -ra pats <<< "$filter"
sel=()
for t in "${targets[@]}"; do
    for pat in "${pats[@]}"; do
        case "$t" in $pat) sel+=("$t"); break ;; esac
    done
done
# A SELECTION OF NOTHING IS NOT A PASS. This printed `# totals: 0 pass, 0 fail, 0 skip` — a
# well-formed report, signed with the commit and the Qt release, about a run that visited no
# target at all. It happened because the MSYS runtime EXPANDS WILDCARDS in the command line when
# an MSYS program is launched from a native Windows process: `sh.exe tools/test-report.sh *` from
# PowerShell arrived as `tools/test-report.sh CONTRIBUTING.md LICENSE …`, so the filter was a
# filename and matched no target. The launcher no longer passes `*` (tools/win/runreport.ps1), but
# the report is what must refuse: any filter that selects nothing is an operator error, and the
# one thing it must never do is look like success.
if [ "${#sel[@]}" -eq 0 ]; then
    echo "# ERROR: the filter '$filter' selected 0 of ${#targets[@]} target(s) — nothing to report" >&2
    exit 2
fi
printf '# scheduling: %d target(s), batches of %d (BATCH=1 for one invocation per target)\n' \
       "${#sel[@]}" "$BATCH"

# Decide one target's row from its own log slice. Sets `st` and `logcol`.
verdict() {  # $1 = target, $2 = its log, $3 = rc of the invocation that produced it
  local t="$1" log="$2" rc="$3"
  if [ "$rc" -eq 124 ]; then
    st=hang; fail=$((fail+1)); logcol="$log"
    echo "# target exceeded $(budget "$t")s and was killed" >> "$log"
  elif [ "$rc" -eq 0 ]; then
    # THE MARKER OPENS A LINE, it is not a word somewhere in one. A capability-gated target says
    # so as its verdict — `qmltc-o3-gate: skipped — no QtQuick.Controls under …`, `cross-preflight
    # SKIP: no wine` — and anything looser reads a sentence ABOUT a check as the whole target being
    # skipped. Measured: `nonqobject: block-freed check skipped — the MS x64 ABI frees inside Qt's
    # DLL` is a passing target stating which sub-check that ABI does not allow, and ten Windows
    # rows came back `skip` while their logs also said OK. A capability skip phrased some other way
    # now reads as `mute` instead, which is a failure and therefore loud — the safe direction.
    if grep -qiE '^([A-Za-z0-9_.-]+:?[[:space:]]+)?(SKIP|skipped|skipping)\b' "$log"; then
      st=skip; skip=$((skip+1)); rm -f "$log"; logcol=-
    elif [ "$(grep -cvE '^\[build\]|^run-exe:|^$' "$log")" -eq 0 ]; then
      st=mute; fail=$((fail+1)); logcol="$log"
    else
      st=pass; pass=$((pass+1)); rm -f "$log"; logcol=-
    fi
  else st=fail; fail=$((fail+1)); logcol="$log"; fi
}

emit() {  # $1 = target, $2 = ms
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n' \
    "$1" "$(category "$1")" "$(compiler "$1")" "$(qtaxis "$1")" "$(optional "$1")" \
    "$st" "$2" "$logcol"
}

# AN AGGREGATE IS NOT A TARGET, and one number cannot bound both. `expected-fails-run` builds and
# runs the ~28 probes of expected-fails.json; measured alone on Windows it costs 1000 s against a
# 900 s limit, so it reported `hang` — a false failure about a gate that was passing. It survives
# the matrix only because a BATCH gets a batch's budget, which is what made the trap invisible:
# nobody meets it until they re-run the gate by name, which is exactly what one does after fixing
# something. The aggregates listed in category() get the multiple they actually need.
budget() {  # $1 = target -> seconds
  case "$1" in
    expected-fails-run|binding-core|qmltc-smoke|qmltc-corpus) echo $(( ${TARGET_TIMEOUT:-900} * 4 )) ;;
    *) echo "${TARGET_TIMEOUT:-900}" ;;
  esac
}

# One target, its own invocation — the exact shape this report has always had.
run_one() {  # $1 = target
  local t="$1" log start rc
  log="$logdir/$t.log"
  start=$(date +%s%3N)
  # A BOUND PER TARGET. A step that hangs stops the record execution dead — three Windows runs
  # stalled on one target with no output and no child process, and a matrix that never finishes
  # reports nothing at all. `timeout` turns that into a row that says `hang`, and the run goes on.
  rc=0; timeout "$(budget "$t")" "$BUILD" "$t" >"$log" 2>&1 || rc=$?
  verdict "$t" "$log" "$rc"
  emit "$t" "$(( $(date +%s%3N) - start ))"
}

# Cut a batch log into one file per target, at the backend's own announcements. Returns non-zero
# if any target of the batch was never announced — which is the caller's signal to stop trusting
# the batch and run its targets one at a time.
split_batch() {  # $1 = batch log, $2.. = targets
  local blog="$1"; shift
  local t line prev="" ok=0
  # awk writes each slice as it goes: a marker line for a target in THIS batch opens a new file.
  awk -v names="$*" -v dir="$logdir" '
    BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1; out = "" }
    {
      if (match($0, /^\[build\] Shell command generating /)) {
        nm = substr($0, RLENGTH + 1)
        if (nm in want) { if (out != "") close(out); out = dir "/" nm ".log"; printf "" > out }
      }
      if (out != "") print >> out
    }
    END { if (out != "") close(out) }
  ' "$blog"
  for t in "$@"; do [ -f "$logdir/$t.log" ] || ok=1; done
  return $ok
}

i=0
while [ "$i" -lt "${#sel[@]}" ]; do
  if [ "$(buildstamp)" != "$stamp0" ]; then
    echo "# ABORTED: $BUILD was rebuilt during the run — a build input changed under it." >&2
    echo "# Every row after that point would describe the rebuild, not the target." >&2
    exit 3
  fi
  batch=("${sel[@]:$i:$BATCH}")
  i=$(( i + ${#batch[@]} ))
  if [ "${#batch[@]}" -eq 1 ]; then run_one "${batch[0]}"; continue; fi

  blog="$logdir/batch.log"
  start=$(date +%s%3N)
  # The batch's bound is the sum of its targets' budgets, CAPPED: twenty times 900 s is five hours
  # to notice one hang, and a batch that runs out is not lost — it falls back to one invocation per
  # target, each with its own full budget. So the cap costs a batch's startup, never a verdict.
  bt=$(( ${TARGET_TIMEOUT:-900} * ${#batch[@]} ))
  [ "$bt" -le "${BATCH_TIMEOUT:-1800}" ] || bt="${BATCH_TIMEOUT:-1800}"
  rc=0; timeout "$bt" "$BUILD" -s "${batch[@]}" >"$blog" 2>&1 || rc=$?
  ms=$(( $(date +%s%3N) - start ))
  if [ "$rc" -ne 0 ] || ! split_batch "$blog" "${batch[@]}"; then
    # Not trustworthy as a batch: every target of it gets its own invocation, its own log and its
    # own exact time. Costs the startup back for this batch only, and failures are rare.
    rm -f "$blog"
    for t in "${batch[@]}"; do rm -f "$logdir/$t.log"; run_one "$t"; done
    continue
  fi
  rm -f "$blog"
  for t in "${batch[@]}"; do verdict "$t" "$logdir/$t.log" 0; emit "$t" "$ms"; done
done

printf '# totals: %d pass, %d fail, %d skip (optional/advisory targets excluded; run them by name)\n' "$pass" "$fail" "$skip"
# This IS the record execution (r8 #8): exit non-zero if anything failed, so CI can gate on the
# report itself instead of running a second, separate matrix pass whose result it then discards.
[ "$fail" -eq 0 ]
