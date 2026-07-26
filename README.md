# qt-dlang-gen

A **binding generator** for Qt in D. Hand-written D/Qt wrappers die because nobody
can track Qt's surface by hand across versions; a generator re-runs against new Qt
headers instead. The generated binding is **pure `extern(C++)` D** — modules mangle
straight to the Qt symbols, so there is no per-class C++ shim to compile and a class
you never `import` costs nothing (à la carte).

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

Object types (GC-wrapper mode) construct with idiomatic `new`; value types with a
plain ctor, or `make!T` for the rare justified no-arg factory. `X_new(...)` is not a
supported spelling.

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
  QUiLoader on the full baseline corpus, 53/53, incl. `tr()`), `moc`
  (`@QObject`/`Signal`/`@Slot`/`@Property` via `QMetaObjectBuilder`), `qrc`.
- **Exception translation**: C++/Qt exceptions → D via a Lippincott + per-signature
  guard layer (gated).

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
- **Coverage** is written per spec to `generated/<dir>/coverage.txt` (path-aware:
  D bindings emitted + methods/ctors dropped as unmapped-type). A **per-method**
  status manifest (bound / skipped-by-rule / inline-failed / shimmed) is still a
  tracked follow-up — today's counters are path-level, not per-method.

## Roadmap

- Make GC-wrapper mode the **default** so raw-path objects also construct with `new`.
- Introduce a generator IR (drop the remaining dead C-ABI helper functions in `gen.d`).
- Persist a coverage manifest per spec; ownership-invariant tests for `holder`.
