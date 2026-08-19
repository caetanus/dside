<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# Branding

Two marks live here: **DSide**, the Qt bindings for D, and **xiboca**, the wrapper
generator that produces them.

| File | What it is |
|---|---|
| `dside-logo.svg` | D's mark on a grey field joined to Qt's badge carrying `side` |
| `dside-icon.svg` | the square icon — the word cannot survive at 16 px, so it is dropped |
| `xiboca-logo.svg` | the still, sealed like a bottle label, with the wordmark |
| `xiboca-icon.svg` | the seal alone |
| `*.png`, `favicon.ico`, `xiboca-favicon.ico` | renderings, produced by `render.sh` |
| `render.sh` | regenerates every raster from the four SVGs |

The SVGs are the source. If you change one, run `./render.sh` in the same commit —
a PNG that is a stale rendering of an older drawing is exactly the kind of
same-name-different-bytes problem the licensing gates exist to catch.

## The design, and why it is the way it is

The two identities are the D language's mark and Qt's badge. An early attempt kept
D's red next to Qt's green, and red beside green at equal area and equal
saturation is the one pairing that visibly vibrates. Three things fixed it:

- **the red field is desaturated to `#3A4048`**, so the only colour in the mark is
  Qt's green;
- **the green is stepped down to `#57BC64`** from Qt's `#41CD52`, calm enough to
  sit beside a large neutral without shouting;
- **the cut corner falls on the junction**, not on the outer edge. That is Qt's
  own chamfer, and putting it where the two blocks meet makes them interlock — the
  D and both of its moons then cross onto the green, and the result reads as one
  object rather than two logos placed side by side.

The word is outlined from Noto Sans Bold rather than left as `<text>`, so it
renders identically on a machine that does not have the font.

## xiboca

Xiboquinha is a Brazilian drink — cachaça with ginger and honey. The mark is the
**still** that makes the cachaça, because a wrapper generator does what a still
does: raw material goes in, something distilled comes out, and the drop leaving
the swan neck is the output.

It deliberately borrows **no shape from Qt**. A tool should not wear the badge of
the library it targets, so the two marks belong to one family through flat
drawing and a shared neutral (`#3C4148`) rather than through geometry. Side by
side they read as siblings without either pretending to be the other.

The seal is the primary form, and that is a measurement rather than a taste: at
26 px the still on its own loses its swan neck and becomes a blob, while the seal
survives. That is why the icon is the seal.

Three earlier candidates were drawn and rejected — a shot glass (says *drink*,
not *tool*), a ginger root (at 60 px it is a potato), and a honey drop (could be
oil, water or blood). The still is the only one that says what the tool does.

## Provenance and marks

The planet, both moons and the D glyph are upstream paths used verbatim from
`images/dlogo.svg` in `github.com/dlang/dlang.org` at revision
`5da9a709c2905693c148e258740d0484587d0a3d`, sha256
`e96ad4c5…4b21fbc`, retrieved 2026-08-18, under **BSL-1.0** per that
repository's `LICENSE.txt`. Only the field colour was changed. The full record is
in the header of `dside-logo.svg`.

The upstream file names its own parts in comments — `planet`, `bigger moon`,
`smaller moon`. The moons are Phobos and Deimos, the two moons of Mars, which is
where D's standard library gets its name.

**A licence is not a trademark grant.** BSL-1.0 permits copying this artwork. It
says nothing about using the D Language Foundation's or The Qt Company's marks to
identify a product, which is a separate regime with its own rules. Neither
organisation endorses this project. Before the first public release this should be
reviewed together with the rest of the licensing work — see `docs/licensing.md`.
