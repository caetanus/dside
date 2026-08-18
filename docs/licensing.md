<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# Licensing

The short version, for someone deciding whether to use this.

**The project is BSL-1.0.** The generator, the runtime, the tools, the generated D bindings and the
generated C++ shims — all of it, and you may use it in closed-source software. The full text is in
`LICENSES/BSL-1.0.txt`; `LICENSE` states the scope.

**Qt is not.** This project produces bindings *to* Qt. Qt is a separate work under its own terms, and
nothing here changes them. If you ship an application built with these bindings, the Qt obligations
are yours, and they are the substantial part of the compliance work. `docs/distributing-qt.md` is
written for that job.

## What the generated-output grant means

Every file the generator emits carries this, and it says three things on purpose:

```
// SPDX-License-Identifier: BSL-1.0
//
// The generator-authored portions of this file — its structure, boilerplate and templates — are
// offered under BSL-1.0. That grant does NOT change the licence or the ownership of the input this
// was generated from, and it grants no rights in the Qt APIs named here.
//
// provenance: generator=<rev> qt=<version> modules=<list> spec=<file>
```

- **You keep your input.** Your specs, headers, QML and `.ui` files are yours; running them through
  this generator does not give the project any claim on them, and does not license them to anyone.
- **The grant is over our text.** The boilerplate, the emitted structure, the templates — the parts
  we wrote. That is what BSL-1.0 covers in the output.
- **It grants nothing in third-party APIs.** A generated declaration naming `QWidget` conveys no
  right to Qt. Only Qt's own licence does that.
- **It is not a safety claim.** Generating from input you may not redistribute produces output you
  may not redistribute. The generator cannot know, and does not check.

The `provenance:` line records what produced the file: generator revision, Qt version, module list
and spec. It is in the file rather than only in a side manifest because a file travels alone — into
bug reports, into pasted questions, into someone else's vendor directory.

## Qt modules: what is allowed

The supported open-source model links Qt **dynamically**, under each module's own terms — normally
LGPLv3. A defined set of Qt modules is **GPL-only** for open-source users, and one of them (Qt Qml
Compiler) is genuinely used *by a test here*, to validate our generated `.qmltypes` against Qt's own
reader.

That test may exist. A shipped artifact that links it may not, and the boundary is enforced rather
than promised: `license-no-gpl-product` rejects a GPL-only module in a product spec, and inspects the
undefined symbols of every archive and the `DT_NEEDED` of every executable. Adding such a module to a
product spec is meant to fail the build with a licensing diagnostic, not with a link error later.

The denylist in `docs/licensing-plan.md` is a **floor**. Qt's own licensing page and SBOM for the
exact release are the source of truth, and every Qt minor has to be checked again.

## Third-party material in this repository

`THIRD-PARTY.md` is the inventory. The machine-readable form is the files themselves: each states
its own SPDX expression, or carries a `<name>.license` sidecar when its format cannot. Two things
are worth knowing before you clone:

- `tests/qmltc/cpptypes/` — 42 files, and **not one population**. Counted file by file: 19 are
  Qt's, under `LicenseRef-Qt-Commercial OR GPL-3.0-only` as their own headers state; 22 are `C*.qml`
  and `C*.set` fixtures written HERE to drive those types, under BSL-1.0; and
  `singletontype.cpp` is three lines written here against Qt's declaration. `LICENSES/GPL-3.0-only.txt`
  travels with the repository, because asserting a licence and not shipping its text is what GPLv3 §4
  forbids.
- `tests/uic/corpus/` — 60 `.ui` files, **provenance established 2026-08-14**: every one is
  byte-identical to `tests/auto/uic/baseline/` in `github.com:qt/qt` at revision
  `0a2f2382541424726168804be2c90b91381608c6` (v4.8.7-3), and each carries a `.license` sidecar with
  the repository, revision, path, SHA-256 and the date the equality was checked. Their terms are the
  ones those files declare: `LicenseRef-Qt-Commercial OR LGPL-2.1-only OR LGPL-3.0-only OR
  GPL-3.0-only`, and all four texts are in `LICENSES/`.

There is **no `NOASSERTION` left in the tree**: `sh tests/license-coverage.sh --publish` passes, and
it is a mandatory gate rather than a documented aspiration. What still blocks a public release is
engineering — CI has never been green on a real runner — and the Qt5 parity archives are built with
a release the licence matrix does not record (`qt5-parity-release-not-audited` in
`tests/expected-fails.json`).

Neither reaches an installed package. That is checked, not asserted.

## Status

`docs/licensing-plan.md` is the full plan, its phases and its release checklist. As of **2026-08-17**
the decision is adopted, the metadata is in place, and `license-publishable` — the gate that answers
"could this tree be published?" — passes with zero files whose terms are unestablished. That is a
change of state from the 2026-08-13 wording this paragraph used to carry, which said publication was
blocked by the `.ui` corpus; that corpus now has per-file provenance.

What is NOT finished, stated so this section cannot drift into a clean bill of health again:

- the first release has not been reviewed by counsel;
- CI has never been green on a real runner, and the Qt release it uses is not one this project has
  audited;
- the Qt5 parity archives are built with 5.15.19 while the matrix records 5.15.17
  (`qt5-parity-release-not-audited`).

This document describes the policy and the gates that enforce it, not a completed compliance review.
