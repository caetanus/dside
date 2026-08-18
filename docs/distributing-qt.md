<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# Distributing an application built with these bindings

This is the document `LICENSE` sends you to. It is written for the person who has an application
working and now has to ship it, and it is about **Qt's obligations**, not this project's — those are
the substantial part of the work, and nothing here changes them.

It is not legal advice. It is an operational description of what shipping Qt requires, written so
that you know which questions you have, and it is deliberately conservative where the answer depends
on facts only you have.

## What this project's licence does and does not do

The generator, the runtime, the tools, the generated D sources and the generated C++ shims are
BSL-1.0. You may ship them in closed-source software, you owe no source, and the generated output
carries a notice saying so.

That grant covers **our text only**. It says nothing about Qt, and a generated declaration naming
`QWidget` conveys no right to Qt whatsoever. When you link, Qt's terms attach to your program on
their own, and they are what the rest of this document is about.

## The dividing line: how you link Qt

Everything below assumes the **open-source** Qt distribution. If you hold a commercial Qt licence,
its terms replace all of this and you should follow the agreement you signed.

The supported model for open-source Qt here is **dynamic linking against unmodified Qt libraries**,
which is what LGPLv3 is built to permit. It is the only model this project's build produces, and it
is what makes a proprietary application possible at all.

**Static linking of LGPL Qt is a different world.** LGPLv3 still allows it, but only if you supply
what a user needs to relink your application against a modified Qt — object files or an equivalent
mechanism. If you are not prepared to ship relinkable artifacts, do not link Qt statically.

## What LGPLv3 requires of you, concretely

1. **Say that you use Qt, and under which licence.** A visible notice — an About box, a
   `THIRD-PARTY` file next to the binary, a licences screen. Name Qt, name LGPLv3, and name the
   version you shipped.
2. **Supply the LGPLv3 and GPLv3 texts.** LGPLv3 is written as a set of additional permissions on
   top of GPLv3, so shipping only one of the two is incomplete. Put both next to the binary.
3. **Make the Qt source available.** You must be able to give the recipient the *complete
   corresponding source* for the Qt version you shipped, including any patches you applied. In
   practice: publish the exact Qt source tarball you built from (or the distribution package
   version, if you ship an unmodified system Qt), keep it available for as long as you distribute
   the application, and say in your notice where it is.
4. **Keep Qt replaceable.** The user must be able to substitute a modified Qt. With dynamic linking
   this is satisfied by shipping Qt as separate shared libraries and not defeating their
   replacement — do not bake them into the executable, do not verify their signature and refuse to
   run, do not resolve them from a path the user cannot write.
5. **Do not restrict what LGPL grants.** Your EULA cannot forbid reverse engineering *of the Qt
   parts* for the purpose of modification and relinking. This is the clause most commonly violated
   by pasting a stock EULA.

If you modified Qt itself — a patched build, a backported fix, a changed default — those changes are
part of the corresponding source, and you must publish them.

## Modules you may not ship in a proprietary application

A defined set of Qt modules is **GPL-only** for open-source users. Linking one makes your whole
program GPLv3: there is no LGPL fallback for them. This project refuses them in a product build
(`license-no-gpl-product`), but that gate is a floor and the authoritative list is Qt's own
licensing page and the SBOM for your exact Qt version.

**Check the list for your Qt version, every minor release.** Modules move between licences, new
GPL-only modules appear, and a list written for 6.9 is not a statement about 6.11.

## Deployment, in the shape it actually takes

- **Linux.** Shipping the system Qt is the simplest correct case: you distribute no Qt binary at
  all, and your obligation reduces to notices plus pointing at the distribution's Qt source
  package. If you bundle Qt instead, you ship the libraries and you owe the corresponding source.
- **Windows.** `windeployqt` copies the Qt DLLs and plugins next to your `.exe`. Everything it
  copies is Qt under Qt's terms — the DLLs, the `platforms/`, `styles/`, `imageformats/` plugins,
  the translations. That is a Qt distribution and carries every obligation above. Note also that
  **plugins are loaded dynamically but are still Qt**: shipping them is shipping Qt.
- **macOS.** Framework bundles inside the `.app` are the same case as Windows DLLs.

Whatever you bundle, the rule is the same: if a Qt binary leaves your machine, you distributed Qt.

## Components with obligations beyond Qt's own

- **Qt WebEngine** embeds Chromium and pulls in a large third-party stack with its own licences
  (BSD, MPL, ffmpeg's LGPL/GPL configuration, and more). If you ship WebEngine, its licence
  inventory is part of your notices, and the ffmpeg configuration in particular decides whether you
  are shipping GPL code. Read Qt WebEngine's own third-party attribution list; it is not optional
  and it is not short.
- **Fonts, icons and translations** shipped with Qt carry their own terms.
- **Qt Charts, Qt Data Visualization and friends** have changed licence between major versions.
  Check the version you ship rather than what you remember.

## A checklist you can actually run before a release

- [ ] Qt is linked dynamically, and the libraries ship as separate replaceable files.
- [ ] Notices name Qt, the exact version, and LGPLv3.
- [ ] LGPLv3 **and** GPLv3 texts ship with the application.
- [ ] The corresponding Qt source (plus your patches, if any) is published and reachable from the
      notice, and will stay reachable.
- [ ] No GPL-only Qt module is linked. Verified against Qt's licensing page for **this** version.
- [ ] The EULA does not forbid reverse engineering for modification and relinking of the Qt parts.
- [ ] Every bundled plugin, translation, font and helper binary is in the notice inventory.
- [ ] If WebEngine is included, its third-party attribution list is included too.

## Where the authority is

Qt's own licensing documentation and the SBOM published for your exact release are the source of
truth. This project tracks a floor, in `docs/licensing-plan.md`, and states plainly that the floor
can go out of date — a list of module names is not a licence matrix, and this document is not a
substitute for reading Qt's.
