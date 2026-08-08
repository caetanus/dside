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

- **Is:** a code generator (`generator-d/` → `gend`) built on the libclang **C API**
  (stable, no `clang.cindex`), plus a small hand-written runtime (`runtime/`) and a
  reggae build that generates → compiles → links in one incremental graph.
- **Isn't:** a committed, hand-maintained wrapper. Generated output lands in a
  **gitignored `generated/`** dir, produced **on demand, never committed**.

The status of every directory is in the [matrix](#directory-status) below, and the
full feature list is in **`docs/FEATURES.md`** — the single source of truth for
capabilities. This README is the map, not the catalogue.

## Building

```sh
cd generator-d && dub build          # build the `gend` generator
cd .. && reggae -b binary . --reggaefile-import-path "$PWD/reggae"
./build                              # generate bindings + build & run the test matrix
./build widget_test-ldc2-qt6         # one target;  ./build --list to see them
```

`gend <spec.json>` emits `qt/<pkg>/*.d` (+ minimal `.cpp` trampolines) into
`generated/`. reggae compiles each `.d` per-module into an archive and lets the linker
select what each app references — no hand-rolled import closure. Every target is
verified on **ldc2 AND dmd**, **Qt5 AND Qt6** where applicable.
(The `:runtime` subpackage is a `sourceLibrary` — it is **not** built in isolation
(`dub build :runtime` errors); reggae compiles the runtime and its C++ companions.
reggae is the build of record, not dub.)

## Construction

Two modes. In **GC-wrapper mode** object types construct with idiomatic `new`
(`new QWidget(parent)`); value types use a plain ctor or `make!T`. In **raw
(non-wrapper) mode** — still the default for several bindings (QtWidgets raw, QML,
the uic harness) — object construction is the generated `X_new(...)` factory
(e.g. `QQmlApplicationEngine_new`, `QWidget_new`), which the tests and generated
uic use today. Making wrapper mode the default so `new` is the ONLY spelling is a
roadmap item, not the current state.

```d
auto w   = new QWidget(parent);      // GC wrapper owns a C++-heap object; Qt deletes it
auto col = QColor(0, 0, 128);        // value type — struct ctor
auto v   = make!QVariant();          // value type, no-arg (D forbids a struct this())
```

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
- **`qmltc-d`**: a QML→D compiler with a fallback ladder — see below.

## qmltc-d: QML compiled to D, and a floor under it

`qmltc-d` turns a `.qml` document into a D class. What it cannot turn into D it does not
drop: an expression goes to the QML engine (as a source string, or as a document
`qmlcachegen` compiled to bytecode), and a whole document can go to the engine too, held
behind an opaque pointer the way COM holds an interface. **`-O` is a degree of certainty,
and it runs the other way from speed:**

| level | what it adds | certainty |
|---|---|---|
| `-O0` | nothing of ours runs — Qt builds the document, AOT where `qmlcachegen` can, interpreted where it cannot | by construction |
| `-O1` | statically typed translation only: `a === b` compiles because both sides have a known D type | nothing crosses untyped |
| `-O2` | ...and `QVariant` where the type is only known at run time | value right, type late |
| `-O3` | ...and COM-style containment and delegation — **and only what RENDERS THE SAME**; what differs is demoted | measured, per document |
| `-Ox` | `-O3` with the render check waived | experimental |

**The measured claim.** Over Qt's own Quick Controls — five styles, 290 documents — every
document that has a frame renders **byte-identical** to the QML engine: 247 compiled to D,
37 handed to the engine, 284 judged, **none unplaced**. `./build` re-checks it: `qmltc-o3-gate-<Style>`
compiles each document, renders it, compares with the engine's frame, demotes what differs,
and fails on a single document no level can place. It is a gate, not a number someone
remembered to take.

**The scope, which matters as much as the claim.** That corpus is Qt's own QML: `T.Foo`
roots, declared properties, little loose JS, imports from Qt. **Application QML is not
characterised** — models, `Loader`, real JS, app-registered types, documents importing each
other. The floor (`-O0`) is the engine itself and should hold anywhere; everything above it
is measured only on the corpus above.

Six documents are outside the frame axis and honestly so: `Action`, `ButtonGroup`,
`CalendarModel` and the `*Delegate`s have no frame by nature — a delegate needs a view to exist
and an `Action` is not drawn at all — so they are judged on the value axis instead. They are not
counted as passes here.

## Directory status

| Path | Status | Notes |
|------|--------|-------|
| `generator-d/` | **supported** | the `gend` generator (libclang C API) — source of truth |
| `runtime/{holder,qtmoc,uic,qrc}/` | **supported** | hand-written runtime the generated code links |
| `reggae/`, `reggaefile.d` | **supported** | the build of record (POSIX/Linux) |
| `generated/` | **generated** | gitignored, on-demand output |
| `tests/`, `examples/`, `apps/` | **tests only** | ldc2×dmd × Qt5×Qt6 matrix |
| `docs/` | **supported** | `FEATURES.md`, `test-suite.md`, `uic-spec.md`, `windows-roadmap.md` |
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

- Make GC-wrapper mode the **default** so raw-path objects also construct with `new`.
- Introduce a generator IR (drop the remaining dead C-ABI helper functions in `gen.d`).
- Expand manifest gates beyond Qt6 raw-QtWidgets + Qt6-QML (Qt5, wrapper, webengine);
  ownership-invariant tests for `holder`.
