#!/bin/sh
# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# Regenerates every raster in this directory from the two SVGs. Run it after
# touching either SVG, so the PNGs in the tree are never a stale rendering of an
# older drawing — the same reason the rest of this repository compares artifacts
# against the graph that produced them instead of trusting their names.
#
# Needs rsvg-convert (librsvg) and magick (ImageMagick).
set -eu
cd "$(dirname "$0")"

command -v rsvg-convert >/dev/null || { echo "render.sh: rsvg-convert not found" >&2; exit 1; }
command -v magick       >/dev/null || { echo "render.sh: magick not found" >&2; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

rsvg-convert -w 992  dside-logo.svg        -o dside-logo@2x.png
rsvg-convert -w 1096 xiboca-logo.svg       -o xiboca-logo@2x.png
rsvg-convert -w 512 -h 512 dside-icon.svg  -o dside-icon-512.png
rsvg-convert -w 256 -h 256 dside-icon.svg  -o dside-icon-256.png
rsvg-convert -w 512 -h 512 xiboca-icon.svg -o xiboca-icon-512.png
rsvg-convert -w 256 -h 256 xiboca-icon.svg -o xiboca-icon-256.png

for s in 16 32 48; do
    rsvg-convert -w "$s" -h "$s" dside-icon.svg  -o "$tmp/d$s.png"
    rsvg-convert -w "$s" -h "$s" xiboca-icon.svg -o "$tmp/x$s.png"
done
magick "$tmp/d16.png" "$tmp/d32.png" "$tmp/d48.png" favicon.ico
magick "$tmp/x16.png" "$tmp/x32.png" "$tmp/x48.png" xiboca-favicon.ico

echo "render.sh OK: 4 PNG pairs and 2 icons"
