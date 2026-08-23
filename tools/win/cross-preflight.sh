#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# THE MSVC ABI, CHECKED FROM LINUX, BEFORE THE ROUND TRIP TO A WINDOWS MACHINE.
#
# A commit -> push -> pull -> build cycle on the VM is minutes; this is seconds. It answers exactly
# one class of question — does our code compile, link and RUN against the MSVC ABI — which is the
# class that produced the sret ordering, the exported inline members and the mangling table errors.
#
# It answers NOTHING about the build itself: MSYS paths, cmd.exe, PATHEXT, guard.ps1. Those exist
# only on the real machine, and wine has no PowerShell. So this is a pre-flight, never a verdict:
#
#     the VM stays the authority.
#
# ---------------------------------------------------------------------------------------------
# SETUP (once). No Windows machine and no Visual Studio are involved.
#
#   cargo install xwin
#   cd ~/winsdk && xwin --accept-license --arch x86_64 --sdk-version 10.0.22621 splat --output ~/winsdk/splat
#
#   `cd` FIRST, and not into the checkout: xwin caches its downloads in .xwin-cache under its
#   WORKING directory, and run from the repository root that is 1.1 GB of Microsoft redistributables
#   inside the tree — which the licence gate then reports, correctly, as 181 files stating no terms.
#
#   pipx install aqtinstall
#   cd ~/winqt && aqt install-qt windows desktop 6.10.3 win64_msvc2022_64
#
#   curl -sL -o ldc.7z https://github.com/ldc-developers/ldc/releases/download/v1.42.0/ldc2-1.42.0-windows-x64.7z
#   7z x ldc.7z          # only its lib/ is used: the Windows druntime and phobos
#
# TWO THINGS THAT STOP THIS HALFWAY, both measured:
#
#   `-L=-libpath:DIR` does not reach the linker — ldc2 eats the `-l` and lld-link asks for
#   `ibpath:DIR.lib`. The MSVC spelling `-L=/LIBPATH:DIR` works.
#
#   xwin ships no `vcruntime140.lib`, which is what ldc2 asks for by default. `-mscrtlib=msvcrt`
#   uses the dynamic CRT umbrella that IS there — and it has to be the dynamic one, because the Qt
#   DLLs are built against it.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
W=${XWIN_SPLAT:-$HOME/winsdk/splat}
Q=${WINQT:-$HOME/winqt/6.10.3/msvc2022_64}
L=${WINLDC:-$HOME/winldc/ldc2-1.42.0-windows-x64}
OUT=${1:-$ROOT/.build/cross}

for d in "$W/crt/include" "$Q/lib" "$L/lib"; do
    [ -d "$d" ] || { echo "cross-preflight SKIP: $d is missing (see the setup notes in this file)" >&2; exit 0; }
done
command -v wine >/dev/null || { echo "cross-preflight SKIP: no wine to run the result" >&2; exit 0; }

mkdir -p "$OUT"
SYSINC="-isystem $W/crt/include -isystem $W/sdk/include/ucrt -isystem $W/sdk/include/um -isystem $W/sdk/include/shared"
LIBS="-L=/LIBPATH:$L/lib -L=/LIBPATH:$W/crt/lib/x86_64 -L=/LIBPATH:$W/sdk/lib/um/x86_64 -L=/LIBPATH:$W/sdk/lib/ucrt/x86_64"

# 1) the calling convention, against a class we wrote — proves the shape.
clang++ --target=x86_64-pc-windows-msvc -std=c++17 $SYSINC \
        -c "$ROOT/tests/abi/windows/probe_impl.cpp" -o "$OUT/probe_impl.obj"
ldc2 -mtriple=x86_64-pc-windows-msvc -mscrtlib=msvcrt -of="$OUT/probe.exe" \
     "$ROOT/tests/abi/windows/probe.d" "$OUT/probe_impl.obj" $LIBS

# 2) ...and against Qt itself, through the explicit-self pattern xiboca emits.
clang++ --target=x86_64-pc-windows-msvc -std=c++17 -DQT_CORE_LIB $SYSINC \
        -I"$Q/include" -I"$Q/include/QtCore" \
        -c "$ROOT/tests/abi/windows/qtglue.cpp" -o "$OUT/qtglue.obj"
ldc2 -mtriple=x86_64-pc-windows-msvc -mscrtlib=msvcrt -of="$OUT/qtd.exe" \
     "$ROOT/tests/abi/windows/qtd.d" "$OUT/qtglue.obj" "$Q/lib/Qt6Core.lib" $LIBS

cp -f "$Q/bin/Qt6Core.dll" "$OUT/" 2>/dev/null || true

fail=0
for exe in probe qtd; do
    if out=$(WINEDEBUG=-all wine "$OUT/$exe.exe" 2>/dev/null); then
        # An exit code is not the check: a wine run that never started the program exits 0 too.
        case "$out" in
            *PASS*) echo "cross-preflight $exe: $(echo "$out" | tail -1)" ;;
            *) echo "cross-preflight FAIL: $exe produced no PASS line" >&2
               echo "$out" | sed 's/^/    /' >&2; fail=1 ;;
        esac
    else
        echo "cross-preflight FAIL: $exe exited non-zero" >&2; fail=1
    fi
done
[ "$fail" -eq 0 ] || exit 1
echo "cross-preflight OK: the MSVC ABI answers from Linux — this is a pre-flight, the VM is the verdict"
