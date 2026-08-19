<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# Generating a wrapper with xiboca

xiboca reads a **spec** — one JSON file — and writes D source. It compiles
nothing: the sources it emits are compiled by whatever build you already have.
The spec is therefore the entire user interface, and this page is about writing
one.

Three cases are covered, in increasing distance from Qt itself:

1. [a Qt module](#1-a-qt-module) — `QtWidgets`, `QtQuick`, `QtNetwork`;
2. [a third-party Qt library](#2-a-third-party-qt-library) — anything that ships
   headers and a `.pc` file;
3. [your own C++](#3-your-own-c) — your project's classes, which need not be Qt
   at all beyond what they inherit.

## The shortest spec that works

```json
{
  "qt_version": "6.11-userlib",
  "pkg_config": "Qt6Core",
  "out_dir": "../generated/userlib",
  "d_package": "userlib",
  "headers": ["/path/to/your/shape.h"],
  "source_filter": "examples/userlib",
  "include_paths": ["/path/to/your"]
}
```

That is `generator/spec_userlib.json`, complete, and it binds a hand-written
`QObject` subclass plus a plain value type. Run it:

```sh
cd xiboca && dub build          # -> ./xiboca
./xiboca ../generator/spec_userlib.json
```

## What comes out

Into `out_dir`:

| | |
|---|---|
| `<d_package>/*.d` | one module per class/enum, at a path matching its `module` name so `import userlib.shape` resolves against `-I<out_dir>` |
| `cxxrt.d`, `holder.d` | the runtime, copied in — the binding is self-contained |
| `*.cpp` | shims and trampolines, to be compiled and linked alongside |
| `coverage.txt` | the human summary |
| `coverage-manifest.tsv` | one row per symbol, with its fate |

`coverage.txt` is the file to read first:

```
671 classes emitted, 0 shiboken-rejected.
per-symbol manifest: coverage-manifest.tsv, 8428 rows. fate breakdown:
  bound          4479
  inherited      1487
  pure-virtual    190
  shimmed        1046
  signal          501
  unmapped-type   725
```

`unmapped-type` is the only line that means "you did not get this". Every one of
those 725 is named in the manifest with the type that stopped it, so "what is
missing" is a `grep`, not a guess.

**A parse failure is a hard error, not an empty binding.** If a header cannot be
found, libclang returns a translation unit with fatal diagnostics and *zero*
classes; xiboca refuses to emit rather than writing a binding with nothing in it.
That failure mode was live once — a spec whose include path had stopped resolving
produced "0 classes" and exit 0 — and closing it is why `include_paths` being
wrong now fails loudly.

## 1. A Qt module

```json
{
  "qt_version": "6.11",
  "pkg_config": "Qt6Widgets",
  "out_dir": "../generated/qt-6.11/cxx-qtwidgets",
  "d_package": "qt.widgets",
  "abi": "cxx",
  "exceptions": true,
  "discover_module": "QtWidgets",
  "subclass": ["QWidget"],
  "wrapper": true
}
```

`discover_module` becomes `#include <QtWidgets>` and everything the umbrella
header pulls in is scanned. Which of those classes are *kept* is decided by
`qt_marker`, a path fragment that defaults to `/qt6/`: a class is Qt's if its
name starts with `Q` **and** it was declared in a file under that path. Point
`qt_marker` elsewhere for a Qt installed somewhere unusual.

## 2. A third-party Qt library

Nothing about xiboca is Qt-specific beyond the defaults. A library that ships
headers and a `.pc` file is bound the same way:

```json
{
  "qt_version": "6.11-charts",
  "pkg_config": "Qt6Charts",
  "out_dir": "../generated/charts",
  "d_package": "charts",
  "abi": "cxx",
  "discover_module": "QtCharts",
  "qt_marker": "/QtCharts/"
}
```

Two things to get right:

- **`pkg_config` must name the library**, not just its dependencies. It supplies
  the compile flags for parsing *and* the symbol table described below.
- **`qt_marker` or `source_filter` must match where the headers live**, or
  discovery keeps nothing. If the emitted binding has 0 classes and there were no
  fatal diagnostics, this is almost always why.

Whether such a library may be linked into a product is a separate question with
its own gate — see `docs/qt-license-matrix.tsv`. A module absent from that file
is refused, deliberately.

## 3. Your own C++

Use `headers` plus `source_filter` instead of `discover_module` plus
`qt_marker`:

```json
"headers": ["/abs/path/shape.h"],
"source_filter": "examples/userlib",
"include_paths": ["/abs/path"]
```

`source_filter` switches discovery into **your-own-code mode**: any class whose
declaring file path contains that fragment is kept, whatever it is called. The
`Q` prefix rule does not apply — `Circle` is bound exactly like `QWidget`.

The two mechanisms **combine**, which is the case people usually want: a module
*plus* extra headers, all parsed as one translation unit. That is how the Quick
binding reaches the private element headers declaring `QQuickRectangle`.

Relative paths in `include_paths` and `out_dir` resolve **against the spec file**,
not the working directory, so a spec works whether it is run from the repository
root or from `generator/`.

## Choosing WHICH Qt, and libraries with no `.pc`

`pkg_config` says *which modules*. It does not say *which installation* — that
came from whatever `PKG_CONFIG_PATH` happened to hold, which is invisible in the
spec and therefore unrecorded: the same spec binds against a different Qt on a
different machine and nothing says so. `pkg_config_path` moves that choice into
the spec, where it is reviewable:

```json
"pkg_config_path": ["/opt/qt/6.8.1/gcc_64/lib/pkgconfig"]
```

Listed directories are **prepended**, so the spec's choice wins over the
environment's. Relative paths resolve against the spec file, like `out_dir` and
`include_paths`.

For a library that ships no `.pc` file at all — VTK, OpenCASCADE, anything that
is CMake-config-only — `pkg_config` cannot name it, so give its flags directly:

```json
"pkg_config": "Qt6Core",
"cflags": ["-I/usr/include/vtk-9.3"],
"libs":   ["-L/usr/lib/vtk-9.3", "-lvtkCommonCore-9.3", "-lvtkRenderingCore-9.3"],
"headers": ["/usr/include/vtk-9.3/vtkPolyData.h"],
"source_filter": "vtk-9.3"
```

`cflags` reaches the parse; `libs` reaches the symbol scan described below, and is
what a build needs in order to link. `pkg_config` stays required — name the Qt
modules there and put the non-pkg-config library in `cflags` / `libs`.

**The build must be told the same thing.** xiboca only emits sources; the compile,
the link and the licence gates resolve Qt through pkg-config independently.
Generating against one Qt and linking against another is an ABI mismatch that this
project's `extern(C++)` design is precisely sensitive to, so a custom location has
to reach all of them — today that means the build environment must agree with the
spec. Making the build read these keys is not done yet.

### The symbol check, and why it does not get in your way

xiboca refuses to bind a method whose mangled symbol is provably absent from the
libraries being linked: it runs `nm -D --defined-only` over the `.so` files that
`pkg-config --libs` and `libs` name — searching the `-L` directories they give,
then `/usr/lib`, `/usr/lib64`, `/usr/local/lib` — and drops what it cannot find. Binding a declaration
whose definition does not exist produces a link error at the far end of the
pipeline, where it is hardest to read.

For your own library this would be exactly wrong — your `.so` is not in
`pkg_config`, so nothing of yours would be found. So the check is **per class and
self-disabling**: it applies to a class only if at least one of that class's
non-inline public methods is already in the symbol table. A class from a library
xiboca knows nothing about has no methods in the table, the check never turns on,
and everything is bound.

The consequence worth knowing: the check protects Qt-side mistakes and is silent
about yours. If your own class fails to link, the missing definition is in your
`.cpp`, and xiboca did not warn you because it could not.

## Ownership: the keys that decide who frees what

These are the keys that cannot be inferred, and the reason a Qt spec is longer
than a spec for your own code. They are **audited against the library's own
documentation**, not guessed:

| Key | Meaning |
|---|---|
| `transfer_in` | `"QTreeWidget::addTopLevelItem/0"` — argument 0 of that method **takes** ownership |
| `transfer_out` | the call **gives** ownership back to the caller |
| `disposable` | this type has an owner-managed lifetime and may be destroyed explicitly |
| `ctor_parents` | which constructor arguments act as parents; `[]` means "none of them do" |

The `/0` suffix is the argument index.

**`no_transfer` belongs to the gate, not to the generator.** xiboca never reads
it. It is consumed by `tests/ownership-gate.sh`, which walks every generated
method taking a `disposable` type and fails on any that appears in none of the
three lists. So `no_transfer` changes no emitted code — it records that a method
was examined and found harmless. Without it, an unclassified method and a
checked-and-harmless one are indistinguishable, which is the difference between a
gap and a decision.

For your own code you usually need none of these — until you write a method that
takes ownership of a raw pointer, at which point you need `transfer_in` for the
same reason Qt does.

## The other keys

| Key | Effect |
|---|---|
| `out_dir` | where to write, resolved against the spec file |
| `d_package` | the D package name; dots become directories under `out_dir` |
| `qt_version` | a label, carried into `coverage.txt` and used to select Qt5-vs-Qt6 emission |
| `pkg_config` | the modules to parse and link against, space-separated. Required |
| `pkg_config_path` | directories prepended to `PKG_CONFIG_PATH`, i.e. *which* installation |
| `cflags` | raw compile flags, for a library that ships no `.pc` |
| `libs` | raw link flags, same case; also feeds the symbol scan |
| `classes` | legacy fallback: an explicit list of `{"include": ...}` entries, used only when neither `discover_module` nor `headers` is given |
| `abi` | must be `"cxx"`. The C-ABI shim emitter was removed; any other value is an error |
| `wrapper` | GC wrapper mode: emits the parenting-pins lifetime layer |
| `exceptions` | translate C++ exceptions into D ones across the boundary |
| `subclass` | classes you intend to derive from in D — emits virtual trampolines |
| `subclass_derived` | the same for types discovered as derived rather than named |
| `qmltypes` | also emit a `.qmltypes` description for QML tooling |
| `typesystem_dir`, `typesystem_glob` | read PySide's typesystem XML as data (below) |

### Typesystem rules are a small subset, on purpose

If `typesystem_dir` is set, xiboca extracts **by regex** two things from PySide's
XML: `<rejection>` (skip this class or method) and `<object-type>` versus
`<value-type>` (never heap-copy an object type by value). It does not parse
ownership or renaming semantics, and it is not a general typesystem parser. This
is a deliberate borrowing of data, not a shiboken fork — and it is why ownership
lives in the spec keys above rather than being read from XML.

```json
"typesystem_dir": "/usr/share/PySide6/typesystems",
"typesystem_glob": "typesystem_core*.xml"
```

### Keys starting with `_` are ignored, and that is a convention

xiboca reads no key beginning with an underscore, so specs use them to record why
a decision was made where the decision lives:

```json
"_spinbox_not_bindable_reason": "QQuickSpinBox/QQuickDoubleSpinBox are NOT
  bindable, measured 2026-08-02: adding their headers DOES map them, and then
  every subclass fails ..."
```

Four such keys exist in the shipped specs. They are the answer to "why is this
absent" written next to the absence, rather than in a commit message nobody will
find.

## Building what came out

xiboca emits sources and stops. In this repository reggae owns the rest — compile
each `.cpp` and `.d`, archive per module, link — and `reggae/qtd_build.d` is the
worked example. By hand the shape is:

```sh
clang++ -std=c++17 -fPIC -c $(pkg-config --cflags Qt6Core) out/*.cpp
ldc2 -c -I out out/<d_package>/*.d out/cxxrt.d
# then link the objects together with $(pkg-config --libs Qt6Core)
```

Both `ldc2` and `dmd` are supported and this project requires parity between
them: a binding that works on one compiler and not the other is a defect, not a
preference.

## When it goes wrong

| Symptom | Cause |
|---|---|
| fatal diagnostics, no output | a header did not resolve — check `include_paths` |
| 0 classes, no diagnostics | `qt_marker` / `source_filter` matches nothing |
| `only abi:cxx is supported`, exit 1 | the spec is missing `"abi": "cxx"` |
| a method you wanted is `unmapped-type` | its signature uses a type not yet mapped; the manifest names it |
| link error on a Qt symbol | the symbol check was off for that class — its siblings were not in the `.so` either |
| link error on your own symbol | your definition is missing; the check cannot see your library |

## See also

- `xiboca/README.md` — what the generator is, and its files
- `docs/FEATURES.md` — the capability list
- `docs/test-suite.md` — how the matrix exercises all of this
