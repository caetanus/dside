<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# qt-dlang-gen

A **binding generator** for Qt in D. Hand-written D/Qt wrappers die because nobody
can track Qt's surface by hand across versions; a generator re-runs against new Qt
headers instead. The generated binding is **pure `extern(C++)` D** — modules mangle
straight to the Qt symbols, so there is no per-class C++ shim to compile and a class
you never `import` costs nothing (à la carte).

**Runs on Qt 5 and Qt 6** (5.15 and 6.11 in the test matrix) from day one — that dual
coverage is deliberate: the generator re-runs against either version's headers, and the
few genuine Qt-version differences (value-type ABI, and private-API shapes like
`QQmlPrivate::RegisterType`) are isolated behind single `QT_VERSION` seams, so a future
Qt 7 should be a small localized delta rather than a rewrite. The **runtime** features —
bindings, moc, uic, qrc, QML (`setContextProperty`, `qmlRegisterType`, moc lifetime), and
translation (`tr`) — are verified on **both** Qt 5 and Qt 6, on **both** ldc2 and dmd. Two
QML build-tool paths are Qt6-only for now: `qmlcachegen` AOT (the Qt5 loader format differs)
and `.qmltypes` validation (its reader, QtQmlCompiler, is Qt6-only) — the `.qmltypes`
generation itself is Qt-agnostic. Not every target is a full matrix cell either: the
manifest gates and `lupdate-check` are single-config.

> **Platform: Linux / POSIX is Tier 1.** The build orchestrates `clang++`/`ldc2`/`dmd`
> through reggae with POSIX shell (`flock`, `find`, globs). Windows/MSVC-x64 is a
> documented, not-yet-working roadmap — see `docs/windows-roadmap.md`.

## What it is (and isn't)

- **Is:** a code generator (`xiboca/` → `xiboca`) built on the libclang **C API**
  (stable, no `clang.cindex`), plus a small hand-written runtime (`runtime/`) and a
  reggae build that generates → compiles → links in one incremental graph.
- **Isn't:** a committed, hand-maintained wrapper. Generated output lands in a
  **gitignored `generated/`** dir, produced **on demand, never committed**.

The status of every directory is in the [matrix](#directory-status) below, and the
full feature list is in **`docs/FEATURES.md`** — the single source of truth for
capabilities. This README is the map, not the catalogue.

## Building

```sh
cd xiboca && dub build          # build the `xiboca` generator
cd .. && reggae -b binary . --reggaefile-import-path "$PWD/reggae"
./build                              # generate bindings + build & run the test matrix
./build widget_test-ldc2-qt6         # one target;  ./build --list to see them
```

`xiboca <spec.json>` emits `qt/<pkg>/*.d` (+ minimal `.cpp` trampolines) into
`generated/`. reggae compiles each `.d` per-module into an archive and lets the linker
select what each app references — no hand-rolled import closure. Every target is
verified on **ldc2 AND dmd**, **Qt5 AND Qt6** where applicable.
(The `:runtime` subpackage is a `sourceLibrary` — it is **not** built in isolation
(`dub build :runtime` errors); reggae compiles the runtime and its C++ companions.
reggae is the build of record, not dub.)

## Construction

**`new` is the only spelling.** Object types construct with `new QWidget(parent)`;
value types use a plain ctor or `make!T`. There is no `X_new(...)` factory anywhere in
the generated output — the flip to GC-wrapper mode is done, and the specs the build
uses (QtWidgets on Qt5 and Qt6, QML, Quick, Controls, and the uic/qrc harnesses that
sit on the widgets binding) all carry `"wrapper": true`.

Two specs still generate without the wrapper: the WebEngine link smoke test and the
`corpustypes` fixture. Neither emits an `X_new` either — raw mode means no GC holder,
not a different way to construct.

```d
auto w   = new QWidget(parent);      // GC wrapper owns a C++-heap object; Qt deletes it
auto col = QColor(0, 0, 128);        // value type — struct ctor
auto v   = make!QVariant();          // value type, no-arg (D forbids a struct this())
```

## Using it from your own project

One import path, two archives, and Qt's own libraries — as a dub package or by hand.
Both routes, the exact commands, and the Qt-mismatch check the package performs are in
the manual: **[Using DSide → Getting a build](docs/manual/dside/using-the-binding.rst)**.

Both are exercised on every build (`consumer-smoke-{ldc2,dmd}` and
`dub-consumer-{ldc2,dmd}`), from sources copied outside the checkout — so "it compiles
in-tree" cannot be mistaken for "somebody else can use it".

On licensing and distribution: the project is **BSL-1.0** (`LICENSE`, `docs/licensing.md`),
every tracked file states its own terms or carries a `.license` sidecar, and
`license-publishable` reports zero files with unestablished terms. What still blocks a
public push is engineering rather than licensing: CI has never been green on a real
runner, and the full matrix fails intermittently under parallelism (see
`matrix-intermittency-under-concurrency` in `tests/expected-fails.json`).


## Highlights (see `docs/FEATURES.md` for the full list)

- **Pure `extern(C++)`** codegen: value types (correct ABI incl. CoW), enums,
  containers (`QList`↔`T[]`, QHash/QMap), multiple inheritance, iterators→D ranges,
  correct **overridden-virtual dispatch** (incl. value returns).
- **GC lifetime layer** (`runtime/holder/`, wrapper mode): a nullable `_cpp` with
  identity map, parenting-pins, `destroyed()` invalidation — no dangling pointers.
- **CTFE tooling**: `uic` (`mixin(uiForm(import(".ui")))` → typed struct; matches
  QUiLoader on the full baseline corpus, 60/60, incl. `tr()`), `moc`
  (`@QObject`/`Signal`/`@Slot`/`@Property` via `QMetaObjectBuilder`), `qrc`.
- **Exception translation**: C++/Qt exceptions → D via a Lippincott + per-signature
  guard layer (gated).
- **`qmltc-d`**: a QML→D compiler with a fallback ladder — see below, and
  `docs/qmltc-d.md` (reference) / `docs/qmltc-d-vs-qmltc.md` (vs Qt's own `qmltc`).

## qmltc-d: QML compiled to D

`qmltc-d` turns a `.qml` document into a D class. A binding stops being a JavaScript
expression the engine re-evaluates and becomes a D method plus a signal connection — Qt's
own Basic Button,

```qml
implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                        implicitContentWidth + leftPadding + rightPadding)
```

comes out as a slot the meta-object calls when any operand changes.

It is judged against the engine on two axes at once: a byte-identical rendered frame **and**
every property of every named object. And it does not have to compile everything — `-O0`
through `-O3` are degrees of *certainty*, not of speed, so a document the compiler cannot
prove it handles is handed to the engine rather than emitted half-translated.

Measured against Qt's own shipped Controls, and against this project's own application QML:

| corpus | documents | compiled | at `-O0` | unjudgeable | unplaced |
|---|---:|---:|---:|---:|---:|
| Qt's Controls | 329 | 248 | 36 | 45 | 0 |
| application-shaped | 18 | 7 | 11 | 0 | **0** |

**Seven of eighteen** on application-shaped QML is the honest number and the interesting one:
that dialect is where the compiler is weak today, and the ladder is what keeps it correct
anyway — all eighteen behave identically to the engine.

The mechanisms, the per-style breakdown, what each `-O` level compiles, and a decomposition
of every document that is not compiled are in **[`docs/qmltc-d.md`](docs/qmltc-d.md)**. The
numbers in both files are compared against what the gates counted, by `docs-numbers`.

## Directory status

| Path | Status | Notes |
|------|--------|-------|
| `xiboca/` | **supported** | the `xiboca` generator (libclang C API) — source of truth |
| `runtime/{holder,qtmoc,uic,qrc}/` | **supported** | hand-written runtime the generated code links |
| `reggae/`, `reggaefile.d` | **supported** | the build of record (POSIX/Linux) |
| `generated/` | **generated** | gitignored, on-demand output |
| `tests/`, `examples/`, `apps/` | **tests only** | ldc2×dmd × Qt5×Qt6 matrix |
| `docs/` | **supported** | `FEATURES.md`, `test-suite.md`, `uic-spec.md`, `qmltc-d.md`, `qmltc-d-vs-qmltc.md`, `windows-roadmap.md` |
| `generator/` (specs) | **supported** | `spec_cxx_*.json` |

## Known risks / honest gaps

- **The generator is a large orchestrator.** `emit_cxx.d`/`emit.d` mix AST walk, type
  policy, textual emission, and (for inline recovery) a compile-check-and-retry pass.
  An explicit IR is the intended refactor; not done.
- **Typesystem consumption is a small regex subset** (`loadRules`): rejections +
  object-type/value-type only, **not** full ownership/rename semantics. It is not a
  general typesystem parser.
- **`QMetaObjectBuilder` is a Qt private API.** The moc bridge depends on it; treated
  as a compatibility risk, exercised on the Qt versions in the test matrix (6.11, 5.15).
- **Coverage** is written per spec to `generated/<dir>/coverage.txt` (summary) and a
  **per-symbol manifest** `coverage-manifest.tsv` (`cppClass · symbol · usr · fate`; fates:
  bound / shimmed / signal / inherited / pure-virtual / unmapped-type / inline-failed).
  The manifest is **gated** against a checked-in baseline (`manifest-gate-*` targets fail
  on regression). It covers the object-method path per-symbol; value-type/wrapper/ctor/stub
  drops are now emitted per-symbol too; the aggregate residual in `coverage.txt` is 0.

## Roadmap

- Introduce a generator IR (drop the remaining dead C-ABI helper functions in `gen.d`).
- Expand manifest gates beyond Qt6 QtWidgets, QML and Controls (Qt5, WebEngine);
  ownership-invariant tests for `holder`.
- Turn `tests/expected-fails.json` from a linted inventory into a RUNNER: today it
  validates that each entry is well-formed and that named probe targets exist, but
  nothing executes `remove_when`, so a gap that has been closed stays listed.
