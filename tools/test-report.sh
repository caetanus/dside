#!/usr/bin/env bash
# Structured test report (round-5 #7): run each reggae target and emit a TSV with
# target, category, compiler, qt, optional, status and duration — so the ~140-target matrix
# (with availability-gated optional targets) is auditable as data, not a wall of stdout.
#
#   tools/test-report.sh            > report.tsv      # whole suite
#   tools/test-report.sh 'qml*'     > report.tsv      # a glob subset (matched against target names)
set -u
cd "$(dirname "$0")/.."
filter="${1:-*}"
commit=$(git rev-parse --short HEAD 2>/dev/null || echo '?')

category() {  # by target name prefix
  case "$1" in
    sample_*)                                                 echo libsample ;;
    wraptest*|widget_test*|moc_test*|ownership*)              echo lifetime ;;
    cannon*)                                                  echo moc ;;
    uic-*|dialog-*|tabs-*|mainwin-*|hello-*|egroup-*|combo-*|spacer-*|icon-*|uicheck*|corpus-check*) echo uic ;;
    qml-*|qmlreg-*|qmlaot-*|qmltypes-*|moclife-*)             echo qml ;;
    tr-*|lupdate-check)                                       echo i18n ;;
    manifest-gate-*)                                          echo gate ;;
    qrc-*|container_*|qlist*|holder_test*|webengine-*)        echo misc ;;
    *)                                                        echo other ;;
  esac
}
optional() {  # availability-gated (qmlcachegen / Qt6QmlCompiler / lrelease / dub)
  case "$1" in qmlaot-*|qmltypes-*|lupdate-check|tr-*) echo yes ;; *) echo no ;; esac
}
axis() {  # compiler + qt from the name suffix
  local c=- q=-
  case "$1" in *-ldc2*) c=ldc2 ;; *-dmd*) c=dmd ;; esac
  case "$1" in *-qt5*) q=qt5 ;; *-qt6*) q=qt6 ;; esac
  echo "$c	$q"
}

printf '# qt-dlang-gen test report — commit %s\n' "$commit"
printf 'target\tcategory\tcompiler\tqt\toptional\tstatus\tms\n'
pass=0 fail=0
for t in $(./build --list 2>/dev/null | sed -n 's/^- //p'); do
  case "$t" in $filter) ;; *) continue ;; esac
  start=$(date +%s%3N)
  if ./build "$t" >/dev/null 2>&1; then st=pass; pass=$((pass+1)); else st=fail; fail=$((fail+1)); fi
  ms=$(( $(date +%s%3N) - start ))
  printf '%s\t%s\t%s\t%s\t%s\t%d\n' "$t" "$(category "$t")" "$(axis "$t")" "$(optional "$t")" "$st" "$ms"
done
printf '# totals: %d pass, %d fail\n' "$pass" "$fail"
