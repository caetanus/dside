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

`qmltc-d` turns a `.qml` document into a D class. A binding stops being a JavaScript
expression the engine re-evaluates and becomes a D method plus a signal connection — Qt's
own Basic Button,

```qml
implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                        implicitContentWidth + leftPadding + rightPadding)
```

comes out as a slot the meta-object calls when any operand changes:

```d
@Slot void __rcb_implicitWidth() {
    setProp(this, "implicitWidth", __qmltcMax(
        propDouble(this, "implicitBackgroundWidth") + propDouble(this, "leftInset") + …,
        propDouble(this, "implicitContentWidth")   + propDouble(this, "leftPadding") + …));
}
```

No JS engine is involved in that binding again.

### The four mechanisms

Everything qmltc-d does is one of four, and they are not equally trustworthy. That ordering
IS the `-O` scale.

**1 — Static translation.** Every name has a known D type, so the expression becomes D. This
is where `a === b`, arithmetic, string concatenation, ternaries, enum keys and property reads
live. Trivial JS is not a problem; *untypable* JS is. The limit is the type registry, not the
language.

**2 — QVariant, for what is typed only at run time.** `property var control`, `property color
targetColor`: the meta-object declares the property, the value lives in a runtime slot, and
reads go through the meta channel. The value is right; the type is late. (No D field is
generated for these — a `QColor` field changed how every read of it compiled, and cost eight
link failures before it was done this way.)

**3 — Containment, COM-style.** Qt's Material style is built on `impl` types it does not
export — `Ripple`, `BoxShadow`, `ElevationEffect`. No D subclass can wrap a type with no
linkable symbol, so the **engine** builds the object and the generated class holds an opaque
pointer to it; every member is asked of whichever object owns it. This is why Material
compiles far less than Basic: not weak JS translation, unexported types.

**4 — Delegation, to the engine.** `control.model[control.headerView.textRole]` reads a member
by a name known only at run time: there is no property to name and no type to hold the result.
The expression is handed to the engine, which also tracks its dependencies — the point being
that the dependencies of an expression we cannot compile are exactly the ones we cannot
enumerate. With `--shadow-dir` the same expression is compiled at build time instead: it
becomes a generated QML document carrying a real `Binding`, which `qmlcachegen` turns into
bytecode. It has to be a binding and not a function — what makes a delegated expression live
is the engine capturing a *binding's* dependencies, and a function call captures nothing.

### `-O` is a degree of certainty

The scale is the four mechanisms, in order, and it runs the other way from speed: the higher
the level the more compiles and the less is proven. A document that needs a mechanism its
level does not allow is not compiled with it — it goes to the engine whole.

| level | mechanisms | certainty |
|---|---|---|
| `-O0` | none of ours: Qt builds the document, as `qmlcachegen` bytecode where it can, interpreted where it cannot | by construction — it is the engine |
| `-O1` | static translation only | nothing crosses untyped |
| `-O2` | ...and QVariant | value right, type late |
| `-O3` | ...and containment and delegation, **and only what RENDERS THE SAME** — what differs is demoted to `-O0` | measured, per document |
| `-Ox` | `-O3` with the render check waived | experimental |

`-O3` is not a compiler flag but a pipeline: the compiler cannot tell whether something renders
the same, so the build compiles, renders, compares with the engine's frame, and demotes what
differs. Two more switches exist for working on coverage rather than shipping: `--no-fallback`
turns the whole ladder off, and `--pedantic` also makes a delegation a failure (its own exit
code, 4 — "we could not compile this" and "we handed this over" are different jobs).

**What each level actually compiles**, over Qt's five Controls styles (a document not compiled
at a level is handed to the engine there, and still renders correctly):

| style | documents | `-O1` | `-O2` | `-O3` |
|---|---:|---:|---:|---:|
| Basic | 69 | 53 | 53 | 69 |
| Fusion | 55 | 42 | 42 | 55 |
| Universal | 55 | 40 | 42 | 55 |
| Imagine | 54 | 2 | 2 | 54 |
| Material | 57 | 10 | 10 | 57 |
| **total** | **290** | **147** | **149** | **290** |

The middle rung is nearly flat: QVariant alone unlocks **two** documents, both in Universal.
Everything else that needs weak typing also needs containment or delegation, so it lands at
`-O3` regardless — the scale has three rungs and two of them nearly coincide.

Imagine's 2-of-54 and Material's 10-of-57 are the same story from mechanism 3, not a weak JS
translator: Imagine resolves every image through a `NinePatchImageSelector` and Material is
built on unexported `impl` types, and both are containment by definition.

**The measured claim, on two axes.** Over Qt's own Quick Controls — five styles, 290
documents — every document that has a frame renders **byte-identical** to the QML engine:
247 compiled to D, 37 handed to the engine, 284 judged, **none unplaced**. And of the 247
compiled, **226 also agree on every property of every named object**, which is the stronger
axis: a frame is offscreen software rendering at the implicit size, and a control that draws
small hides a lot.

| style | compiled | of those, values differ | handed to the engine | unplaced |
|---|---:|---:|---:|---:|
| Basic | 54 | 1 | 5 | 0 |
| Fusion | 51 | 2 | 6 | 0 |
| Universal | 51 | 2 | 4 | 0 |
| Imagine | 48 | 7 | 4 | 0 |
| Material | 43 | 9 | 18 | 0 |
| **total** | **247** | **21** | **37** | **0** |

The 21 are counted with the census, not a raw diff: a path the oracle marks `<missing>` is
one it cannot walk, not a disagreement — Qt defers a Transition's animations, so at rest it
has none and we have ours. Counting those reported six Fusion documents as wrong when two
are. Most of the 21 differ in one to four properties; Imagine's DelayButton (82) is the
`layer.effect` shape, which crashes inside Qt itself and is documented as a ceiling.

`./build` re-checks all of it: `qmltc-o3-gate-<Style>` compiles each document, renders it,
compares the frame AND every property, demotes what the frame says differs, and fails on a
single document no level can place. It is a gate, not a number someone remembered to take.

**The scope, which matters as much as the claim.** That corpus is Qt's own QML: `T.Foo`
roots, declared properties, little loose JS, imports from Qt. **Application QML is not
characterised** — models, `Loader`, real JS, app-registered types, documents importing each
other. The floor (`-O0`) is the engine itself and should hold anywhere; everything above it
is measured only on the corpus above.

Pointed at a real application (a 78-document status bar), the gate reports 3 compiled, 10
demoted, 4 unplaced and **61 unjudgeable** — and that last number is the finding, not the
first three. A Controls document is self-contained by construction; an application's is not.
`Bitcoin.qml` exists inside the bar, with its data and its context, and the engine draws
nothing for it standalone. So it is not only that the compiler is less proven off this
corpus: **the per-document criterion itself does not transfer.** Judging an application means
judging it running, which is a different harness and an open question here.

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
