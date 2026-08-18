<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# lupdate-d

A **D-aware `lupdate`** (a PySide-style side-car): it extracts translatable strings and
produces a Qt `.ts`. The division of labour:

- **D sources (`.d`)** — parsed with **libdparse** (an AST walk, not regex) to find
  `tr("…")`, `obj.tr("…", "disambiguation")`, and `[QCoreApplication.]translate("Ctx", "…")`.
  Qt's own `lupdate` can't read D — this is the whole reason the tool exists.
- **`.ui` / `.qml`** — delegated to **Qt's normal `lupdate`** (it owns those; the tricky
  bits live there).
- The per-source `.ts` files are merged with Qt's **`lconvert`** (dedup + keep existing
  translations). Compile to `.qm` with Qt's **`lrelease`** as usual.

```sh
dub build
./lupdate-d src/app.d ui/main.ui qml/View.qml -ts i18n/app.ts   # D=ours, ui/qml=Qt's, merged
lrelease i18n/app.ts -qm i18n/app.qm
```

Context for a bare `tr()` is the enclosing class/struct; `translate()`'s first argument is
the explicit context.
