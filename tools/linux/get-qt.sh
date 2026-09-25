#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# FETCH A Qt 6 RELEASE FOR LINUX FROM Qt'S OWN REPOSITORY — the Linux twin of tools/win/get-qt.ps1.
#
#   tools/linux/get-qt.sh [--version 6.11.1] [--dest "$HOME/Qt"] [--skip-webengine]
#
# WHY NOT THE DISTRIBUTION'S Qt. The CI runner is Ubuntu 24.04, whose Qt 6 is 6.4.2, and this
# project's matrix is 6.11 + 5.15. On 6.4 the build fails in ways that say nothing about the code
# under test: moc 6.4 cannot parse `Q_PROPERTY(... BINDABLE b READ default WRITE default)` and the
# quick binding refuses to generate because a private header it binds is not there. Run 34654242442
# came back 647 pass / 698 fail — 641 of the failures qmltc — against a local 1199 / 0. The runner
# was testing a Qt nobody had claimed to support.
#
# WHY NOT aqtinstall. Its newest release asks for a repository layout Qt no longer publishes (see
# the Windows script). The repository is a plain HTTP index, so this reads the same Updates.xml,
# VERIFIES THE PUBLISHED sha256 of every archive, and unpacks. It installs exactly the module set
# this build names (grep `Qt6[A-Z]` in reggaefile.d and generator/spec*.json) and nothing else.
#
# THE .pc FILES NAME THE MACHINE THE ARCHIVES WERE BUILT ON — `prefix=/home/qt/work/install` —
# and this build finds Qt through pkg-config. Every `prefix=` is rewritten to the directory the tree
# actually landed in; without that, pkg-config answers with paths that do not exist and every
# compile fails with a missing QtCore header.
set -euo pipefail

version=6.11.1
dest="$HOME/Qt"
webengine=1
base=https://download.qt.io/online/qtsdkrepository/linux_x64
# Separate addons this build references; everything else it uses (Core, Gui, Widgets, Network,
# OpenGL, Qml, Quick, QuickControls2, QuickLayouts, QmlCompiler, UiTools) is in the base package.
modules=(qtwebchannel qtpositioning qtshadertools)

while [ $# -gt 0 ]; do
    case "$1" in
        --version) version=$2; shift 2 ;;
        --dest) dest=$2; shift 2 ;;
        --skip-webengine) webengine=0; shift ;;
        *) echo "get-qt: unknown argument $1" >&2; exit 2 ;;
    esac
done

case "$version" in 6.*) ;; *) echo "get-qt: Qt 6 only (Qt 5 comes from the distribution)" >&2; exit 2 ;; esac
v=${version//./}                    # 6.11.1 -> 6111
arch=linux_gcc_64
prefix="$dest/$version/gcc_64"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$prefix"

# py7zr, as on Windows, and NOT 7z: qtbase ships `libQt6DBus.so -> libQt6DBus.so.6 ->
# libQt6DBus.so.6.11.1`, and 7-Zip 26 refuses the first link ("Dangerous link via another link
# was ignored"), leaving a ZERO-BYTE libQt6DBus.so — the linker then fails on a file that exists.
# `-snld` did not change that (measured). py7zr restores the chain.
python3 -m py7zr --help >/dev/null 2>&1 || { echo "get-qt: need python3 -m py7zr (pip install py7zr)" >&2; exit 1; }
unpack() { python3 -m py7zr x "$1" "$2"; }

# One package from one repository: its archives, each verified against the published sha256
# before it is unpacked. A mismatch removes the file and stops — never unpacks it.
get_package() {   # <repository url> <package name>
    local repo=$1 name=$2
    python3 - "$repo/Updates.xml" "$name" > "$tmp/list" <<'EOF'
import sys, urllib.request, xml.etree.ElementTree as ET
url, want = sys.argv[1], sys.argv[2]
root = ET.fromstring(urllib.request.urlopen(url).read())
for p in root.iter("PackageUpdate"):
    if p.findtext("Name") != want:
        continue
    ver = p.findtext("Version")
    for a in (p.findtext("DownloadableArchives") or "").split(","):
        if a.strip():
            print(ver + a.strip())
    sys.exit(0)
sys.exit(f"get-qt: {want} is not in {url}")
EOF
    while read -r file; do
        local url="$repo/$name/$file" out="$tmp/$file"
        echo "  fetch $file"
        curl -fsSL -o "$out" "$url"
        local want have
        want=$(curl -fsSL "$url.sha256" | awk '{print $1}')
        have=$(sha256sum "$out" | awk '{print $1}')
        if [ "$want" != "$have" ]; then
            rm -f "$out"
            echo "get-qt: sha256 mismatch for $file (published $want, got $have)" >&2
            exit 1
        fi
        # The ICU archive is the one that carries NO layout: its libicu*.so* sit at the archive's
        # root, and Qt's installer is what files them under lib/. Unpacked like the others they
        # landed beside bin/, and every Qt tool died on `libicui18n.so.73: cannot open`.
        case "$file" in *icu-*) unpack "$out" "$prefix/lib" ;; *) unpack "$out" "$prefix" ;; esac
        rm -f "$out"
    done < "$tmp/list"
}

# Linux's Qt 6 desktop repository is NOT split by architecture the way Windows' is:
# `qt6_6111/qt6_6111`, probed (the `_linux_gcc_64` spelling is a 404).
desktop="$base/desktop/qt6_$v/qt6_$v"
echo "repository: $desktop"
get_package "$desktop" "qt.qt6.$v.$arch"
for m in "${modules[@]}"; do get_package "$desktop" "qt.qt6.$v.addons.$m.$arch"; done

if [ "$webengine" = 1 ]; then
    # A separate repository with its own layout: extensions/qtwebengine/<v>/x86_64 (probed; the
    # linux_gcc_64 spelling is a 404 here too).
    ext="$base/extensions/qtwebengine/$v/x86_64"
    echo "repository: $ext"
    get_package "$ext" "extensions.qtwebengine.$v.$arch"
fi

test -f "$prefix/include/QtCore/qconfig.h" || { echo "get-qt: unpacked, but $prefix has no include/QtCore/qconfig.h" >&2; exit 1; }

n=0
for pc in "$prefix"/lib/pkgconfig/*.pc; do
    sed -i "s|^prefix=.*|prefix=$prefix|" "$pc"
    n=$((n + 1))
done
echo "get-qt: rewrote prefix= in $n .pc files"
echo "get-qt: $version is at $prefix"
echo "  PKG_CONFIG_PATH=$prefix/lib/pkgconfig  PATH=$prefix/bin:\$PATH  LD_LIBRARY_PATH=$prefix/lib"
