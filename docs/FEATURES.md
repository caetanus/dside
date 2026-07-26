# qt-dlang-gen — Feature Summary

Pure-D Qt bindings generated as `extern(C++)` (no C++ wrapper shim). The generator
(`generator-d/`, builds `gend`) parses Qt headers via libclang and emits per-class `.d` plus
minimal `.cpp` trampolines; reggae owns all compilation. Verified on **ldc2 + dmd**, **Qt5 + Qt6**.

## Core binding (generator)
- **extern(C++) codegen** — per-class modules, à-la-carte (`--gc-sections` drops unused shims).
- **Construction** — object types: `new QWidget(parent)` (idiomatic D). Value types:
  `QColor(r,g,b,a)` (struct ctor) or `make!QVariant()` (justified no-arg factory — D forbids a struct
  no-arg `this()` and a CoW `.init` is a null d-pointer). **`X_new(...)` is UNACCEPTABLE** — never a
  factory named `Foo_new`. Done: value types (all modes) and objects in wrapper mode. Raw-path
  objects still carry `_new` until wrapper mode becomes the default.
- **Types** — value types (correct sizeof/ABI, incl. CoW non-trivial like QIcon/QFont); enums
  (incl. 2-part `Qt::X` via a `qt` aggregator + `Class::X`); containers (`QList`↔`T[]`, QHash/QMap);
  multiple inheritance (secondary-base upcasts); forward iterators → D ranges (`foreach (x; t[])`).
- **`const ObjectType&` params** bound (a reference is ABI-a-pointer).
- **Overridden virtuals** dispatch correctly via the C++ method shim (simple **and** value returns,
  e.g. `sizeHint`); only container/QList-return virtuals remain non-virtual.

## Memory / lifetime — GC wrapper (`"wrapper": true`, gated; legacy raw path is default)
- **QtdObject** wrapper layer (`runtime/holder/`): nullable `_cpp` + `checkAlive` (destroyed object
  throws, no segfault); C++-side identity map; **parenting-pins** (a parented child is a GC root);
  `destroyed()` invalidation; GC finalizer → `deleteLater` for D-owned objects; runtime reparent
  detection. Works incl. moc/subclass trampolines. Functionally complete; still gated.

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
- **Kill `X_new` — front #2**: make the GC-wrapper path the DEFAULT so raw-mode objects also
  construct with `new`. (Front #1 done: value-type `make!Foo`, and wrapper-mode objects `new X`.)
  Literal `new` is unsafe in the raw path (D `new` GC-allocates the object; Qt would C++-`delete` a
  GC block), so the fix is to flip `spec_cxx_qtwidgets{,_qt5}.json` + webengine to `"wrapper": true`
  and migrate the committed cxx-path tests (cannon_t1..9, qlist_roundtrip, container_qvector).
