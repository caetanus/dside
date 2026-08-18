<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# Third-party material

What of this repository is not ours, stated as precisely as the repository allows. Written because
choosing a licence for the project is impossible without it, and because two of the three answers
below were not recorded anywhere before.

**This is an inventory, not legal advice.** It says what is here and what the upstream files
themselves declare. What that permits is a question for whoever decides the licence.

## Read at build time, never distributed

Neither of these is in the repository. They are inputs the build reads from a machine that already
has them, so nothing of them is copied, committed or shipped.

| what | where it is read from | what reads it |
|---|---|---|
| Qt's Quick Controls QML — 329 documents across five styles | the installed Qt (`qtInstallQml()`, e.g. `/usr/lib/qt6/qml/QtQuick/Controls/…`) | `qmltc-o3-gate-*`, `qmltc-optlevels-controls-*` |
| PySide's `libsample` conformance corpus | a clone of `pyside-setup` at `../pyside-setup`, pinned to 6.8.0 by CI | `sample_*` (58 targets) |

Checked, not assumed: of the 176 `.qml` files tracked by git, **none** carries a Qt copyright
header, and no PySide or libsample source is tracked. `tests/libsample/` holds 29 D files, which are
our own test drivers for that corpus and not copies of it. A machine without either input builds
fine — `libsampleTargets()` returns nothing, and the Controls gates say so out loud rather than
going quietly green over an absent corpus.

## Vendored, and it declares its licence

**`tests/qmltc/cpptypes/` — 42 files, and NOT one population.** Counted file by file on 2026-08-14,
because the previous version of this entry called all 42 verbatim Qt copies and that was false in a
direction worth naming: it attributed twenty-two files written in this repository to The Qt Company,
and licensed our own work as GPL-3.0-only.

| what | how many | terms |
|---|---:|---|
| upstream C++ types from `qtdeclarative/tests/auto/qml/qmltc/QmltcTests/cpptypes/` | 19 | `LicenseRef-Qt-Commercial OR GPL-3.0-only`, as each file's own header states (10 dated 2021, 7 dated 2022, 1 dated 2024, 1 with the expression and no copyright line) |
| `C*.qml` and `C*.set` — this project's fixtures, written here to drive those types | 22 | BSL-1.0, stated in each file |
| `singletontype.cpp` — three lines implementing a class Qt's header declares | 1 | **BSL-1.0, written here** on 2026-08-14. It carried `NOASSERTION` until then; the qtdeclarative sources were not available to hash against, so round 17's second sanctioned route was taken — an implementation of our own, with the reasoning in the file itself. The body is the only one the declaration admits: a constructor forwarding its parent to QObject |

The 19 upstream files are **GPL-3.0-only**, not LGPL, and `LICENSES/GPL-3.0-only.txt` now travels
with the repository — an SPDX identifier points at a licence, it is not a copy of one, and GPLv3 §4
asks for the copy.

**They do not reach the product.** Measured: `tests/install.sh` packages `source/` — the generated
QtWidgets binding — and `lib/` — its two archives. The binding built from these headers is a
separate one (`spec_cxx_corpustypes.json`, `libcorpustypes.a`) and **no target installs it**; it is
linked only into test binaries, which are never distributed. So "we only used it to test" is true of
the PRODUCT and not of the REPOSITORY: the 42 files are in the tree, and distributing the tree
distributes them. That is the whole of the exposure, and it is narrower than "it contaminates the
binding" — but it is not nothing, and it is not a question this document can answer.

They were vendored so the build stays hermetic — the differential runs
against types we did not write — and the trade that bought is exactly this entry. The upstream
revision they were taken at is **not recorded**.

## Vendored, and its provenance is NOT reconstructible from this repository

**`tests/uic/corpus/` — 60 `.ui` files.** The documentation states they are Qt's and that we wrote
none of them, and that is all that is recorded. The files carry no licence header (a `.ui` is XML
with an empty `<comment>` element), no upstream revision is noted, and there is no README beside
them.

The filenames span at least two different parts of Qt, which do not share a licence:
`addtorrentform.ui` and `bookwindow.ui` look like Qt **examples**, while `qtresourceeditordialog.ui`
is a file of Qt **Designer's own source** (`qttools`). Searched for on this machine, **0 of the 60**
are present in the installed Qt, so provenance cannot be settled locally — it needs the upstream
trees.

Until each file is attributed, this corpus cannot be described accurately, and a licence for the
project cannot honestly account for it.

## The remedy that exists, and its cost

Both vendored corpora could be **fetched instead of committed**, which is the pattern the project
already uses for `libsample`: the CI clones it, and the targets vanish loudly when it is not there.
That would remove all 102 third-party files from what this repository distributes.

A third option exists for the C++ types and is worth naming, because it is cheaper than fetching:
**write equivalents ourselves.** The reggaefile describes them as "ordinary Q_OBJECT + QML_ELEMENT +
Q_PROPERTY classes", and the shapes they exercise — grouped, attached, singleton, a private
property, extension types — are ones we could write from scratch. What that costs is the property
the corpus was chosen for: they are types WE DID NOT WRITE, so the compiler cannot have been tailored
to them. Replacing them keeps the coverage and gives up the independence.

Fetching is not free either. `tests/qmltc/cpptypes/` feeds a whole differential family — moc →
qmltyperegistrar → `.qmltypes`, then a generated binding over those headers — and fetching it means
the build needs `qtdeclarative`'s **source**, not just an installed Qt, on any machine that wants
that coverage. The `.ui` corpus NO LONGER has that problem: on 2026-08-14 all 60 files were matched byte-for-byte
against `tests/auto/uic/baseline/` in `github.com:qt/qt` at `0a2f2382541424726168804be2c90b91381608c6`
(v4.8.7-3), and each carries a `.license` sidecar recording repository, revision, path, SHA-256 and
the date of the check. Fetching them at test time instead of vendoring them remains possible and is
now a convenience question rather than a licensing one.

The expected-fail this section used to cite (`no-licence-so-nothing-is-publishable`) was removed when
`license-publishable` went green; the entry that is live today is
`qt5-parity-release-not-audited`.
