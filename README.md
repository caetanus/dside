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
| `-O3` | ...and containment and delegation, **and only what BEHAVES THE SAME** — what differs on either axis is demoted to `-O0` | measured, per document |
| `-Ox` | `-O3` with the check waived | experimental |

`-O3` is not a compiler flag but a pipeline: the compiler cannot tell whether something behaves
the same — it does not render and it does not run — so the build compiles the document, renders
it, compares the frame with the engine's, compares every property of every named object, and
demotes what differs on either. Two more switches exist for working on coverage rather than
shipping: `--no-fallback` turns the whole ladder off, and `--pedantic` also makes a delegation a
failure (its own exit code, 4 — "we could not compile this" and "we handed this over" are
different jobs).

**What each level actually compiles**, over Qt's five Controls styles (a document not compiled
at a level is handed to the engine there, and still renders correctly):

| style | documents | `-O1` | `-O2` | `-O3` |
|---|---:|---:|---:|---:|
| Basic | 70 | 39 | 39 | 70 |
| Fusion | 70 | 38 | 38 | 70 |
| Universal | 66 | 27 | 27 | 66 |
| Imagine | 56 | 0 | 0 | 56 |
| Material | 67 | 7 | 7 | 67 |
| **total** | **329** | **111** | **111** | **329** |

The middle rung currently buys **nothing**: `-O1` and `-O2` compile the same 111 documents.
Everything that needs weak typing in this corpus also needs containment, delegation or has a
member the compiler skips, so it lands at `-O3` regardless. The scale has three rungs and two of
them coincide — stated because it is a real property of the corpus, not a defect to hide.

The certainty levels are stricter than the mechanism list suggests, on purpose: they also refuse a
document with any SKIPPED member. A skip is worse than weak typing — weak typing still produces
the member, a skip produces a document missing behaviour — and no caller can tell by reading the
generated D. That refusal costs `-O1` sixty documents against a version that emitted them, and it
is what makes "`-O1` agrees with the engine" true without a render step to check it.

Imagine's 0-of-56 and Material's 7-of-67 are mechanism 3, not a weak JS translator: Imagine
resolves every image through a `NinePatchImageSelector` and Material is built on unexported
`impl` types, and both are containment by definition.

`qmltc-optlevels-*` holds the levels to that promise: each document is built at `-O1` and `-O2`
and both must produce the engine's value for every property of every named object, and the same
value as each other. `-O3` is deliberately outside it — `-O3` is a pipeline, and disagreeing
before the demotion step is its normal intermediate state, which is what the gate below measures.

**The measured claim.** Over Qt's own Quick Controls — five styles, 329 documents — every
document the engine can draw standalone behaves **identically** to it: same frame, byte for
byte, and the same value for every property of every named object. 226 of them reach that as
compiled D; 58 reach it as `-O0`, where Qt builds the document; 45 have no frame to compare;
**none is unplaced**.

| style | documents | compiled | at `-O0` | unjudgeable | unplaced |
|---|---:|---:|---:|---:|---:|
| Basic | 70 | 53 | 6 | 11 | 0 |
| Fusion | 70 | 49 | 8 | 13 | 0 |
| Universal | 66 | 49 | 6 | 11 | 0 |
| Imagine | 56 | 41 | 11 | 4 | 0 |
| Material | 67 | 34 | 27 | 6 | 0 |
| **total** | **329** | **226** | **58** | **45** | **0** |

Both axes are required, and demoting on either is what makes the number mean something. The
frame alone placed 247 documents; 21 of those disagreed on a property while the frame matched,
which is what a control that draws small at its implicit size will do. Those 21 are the
difference between the two columns — they are at `-O0` now, still identical to the engine,
just not by our compilation.

The comparison is filtered twice, and both filters exist because the harness was wrong before
the compiler was. A path the oracle marks `<missing>` is one it cannot walk rather than a
disagreement — Qt defers a `Transition`'s animations, so at rest it has none and we have ours;
counting those called six Fusion documents wrong when two were. And a path the ENGINE cannot
reproduce cannot be a verdict about us: Material's SpinBox background carries
`placeholderTextHAlign`, which Qt reads out of uninitialised memory and which answered
1154029312, 1895307008 and -1856497920 on three consecutive engine runs. Judged against one
engine dump, three Material documents were unplaceable at every level, `-O0` included. The
engine is asked twice and every path where it contradicts itself is dropped from both sides.

`./build` re-checks all of it: `qmltc-o3-gate-<Style>` compiles each document, renders it,
compares the frame AND every property, demotes what differs on either, and fails on a single
document no level can place. It is a gate, not a number someone remembered to take.

**The scope, which matters as much as the claim.** That corpus is Qt's own QML: `T.Foo` roots,
declared properties, little loose JS, imports from Qt. Application QML is a different dialect, so
there is a second corpus for it (`tests/qmltc/app/`, gate `qmltc-o3-gate-app`) — list models and
delegates, `ListView`, `Loader`, real JS with loops and arrays and objects, states and
transitions, inline components, `Connections`, signals crossing documents, one document
instantiating another from its own directory, anchors, a `Timer`, and an application *consuming*
Controls rather than defining them.

| corpus | documents | compiled | at `-O0` | unjudgeable | unplaced |
|---|---:|---:|---:|---:|---:|
| Qt's Controls | 329 | 226 | 58 | 45 | 0 |
| application-shaped | 14 | 2 | 12 | 0 | **0** |

**Two of fourteen** is the honest number, and it is the point rather than an embarrassment: this
dialect is where the compiler is weak today and the ladder is what makes it correct anyway. Every
one of the fourteen behaves identically to the engine, and at `-O1`/`-O2` none of them is emitted
partial — twelve are handed over whole, which `qmltc-optlevels-*` checks property by property.

What the second corpus still does not cover is an application's **context**: a document that needs
the app's C++ context properties, its models and its data. Pointed at a real one (a 78-document
status bar) the gate reports 3 compiled, 10 demoted, 4 unplaced and **61 unjudgeable** — and that
last number is the finding, not the first three. `Bitcoin.qml` exists inside the bar, and the
engine draws nothing for it standalone either, so there is no oracle to compare against. The
documents above are self-contained on purpose, which is what makes them judgeable and also what
they do not prove. Judging a whole running application is a different harness and remains open.

The 45 unjudgeable are outside the frame axis and honestly so: `Action`, `ButtonGroup`,
`CalendarModel`, the `*Delegate`s and the styles' `impl/` helpers have no frame by nature — a
delegate needs a view to exist and an `Action` is not drawn at all. The engine renders nothing
for them standalone, so there is nothing to compare a frame against; they are **not** counted as
passes above.

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

- Introduce a generator IR (drop the remaining dead C-ABI helper functions in `gen.d`).
- Expand manifest gates beyond Qt6 QtWidgets, QML and Controls (Qt5, WebEngine);
  ownership-invariant tests for `holder`.
- Turn `tests/expected-fails.json` from a linted inventory into a RUNNER: today it
  validates that each entry is well-formed and that named probe targets exist, but
  nothing executes `remove_when`, so a gap that has been closed stays listed.
