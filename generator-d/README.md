# generator-d — the generator, in D (fast)

A native D port of `generator/gen.py`, calling the **libclang C API directly**
(`clang_c.d`) instead of Python's `clang.cindex`. Same pipeline — discover
classes, extract public ctors/methods, map types across the C-ABI boundary, emit
the C shim + `extern(C)` D decls + an idiomatic D `struct` — but without the
per-cursor Python↔C overhead.

## Speed

Whole **QtCore** (243 classes, ~4.5k shim functions):

| generator | time |
|---|---|
| Python (`clang.cindex`) | minutes (didn't finish a full run in one sitting) |
| **D (libclang C API)** | **~4.7 s** |

The generator is a dev-time tool (FFTW model), so its language is invisible to
users — but at whole-Qt scale the speed matters to the maintainer, and D
dogfoods the project.

## Build / run

```sh
ldc2 gen.d emit.d clang_c.d -L-lclang -of=gend      # dmd works too
./gend ../generator/spec_qtcore_d.json               # discover_module: "QtCore"
```

## Coverage (first pass)

Discovery binds every public class in a module and all its own public methods
(no hand-picked method lists). On a 60-class QtCore sample, **~83% of shims
compile clean** after the initial type-rule pass; the rest are edge cases
(QCbor*, QDataStream, some abstract models) that need incremental type rules —
not architectural gaps. Fixes already applied: correct C-vs-D primitive spelling
(`unsigned int` vs `uint`), `(void*)` const-strip on pointer returns, skipping
moc boilerplate (`metaObject`/`qt_metacall`/`tr`/…) and `QPrivateSignal` params.

## Bind your own Qt C++ (not just the framework)

The generator binds *any* Qt C++ — your own `QObject` subclasses and value types,
not only Qt's classes. Point it at your headers with a source filter:

```json
"headers": [".../shape.h"],
"source_filter": "examples/userlib",
"include_paths": [".../userlib"]
```

It discovers every class defined in your files (no `Q` prefix required) and emits
the same dual-layer binding. Demo (`examples/userlib/shape.h`): a `Shape : QObject`
and a plain `Circle` become idiomatic D structs — `Shape.create()`, `setSize(int,int)`,
`describe()` returning a native D `string` (QString conversion) — both shims
compile clean. Same machinery as the framework binding; your code is just another
input.

## Rules from shiboken — "what doesn't come for free"

The ~17% that don't map automatically are handled by pulling PySide/shiboken's
hand-tuned **typesystem XML** (`/usr/share/PySide6/typesystems/`, matching the
installed Qt) as data — no fork of shiboken, just its rules:

- `<rejection>` (class + optional `function-name`) → skip exactly what PySide
  skips (private helpers, problematic methods).
- `<object-type>` vs `<value-type>` → object-types are QObject-derived /
  non-copyable, so we never heap-copy them by value (only value-types are).

Wire it via the spec:
```json
"typesystem_dir": "/usr/share/PySide6/typesystems",
"typesystem_glob": "typesystem_core*.xml"
```
The generator parses these once (regex, no XML dep) and applies them during
discovery/extraction. For QtCore that's 19 rejected classes, 11 rejected
methods, 104 object-types, 89 value-types.

## Version-agnostic (Qt5 and Qt6)

The generator is not Qt6-specific — it reads whatever headers pkg-config points
at. Regenerating for Qt5 is just a different spec (no code changes):

```json
"pkg_config": "Qt5Core", "discover_module": "QtCore", "qt_marker": "/qt/",
"typesystem_dir": "/usr/share/PySide2/typesystems"
```

That produced the whole **Qt 5.15 QtCore — 208 classes, ~4.1k functions in ~2s**,
using PySide2's typesystem for the rules. Same machine, same generator; the
"regenerate against any Qt version" thesis, demonstrated.

## Beyond gen.py — the one to use

Everything the Python generator did, faster, plus more:
value types (`QString`/`QByteArray`/`QUrl`), **sequence containers (`QList<T>`/
`QVector<T>` → native `T[]`)** and **associative containers (`QHash<K,V>`/
`QMap<K,V>` → native `V[K]`, iterator-based)** — both with explicit C++ template
instantiation per concrete type into `qtcontainers.{h,cpp,d}`, element conversion
composing (`QHash<QString,int>` → `int[string]`, `QMap<QString,QString>` →
`string[string]`). Plus enums/`QFlags`, handles, abstract detection, overload/
collision, base-walk, the dual-layer idiomatic struct, and the shiboken rules.

Verified on both sides (C++ shim + generated `.d` compile).

## Scale — whole modules

| module | classes | functions | list/assoc containers | time |
|---|---|---|---|---|
| QtCore | 243 | ~4.5k | 7 / 1 | ~3.7s |
| QtGui  | 441 | ~8.6k | 18 / 1 | ~4.6s |
| QtQml  | 333 | ~6.0k | 9 / 1 | ~4.3s |

~1000 classes / ~19k functions across three modules in ~13s. Each is just a spec
(`discover_module` + `pkg_config` + the matching PySide typesystem). Framework and
your own classes can even be mixed in one spec.

## Whole-module D-side compile + the meta system

Discovery includes **`struct`s too** (not just classes), so the reflection system
binds: `QMetaObject`, `QMetaType`, `QMetaMethod`, `QMetaProperty`, `QMetaEnum`
(and `QModelIndex`, `QMargins`, …) — QtCore went 243 → **287 classes**. That work
surfaced/fixed several general robustness issues, and now the **entire generated
D side compiles clean across all three modules**:

| module | classes | functions | D-side compile |
|---|---|---|---|
| QtCore | 287 | ~4.8k | 0 errors / 288 files |
| QtGui  | 494 | ~9.3k | 0 errors / 495 files |
| QtQml  | 386 | ~6.4k | 0 errors / 387 files |

(~1,170 classes, ~20.5k functions.) The fixes behind it:
- `extern(C)` decls use D types (`long`, `uint`) not C spellings (`long long`,
  `unsigned int`);
- method names that are **D keywords or aliases** (`cast`, `function`, `scope`,
  `version`, `in`, `string`, …) are escaped (`cast_`, `string_`);
- ctor factory (`create`) is renamed when a class already has a `create` method;
- `std::function` / callback params are skipped.

## Coverage — ~83% → ~96%

A round of type-mapper work lifted the compile pass rate from ~83% to **QtCore
58/60 (97%)**, **QtGui 38/40 (95%)**. What it added:
- full primitives (`char`/`uchar`/`short`/`ushort`/`ulong`/`char16_t`/`char32_t`/…),
  covering the OpenGL typedefs (`GLuint`/`GLboolean`/…);
- `void*` and typed pointer-to-primitive (`qintptr*` → `long long*`);
- **reference returns** (`const QBrush& brush()` → borrowed handle) — the real
  cause behind the "const T&" skips;
- iterator methods (`begin`/`end`) and recursive **abstract-class** detection
  (bases' unimplemented pure virtuals) → no invalid `new`;
- **string views** idiomatic: `QStringView`/`QAnyStringView`/`QByteArrayView` →
  native `string` (reusing the QString/QByteArray helpers).

**`QVariant` is idiomatic** now too: it maps to a D `QtVariant` struct (owns the
handle, no temp-free) with a type tag (`QtVariantKind`) and accessors
(`from(int/double/bool/string)`, `.kind`, `.toLong/.toDouble/.toBool/.toStr`).
Round-trip verified. This also makes `QVariant` usable as the meta-object's
dynamic transport for properties and signal/slot args, and pulls in
`QList<QVariant>` / `QVariantMap` container instantiations for free.

Instrument with the built-in `UNMAPPED` histogram (printed each run) to see what's
left. The remaining tail is legitimate and compiles today as opaque handles:
function pointers (`QFunctionPointer`), rvalue-ref move params (`T&&`),
`std::nullptr_t`, and `QChar`/`QCborValue` (a `dchar` map and another tagged type
would finish those).
