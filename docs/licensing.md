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

`THIRD-PARTY.md` is the inventory and `REUSE.toml` is the machine-readable form. Two things in it
are worth knowing before you clone:

- `tests/qmltc/cpptypes/` — 42 files copied verbatim from Qt's own qmltc test corpus,
  **GPL-3.0-only**. Used by tests, excluded from every installed artifact.
- `tests/uic/corpus/` — 60 `.ui` files, of which **47 have no recorded provenance at all**. They are
  marked `NOASSERTION`, which is not a licence: it is the honest statement that their terms are not
  established. Removing or replacing them is Phase 1 of the licensing plan and is a precondition for
  publication.

Neither reaches an installed package. That is checked, not asserted.

## Status

`docs/licensing-plan.md` is the full plan, its phases and its release checklist. As of 2026-08-13 the
decision is adopted and the metadata is in place; publication is still blocked by the unprovenanced
`.ui` corpus, and the first release has not been reviewed by counsel. This document describes the
policy, not a completed compliance review.
