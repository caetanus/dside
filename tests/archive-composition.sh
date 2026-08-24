#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
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
# The list comes from the GRAPH, as a file the reggaefile writes: one line per archive the build
# produces, with the QML decision that produced it. Three earlier shapes were wrong and the audit
# caught each (critics r13 #3, r14 #4): inferring from QQml symbols anywhere in the archive (which
# `webengine` fails, because its own bound API uses QQmlProperty); inferring from the shared unit's
# object; and globbing `.build/*/libshims.a`, which proves something about the artefacts that happen
# to exist rather than the ones the build promises. A missing archive is now a FAILURE, not a skip.
set -eu
[ $# -eq 1 ] || { echo "usage: archive-composition.sh <spec.tsv>" >&2; exit 2; }
SPEC=$1
[ -f "$SPEC" ] || { echo "archive-composition FAIL: no spec at $SPEC" >&2; exit 1; }

bad=0
seen=0
while IFS="	" read -r a wants; do
    [ -n "$a" ] || continue
    seen=$((seen + 1))
    name=$(basename "$(dirname "$a")")
    if [ ! -f "$a" ]; then
        echo "archive-composition FAIL: $name — $a was never built, and this gate promised to look at it" >&2
        bad=$((bad + 1)); continue
    fi
    case "$wants" in
      yes|no) ;;
      *) echo "archive-composition FAIL: $name — spec says \`$wants\`, which is neither yes nor no" >&2
         bad=$((bad + 1)); continue ;;
    esac
    # THE OBJECT SUFFIX IS THE PLATFORM'S, and `ar` is not the only archiver: MSVC objects are
    # `.obj` and the archive is read with llvm-ar. Pinned to `.o`, this canary reported
    #     libsample has neither qtdmoc_qml.o nor qtdmoc_qml_stub.o
    # about an archive that carries qtdmoc_qml_stub.obj — a false red about the one thing it exists
    # to check, on every Windows build.
    # ...and llvm-ar lists FULL PATHS where GNU ar lists bare names, so the name is matched at its
    # last separator rather than at the start of the line. Anchored with `^`, nothing ever matched
    # on Windows and the canary reported every archive as missing the unit it plainly contains.
    AR=${AR:-ar}; command -v "$AR" >/dev/null 2>&1 || AR=llvm-ar
    have_qml_obj=$("$AR" t "$a" 2>/dev/null | grep -cE '(^|[/\\])qtdmoc_qml\.(o|obj)$' || true)
    have_stub=$("$AR" t "$a" 2>/dev/null | grep -cE '(^|[/\\])qtdmoc_qml_stub\.(o|obj)$' || true)

    if [ "$wants" = no ] && [ "$have_qml_obj" -ne 0 ]; then
        echo "archive-composition FAIL: $name has no QtQml and still carries qtdmoc_qml.o" >&2
        echo "    the QML runtime is in a product that cannot use it — the boundary is source-only" >&2
        bad=$((bad + 1))
    fi
    if [ "$wants" = no ] && [ "$have_stub" -eq 0 ]; then
        echo "archive-composition FAIL: $name has neither qtdmoc_qml.o nor qtdmoc_qml_stub.o" >&2
        echo "    its exports are simply missing; a link against it will fail late and obscurely" >&2
        bad=$((bad + 1))
    fi
    if [ "$wants" = yes ] && [ "$have_qml_obj" -eq 0 ]; then
        echo "archive-composition FAIL: $name links QtQml and does NOT carry qtdmoc_qml.o" >&2
        echo "    the QML runtime became no-op stubs; compiled documents would run against nothing" >&2
        bad=$((bad + 1))
    fi
done < "$SPEC"

[ "$seen" -gt 0 ] || { echo "archive-composition FAIL: the spec is empty" >&2; exit 1; }
[ "$bad" -eq 0 ] || exit 1
echo "archive-composition OK: $seen archive(s) from the build graph — the QML runtime is in the bindings that link QtQml and in no others"
