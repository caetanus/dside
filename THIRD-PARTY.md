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

**`tests/qmltc/cpptypes/` — 42 files.** Verbatim copies of the app-defined C++ QML types from Qt's
own `qmltc` test corpus (`qtdeclarative/tests/auto/qml/qmltc/QmltcTests/cpptypes/`), as that
directory's own README says. Every header states:

```
// Copyright (C) 2021 The Qt Company Ltd.
// SPDX-License-Identifier: LicenseRef-Qt-Commercial OR GPL-3.0-only
```

**GPL-3.0-only**, not LGPL. They were vendored so the build stays hermetic — the differential runs
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

It is not free. `tests/qmltc/cpptypes/` feeds a whole differential family — moc →
qmltyperegistrar → `.qmltypes`, then a generated binding over those headers — and fetching it means
the build needs `qtdeclarative`'s **source**, not just an installed Qt, on any machine that wants
that coverage. The `.ui` corpus has the same shape and the additional problem that we would first
have to know which upstream tree each file comes from.

Tracked as `no-licence-so-nothing-is-publishable` in `tests/expected-fails.json`.
