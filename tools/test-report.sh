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
filter="${1:-*}"
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
qt6v=$(pkg-config --modversion Qt6Core 2>/dev/null || qtver "${QTDIR6:-$QTDIR}")
qt5v=$(pkg-config --modversion Qt5Core 2>/dev/null || qtver "${QTDIR5:-}")
dmdv=$(dmd --version 2>/dev/null | head -1 | grep -oE 'v[0-9.]+' || echo none)
ldcv=$(ldc2 --version 2>/dev/null | grep -oE 'LDC.*\([0-9.]+\)' | head -1 || echo none)
# ...and the same for a tool: it is `qmlcachegen.exe` under a Qt prefix on Windows, which is why
# this said `qmlcachegen=n` on a machine that has it.
have() { command -v "$1" >/dev/null 2>&1 || command -v "$1.exe" >/dev/null 2>&1 \
         || [ -x "/usr/lib/qt6/$1" ] || [ -x "/usr/lib/qt6/bin/$1" ] \
         || [ -x "${QTDIR6:-$QTDIR}/bin/$1" ] || [ -x "${QTDIR6:-$QTDIR}/bin/$1.exe" ]; }
haveqtlib() {  # a Qt module, by pkg-config or by its import library under the prefix
    pkg-config --exists "$1" 2>/dev/null && return 0
    [ -f "${QTDIR6:-$QTDIR}/lib/$1.lib" ] || [ -f "${QTDIR6:-$QTDIR}/lib/lib$1.so" ]; }
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
# Only the DEFAULT (mandatory) targets: `- name`. Optional targets print as `- name (optional)`
# (the manifest gates, r8 #1) and are advisory, so they're excluded from the gated record here.
mapfile -t targets < <("$BUILD" --list 2>/dev/null | grep -oE '^- [^ ]+$' | sed 's/^- //')
if [ "${#targets[@]}" -eq 0 ]; then echo "# ERROR: "$BUILD" --list produced no default targets" >&2; exit 2; fi
for t in "${targets[@]}"; do
  case "$t" in $filter) ;; *) continue ;; esac
  log="$logdir/$t.log"
  start=$(date +%s%3N)
  if "$BUILD" "$t" >"$log" 2>&1; then
    # A capability-gated target (qmlaot/qmltypes with the tool absent) runs but prints SKIP and
    # does no work — record it as skip, not a green pass it didn't actually perform (r8 #8/#10).
    if grep -qiE '(^|[^a-z])skip(ping|ped)?([^a-z]|$)' "$log"; then
      st=skip; skip=$((skip+1)); rm -f "$log"; logcol=-
    # A TARGET THAT PRODUCED NOTHING DID NOT RUN. Exit status alone is not evidence: on Windows a
    # runner that could not START any binary reported thirteen targets passing, and every one of
    # their logs held nothing but the build's own progress lines. A green with no output of its own
    # is reported as `mute` and counts as a failure.
    elif [ "$(grep -cvE '^\[build\]|^$' "$log")" -eq 0 ]; then
      st=mute; fail=$((fail+1)); logcol="$log"
    else
      st=pass; pass=$((pass+1)); rm -f "$log"; logcol=-
    fi
  else st=fail; fail=$((fail+1)); logcol="$log"; fi
  ms=$(( $(date +%s%3N) - start ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n' \
    "$t" "$(category "$t")" "$(compiler "$t")" "$(qtaxis "$t")" "$(optional "$t")" "$st" "$ms" "$logcol"
done
printf '# totals: %d pass, %d fail, %d skip (optional/advisory targets excluded; run them by name)\n' "$pass" "$fail" "$skip"
# This IS the record execution (r8 #8): exit non-zero if anything failed, so CI can gate on the
# report itself instead of running a second, separate matrix pass whose result it then discards.
[ "$fail" -eq 0 ]
