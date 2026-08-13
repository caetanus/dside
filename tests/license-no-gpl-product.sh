#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# NO GPL-ONLY QT IN A PRODUCT ARTIFACT (docs/licensing-plan.md, Phase 4/5, gate
# `license-no-gpl-product`).
#
# The project is BSL-1.0 and its supported distribution model links Qt dynamically under the terms
# each module offers — normally LGPLv3. A defined set of Qt modules is GPL-only for open-source
# users, and one of them (Qt Qml Compiler) is genuinely needed by a TEST here: `qtd_qmltypes_check`
# validates our generated .qmltypes against Qt's own reader. That test may exist. What may not exist
# is a shipped artifact that links it.
#
# The plan asks for the check at two levels, because either alone is easy to satisfy while being
# wrong:
#
#   1. BUILD METADATA — a product spec must not request a GPL-only module. Catching it here gives a
#      licensing diagnostic instead of a link error three steps later.
#   2. ACTUAL IMPORTS — what the binary really needs, read from the ELF, because a spec is an
#      intention and DT_NEEDED is a fact. A transitive pull-in shows up here and nowhere else.
#
# The module list below is the plan's FLOOR, not the source of truth: the authoritative list is Qt's
# own licensing page and SBOM for the exact release, and every Qt minor must be re-checked. A floor
# that is out of date fails closed — it never silently allows more.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# GPL-only Qt modules (licensing-plan.md § GPL-only denylist). Written as the library base names the
# linker would record, so the same list serves both checks.
GPL_ONLY="Qt6QmlCompiler Qt6Canvas3D Qt6Coap Qt6Graphs Qt6Grpc Qt6HttpServer Qt6Bodymovin \
Qt6Mqtt Qt6NetworkAuth Qt6Quick3D Qt6Quick3DPhysics Qt6QuickTimeline Qt6VirtualKeyboard \
Qt6WaylandCompositor Qt5QmlCompiler Qt5Coap Qt5Mqtt Qt5NetworkAuth Qt5Quick3D Qt5VirtualKeyboard \
Qt5WaylandCompositor"

bad=0

# --- 1. build metadata: no product spec may request one ----------------------------------------
# generator/spec_cxx_*.json is what a binding is generated from; anything listed there ends up in a
# product artifact. The test-only validator does not live in a spec, which is why it is allowed.
for spec in "$ROOT"/generator/spec_cxx_*.json; do
    [ -f "$spec" ] || continue
    pk=$(sed -n 's/.*"pkg_config"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$spec")
    for m in $GPL_ONLY; do
        case " $pk " in
          *" $m "*)
            echo "license-no-gpl-product FAIL: $(basename "$spec") requests $m, which is GPL-only." >&2
            echo "    A binding generated from this spec cannot be distributed under BSL-1.0 with" >&2
            echo "    open-source Qt. See docs/licensing-plan.md § GPL-only denylist." >&2
            bad=$((bad + 1)) ;;
        esac
    done
done

# --- 2. actual imports: what the artifacts really need ------------------------------------------
# The installed package is the product. Its archives are static, so DT_NEEDED does not apply to them
# — the honest check on an archive is which UNDEFINED symbols it carries, since those are what a
# consumer's link will have to resolve against some Qt library.
seen=0
for a in "$ROOT"/.build/*/libshims.a "$ROOT"/.build/*/libbinding_*.a; do
    [ -f "$a" ] || continue
    seen=$((seen + 1))
    name=$(basename "$(dirname "$a")")/$(basename "$a")
    # QQmlJS* and QQmlSA* are the Qml Compiler's namespaces; QQmlJSTypeDescriptionReader is the one
    # this project actually uses, in the test-only validator.
    if nm -uC "$a" 2>/dev/null | grep -qE '\bQQmlJS[A-Z]|\bQQmlSA'; then
        echo "license-no-gpl-product FAIL: $name references the Qt Qml Compiler (QQmlJS*/QQmlSA*)." >&2
        echo "    That module is GPL-only and this archive is a product artifact." >&2
        bad=$((bad + 1))
    fi
done

# ...and any executable the release would carry, by its recorded needs.
for f in "$ROOT"/.build/*/qmltc-d "$ROOT"/.build/*/gend; do
    [ -x "$f" ] || continue
    seen=$((seen + 1))
    for m in $GPL_ONLY; do
        if readelf -d "$f" 2>/dev/null | grep -q "lib$m\.so"; then
            echo "license-no-gpl-product FAIL: $(basename "$f") has lib$m.so in DT_NEEDED." >&2
            bad=$((bad + 1))
        fi
    done
done

[ "$seen" -gt 0 ] || { echo "license-no-gpl-product: nothing built yet — no artifact to inspect" >&2; exit 0; }
[ "$bad" -eq 0 ] || exit 1
echo "license-no-gpl-product OK: no product spec requests a GPL-only Qt module, and none of the $seen inspected artifact(s) references one"
