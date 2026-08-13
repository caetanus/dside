#!/bin/sh
# ARCHIVE COMPOSITION CANARY (critics r13 #3).
#
# `runtime-boundary` counts QML types in a source file. That is LEXICAL LOCATION, and the audit was
# right that it can fall to zero without removing a byte of QML runtime from a binding that has no
# QtQml: the source moved to its own file and every archive still carried the object.
#
# This looks at the artefact instead. Two directions, because only checking one of them lets the
# boundary close by deleting the feature:
#
#   * a binding WITHOUT QtQml must NOT contain qtdmoc_qml.o — it gets the generated thin stubs;
#   * a binding WITH QtQml must contain it — otherwise the QML runtime silently became no-ops and
#     every compiled document would keep running against stubs.
#
# Which is which comes from the archive itself, not from a list kept here: a binding links QtQml iff
# its own libbinding archive references a Qt QML symbol. A hard-coded list of binding names would be
# one more thing to forget when a binding is added.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

bad=0
seen=0
for a in "$ROOT"/.build/*/libshims.a; do
    [ -f "$a" ] || continue
    d=$(dirname "$a"); name=$(basename "$d")
    have_qml_obj=$(ar t "$a" 2>/dev/null | grep -c '^qtdmoc_qml\.o$' || true)
    have_stub=$(ar t "$a" 2>/dev/null | grep -c 'qtdmoc_qml_stub\.o$' || true)

    # Did the BUILD enable QML for this binding? It says so itself, in a marker the shims step
    # writes. TWO earlier versions of this line INFERRED it — from QQml symbols anywhere in the
    # archive, then from symbols in the shared unit's object — and the first failed `webengine`,
    # which references QQmlProperty because ITS OWN bound API does, with no QML runtime involved. A
    # gate that has to be right about someone else's API is the wrong shape. This reads a fact.
    marker="$d/qml-enabled"
    if [ ! -f "$marker" ]; then
        echo "archive-composition: $name has no qml-enabled marker — rebuild its shims" >&2
        continue
    fi
    wants=$(cat "$marker")
    seen=$((seen + 1))

    if [ "$wants" = no ] && [ "$have_qml_obj" -ne 0 ]; then
        echo "archive-composition FAIL: $name has no QtQml and still carries qtdmoc_qml.o" >&2
        echo "    the QML runtime is in a product that cannot use it — the boundary is source-only" >&2
        bad=$((bad + 1))
    fi
    if [ "$wants" = no ] && [ "$have_stub" -eq 0 ]; then
        echo "archive-composition FAIL: $name has neither qtdmoc_qml.o nor the generated stubs" >&2
        echo "    its exports are simply missing; a link against it will fail late and obscurely" >&2
        bad=$((bad + 1))
    fi
    if [ "$wants" = yes ] && [ "$have_qml_obj" -eq 0 ]; then
        echo "archive-composition FAIL: $name links QtQml and does NOT carry qtdmoc_qml.o" >&2
        echo "    the QML runtime became no-op stubs; compiled documents would run against nothing" >&2
        bad=$((bad + 1))
    fi
done

[ "$seen" -gt 0 ] || { echo "archive-composition: no archives built yet" >&2; exit 0; }
[ "$bad" -eq 0 ] || exit 1
echo "archive-composition OK: $seen archive(s) — the QML runtime is in the bindings that link QtQml and in no others"
