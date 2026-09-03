#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# CROSS-COMPILE THE BINDING FOR ANDROID, and prove nothing more than that.
#
#   tools/android/cross-build.sh <ndk-root> <qt-for-android-prefix> [abi] [api] [workdir]
#
# WHAT THIS DOES AND DOES NOT CLAIM. It generates the binding against Qt for Android, compiles the
# C++ shims with the NDK's clang++, compiles the generated D with ldc2 for the Android triple, and
# archives both. That is the whole claim: the sources cross-compile and the archives are for the
# right machine. It runs NO test — the ~1200 targets of the record execution are host processes
# driven by `sh`, and running them would mean an emulator and a rewrite, which is a different piece
# of work with a different price.
#
# WHY THIS IS A SCRIPT AND NOT A reggae TARGET, for now. The build's platform axis is the HOST's
# (`hostPlatform()` answers windows/macos/linux/posix) and every binding derives its flags from a
# pkg-config or a probe of the machine it is running on. Growing a cross axis through
# `qtdBinding` touches every one of the 1223 targets; doing it here first gives that change a
# worked example to absorb instead of a design to guess at.
#
# The generator itself needs NO change, and that is the one pleasant surprise: a spec may carry
# `cflags` directly — the Windows build already derives one that way — so an Android spec is just
# the flags of the Qt that is being bound, plus a target triple libclang understands.
set -eu

NDK=${1:?usage: cross-build.sh <ndk-root> <qt-for-android-prefix> [abi] [api] [workdir]}
QTA=${2:?usage: cross-build.sh <ndk-root> <qt-for-android-prefix> [abi] [api] [workdir]}
ABI=${3:-arm64-v8a}
API=${4:-23}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=${5:-$ROOT/.build/android-$ABI}

fail() { echo "android: $1" >&2; [ $# -gt 1 ] && echo "    $2" >&2; exit 1; }

# The ABI names Android uses are not the triples the compilers want, and the two do not map by
# string surgery — `armeabi-v7a` is `armv7a-linux-androideabi`, with an `eabi` the others lack.
case "$ABI" in
  arm64-v8a)   TRIPLE=aarch64-linux-android;    LDCTRIPLE=aarch64-linux-android ;;
  armeabi-v7a) TRIPLE=armv7a-linux-androideabi; LDCTRIPLE=armv7a-linux-androideabi ;;
  x86_64)      TRIPLE=x86_64-linux-android;     LDCTRIPLE=x86_64-linux-android ;;
  *)           fail "unknown ABI '$ABI'" "one of arm64-v8a, armeabi-v7a, x86_64" ;;
esac

TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64
[ -x "$TC/bin/clang++" ] || fail "no clang++ under $TC/bin" "is \$1 an NDK root?"
[ -d "$QTA/include/QtCore" ] || fail "no include/QtCore under $QTA" "is \$2 a Qt for Android prefix?"
command -v ldc2 >/dev/null || fail "ldc2 is not on PATH"

CXX=$TC/bin/clang++
AR=$TC/bin/llvm-ar
SYSROOT=$TC/sysroot

# THE RESOURCE DIRECTORY IS THE NDK'S, NOT THE HOST libclang'S. xiboca parses with the libclang
# that is installed on the machine it runs on, and a compiler's BUILTIN headers - stddef.h,
# stdarg.h, the rest - live beside that compiler rather than in the sysroot. Handed the NDK's
# sysroot but the host compiler's idea of builtin, the first parse failed on libc++'s very first
# include:
#
#     <cstddef> tried including <stddef.h> but didn't find libc++'s <stddef.h> header
#
# which reads like a broken NDK and is really two compilers not lining up.
RESDIR=$(ls -d "$TC"/lib/clang/* 2>/dev/null | sort -V | tail -1)
[ -n "$RESDIR" ] || fail "no clang resource directory under $TC/lib/clang"

rm -rf "$WORK"; mkdir -p "$WORK/gen" "$WORK/ocpp" "$WORK/od"

# THE SPEC, DERIVED. Same shape the Windows build derives: everything the shipped spec says, with
# `pkg_config` replaced by the flags of the Qt in front of us and `out_dir` made absolute. There is
# no pkg-config in an Android Qt and there is no reason for the shipped spec to know about one.
python3 - "$ROOT/generator/spec_cxx_qtwidgets.json" "$WORK/spec.json" "$WORK/gen" \
         "$QTA" "$TRIPLE$API" "$SYSROOT" "$RESDIR" <<'PY'
import json, sys, os
src, dst, out, qta, target, sysroot, resdir = sys.argv[1:8]
s = json.load(open(src))
s.pop("pkg_config", None)
s["out_dir"] = os.path.abspath(out)
inc = os.path.join(qta, "include")
mods = ["QtCore", "QtGui", "QtWidgets"]
s["cflags"] = ["--target=" + target, "--sysroot=" + sysroot,
               "-resource-dir=" + resdir, "-I" + inc] + \
              ["-I" + os.path.join(inc, m) for m in mods] + \
              ["-DQT_NO_KEYWORDS"]
s["libs"] = []
json.dump(s, open(dst, "w"), indent=2)
print("spec: target=%s resource-dir=%s qt=%s" % (target, resdir, qta))
PY

"$ROOT/xiboca/xiboca" "$WORK/spec.json" > "$WORK/gen.log" 2>&1 \
    || fail "xiboca refused the Android spec" "$(tail -5 "$WORK/gen.log")"
emitted=$(sed -n 's/.*done: \([0-9]*\) classes emitted.*/\1/p' "$WORK/gen.log")
[ -n "${emitted:-}" ] && [ "$emitted" -gt 0 ] \
    || fail "xiboca emitted no classes" "$(grep -a 'skipped\|done:' "$WORK/gen.log" | head -3)"
echo "android: $emitted class(es) generated for $ABI"

# The shims, with the NDK's clang++ — the same command line reggae/qtd_build.d builds, minus the
# host's pkg-config flags and plus the target.
for c in "$WORK"/gen/*.cpp; do
    b=$(basename "$c" .cpp)
    "$CXX" --target="$TRIPLE$API" --sysroot="$SYSROOT" -std=c++17 -fPIC -O2 \
        -ffunction-sections -fdata-sections \
        -I"$QTA/include" -I"$QTA/include/QtCore" -I"$QTA/include/QtGui" -I"$QTA/include/QtWidgets" \
        -c "$c" -o "$WORK/ocpp/$b.o" 2>>"$WORK/cxx.err" \
        || fail "the shim $b.cpp did not compile" "$(tail -5 "$WORK/cxx.err")"
done
"$AR" rcs "$WORK/libshims.a" "$WORK"/ocpp/*.o || fail "ar failed on the shims"

# ...and the D half. `-c` only: linking would need an Android druntime, and what is being proved is
# that the generated sources compile for the target, not that a program links.
ldc2 -mtriple="$LDCTRIPLE" -c -oq -od="$WORK/od" -I"$WORK/gen" \
    $(find "$WORK/gen" -name '*.d') 2>"$WORK/d.err" \
    || fail "the generated D did not compile for $LDCTRIPLE" "$(head -8 "$WORK/d.err")"
"$AR" rcs "$WORK/libbinding_ldc2.a" "$WORK"/od/*.o || fail "ar failed on the binding"

# THE ARCHIVES ARE FOR THE RIGHT MACHINE, checked rather than assumed: a cross build that silently
# produced host objects would pass every step above.
for a in "$WORK/libshims.a" "$WORK/libbinding_ldc2.a"; do
    [ -s "$a" ] || fail "$a is empty"
    m=$("$TC/bin/llvm-readobj" --file-headers "$a" 2>/dev/null | sed -n 's/.*Machine: *//p' | head -1)
    case "$ABI:$m" in
      arm64-v8a:EM_AARCH64*|armeabi-v7a:EM_ARM*|x86_64:EM_X86_64*) ;;
      *) fail "$a is $m, not the machine $ABI asks for" ;;
    esac
done

printf 'android: OK — %s and %s for %s (%s), %s class(es), %s shim object(s)\n' \
    "$(basename "$WORK/libbinding_ldc2.a")" "$(basename "$WORK/libshims.a")" \
    "$ABI" "$TRIPLE$API" "$emitted" "$(ls "$WORK"/ocpp/*.o | wc -l)"
