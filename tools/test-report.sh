#!/usr/bin/env bash
# Structured test report (critics r6 #4). Emits a TSV over the reggae targets with EXPLICIT
# environment metadata (commit, dirty, platform, exact Qt5/Qt6 + dmd/ldc2 + tool versions) and,
# per target: category, compiler, qt, optional-capability, status (pass|fail|skip), duration, and
# — on failure — a saved log path. Axes come from the naming convention (the project's contract:
# `-ldc2`/`-dmd`, `-qt5`; unsuffixed Qt-linked targets are Qt6); version-agnostic targets get `-`.
#
#   tools/test-report.sh [glob] > report.tsv
set -uo pipefail
cd "$(dirname "$0")/.."
selftest=no; [ "${1:-}" = "--self-test" ] && { selftest=yes; shift; }
filter="${1:-*}"
logdir=".build/report-logs"; mkdir -p "$logdir"

commit=$(git rev-parse --short HEAD 2>/dev/null || echo '?')
# --porcelain also counts UNTRACKED files (a plain `git diff` misses them), so a report run
# against a tree with stray generated/edited files is honestly flagged DIRTY (r8 #8).
dirty=$([ -z "$(git status --porcelain 2>/dev/null)" ] && echo clean || echo DIRTY)
qt6v=$(pkg-config --modversion Qt6Core 2>/dev/null || echo none)
qt5v=$(pkg-config --modversion Qt5Core 2>/dev/null || echo none)
dmdv=$(dmd --version 2>/dev/null | head -1 | grep -oE 'v[0-9.]+' || echo none)
ldcv=$(ldc2 --version 2>/dev/null | grep -oE 'LDC.*\([0-9.]+\)' | head -1 || echo none)
have() { command -v "$1" >/dev/null 2>&1 || [ -x "/usr/lib/qt6/$1" ] || [ -x "/usr/lib/qt6/bin/$1" ]; }
caps="qmlcachegen=$(have qmlcachegen && echo y || echo n) Qt6QmlCompiler=$(pkg-config --exists Qt6QmlCompiler 2>/dev/null && echo y || echo n) lrelease=$(command -v lrelease >/dev/null && echo y || echo n)"

if [ "$selftest" = no ]; then
printf '# qt-dlang-gen report — commit %s (%s) — %s\n' "$commit" "$dirty" "$(uname -sm)"
printf '# Qt6=%s Qt5=%s | dmd=%s ldc2=%s | caps: %s\n' "$qt6v" "$qt5v" "$dmdv" "$ldcv" "$caps"
printf 'target\tcategory\tcompiler\tqt\toptional\tstatus\tms\tlog\n'
fi

category() {
  case "$1" in
    sample_*) echo libsample ;;
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
    qtmoc-probe-*|report-selftest) echo gate ;;
    tr-*|lupdate-check) echo i18n ;;
    manifest-gate-*|registry-gate-*|expected-fails-lint|expected-fails-run|ctor-guard|ownership-gate-*) echo gate ;;
    qrc-*|container_*|qlist*|holder_test*|webengine-*) echo misc ;;
    consumer-smoke-*|dub-consumer-*) echo gate ;;
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
    qmltc5-*|qtmoc-probe-qml5) echo qt5 ;;
    manifest-gate-*|registry-gate-*|expected-fails-lint|lupdate-check|holder_test*|sample_*|report-selftest) echo - ;;
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
  ck report-selftest                 gate      -   -
  ck tr-ldc2                         i18n      qt6 ldc2
  ck qrc-ldc2                        misc      qt6 ldc2
  # ...and no target the build actually offers may be unclassified.
  # The ` (optional)` suffix is part of the LISTING, not of the name. Glob-matched families never
  # noticed; `binding-core` is matched exactly and came back unclassified the day it became optional.
  if list=$(./build --list 2>/dev/null | sed -e 's/^- //' -e 's/ (optional)$//' | grep -v '^List'); then
    n_other=0
    while read -r t; do [ -n "$t" ] && [ "$(category "$t")" = other ] && {
      printf 'self-test FAIL unclassified target: %s\n' "$t"; n_other=$((n_other+1)); }
    done <<< "$list"
    [ "$n_other" -eq 0 ] || st_fail=1
    printf 'report self-test: %s targets classified, %s unclassified\n' "$(wc -l <<< "$list")" "$n_other"
  else
    printf 'report self-test: canaries only (./build --list unavailable)\n'
  fi
  [ "$st_fail" -eq 0 ] && printf 'report self-test: OK\n'
  exit "$st_fail"
fi


pass=0 fail=0 skip=0
# Only the DEFAULT (mandatory) targets: `- name`. Optional targets print as `- name (optional)`
# (the manifest gates, r8 #1) and are advisory, so they're excluded from the gated record here.
mapfile -t targets < <(./build --list 2>/dev/null | grep -oE '^- [^ ]+$' | sed 's/^- //')
if [ "${#targets[@]}" -eq 0 ]; then echo "# ERROR: ./build --list produced no default targets" >&2; exit 2; fi
for t in "${targets[@]}"; do
  case "$t" in $filter) ;; *) continue ;; esac
  log="$logdir/$t.log"
  start=$(date +%s%3N)
  if ./build "$t" >"$log" 2>&1; then
    # A capability-gated target (qmlaot/qmltypes with the tool absent) runs but prints SKIP and
    # does no work — record it as skip, not a green pass it didn't actually perform (r8 #8/#10).
    if grep -qiE '(^|[^a-z])skip(ping|ped)?([^a-z]|$)' "$log"; then st=skip; skip=$((skip+1)); else st=pass; pass=$((pass+1)); fi
    rm -f "$log"; logcol=-
  else st=fail; fail=$((fail+1)); logcol="$log"; fi
  ms=$(( $(date +%s%3N) - start ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n' \
    "$t" "$(category "$t")" "$(compiler "$t")" "$(qtaxis "$t")" "$(optional "$t")" "$st" "$ms" "$logcol"
done
printf '# totals: %d pass, %d fail, %d skip (optional/advisory targets excluded; run them by name)\n' "$pass" "$fail" "$skip"
# This IS the record execution (r8 #8): exit non-zero if anything failed, so CI can gate on the
# report itself instead of running a second, separate matrix pass whose result it then discards.
[ "$fail" -eq 0 ]
