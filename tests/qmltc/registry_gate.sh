#!/bin/sh
# Every QML type the registry can NAME must also be TYPEABLE.
#
# `qmlmap.tsv` says which C++ class a QML name is; `qmlprops.tsv` says what its properties are. A
# name in the first with no rows in the second is a type the compiler can recognise and then fail to
# compile a single binding on -- and it fails with "declared type '?'", which reads like an
# expression the compiler does not handle rather than a type it was never told about.
#
# That is not hypothetical: `Text` was exactly this in the Controls binding, its 78 rows filed under
# `QQuickText` because an unexported re-declaration overwrote the QML name. Not one Text binding in
# either corpus could be typed, and the refusals came out wearing another shape.
set -u
fail=0
for map in "$@"; do
    props=$(dirname "$map")/qmlprops.tsv
    [ -f "$map" ] && [ -f "$props" ] || continue
    cut -f1 "$map"   | sort -u > "/tmp/.rg_map.$$"
    cut -f1 "$props" | sort -u > "/tmp/.rg_prop.$$"
    missing=$(comm -23 "/tmp/.rg_map.$$" "/tmp/.rg_prop.$$")
    rm -f "/tmp/.rg_map.$$" "/tmp/.rg_prop.$$"
    n=$(printf '%s' "$missing" | grep -c . || true)
    if [ "$n" -ne 0 ]; then
        echo "registry-gate: $(dirname "$map"): $n QML type(s) named but with no property rows:"
        printf '%s\n' "$missing" | sed 's/^/  /'
        fail=1
    fi
done
# ...and the top of the hierarchy has to be there too. `objectName` is the one property EVERY QObject
# has, so a registry where no type publishes it is one whose prototype chain never reached QObject:
# the QtQuick binding read only QtQuick's plugins.qmltypes, and QtObject -- where objectName is
# declared -- lives in the QML module's. 0 rows out of 186 types, while the Controls binding had 310
# out of 331. A type having SOME rows is not the same as having the right ones.
for map in "$@"; do
    props=$(dirname "$map")/qmlprops.tsv
    [ -f "$props" ] || continue
    if ! grep -q "	objectName	" "$props"; then
        echo "registry-gate: $(dirname "$map"): no type publishes objectName -- the prototype chain"
        echo "  never reached QObject. Is the QML module's plugins.qmltypes in this spec?"
        fail=1
    fi
done
[ "$fail" -eq 0 ] && echo "registry-gate: every named QML type has property rows, and QObject is in the chain"
exit "$fail"
