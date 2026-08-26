# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# WHAT AN `sh` GATE HAS TO KNOW ABOUT THE PLATFORM IT IS RUNNING ON. Sourced, not executed:
#
#     . "$(dirname "$0")/../shplatform.sh"
#
# Two facts, both measured on the Windows VM, both invisible until the tools they affect finally
# ran there.
#
# MSYS REWRITES ARGUMENTS THAT LOOK LIKE PATHS. `--shadow-url qrc:/qtdshadow/` reached the compiler
# as `:C:/msys64/qtdshadow/` — the `:` followed by `/` is exactly the shape its POSIX-to-Windows
# conversion exists for — and the tool answered
#     Cannot read files from resource directory ":C:/msys64/qtdshadow/"
# about a path nobody wrote. Every path these gates handle arrives from the build already native,
# so none of them wants the conversion.
MSYS2_ARG_CONV_EXCL='*'
export MSYS2_ARG_CONV_EXCL

# -fPIC IS REQUIRED ON ELF AND REFUSED ON THE MSVC TARGET (`clang++: error: unsupported option
# '-fPIC' for target 'x86_64-pc-windows-msvc'`). The build answers this with cxxPic(); a gate that
# composes its own compile line has to ask it too.
# ...AND THE FRAME POINTER, on Windows. dmd's Win64 exception handling walks the RBP chain
# (rt/deh_win64_posix.d), and x64 omits it by default — one C++ frame between a D `throw` and its
# `catch` was enough to lose the exception. Measured on a minimal case: the same C++ source caught
# by dmd with `-fno-omit-frame-pointer` and lost without it.
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) QTD_PIC="";      QTD_FP="-fno-omit-frame-pointer" ;;
  *)                    QTD_PIC="-fPIC"; QTD_FP="" ;;
esac

# THE INSTALLED Qt RELEASE, WITHOUT pkg-config. Qt's MSVC builds ship no .pc files at all, so on
# Windows every `pkg-config --modversion` answers nothing and a gate keyed on it either says
# "no Qt found" about an installation the build already resolved, or skips itself in silence. The
# environment names the prefix (QTDIR6/QTDIR5, the same ones the build uses) and Qt writes its
# release into qconfig.h as QT_VERSION_STR.
qt_release_from_prefix() {
    [ -n "${1:-}" ] || return 1
    for h in "$1/include/QtCore/qconfig.h" "$1/include/QtCore/qtcoreversion.h"; do
        [ -f "$h" ] || continue
        v=$(sed -n 's/^#[[:space:]]*define[[:space:]]\+QT_VERSION_STR[[:space:]]\+"\([^"]*\)".*/\1/p' "$h" | head -1)
        [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    done
    return 1
}

# A DIRECTORY IN THE SPELLING A NATIVE PROGRAM CAN OPEN. `cd … && pwd` answers `/c/Users/…` under
# MSYS, and python, clang++, ldc2 and xiboca are all native Windows programs that know nothing
# about `/c`. Handing them the MSYS form is not a path error they can explain — python said
#     FileNotFoundError: '/c/Users/caetano/dside/generator/spec_userlib.json'
# about a file that is plainly there. `pwd -W` is the same directory said the other way, and the
# MSYS shell reads `C:/…` perfectly well, so ONE form serves both sides.
qtd_abs() {  # $1 = directory
    ( CDPATH= cd -- "$1" && { pwd -W 2>/dev/null || pwd; } )
}
