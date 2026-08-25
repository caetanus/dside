#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
# INSTALL THE BINDING AS A PACKAGE, and then consume it as one.
#
# CRITICS round 12 #6: "um exemplo consumidor em diretorio temporario deve depender apenas de um
# artefato instalado/empacotado". The consumer smoke gets half of that — the application is built
# outside the checkout — but it still points `-I` and `-L` at a build directory, which is not a
# dependency, it is a path that happens to exist. This closes the other half: lay the artifacts out
# as a dub package and let dub resolve it.
#
# There is nothing clever here, and that is the finding: the whole package is an import path, two
# archives and eleven lines of dub.json. What was missing was never machinery — it was that nobody
# had tried, which is also how three papercuts survived until somebody wrote an application.
#
#   install.sh <gen dir> <build dir> <prefix> <pkg name> <qt libs...>
set -eu
GEN="$1"; BDIR="$2"; PREFIX="$3"; PKG="$4"; shift 4
LIBS="$*"

rm -rf "$PREFIX"; mkdir -p "$PREFIX/lib"
cp -r "$GEN" "$PREFIX/source"
# Both compilers' archives, selected by dub's `lflags-<compiler>` — one package, either compiler.
for a in "$BDIR"/libbinding_*.a "$BDIR/libshims.a"; do [ -f "$a" ] && cp "$a" "$PREFIX/lib/"; done

# `libs` as PLAIN NAMES, not the pkg-config line: dub passes them to the compiler's -L machinery,
# and a `-lQt6Widgets` here would arrive as `--l-lQt6Widgets`.
#
# The same walk builds the HUMAN list, because the NOTICE promised one and never had it: it printed
# `${qlibs_human:-see qtd-build.txt}`, and `qlibs_human` was defined nowhere in this repository —
# `git grep` found exactly one line, the one reading it. So every package ever built took the
# fallback, and it pointed at a file that recorded qt/generator/generated-from and no modules at
# all. A dead cross-reference in the one field that decides whether the reader's obligation is LGPL
# or GPL. Found by license-package, which now refuses the pair.
qlibs=""
qlibs_human=""
# TWO SPELLINGS, because a Qt module is `-lQt6Widgets` where pkg-config answers and a full path to
# `Qt6Widgets.lib` where it does not. Reading only the first left `libs` EMPTY on Windows — the
# package named no Qt at all and the consumer's link ended with 7476 unresolved QObject symbols.
qtlibdir=""
for l in $LIBS; do
  case "$l" in
    -l*)   n=${l#-l} ;;
    *.lib) n=$(basename "$l" .lib)
           [ -n "$qtlibdir" ] || qtlibdir=$(dirname "$l") ;;
    *)     continue ;;
  esac
  qlibs="$qlibs\"$n\", "
  qlibs_human="${qlibs_human:+$qlibs_human, }$n"
done

# WHAT THIS WAS BUILT AGAINST, recorded in the package. A binding generated from Qt 6.11's headers
# and linked against 6.12 at run time is the silent breakage this whole project exists to avoid, and
# until now nothing in the artifact said which Qt it came from — the audit's "nada versiona o
# artefacto contra o Qt minor". The consumer checks it (dub-consumer.sh), so the mismatch is a
# refusal with both numbers rather than a crash somewhere in a vtable.
QTVER=$(pkg-config --modversion Qt6Core 2>/dev/null || echo unknown)
SRCROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# The revision AT PACKAGING TIME, which is not the same fact as the revision that emitted the
# sources sitting next to it — and the two really did disagree: qtd-build.txt said `a0b3b94` while
# all 824 generated files said `generator=fa680f9`, one commit apart, in the same package. This
# field used to be called `generator=`, which made it a statement about files it had never touched.
# It is now `packaged-at=`, and `generator=` is READ FROM THE SOURCES, so the package cannot claim a
# provenance its own contents contradict.
PKGREV=$(git -C "$SRCROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ -n "$(git -C "$SRCROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  PKGREV="$PKGREV-dirty"
fi
GENREV=$(sed -n 's/^\/\/ provenance: generator=\([^ ]*\).*/\1/p' \
         "$(find "$GEN" -name '*.d' -exec grep -l "^// provenance:" {} + 2>/dev/null | head -1)" \
         2>/dev/null | head -1)
GENREV=${GENREV:-unknown}
# `generated-from` is a path RELATIVE to the repository. The absolute one names the home directory
# of whoever built the package and resolves nowhere else, so as provenance it is worse than useless
# — it looks like an input the consumer could go and read. What identifies the tree is
# `generated/<qt>/<spec>`; the prefix in front of it is a fact about my laptop. Caught by
# license-package on its first run.
cat > "$PREFIX/qtd-build.txt" <<EOF
qt=$QTVER
generator=$GENREV
packaged-at=$PKGREV
generated-from=${GEN#"$SRCROOT"/}
modules=${qlibs_human:-unknown}
EOF

# THE VERBATIM COPIES, NAMED IN THE PACKAGE. A handful of shipped files are byte-identical copies of
# hand-written sources under runtime/ — no generator produced them, so they carry our SPDX header and
# no `// provenance:` line, and that is correct. What was NOT correct is how their absence was
# excused: license-package consulted `runtime/` in the repository, a directory the consumer does not
# have. Phase 3's exit criterion is that the package answers for itself, so the answer belongs IN it.
#
# They stay byte-identical rather than being stamped, because `runtime-provenance` requires exactly
# that (a copy that had drifted from its origin once produced a false ALL PASS) — the two demands
# only look contradictory until the record moves out of the file and into the manifest.
# `cmp` IS NOT EVERYWHERE. MSYS2 ships without diffutils, and a missing cmp is indistinguishable
# from "the files differ": the loop below matched nothing, verbatim.txt came out EMPTY, and
# license-package then reported five runtime copies as files that "travel alone" without saying
# what produced them — the right verdict about a package this script had quietly built wrong.
command -v cmp >/dev/null || {
    echo "install: cmp is not on PATH — the verbatim manifest cannot be built." >&2
    echo "    Every runtime copy would look unexplained to license-package. On MSYS2:" >&2
    echo "        pacman -S --noconfirm --needed diffutils" >&2
    exit 1
}
: > "$PREFIX/verbatim.txt"
for f in "$PREFIX"/source/*.d "$PREFIX"/source/*.cpp; do
  [ -f "$f" ] || continue
  grep -q "^// provenance:" "$f" && continue
  base=$(basename "$f")
  for origin in $(find "$SRCROOT/runtime" -name "$base" 2>/dev/null); do
    if cmp -s "$origin" "$f"; then
      echo "source/$base <- ${origin#"$SRCROOT"/} @ $PKGREV" >> "$PREFIX/verbatim.txt"
      break
    fi
  done
done

# The package carries its own license and notices (licensing-plan, Phase 3): a consumer must be able
# to answer "what may I do with this?" from the unpacked package alone, without the repository.
cp "$(dirname "$0")/../LICENSE" "$PREFIX/LICENSE"
mkdir -p "$PREFIX/LICENSES"
cp "$(dirname "$0")/../LICENSES/BSL-1.0.txt" "$PREFIX/LICENSES/BSL-1.0.txt"
cat > "$PREFIX/NOTICE" <<EOF
$PKG — generated Qt binding for D.

The generated D sources, the generated C++ shims and trampolines, and the runtime copied into this
package are offered under BSL-1.0 (see LICENSE and LICENSES/BSL-1.0.txt).

This package contains NO Qt source or Qt binary. It BINDS to Qt $QTVER, which you must obtain and
comply with separately: the open-source Qt distribution is normally LGPLv3, and a defined set of
modules is GPL-only. Linking this package into an application does not discharge those obligations.

Qt modules this binding was generated against: ${qlibs_human:-see qtd-build.txt}
Generator revision: $GENREV (packaged at $PKGREV)
EOF

# THE LINK LINE IS THE PLATFORM'S. `-lname` and `--start-group` are GNU ld's; lld-link answers
#     could not open 'binding_ldc2.lib': no such file or directory
# for each of them, and `stdc++` does not exist on Windows at all. The archives are copied into
# lib/ under their POSIX names, so on Windows the package names the FILES.
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*)
    # NO `-L` PREFIX HERE. dub adds the compiler's own pass-to-linker escape to every lflags entry,
    # so an entry is what the LINKER sees: `-L$PACKAGE_DIR/lib/libshims.a` reached link.exe as
    # `-LC:/…/libshims.a`, which it reads as a search PATH — the archive was never an input and the
    # link ended with 8130 unresolved externals. On POSIX the entries below are `-L<dir>`/`-l<name>`
    # for the same reason: that is ld's spelling, not the compiler's.
    # ...and where Qt's own import libraries are. On POSIX the linker's default search path finds
    # `-lQt6Widgets`; on Windows nothing does, so the directory is named. It is Qt's prefix, not the
    # checkout — the package is already tied to that exact release, and says so in qtd-build.txt.
    qtpath=${qtlibdir:+\"/LIBPATH:$qtlibdir\", }
    lf_ldc="${qtpath}\"\$PACKAGE_DIR/lib/libbinding_ldc2.a\", \"\$PACKAGE_DIR/lib/libshims.a\""
    lf_dmd="${qtpath}\"\$PACKAGE_DIR/lib/libbinding_dmd.a\", \"\$PACKAGE_DIR/lib/libshims.a\""
    cxxlib=""   # the MSVC runtime is the compiler's default; there is no libstdc++ to name
    ;;
  *)
    lf_ldc='"-L$PACKAGE_DIR/lib", "--start-group", "-lbinding_ldc2", "-lshims", "--end-group"'
    lf_dmd='"-L$PACKAGE_DIR/lib", "--start-group", "-lbinding_dmd", "-lshims", "--end-group"'
    cxxlib='"stdc++"'
    ;;
esac

cat > "$PREFIX/dub.json" <<EOF
{
  "name": "$PKG",
  "license": "BSL-1.0",
  "description": "Qt binding for D, generated by qt-dlang-gen against Qt $QTVER (generator $GENREV). Not hand-written; regenerate rather than patch.",
  "copyright": "Copyright (c) 2026 Marcelo A Caetano",
  "targetType": "sourceLibrary",
  "importPaths": ["source"],
  "lflags-ldc": [${lf_ldc}],
  "lflags-dmd": [${lf_dmd}],
  "libs": [${qlibs%, }${cxxlib:+, }${cxxlib}]
}
EOF
# THE CLOSED SET. Written LAST, because it describes everything else, and it lists every file the
# package contains with its size and SHA-256 — the manifest itself excepted, since it cannot state
# its own digest.
#
# Round 16 #2: the gate inspected the files it knew how to look for, so anything ELSE was invisible.
# Copying `libshims.a` to `lib/libanything.a` produced a package that the gate called clean while
# carrying an opaque, undeclared binary — which could be proprietary, GPL, or simply stale, and the
# verdict would not change. A gate that examines named categories can only ever be as complete as
# the list of categories; a closed manifest inverts that, and an unlisted file is a failure by
# construction rather than by recognition.
( cd "$PREFIX" && find . -type f ! -name MANIFEST.sha256 | sed 's|^\./||' | LC_ALL=C sort |
  while IFS= read -r f; do
      printf '%s\t%s\t%s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(wc -c < "$f" | tr -d ' ')" "$f"
  done ) > "$PREFIX/MANIFEST.sha256"

echo "install OK: $PKG -> $PREFIX ($(du -sh "$PREFIX" | cut -f1)) — Qt $QTVER, generator $GENREV, packaged at $PKGREV, $(wc -l < "$PREFIX/MANIFEST.sha256") file(s) manifested"
