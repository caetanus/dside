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

printf '# qt-dlang-gen report — commit %s (%s) — %s\n' "$commit" "$dirty" "$(uname -sm)"
printf '# Qt6=%s Qt5=%s | dmd=%s ldc2=%s | caps: %s\n' "$qt6v" "$qt5v" "$dmdv" "$ldcv" "$caps"
printf 'target\tcategory\tcompiler\tqt\toptional\tstatus\tms\tlog\n'

category() {
  case "$1" in
    sample_*) echo libsample ;;
    wraptest*|widget_test*|moc_test*|moclife_widget*|ownership*) echo lifetime ;;
    cannon*) echo moc ;;
    uic-*|dialog-*|tabs-*|mainwin-*|hello-*|egroup-*|combo-*|spacer-*|icon-*|uicheck*|corpus-check*) echo uic ;;
    qml-*|qmlreg-*|qmlaot-*|qmltypes-*|moclife-*|qmltwo-*|homonym-*|homocollide-*|metacast-*|metacontract-*|boom-*|metathread-*) echo qml ;;
    tr-*|lupdate-check) echo i18n ;;
    manifest-gate-*|expected-fails-lint) echo gate ;;
    qrc-*|container_*|qlist*|holder_test*|webengine-*) echo misc ;;
    *) echo other ;;
  esac
}
optional() { case "$1" in qmlaot-*|qmltypes-*|lupdate-check|tr-*) echo yes ;; *) echo no ;; esac ; }
compiler() { case "$1" in *-ldc2*) echo ldc2 ;; *-dmd*) echo dmd ;; *) echo - ;; esac ; }
# qt axis: -qt5 => qt5; version-agnostic targets => -; everything else Qt-linked => qt6.
qtaxis() {
  case "$1" in
    *-qt5*) echo qt5 ;;
    manifest-gate-*|expected-fails-lint|lupdate-check|holder_test*|sample_*) echo - ;;
    *) echo qt6 ;;
  esac
}

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
