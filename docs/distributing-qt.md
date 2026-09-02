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

## `qtd-deploy`: the inventory, and a tree that resolves

The checklist below ends with *"every bundled plugin, translation, font and helper binary is in the
notice inventory"*, and that list is not something to assemble by hand. `tools/deploy/` builds
`qtd-deploy`, which produces it by reading rather than guessing:

```
qtd-deploy map    app                          # the manifest, as TSV (or --json)
qtd-deploy bundle app --out dist               # ...and a tree laid out so it runs
```

- **Libraries** come out of the binary itself — `PT_DYNAMIC` on ELF, the import and delay-load
  directories on PE — so the answer does not require running the program and a Windows tree can be
  mapped from Linux. `ldd` can do neither.
- **Plugins** cannot come from the binary, because nothing links them: an application without
  `libqxcb.so` dies with *no Qt platform plugin could be initialized*, and no linker recorded the
  dependency. Qt installs a machine-readable description of which plugins belong to which module
  (`lib/cmake/Qt6Gui/Qt6QXcbIntegrationPluginTargets-*.cmake`, and the Qt 5 spelling of the same
  thing), so the tool reads *that*, for the modules the binary actually links. A table written into
  the tool would be a table about one Qt installation.
- **QML modules** come from the imports in your `.qml` sources (`--qml`), and then from three more
  places, each of which was found by a bundle that failed without it:
  - the module's own `qmldir`, including the `optional import X auto` and `default import X auto`
    forms — reading only `depends` and `import` missed every Qt Quick Controls style;
  - the imports written inside **Qt's own** QML files, because `QtQuick.Controls.impl` and
    `QtQuick.Templates` appear in no `qmldir` at all;
  - and again for plugins, because a QML module's plugin brings Qt modules with it
    (`libqtquickcontrols2plugin.so` brings Qt6QuickTemplates2), and those modules have plugins of
    their own. The collection repeats until the answer stops changing.

  **Every declared Controls style ships**, and `--qml-style` narrows it. That is deliberate and it
  is the one place this tool is inclusive by default: the style is chosen at run time by
  `QQuickStyle`, from `QT_QUICK_CONTROLS_STYLE` or a `qtquickcontrols2.conf` compiled into the
  plugin as a Qt resource — neither readable from the module directory. On the machine this was
  written on, `QtQuick/Controls/qmldir` says `default import QtQuick.Controls.Basic` and the style
  actually loaded is **Fusion**. A bundle carrying the qmldir's answer started, loaded no root
  object, and printed nothing at all. The five extra styles are about 7 MB against a 150 MB bundle.
- **Which libraries not to carry** is the one judgement call, and it lives in
  `tools/deploy/system-libs.txt` rather than in the code: glibc, the compiler runtimes, and the
  graphics and windowing stack belong to the machine, and a bundled copy of any of them is how a
  bundle breaks on a computer that is not the build machine.

The layout is measured, not imposed. Qt's own libraries carry `RUNPATH=$ORIGIN` and its plugins
carry `RUNPATH=$ORIGIN/../../../`; they already know how to find each other, so `bundle` reproduces
the *distance* between `lib/` and `plugins/` that the installed prefix has, and none of them needs
editing. On PE there is no run path at all and DLLs are looked for beside the executable, so there
the libraries go into the executable's directory instead — the choice follows the binary format,
not the machine running the tool.

What remains is the part everyone gets wrong. Distribution libraries ship **no run path at all** —
in a bundle of this repository's own `hello`, 103 of 118 — and `DT_RUNPATH` applies only to the
object that carries it, so the search for `libfreetype.so.6` made on behalf of `libfontconfig.so.1`
consults nothing and reaches the system copy. `DT_RPATH` on the **executable** is inherited by
everything loaded beneath it and covers all of them at once. So link your application with

```
-L-rpath='$ORIGIN/../lib' -L--disable-new-dtags
```

and `qtd-deploy` will report it if you did not. What it rewrites is the case `auditwheel` exists
for: a third-party library whose run path names a directory on the machine it was built on. Those
are shortened to `$ORIGIN` in place — an absolute build path is never shorter, so it always fits.
It will not rewrite what it cannot: a `.dynstr` entry cannot grow, and a tool that silently
declined would ship a bundle that resolves here and nowhere else.

`deploy-bundle-{ldc2,dmd}` and `deploy-qml-{ldc2,dmd}` are the checks, and they assert the thing
that matters rather than that files were copied: the bundled application is started from elsewhere
with the environment cleared, and `LD_DEBUG=libs` is read back to confirm that **no** library
outside the policy came from the system and that the platform plugin came out of the bundle. The
QML pair loads a Qt Quick Controls document, which is the case that fails when a style is missing —
and fails silently, which is why the assertion is on the root object and not on the exit status.

On Windows the proof is the one that platform allows: the bundled executable is run with the Qt
directories taken out of `PATH`, so a missing DLL or plugin has nothing to fall back to.

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
