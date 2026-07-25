# qt-dlang-gen

A **binding generator** for Qt in D — not a hand-written wrapper. Existing D/Qt
wrappers are dead because nobody can maintain Qt's surface by hand across
versions. A generator re-runs against new Qt headers, so the binding never goes
stale (the shiboken/PyQt lesson).

## Building

A **dub workspace** (`dub.json`) holds two subpackages, and **reggae** drives the
C+++D interop build:

```
dub build :generator        # build the `gend` generator (generator-d/ -> gend)
reggae -b binary . --reggaefile-import-path "$PWD/reggae"
./build                     # generate bindings + build & run the whole test matrix
./build widget_test-ldc2-qt6   # one target;  ./build --list to see them;  --single for serial
```

`gend` is a pure code generator: it emits a nested-layout binding (`qt/<pkg>/*.d`
matching each `module`, plus the C++ shim `.cpp`) into a gitignored `generated/`
dir — **on demand, never committed**. reggae then compiles each `.d` per-module
into an archive and links the app against it, so the linker selects only what each
app references (no hand-rolled import closure). Every target is verified on **ldc2
AND dmd**, Qt5 and Qt6 where applicable. See `reggae/qtd_build.d`.

> The design notes below predate the current `extern(C++)` + reggae direction
> (see the `extern(C++) direction` section): the binding is now pure `extern(C++)`
> D — no C-ABI shim — and generated output is produced on demand, not committed.
> The legacy C-ABI path lives quarantined in `legacy/`.

## Target: QML + QJS (not Widgets)

QML is one path, classic Qt (Widgets) is another. We deliberately target
**QML + QJSEngine**:

- The visual surface lives in `.qml` text, instantiated by the engine, so the
  C++ surface to bind is *tiny* (engine + a few value types) instead of the
  hundreds of QtWidgets classes.
- Same prior art as the strongest one out there: `qmetaobject-rs` (by Olivier
  Goffart, the moc author) — QML frontend + backend objects exposed via the
  meta-object system.
- The generator machine is the same for both paths; Widgets is just "more
  classes + virtual-override (`paintEvent`) across the boundary" — future scale,
  not a rewrite.

## Architecture decisions

1. **Generator, not hand-wrapper.** libclang (stable C API — future-proofs the
   generator too), *not* clangd (LSP daemon, wrong tool for batch AST).
2. **Reuse the Qt typesystem XML as data** (path B): consume PySide's declarative
   rules (ownership / ignore / rename) with our own generator; do *not* fork
   shiboken's unstable C++ internals or its CPython-specific injected code.
3. **C-ABI shim boundary (CFFI), not `extern(C++)`.** An opaque handle per class
   + flat `extern "C"` functions. Stable ABI, immune to MSVC/mangling/version
   drift, portable to any D compiler (and any other FFI). This is what the
   generator emits.
4. **FFTW model: generate at home, version the output.** The generator is a
   dev-time tool (like FFTW's `genfft`); the generated `.d` + `.cpp` shim are
   committed per Qt minor version (`generated/qt-6.x/`). Users get plain files —
   no libclang, no Qt headers at build time. Generation must be reproducible
   (pinned libclang/Qt/rules, stable ordering, manifest header) and CI-checked
   (`git diff --exit-code`). Never hand-edit generated files.
5. **Native meta-object (phase 2), not moc.** D's CTFE + UDAs (`@qtSignal`,
   `@qtSlot`, `@qtProperty`) + `__traits` gather the descriptors at compile time;
   `QMetaObjectBuilder` builds the runtime `QMetaObject` (robust across Qt
   versions — same approach PySide uses). Phase 1 already emits the UDAs so
   phase 2 consumes them with zero rework. For a QML/QJS target this bridge is
   the *core deliverable*, not an afterthought.

## Layout (target)

```
generator/     libclang tool (Python + clang.cindex) — dev-time only
rules/         vendored Qt typesystem XML + our declarative patches
generated/
  qt-6.11/     committed .d + C shim, per Qt minor — what users consume
runtime/       hand-written: meta-object framework (phase 2), escape hatches
bootstrap/     hand-written C-ABI hello world — proves the toolchain
```

## Milestones done

- **`generator-d/`** — the generator **rewritten in D** on the libclang C API
  (no Python `cindex` overhead). Generated **all of QtCore — 243 classes, ~4.5k
  shim functions — in ~4.7s** (the Python generator took minutes and didn't
  finish a full run). Module auto-discovery, abstract-class detection, value
  types / enums / `QFlags` / handles, and the dual-layer struct are ported;
  now at parity with the Python generator — including **containers (`QList<T>` →
  native `T[]` with explicit C++ template instantiation)** and the full conversion
  registry. ~83% of a 60-class sample compiles clean on the first pass. Builds on
  ldc2 and dmd. `generator/gen.py` is now the historical reference.
  - **Shiboken rules, not fork**: consumes PySide's typesystem XML as data
    (rejections, object-type vs value-type) — "what doesn't come for free" comes
    from shiboken. Wired via `typesystem_dir`/`typesystem_glob` in the spec.
  - **Version-agnostic**: the same generator produced **Qt 5.15 QtCore (208
    classes, ~4.1k functions, ~2s)** by just changing the spec (`Qt5Core`,
    `qt_marker: "/qt/"`, PySide2 typesystem) — 10/10 sampled value-type shims
    compile clean against Qt5. Regenerate against any Qt version.
  - **Binds your own Qt C++**, not just the framework: point `headers` +
    `source_filter` at your project and it binds your `QObject` subclasses and
    value types the same way (demo: `examples/userlib/shape.h` → idiomatic
    `Shape`/`Circle` D structs, `describe()` → native `string`).
- **`runtime/app/`** — **the canonical app: all four pillars in one binary**,
  building on **both ldc2 and dmd** (both required). QML calls an async
  `@qtSlot` that runs as a vibe fiber (UI never blocks), which updates an
  `@qtProperty` and the QML binding reacts — on a single vibe-on-Qt event loop.
  Surfaced and fixed a real gotcha: emitting a notify **from a fiber** runs the
  QML binding's V4 JS on the fiber stack, which V4's stack guard rejects; the fix
  is `notifyQueued` (emit on the main loop stack). See its README.
- **`runtime/metaobject/`** — **native meta-object (phase 2), no moc.** A C++
  trampoline `QtdObject : QObject` carries a `QMetaObject` built at runtime with
  `QMetaObjectBuilder`; `qt_metacall` dispatches slot calls and property
  read/writes back into D (the C++ side owns the QObject vtable, so D never
  needs C++-ABI vtable compat — same approach as qmetaobject-rs/PySide). On top,
  a **CTFE layer** generates the description *and* the dispatch from UDAs:
  ```d
  final class Backend {
      @qtProperty int count;
      @qtSlot void increment() { ++count; notify!"count"(); }
      mixin QtObject;                 // meta-object + dispatch: CTFE, no codegen
  }
  ```
  Verified headless QML↔D round-trip: D property read by a QML binding, QML
  calling a D slot, and a D signal re-evaluating the QML binding. Exposed via
  `setContextProperty`. Next: `QVariant` for richer property/arg types, signal/
  slot args, and async slots that spawn a vibe `Task`.


- **`bootstrap/`** — hello world: D → C-ABI → Qt6 → QML window.
- **`generator/`** — `clang.cindex` parses Qt headers and emits the C shim +
  `.d` binding (spec-selected classes/methods, shiboken-style). Verified twice:
  - `verify/run.sh` — `QPoint` round-trip (regenerate → compile → assert).
  - `verify/run_qml.sh` — generates the **QtQml** binding (`QGuiApplication` +
    `QQmlApplicationEngine`) and opens a real QML window from D, **retiring the
    hand-written bootstrap shim**.
  Type-mapper handles: primitives, `int&`→`int*`, `char**`, opaque-pointer/value
  handles (any Qt class incl. `QUrl`), **static methods via base-class walk**
  (`exec`), and **default-arg truncation** (`new QQmlApplicationEngine()`).
  Overload-aware naming, unconditional `delete`, skip-with-reason, manifest headers.
- **Conversions folded into the generator** — a conversion registry makes
  convertible Qt types travel as handles in the raw layer and appear as native
  D types in a generated idiomatic **`struct` wrapper** (factories for ctors,
  methods, static methods):
  - `QString` / `QByteArray` / `QUrl` ↔ `string` (value types as handles in the
    raw layer, native `string` in the wrapper).
  - `QList<T>` / `QVector<T>` → native D array (`T[]`), with **explicit C++
    template instantiation** emitted per concrete `T` into `qtcontainers.{h,cpp,d}`
    (D can't instantiate C++ templates). Element conversion composes:
    `QList<QByteArray>` → `string[]`.
  - **Idiomatic-overload collision** handling: Qt overloads that collapse to the
    same D signature (`load(QString)` + `load(QUrl)` → `load(string)`) keep the first.
  - **Base-class method walk** resolves definitions via `get_definition()` so
    inherited methods (`QObject::dynamicPropertyNames`) bind through the chain.
  Verified end-to-end from D: `engine.load(string)` opens a QML window,
  `engine.rootObjects()` → `void*[]` (len 1), `engine.dynamicPropertyNames()` →
  `string[]`. `QHash<QString,QString>` ↔ `string[string]` proven in
  `runtime/convert` (iterator-based); generator integration mirrors `QList`.
  `QVariant` and `QHash`/`QMap` in the generator come with the meta-object work.
- **`runtime/vibe_qt/`** — **Qt is vibe-core's event driver backend**: fds →
  `QSocketNotifier`, the wait → `QCoreApplication::processEvents` (no polling).
  Verified with a timer path (`sleep`) and an fd path (TCP loopback). See its
  README.
- **`runtime/convert/`** — the **type-interchange layer** (proven): `QString ↔
  string` (utf8 ptr+len, no `toStringz`), `QList<int>` as a native D range
  (`foreach` + `filter!.map!.sum`). The pattern the generator will emit as a
  second, idiomatic `.d` layer over the raw handle ABI. Conversions are written
  once per Qt container (QString/QList/QHash/QMap/QUrl/…) and reused for every
  instantiation; templates get explicit C++ instantiation per concrete type.
  Raw layer stays `@nogc`; idiomatic layer allocates (GC).

## bootstrap/ — hello world (done)

Hand-written instance of exactly what the generator will emit: `qml_shim.h/.cpp`
(the C-ABI contract) + `app.d` (`extern(C)` binding) driving a QML window.

```sh
cd bootstrap && sh build.sh
./hello                                                # opens a window
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software ./hello --selftest   # headless check
```

Verified on Qt 6.11.1, ldc2, libclang 21/22, Manjaro.

## extern(C++) direction (branch `extern-cpp-refactor`)

The binding is being moved from C-ABI shims to **pure `extern(C++)`**: generated
modules are 100% D and mangle straight to the Qt symbols — no per-class C++ to
compile, so a class you never `import` costs nothing (à la carte), and `dub`
never touches a C++ compiler. Constructors allocate on the C++ heap (so Qt's
`delete`/`deleteLater` match), multiple inheritance uses a pure-D pointer offset,
enums bind as `extern(C++) enum`, and containers iterate by layout/sret — all
proven on ldc **and** dmd.

### Inline methods — coverage policy

Inline Qt methods have **no linkable symbol** (the compiler inlines them at each
call site), so `extern(C++)` can't call them. The generator handles them by
**re-implementing the body in D**: it reads each inline's source with libclang and
copies it into the D struct (C++ and D share expression syntax, and `alias this`
resolves the fields). Because the translator is deliberately crude, every
translated inline is **compile-checked during generation**; the ones that don't
compile are dropped for that module (with a warning) — we never emit a binding
that won't build.

What this means:

- **Any Qt C++ module** (framework or your own) can be bound.
- For the **standard Qt** value types (QRect, QSize, QPoint, …) we translate the
  inlines within this heuristic; the common accessors/mutators come across.
- In **your own** C++, prefer out-of-line methods — inlines may not translate and
  will simply be omitted (with a warning), never break the build.

### Idiomatic types (done, ldc + dmd)

- **Strings**: `QString`/`QByteArray` are copyable value types (Qt CoW: postblit
  refcount++, hand-rolled release since the dtors are inline). `QString("foo")` /
  `qs.to!string`; `QByteArray` ↔ `ubyte[]` (raw bytes). `QAnyStringView` (Qt6
  setters) accepts a D string. Methods with `const QString&`/`QByteArray&`/
  `QAnyStringView` params get a `string` overload — `w.setText("hi")`.
- **enums** → `extern(C++) enum` (nested emitted inside the class for the mangling
  substitution). **QFlags<Enum>** → `int`.
- Every out-of-line method carries `pragma(mangle)` with clang's exact symbol — D's
  own mangling diverges between ldc and dmd on Itanium substitutions.

### Containers (design validated; generator wiring in progress)

Two tiers, no QVariant boxing:

- **Basic element types** convert natively: `string`↔QString, `ubyte[]`↔QByteArray,
  `int`↔int (proactively instantiated for a small bounded set of common combos).
- **Unknown types** come through as their normal opaque `extern(C++)` handle.
- A **container is an opaque `void*` + a thin per-container C++ shim** with
  callbacks, both directions:
  - **param** (D→Qt): `new` + `insert` per pair — you pass a native D `V[K]`/`T[]`,
    Qt reads the data.
  - **return** (Qt→D): a thin `iterate(container, cb, ctx)` hands each element's raw
    basic data to a D callback, which builds `V[K]`/`T[]`. (`QList` returns also work
    pure-D via layout.)

The per-container C++ is minimal and only for the container types actually used —
the one place, besides that bounded common set, the toolchain compiles C++.
