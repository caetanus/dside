# qt-dlang-gen — Feature Summary

Pure-D Qt bindings generated as `extern(C++)` (no C++ wrapper shim). The generator
(`generator-d/`, builds `gend`) parses Qt headers via libclang and emits per-class `.d` plus
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

## Exceptions
- C++/Qt exception → D `QtCppException` (Lippincott + **per-signature guards**, complete coverage);
  error-return wrappers for out-param errors (bad JSON/PNG). Gated by `"exceptions"`.

## Build / platform
- reggae binary backend; ldc2 + dmd; Qt5 + Qt6 parity; à-la-carte binaries.
- Windows/MSVC-x64: deferred — see `docs/windows-roadmap.md`.

## In progress / next
- **Flip the last two specs**: WebEngine and `corpustypes` still generate without the wrapper. They
  are the only remaining raw-path consumers now that `spec_cxx_qtwidgets{,_qt5}.json` and the QML
  family are wrapper-mode.
- **`tests/expected-fails.json` is a linted INVENTORY, not a runner**: the linter checks schema,
  unique ids, known kinds and that named probe targets exist. Nothing evaluates `remove_when`, so a
  gap that has been closed can stay listed and no gate objects.
