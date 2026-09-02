<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# qt-dlang-gen — Feature Summary

Pure-D Qt bindings generated as `extern(C++)` (no C++ wrapper shim). The generator
(`xiboca/`, builds `xiboca`) parses Qt headers via libclang and emits per-class `.d` plus
minimal `.cpp` trampolines; reggae owns all compilation. Verified on **ldc2 + dmd**, **Qt5 + Qt6**.

## Core binding (generator)
- **extern(C++) codegen** — per-class modules, à-la-carte (`--gc-sections` drops unused shims).
- **Construction** — object types: `new QWidget(parent)` (idiomatic D). Value types:
  `QColor(r,g,b,a)` (struct ctor) or `make!QVariant()` (justified no-arg factory — D forbids a struct
  no-arg `this()` and a CoW `.init` is a null d-pointer). **`X_new(...)` is UNACCEPTABLE** — never a
  factory named `Foo_new`, and there is none: `grep -r '[A-Z][A-Za-z0-9]*_new' generated/` finds
  nothing in any mode. Done for value types and for objects, wrapper and raw alike.
- **Types** — value types (correct sizeof/ABI, incl. CoW non-trivial like QIcon/QFont); enums
  (incl. 2-part `Qt::X` via a `qt` aggregator + `Class::X`); containers (`QList`↔`T[]`, QHash/QMap);
  multiple inheritance (secondary-base upcasts); forward iterators → D ranges (`foreach (x; t[])`).
- **`const ObjectType&` params** bound (a reference is ABI-a-pointer).
- **Overridden virtuals** dispatch correctly via the C++ method shim (simple **and** value returns,
  e.g. `sizeHint`); only container/QList-return virtuals remain non-virtual.

## Memory / lifetime — GC wrapper (`"wrapper": true` on every spec the build uses)
- **QtdObject** wrapper layer (`runtime/holder/`): nullable `_cpp` + `checkAlive` (destroyed object
  throws, no segfault); C++-side identity map; **parenting-pins** (a parented child is a GC root);
  `destroyed()` invalidation; GC finalizer → `deleteLater` for D-owned objects; runtime reparent
  detection. Works incl. moc/subclass trampolines. Every spec the default build compiles carries
  `"wrapper": true` — QtWidgets (Qt5 and Qt6), QML, Quick, Controls, and the uic/qrc harnesses that
  sit on the widgets binding. Two hold out: the WebEngine link smoke test and the `corpustypes`
  fixture, which exercise the generator's raw path on purpose.

## moc — CTFE meta-objects
- `@QObject` / `Signal` / `@Slot` / `@Property` via `QMetaObjectBuilder` at CTFE — D QObjects with
  own signals/slots/properties (qmlRegisterType-capable).
- Signals/slots → D delegates; subclass **virtual-override trampolines** (model/view, paintEvent, …).

## uic — CTFE (60 baseline forms pass the differential oracle)
- `mixin(uiForm(import("x.ui")))` → typed `Ui_` struct. Generic property engine; layouts
  (box/grid/form + margins); QMainWindow chrome (menus/toolbars/actions/statusbar); tabs/stacked;
  button groups; tab order; font/sizePolicy/palette; icons; shortcuts; buddies; `<connections>` +
  `connectSlotsByName`; **tr() translation**.
- **Corpus 60/60** vs QUiLoader (differential oracle). Targets: `uicheck-*`, `corpus-check-*`.
- Spec: `docs/uic-spec.md`.

## qrc — CTFE
- `mixin(qrcRegister(import("x.qrc")))` → Qt `.rcc` blob registered at runtime (no `rcc` tool).

## Deployment — `qtd-deploy` (`tools/deploy/`)
- **`map`** — the manifest an installer needs, read rather than run: libraries out of `PT_DYNAMIC`
  (ELF) or the import + delay-load directories (PE), so a Windows tree can be mapped from Linux;
  plugins out of Qt's own `Qt6<Mod>*PluginTargets*.cmake` (and the Qt 5 spelling) for the modules
  the binary links, because nothing links a plugin; QML modules out of the app's `import` lines,
  closed over each `qmldir`. What never to bundle is a data file, `tools/deploy/system-libs.txt`.
- **`bundle`** — mirrors the prefix's geometry so Qt's own `$ORIGIN` run paths stay correct, rewrites
  a third-party run path that names the build machine (the `auditwheel` case), and lays PE out the
  other way because a DLL is found beside its executable. Distribution libraries carry no run path
  at all, so the executable's **inherited `DT_RPATH`** is what covers them.
- **QML is the harder half** — modules come from the app's imports, then from each `qmldir`'s
  `depends` / `import` / `optional import` / `default import`, then from the imports inside Qt's own
  QML (`QtQuick.Controls.impl` is in no qmldir), and plugin collection repeats to a fixed point
  because a QML plugin brings Qt modules with it. Every declared Controls style ships (`--qml-style`
  narrows): the style is picked at run time by `QQuickStyle`, and here the qmldir says Basic while
  Fusion is what loads.
- **`deploy-bundle-{ldc2,dmd}`, `deploy-qml-{ldc2,dmd}`** assert the bundle *resolves*: started from
  elsewhere with the environment cleared, `LD_DEBUG=libs` shows 0 libraries from the system and the
  platform plugin coming out of the bundle.

## Exceptions
- C++/Qt exception → D `QtCppException` (Lippincott + **per-signature guards**, complete coverage);
  error-return wrappers for out-param errors (bad JSON/PNG). Gated by `"exceptions"`.

## Consuming the binding (what a user meets, not what the tests meet)

- **Contract**: one import path (`generated/<qt>/<binding>`) + two archives (`libbinding_<dc>.a`,
  `libshims.a`) + Qt's own libs. Gated by `consumer-smoke-{ldc2,dmd}`, which builds an application
  in a temporary directory outside the checkout.
- **Construction**: `new QWidget(null)` and `new QWidget()` both work — the adopt ctor takes a
  `QtdAdopt` tag precisely so a literal `null` is not ambiguous with a parent argument.
- **`QString`**: constructs from a D `string`, `toString()`s back to one, and compares with `==`
  against one. Value semantics are Qt's (CoW, refcounted).
- **Multiple inheritance**: D has one base, so a secondary C++ base is an explicit upcast —
  `w.asQPaintDevice().width()`, not `w.width()`. This is the one place the surface does not read
  like Qt's documentation, and the manifest's `inherited` fate does not point at it.
- **As a package**: `tests/install.sh` lays the artifacts out as a dub package (one `dub.json`,
  both compilers via `lflags-ldc`/`lflags-dmd`) and `dub-consumer-{ldc2,dmd}` resolves it by name.
  Not published anywhere and not versioned against the Qt minor — that part is distribution.
- **Ownership**: a pointer Qt RETURNS is borrowed; a generated constructor owns what it allocated;
  a declared transfer moves ownership at the call (`transfer_in`/`transfer_out`/`ctor_parents`).
  A class in `disposable` is freed by the binding when it still owns it — only `QTreeWidgetItem`
  today, because its destructor detaches itself from its owner and most item classes' do not.
  `ownership-gate-*` fails the build if any method taking a disposable type is unclassified.

## Build / platform
- reggae binary backend; ldc2 + dmd; Qt5 + Qt6 parity; à-la-carte binaries.
- Windows/MSVC-x64: the same 1199 targets as Linux, measured on a VM against Qt 6.11.1 and
  Qt 5.15.2 with ldc2 and dmd — see `docs/windows-roadmap.md`. Two things stay platform-shaped:
  the coverage baselines are per (platform, Qt) pairing (`tests/coverage/*.windows.manifest.tsv`),
  and C++ exceptions reach D by a different route there — the guard stores and the D forwarder
  raises, because dmd's Win64 unwinder walks an RBP chain the MSVC target does not keep. Both
  compilers take that route on Windows, and `uicheck` reports the same `EXC` verdict on both
  platforms and both compilers.

## In progress / next
- **Flip the last two specs**: WebEngine and `corpustypes` still generate without the wrapper. They
  are the only remaining raw-path consumers now that `spec_cxx_qtwidgets{,_qt5}.json` and the QML
  family are wrapper-mode.
- **`tests/expected-fails.json` is linted AND partly executed**: `expected-fails-lint` checks
  schema, unique ids, known kinds and that named probe targets exist; `expected-fails-run` now RUNS
  those probes and fails if a documented risk stops being covered (14 targets today). What is still
  missing is unexpected-PASS detection — that needs each entry to declare whether its probe should
  pass or fail, and `remove_when` is still prose nothing evaluates.
