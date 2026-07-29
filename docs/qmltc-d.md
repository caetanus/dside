# qmltc-d — a QML → D compiler

qmltc-d is our analog of Qt's `qmltc` (which compiles `.qml` to C++ classes): it compiles a
`.qml` document to **D**. The generated D `@QObject` types use the `qtmoc` runtime, so
instantiating a compiled type reproduces the QML object **without the QML engine interpreting the
document at runtime** — the same idea as `qmltc`, targeting D instead of C++.

Source: `tools/qmltc/qmltc_d.cpp` (the compiler) and `tests/qmltc/qtd_qmlvalues.cpp` (the oracle).

## Frontend

The parser is **Qt's own private `QQmlJS`** (`qqmljsparser_p.h` / `qqmljslexer_p.h` /
`qqmljsast_p.h`). `QQmlJS::Parser::parse()` yields one unified AST covering both the QML object
tree AND the JS binding/handler expressions as sub-ASTs. This is exact QML semantics with zero
grammar divergence and no new toolchain dependency (the project already links Qt and uses its
private API, e.g. `QMetaObjectBuilder`). `QQmlJS` exists in Qt5 too, so the frontend is dual-Qt.

Over the upstream `qmltc` test corpus (108 files) the frontend parses **108/108** with no errors.

## Backend model

qmltc-d is a build-time tool (like `gend`/`qmltc`), not a CTFE mixin: CTFE can't drive an external
parser, and QML+JS is too complex for clean CTFE. It emits a D module: one `@QObject class` per
object, with `@Property` fields, `Signal!()` change signals, `@Slot` recompute/handler methods, and
a `__qmltcWire()` method the runtime calls after wiring (see below).

## Differential verification

Every fixture is checked like the uic `corpus-check`: a **differential** against the real engine.

- `qmltc-d --dump` emits the class(es) plus a `main` that instantiates the root, optionally applies
  `name=value` mutations (via the meta-object, so writes fire NOTIFY and live bindings re-evaluate),
  and prints every scalar property — with **dotted paths for children** (`kid.y`) — sorted.
- The oracle (`qtd_qmlvalues`, public `QQmlComponent`) loads the same `.qml`, recurses the object
  tree via `QMetaProperty` (descending into `QObject*` child properties), and prints the same lines.
- The two dumps must be **byte-identical**, statically and — with a `<Name>.set` sidecar — after a
  mutation. Reggae targets: `qmltc-<Name>-<dc>` and `qmltc-<Name>-set-<dc>`, on ldc2 AND dmd.

The oracle is the source of truth: it has already rejected an invalid fixture (an alias not routed
through an `id`), which is exactly the guard we want.

## Supported (all differential-green on ldc2 + dmd)

- **Object tree**: a root object and nested child objects (`property Type kid: Type { ... }`),
  each compiled recursively to a nested `@QObject` held in a plain field and built in `__qmltcWire`.
- **`id`** and self member-access (`root.x` resolves to property `x`).
- **`property alias`**: self targets (`root.x`) are reactive; child targets (`kidObj.y`, via the
  child's id) read the child's value once it is built.
- **Property types**: `int`, `string`, `bool`, `real`/`double` (literals).
- **Bindings** — the expression compiler handles: identifiers, string/number/bool literals, unary
  `-` and `!`, parentheses, `+ - * / %`, comparisons (`< > <= >= == !=` and the strict forms),
  ternary `c ? a : b`, logical `&& ||`, string concat (`+` → `~`), int/double coercion
  (`(a+b)/2.0` is double division), `<string>.length`, and `Math.max/min/abs`.
- **Live (reactive) bindings**: each binding's dependencies are tracked; a dependency's change
  re-evaluates the binding. Implemented with a NOTIFY signal per bound/depended-upon property, an
  `@Slot __rc_<name>` recompute, and connections set in `__qmltcWire`. The runtime hook is one line
  in `qtmoc.wireQObject`: `static if (__traits(hasMember, T, "__qmltcWire")) o.__qmltcWire();` —
  inert for every hand-written `@QObject`.
- **Signal handlers**: `on<Prop>Changed: <stmt>` becomes an `@Slot` connected to the source
  property's change signal; the body may be a single statement or a brace block.
- **`Component.onCompleted`**: its body runs at construction (tail of `__qmltcWire`).
- **`function`s** with a **type-inference layer**: a QML function becomes a D method. A
  parameter's type must **reduce to a definite type** — from body evidence (a concatenation makes
  it `string`), or from its **call sites** (`function times2(n){return n*2}` with `times2(base)`
  and `property int base` gives `int times2(int n)`). Where nothing reduces it, the function is
  **refused with a diagnostic**, not guessed: `f(x,y){return x+y}` was previously emitted as
  `double f(double,double)`, which is simply wrong for `f("a","b")` — QML concatenates there and
  the generated D would add. Call sites that disagree poison the slot and refuse for the same
  reason. Qt declines the identical shape ("Functions without type annotations won't be
  compiled"); being incomplete is recoverable, being silently wrong is not. The return type is
  inferred bottom-up from the parameter types once they are known. A call in a binding is coerced to the target property (`property int d:
  half()` -> `cast(int)(half())`) and is reactive through its arguments. Void functions
  (assignments/calls) and `return`-bodied functions are both supported.
- **Qualified imports**: `import QtQuick.Templates as T` makes the type `T.Button`. The qualifier
  names the IMPORT, not a scope of the type, so it is stripped wherever a type name is read — but
  only when the prefix is a DECLARED alias. Critically, a name that arrived QUALIFIED must never
  then resolve to a local `.qml` file: Qt's own Controls put `Basic/CheckDelegate.qml` right next
  to a root written `T.CheckDelegate`, and resolving that locally gave the root NO Qt base at all
  while also suppressing the "unbound root" diagnostic (a resolved local path is what that check
  tests). Stripping without this guard reported 4 unresolved roots where 46 was the truth.
- **Base-property bindings are reactive**: `width: pad * 10` on a bound base is a BINDING, not an
  assignment. It used to emit a one-shot `setProp` with no connect and no diagnostic, so it kept
  its first value forever while looking correct — the declared-property direction (`inner: width -
  pad`, pinned by QItem) was wired, the reverse was not. It now emits an `__rcb_<prop>` recompute
  slot connected to each dependency's notify, and registers that dependency in needsNotify so the
  signal it connects to actually exists. QBaseReactive pins it: after `pad=7` the engine says
  `width=70`, and the one-shot said `40`.
- **Read-only base properties**: a base property the document only READS was not routable, because
  the map of base properties records only what the document ASSIGNS. The property table knows the
  type either way, so the read now goes through the meta-object like any other. This is what
  `implicitWidth: Math.max(implicitContentWidth + leftPadding, ...)` — the commonest shape in Qt's
  own Controls — was failing on: the operands, not `Math`.
- **The enclosing object (`control.<prop>`)**: Qt's own Controls are written `id: control` on the
  root and then `contentItem: Text { color: control.palette.text }`. A child is a separate D class,
  so it reaches its parent through a generated `__outer` back-reference: a DECLARED property of the
  outer is a typed field (`__outer.gap`), a property of the outer's bound base goes through the
  meta-object (`propDouble(__outer, "width")`) — reading the latter as a field does not compile.
  Bindings that read the outer are wired to ITS notify, and because the parent's emission is what
  creates that signal, the child propagates the requirement up. The back-reference is handed over
  at construction (`__qmltcOuter`) rather than assigned after `new`, because the mixin runs
  `__qmltcWire` at the END of the constructor — assigning afterwards dereferenced null (SIGSEGV,
  confirmed under gdb). `__outer` is always the IMMEDIATE parent; an id further up is reached by
  HOPPING (`__outer.__outer.gap`), and each intermediate carries its own back-reference. Typing
  the field as the id-bearing ancestor instead compiles and then reinterprets the parent as that
  class — `cast(T) someVoidPtr` in D is unchecked, so it reads another object's fields rather than
  failing. The notify requirement travels the same chain: a binding on `__outer.__outer.gap` needs
  the GRANDparent to carry gapChanged. Measured on Qt's Controls: expression failures 349 -> 160.
- **Per-object property tables**: the object's own QML type drives every table lookup. It used to
  be set once at the root, so inside a child every lookup consulted the ROOT's table — a Rectangle
  inside an Item resolved its properties against Item.
- **Value-typed properties copied through the channel**: `font: control.font`, `color:
  control.palette.text` — the two commonest lines in Qt's own Controls. Neither needs the
  generator to know what a QFont or QColor is: the source property is read as a QVariant, which
  CARRIES the type, and QMetaType converts on write (`copyProp` / `copyGroupProp`, one C++ helper
  each). It is emitted as a BINDING, not a one-shot, and that is load-bearing rather than merely
  correct: children are constructed before the parent assigns its own properties, so the first
  copy reads a default and the notify is what corrects it. Declared-type failures over Qt's
  Controls: 263 -> 97. Only a plain property READ takes this path — an arbitrary expression of
  value type is still refused rather than guessed — except a TERNARY between two such reads
  (`color: control.down ? control.palette.light : control.palette.base`, how Qt's Controls pick a
  colour): neither branch can become a D expression, but each is a copy, so the condition picks
  which copy runs and both branches' dependencies are wired. A "group" is either a Q_GADGET value or a
  QObject (`control.palette` is a QQuickPalette OBJECT), and the copy dispatches on what the
  QVariant actually holds: reading an object with readOnGadget reads through a pointer as if it
  were the value.
- **Object groups**: `border.width: 3` on a Rectangle. `border` holds an OBJECT (QQuickPen*), not
  a value, so the write is a plain property write on what the group holds — reached with propObj.
  The distinction is NOT recoverable from the type name (QQuickScaleGrid and QFont look alike): the
  registry marks it with `isPointer`, which the generator now records in the property table as a
  trailing `*`. The member's type comes from the value and QMetaType converts; setProp throws if
  the member does not exist, so a wrong name is loud rather than dropped.
- **A value-typed source into an object group**: `border.color: control.palette.dark`. The group is
  an object, so this is the same QVariant copy a base property uses with the group object as the
  destination. It is a BINDING whose first run is in the LATE phase — a child is constructed before
  its parent assigns anything, so a copy made during the wire necessarily reads a default (measured:
  #b8b8b8 where the engine had seagreen).
- **Value groups that are plain gadgets**: `icon.width: 24`. QQuickIcon has its own meta-object,
  so setVgroup does a read-modify-write through it. What made this safe to enable is telling it
  apart from the case below at COMPILE time — see the `^` marker.
- **NOT supported: `font.pixelSize: 22` on a bound type.** It looks like it should work through
  the same channel — resolve the member by name at runtime, let QMetaType convert — but QFont is
  not a Q_GADGET: `QMetaType::metaObjectForType` finds nothing for it, because QML reaches font
  members through a FOREIGN value-type wrapper (QQuickFontValueType), not the plain meta-object.
  Emitting the call converted a compile-time partial into a construction-time throw, so it stays
  refused — and it is now refused BY DATA rather than by guesswork: the registry says
  `extension: "QQuickFontValueType"` on QFont and says nothing on QQuickIcon, so the generator
  records a `^` on extension-backed value types and qmltc-d routes on it. `setVgroup` now THROWS when the member does not resolve, rather than dropping the
  assignment and leaving a default that looks deliberate — which is how this was caught.
- **Enum properties by KEY**: `verticalAlignment: Text.AlignVCenter` is written as the string
  `"AlignVCenter"` and the meta-object converts it through QMetaEnum — the numeric value never has
  to be known here, which is the same reason a QColor literal works. Recognised as `Type.Member`
  where Type is a bound QML type that is not an object in scope, and Member is capitalised.
- **Diagnostics quote the expression they refused.** Reading a cluster otherwise meant matching a
  property name back to a source line, which picks the FIRST occurrence — the root's — even when
  the failure is in a child. Snippets are resolved against the document the node came from, since
  one global text is wrong the moment a local `.qml` is loaded.
- **`parent.<prop>`**: the centring idiom (`x: (parent.width - width) / 2`). It resolves to the
  same back-reference an enclosing id uses, NOT to `propObj(this, "parent")` — Qt sets the parent
  after construction while the wire runs inside the constructor, so fetching it there reads null.
  A child's visual parent is its enclosing object (Qt reparents contentItem/background to the
  control too), and routing it this way inherits the ordering, hop and notify handling that is
  already correct. A child reparented at runtime, or built by a Repeater, is not compiled at all,
  so the assumption cannot silently drift.
- **Enum comparisons**: `control.checkState === Qt.Checked`. The numeric value is not knowable
  here, but an enum property read as a STRING gives its KEY (QVariant::toString goes through
  QMetaEnum) and the member's key is its own name — so the comparison is done on keys, needing no
  table of enum values. An enum member is also a CONSTANT, so the type name in `Text.AlignHCenter`
  is no longer recorded as a dependency (it reported a dead dependency on an object called `Text`).
- **The LATE phase**, and `control.indicator.width` with it. A scalar reached through an
  object-valued property cannot connect at wire time: the object does not exist yet (a Control
  creates its indicator during completion), and connecting to `indicatorChanged()` instead would
  only fire when the indicator is REPLACED — an under-reactive binding that looks live. Each class
  now emits `__qmltcLate()` holding the connects that need a finished tree, every level forwards it
  to its children, and the ROOT fires it at the end of its own wire — the one point where the whole
  tree is constructed and every componentComplete has run. Emitted only where there is work to do.
- **Property-bound children are ASSIGNED to their property.** `contentItem: Label {}` created the
  object and gave it a Qt parent but never set `contentItem`, so the Control's own contentItem
  stayed NULL and anything Qt computes from it was computed from nothing. The differential missed
  it because it reads OUR D field while the engine reads ITS object — both configured identically —
  instead of asking the control. Found only because a deep read through `control.indicator` came
  back null.
- **LINKAGE CHECKS in the dump.** Two bugs got past this differential because both sides compared
  objects that were configured identically — ours simply was not ATTACHED to anything (a
  property-bound child never assigned to its property; a visual child with no item parent). Reading
  our own D field can never see either. The generated dump now asks QT whether each child is where
  the document says it is: an item child must have the right `parent`, and a child bound to a
  property of the root's BOUND type must be reachable through that property. Guarded by `hasProp`,
  since only an Item has `parent` and a QtObject sitting in `data` legitimately does not. Verified
  to FAIL when the fix is removed, and it immediately found a third case (a local `.qml` Item child
  was not item-parented either).
- **Visual children get an ITEM parent.** QQuickItem tracks visual parentage through parentItem,
  which is a different link from the QObject parent: `setQtParent` alone left it null, and an item
  with no parentItem is not in a scene, so writing `visible = true` on it silently does not take
  (probed directly: set false, then true, and it stays false). This is what the `visible` gap
  recorded here actually was — the binding was fine, the parentage was not. Anchors, layout and
  `parent` reads depend on the same link.
- **`Math.max`/`Math.min` are variadic**: three arguments (which Qt's Controls use) were refused,
  and the two-argument form was emitted as `a > b ? a : b`, evaluating each operand TWICE — every
  operand here being a meta-object read. Both now go through std.algorithm's variadic max/min,
  imported under a private alias so a QML property named `max` cannot collide.
- **Numeric coercion**: `inferType` follows JS/QML (division is always `double`, `+` with a string
  is concatenation), and narrowing to an `int` property inserts a `cast(int)`.

Fixtures (`tests/qmltc/corpus/`): Scalars, Mixed, HelloWorld, Computed, Logic, Bools, Handler,
Ided, Nested, Aliased, Exprs, ChildAlias — 12 files, each static + dynamic on both compilers.

## Honest coverage and scope

Measured over the upstream `qmltc` corpus (108 `.qml`):

- **66 / 108 import `QtQuick`** — visual types (`Item`, `Rectangle`, `Text`, …). The **bound-type
  backend** compiles these as D subclasses of the bound Qt type (`Item`→`QQuickItem`,
  `Rectangle`→`QQuickRectangle`, `Text`→`QQuickText`; the latter two are private-API, discovered via
  additive private-header scanning), with base props (int/string/real incl. `QColor`), custom
  reactive bindings, default children, base props of type int/string/**real**/**bool**
  (`opacity: 0.5`, `clip: true`), **object-typed properties** (`property QtObject o: QtObject {}`),
  the visual types **TextEdit/TextInput/MouseArea** (private API), and **cross-file local `.qml`
  types** (a
  `Foo {}` that resolves to a sibling `Foo.qml`, as both root and child, with use-site member merging
  + override dedup). **7 / 66 are diff-GREEN vs the engine on ldc2+dmd**, and — the key honesty
  guarantee — the tool's own compile-clean count EQUALS this build+diff green count: every file
  qmltc-d reports FULL genuinely diffs green, no silent-wrong emissions. (Guards added to keep this
  true: an unmapped app-C++ root, a `Type on prop` value source, a custom `default property` with
  bare children, a value-returning function with an unresolved return type, and an **identifier
  that resolves to nothing the generated class defines** — a `Repeater` delegate's `index`, a
  context or attached property — all flag PARTIAL.) Cross-file local types are essential to several (`ComponentWithAlias3`,
  `myMatryoshkaItems`, `myCheckBox`, `MyBaseItem`, `LocallyImported`). Each further delta
  (`QtObject`-typed object props, custom `default property list<>` semantics, animations/value-sources,
  more type maps) unlocks ~1 file.
- **42 / 108 are pure QtQml.** Of these, qmltc-d compiles **16 fully** (all 16 build+diff
  verified — see the scoreboard below) as functions, enums, signals, `++`/`--`, `+=`,
  `if`/`else`, `console.log` and function-expression handlers landed.
  **~17 of the 42 are rooted in an app-defined type** (`QmlGroupPropertyTestType`, …). The QtObject-rooted
  files left each need a distinct niche (`Qt.binding`, cross-object member access, `= undefined`,
  external JS imports, `QtObject`-typed signal params).

### App-defined types are NOT a language boundary

An earlier version of this document called the app-defined-type files a *structural* ceiling — "the
corpus is about C++ types, which a generic backend can't bind". **That was wrong.** QML resolves a
type through its **meta-object**; the language that produced it is irrelevant — C++, D, Python
(PySide), JS all register the same way. Concretely, this repo already has BOTH ways in:

- **Bind the app's C++ headers.** That is the generator's primary use case, not an exception:
  `generator/spec_userlib.json` is headers-mode (`headers` + `source_filter`) over an arbitrary
  user header. Pointing a spec at the corpus's own `QmltcTests/cpptypes/*.h` (21 `QML_ELEMENT`
  types across 13 headers) is a spec, not new machinery.
- **Write the type in D.** `@QObject` + `@Property` + `Signal!` + `@Slot` builds a runtime
  meta-object (`QMetaObjectBuilder`, CTFE) and `qmlRegisterType!T` registers it — covered by the
  `qmlreg`/`qmltwo`/`homonym` targets. `qmlTypeComponent!T` (qtmoc.d) even emits the `.qmltypes`
  description of a D type, validated by Qt's own reader (`qmltypes-check-*`).

What actually blocks those files is **QML registration semantics qmltc-d does not implement yet** —
grouped properties, attached properties, singletons, `required`, deferred and extension types. That
is a feature backlog, not a ceiling.

### Compiling a .qml against a D-defined type (DONE)

The app-type registry gap is closed, and it is a THIRD backend alongside fresh-`@QObject` and
bound-Qt-subclass — targets `qmltcd-<Name>-<dc>` over `tests/qmltc/dtypes/`, green on ldc2 and dmd:

```qml
import AppTypes 1.0            // apptypes.d: @QObject class Backend { @Property("valueChanged") int value; … }
Backend {
    value: 21
    label: "hi"
    property int doubled: value * 2
}
```
```d
@QObject class DBasic : Backend {                  // plain D inheritance — no trampoline, no mixin
    @Property("doubledChanged") int doubled;
    Signal!() doubledChanged;
    @Slot void __rc_doubled() { auto _v = (value * 2); if (doubled != _v) { doubled = _v; doubledChanged.emit(); } }
    void __qmltcWire() {
        value = 21;                                // an inherited @Property is a REAL FIELD
        label = "hi";
        __rc_doubled();
        connectMeta(this, "valueChanged()", this, "__rc_doubled()");   // notify name from the registry
    }
}
```

Three things make this work, none of them a special case:

- **The registry is the type's own `.qmltypes`**, emitted from the D type by CTFE
  (`qmlTypeComponent!T`) and validated by Qt's own reader. It is itself a QML document, so qmltc-d
  parses it with the SAME QQmlJS frontend it already uses — no new format, no new parser.
  `--dtypes <registry> <d-module>`; the module is a build input (the format has no field for it).
  A base property's notify signal comes from the registry, so the `<prop>Changed` spelling is
  never assumed.
- **The oracle is still the real QML engine.** `qtd_qmlvalues_d.d` registers the D types with
  `qmlRegisterType` and hands over to `qtd_qmlvalues_main` — the same walk/format/dump the C++
  oracle always ran. Only the type's implementation language changed.
- **One list of types drives both sides** (`AppQmlTypes` in `apptypes.d`), so the registry cannot
  drift from what is registered.

The D case is strictly *simpler* than the bound-Qt one: no generated C++ trampoline, no
`mixin QtdWidget!Base`, and no meta round-trip for base properties — `__traits(allMembers)` already
flattens inherited `@Property`/`Signal`/`@Slot` into the subclass meta-object. The `<Name>.set`
sidecars mutate both sides and re-diff, proving bindings stay live *through the base type's own
notify signal*.

Two real runtime bugs surfaced and were fixed here — see "Bugs this found" below.

### Compiling a .qml against a C++ type from Qt's own corpus (DONE)

The same thing with the type's language swapped — targets `qmltcc-<Name>-<dc>` over
`tests/qmltc/cpptypes/`, green on ldc2 and dmd. The types there are **verbatim copies from Qt's
qmltc corpus** (`TypeWithManyProperties`, `TypeWithProperties`, `TypeWithSpecialProperties`, …),
vendored the way `tests/uic/corpus/` vendors Qt's `.ui` files. We wrote none of them.

The pipeline over them is **Qt's own**, not a reimplementation:

```
moc --output-json  ->  qmltyperegistrar  ->  { registration .cpp , .qmltypes }
```

The registration `.cpp` goes into the ORACLE so the engine can instantiate the types (linked with
`--whole-archive`: the registration is a static `QQmlModuleRegistration` nothing references, and a
plain archive link drops it — the engine then reports *module not installed*). The `.qmltypes` is
the registry qmltc-d reads via `--cpptypes`. It is the same registry code path as `--dtypes`; only
the backend differs:

| registry says | backend | base property access |
|---|---|---|
| a D type | `@QObject class X : Base` — plain D inheritance | inherited field, direct |
| a C++ type | `mixin QtdWidget!Base` — the generator's trampoline | through the meta-object |

The binding for those headers is `spec_cxx_corpustypes.json` in **headers-mode**, which is the
generator's primary use case, not a special mode (`spec_userlib.json` is the same shape).

**Adding a corpus type really is just a header.** Going from 4 vendored headers to 10 (21 bound
classes, 20 registry entries) took no per-type code — only spec `headers` entries, the matching
moc list, and Qt's private include dirs (one corpus header includes `<private/qobject_p.h>`). The
count of pure-QtQml files failing with *"root type is not a bound Qt type"* fell **9 → 2**, and
one of those two is `badFile.qml`, invalid on purpose.

**And it bought zero new green files — honestly reported.** Binding the TYPE is not the blocker
any more; the per-type QML *semantics* are. What each now stops on:

| file | blocker |
|---|---|
| `PrivateProperty` | a private-API property accessor |
| `NamespacedTypes` | a function body form we don't compile |
| `specialProperties`, `propertyAliasAttributes` | alias onto a base property with **no NOTIFY** (refused, see above) + `undefined`/RESET |
| `mySignals` | `font`/`QtObject`-typed properties |
| — | `QML_EXTENDED` no longer blocks a file that doesn't use the extension (see below) |

### QML_EXTENDED, scoped to what it actually breaks

`QML_EXTENDED(Extension)` grafts another object's members onto a type. We don't build that object,
so those members are not ours to emit — but the TYPE still is. Refusing every `.qml` rooted in such
a type was too blunt: both corpus files that use one never touch the extension at all.

So the extension's members are marked unusable **by name**, taken from the extension's own
Component, and inherited down the `prototype` chain (`TypeWithBaseTypeExtension` declares no
extension but derives from one that does). Touching one is an honest PARTIAL:

```
base property 'count' in X has an unsupported declared type — skipped (later phase)
```

while a file that only uses the type's own members compiles. **`QmlTypeWithExtension.qml` and
`QmlTypeWithBaseTypeExtension.qml` are both GREEN.**

The registry fold-in that made this precise also fixed something broader: a Component lists only a
type's OWN members, so a base property was previously invisible to the registry and fell back to
literal inference. The `prototype` chain is now folded in — property types, notify names, signal
signatures and groups all inherit.

Two things the registry buys that literal inference cannot: the declared **type** of a base
property, and its real **notify signature**. `TypeWithProperties::d` notifies with
`dSignal(QString,int)` — connecting it as `dSignal()` matches nothing and leaves the binding
silently dead. The `.set` differential caught exactly that.

**Honest corpus effect.** Over the 42 pure-QtQml corpus files, the count that fails with *"root
type is not a bound Qt type"* drops **9 → 7**. `propertyAliasAttributes` and `specialProperties`
now fail on a FEATURE instead (`property alias` onto a base property) — the language barrier is
gone for them. The remaining 7 root in types we have not vendored yet (`QmlGroupPropertyTestType`,
`TypeWithExtension`, …); reaching them is adding headers to the spec, not writing code.

### `property alias` onto a base property

An alias may now target a property of the base type, not just one declared in the same object —
`property alias xyAlias: root.xy` on a C++ base, `property alias valueAlias: root.value` on a D one.
Reading goes through the one name-resolution path (`readName`): a plain field for a D base, a
meta-object read for a bound C++ one. Fixtures `CAlias.qml` / `DAlias.qml`, both `.set`-mutated.

**A QML alias is a REFERENCE, and it is now compiled as one** — as a compile-time alias, not a
property. Nothing is stored: a read goes straight to the target, a write lands on it, and a binding
that uses the alias depends on the TARGET, whose reactivity already exists.

That removes a whole class of problem rather than guarding against it. The earlier model compiled
an alias to a recomputed COPY, which is only faithful while something re-evaluates it — so an alias
onto a property with **no NOTIFY** (`Q_PROPERTY(int x MEMBER m_x)`) had to be refused, since a later
write would leave the copy stale. As a reference there is nothing to go stale, and the engine's own
behaviour follows for free: in `CAliasWrite.qml` a binding over such an alias does NOT re-evaluate
after a write — and neither does the engine's, because the target has no NOTIFY to fire.

Across the corpus this took alias blockers from 29 occurrences (17 "target unsupported" + 12
"no NOTIFY") down to 5.

Wiring order changed to make this work: connections are now established BEFORE the initial binding
pass. Bindings are recomputed in declaration order but aliases are appended after declared
properties, so `property int n: someAlias + 1` used to be computed while the alias still held 0.
With connections already live the evaluation propagates instead, and recomputes are idempotent
(each emits only on a real change), so the extra passes settle rather than loop.

### Grouped properties

`Q_PROPERTY(TestTypeGrouped *group READ getGroup)` is addressed from QML with dotted syntax. The
group is a real child object reached through the parent's meta-object, so its members are ordinary
properties on it — `qtmoc.propObj` returns it and the member is set/read from there:

```qml
QmlGroupPropertyTestType { group.count: 42; property int mirrored: group.count }
```
```d
setProp(propObj(this, "group"), "count", 42);
auto _v = propInt(propObj(this, "group"), "count");
```

The registry identifies the group: a non-scalar property whose declared type names another
Component in the same `.qmltypes` is a group, and that Component supplies its members' types. (The
`isPointer: true` flag is a boolean literal, not a string, so membership is the reliable test.)

Handlers ON the group work too — the signal belongs to the group object, the slot to this one, and
the signature comes from the group class's registry entry rather than being assumed to be a
parameterless `<prop>Changed`:

```qml
group.onCountChanged: { seen = seen + 1; group.str = "changed" }
```
```d
@Slot void __hg_group_countChanged() {
    seen = (seen + 1);
    setProp(propObj(this, "group"), "str", "changed");
}
// in __qmltcWire:
connectMeta(propObj(this, "group"), "countChanged()", this, "__hg_group_countChanged()");
```

A statement body can also write a group member, increment one (`group.count++` — a
read-modify-write, since there is no D lvalue), and emit a signal belonging to the group
(`group.triggered()`, via the new `qtmoc.invoke0`). Fixtures `CGroup.qml` and `CGroupHandler.qml`.

A CHILD object can be bound into a group member (`group.object: QtObject { … }`): the child is
built in D and attached THROUGH the group with `setPropObj`. Its D field cannot be named after the
dotted path (`class X_group.object` is not valid D), so the field and the QML path the oracle walks
are tracked separately — the same field-vs-label split that mutation targets already needed.
A binding that READS a group member is reactive too: the dependency is kept dotted
(`group.count`), and the wire connects the GROUP's notify rather than looking for a property of
this class. Fixture `CGroupChild.qml`.

**With that, `groupedProperty.qml` from Qt's corpus compiles and diffs GREEN** — the first corpus
file rooted in an app-defined C++ type to do so.

One thing this exposed: the value-DUMP and the MUTATION target are not the same expression. A
child object is a D field chain (`o.kid`), a grouped property is a meta-object hop
(`propObj(o, "group")`), and deriving the mutation target from the dotted label got the latter
wrong. Each dump line now carries its mutation target explicitly.

### `prop: undefined` is a RESET

In QML `x: undefined` does not assign a value — it calls the property's RESET method. It is
emitted as `resetProp(obj, "x")`, and that must go through **`QMetaProperty::reset`**: a
`Q_PROPERTY` RESET method is an ordinary member, not a slot or `Q_INVOKABLE`, so invoking it by
name finds nothing and silently does nothing. (The first implementation did exactly that and the
diff caught it — the property kept its assigned value where the engine had `"reset"`.)

A property with no RESET is a PARTIAL, since there is nothing to call. Works through an alias too,
in both the declarative and the statement form. Fixture `CReset.qml`; `specialProperties.qml` from
the corpus is green because of it.

### `qsTr`, and a group is a QObject — not merely another type

`qsTr("…")` compiles to `translate("<file base name>", …)`. QML's translation context for a
document is the file's base name, so the compiled call resolves against the same context the
engine would use; with no translator covering the string Qt returns the source either way.
Fixture `Tr.qml`; `newLineTranslation.qml` from the corpus is green because of it.

An alias target may also be written through the object's own id — `root.group.str` means what
`group.str` means — which `PrivateProperty.qml` uses.

That file also produced the session's one **SEGFAULT**, and it is worth recording why. A grouped
property was identified as "a non-scalar property whose type names another Component". But
`Q_PROPERTY(ValueTypeGroup vt ...)` also names another Component and is a **value type** — there is
no object behind it. `propObj` returned null and `setProperty` on null crashed. Two fixes, both
needed:

- **`isPointer` is the real test**, and it is a boolean literal — the registry field reader only
  looked at string literals, which is why the flag had been dismissed as unusable earlier. It reads
  booleans now, and a value-type group is an honest PARTIAL.
- **Every property helper in the runtime is null-guarded.** Reaching for an object that isn't there
  must be a visible no-op, never a crash inside Qt.

### Attached properties

`TestType.attachedCount: 42` addresses the object `TestType` attaches to us. The type is resolved
**by name in Qt's own QML type registry**, so nothing about it is hard-coded — and the attached
object is fetched with **`qmlAttachedPropertiesObject`**, not the raw attach function: the raw one
*constructs a new attachment on every call*, so writing then reading saw two different objects and
every value came back as its default. Assignments, handlers (`TestType.onAttachedCountChanged`),
writes/increments/emits through the attachment, children bound into an attached member, and
reactivity of a binding that reads one are all supported. Fixture `CAttached.qml`;
`AttachedProperty.qml` from the corpus is green.

Two things this needed beyond the compiler:

- **A compiled document registers the module itself.** Attached lookup goes through the QML type
  registry, and a module's registration is *lazy* — nothing materialises it without an engine
  importing the module. The generated code calls `qml_register_types_<uri>` (which
  qmltyperegistrar emits) when, and only when, the document uses an attached property.
- **The oracle learned to walk an attached path segment** (`--attached-uri`), since `TestType` is
  not a property of anything.

`attachedPropertyDerived.qml` stays PARTIAL: it inherits attached assignments from a local `.qml`
base, and the engine does *not* re-apply the base's attached bindings to the derived object's
attachment. Rather than emit a plausible-but-different value, that case is refused.

### QML singletons

A sibling `.qml` with `pragma Singleton` compiles to its own D class plus a lazy one-instance
accessor, so `SingletonFixture.integerProperty` is an ordinary read. Fixtures
`SingletonFixture.qml` + `UsesSingleton.qml`.

**`pragma Singleton` alone does not make a type usable** — QML resolves the name through a
`qmldir` entry, and a document using an undeclared singleton does not load at all. So qmltc-d
requires the `qmldir` declaration too. That is why `singletonUser.qml` from the corpus stays
PARTIAL: the corpus ships no `qmldir` (Qt's own test generates one from CMake), and compiling a
file the engine itself rejects would be compile-clean with nothing to compare against.

### A single-object `default property`

`default property QtObject child` takes exactly one bare child, and that child IS the property's
value — the engine reaches it through the property, not through `children()[0]`. So it stays on
the default-child path (which is what resolves the child's own type, local or bound) and only its
DUMP LABEL changes, from `@0` to the property's name. Fixtures `DefaultHolder.qml` +
`UsesDefault.qml`.

A `list<>` default property works the same way, one step further: the children go INTO the list,
so the engine reaches them at an INDEX and the label becomes `<prop>[i]`. The oracle learned to
walk such a segment through `QQmlListReference`. Fixtures `ListHolder.qml` + `UsesList.qml`;
`defaultProperty.qml` from the corpus is green, grandchildren included.

(`list<QtObject>` keeps `list` in the AST's `typeModifier`, not in the type name — testing the
name for `list<` matched nothing and silently kept the old PARTIAL.)

Worth noting how the first cut of this was wrong in a way the diff could not catch: routing the
bare child through the ordinary property-child path lost the child's TYPE, so the child compiled
as a bare `QtObject` and **vanished from the dump entirely**. The diff was green — because both
sides were then compared on fewer properties. A differential only proves that what you emit is
right, never that you emitted enough; the label list is part of what has to be reviewed.

### `default property alias`, and aliases onto object properties

An alias is a reference, so `default property alias child: self.someObject` means the bare child
lands on **`someObject`** — which is what the engine, and therefore the dump, reaches it through.
The default-property machinery now resolves an alias target to that name. Fixtures
`AliasHolder.qml` + `UsesAliasDefault.qml`.

An alias whose target is an OBJECT property is accepted and emits no dump line: it is a second
name for the very object that property already holds, so it contributes nothing of its own to
compare. Refusing the file over a redundant name would have been the wrong call —
`defaultAlias.qml` and `DefaultPropertyAliasChild.qml` from the corpus are both green.

### `Qt.binding`, and what a plain assignment means

`p2 = Qt.binding(function() { return p1 * 2 })` installs a NEW binding at runtime; `p2 = 42`
**removes** the binding entirely. Both compile to a per-property selector: every recompute —
declarative and imperative — is connected up front and simply returns unless it is the active one,
so nothing has to be disconnected at runtime.

```d
private int __bind_p2 = 0;                       // 0 = declarative, N = Nth install, -1 = none
void rebind() { __bind_p2 = 1; __rc_p2_1(); }
void unbind() { __bind_p2 = -1; p2 = 42; }
@Slot void __rc_p2()   { if (__bind_p2 != 0) return; … }   // `p1 + 1`
@Slot void __rc_p2_1() { if (__bind_p2 != 1) return; … }   // `p1 * 2`
```

Verified against the engine across all three states — declarative, rebound, unbound — and the
unbound one is the point: after `unbind()`, changing `p1` must NOT revive the binding.

Assigning **through an alias** does all of this to the alias's TARGET — `aliasToOrigin = 42`
drops `origin`'s binding, `aliasToOrigin = Qt.binding(…)` installs one on it. The selector lives
on the target, so the reassignment scan runs after the aliases are resolved and looks through
them. Fixture `AliasRebind.qml`; `propertyAlias.qml` from the corpus is green across all five of
its states.

**The differential can now invoke methods.** A mutation argument `name()` calls a no-arg method on
both sides (the oracle via `QMetaObject::invokeMethod`). Without it there was no way to observe
anything a method does, which is exactly where imperative binding changes live. Fixtures
`Rebind.qml` / `Unbind.qml`.

## The differential's blind spot, and the gate that closes it

A differential proves that what the tool EMITTED matches the engine. It cannot prove the tool
emitted ENOUGH — the label list is chosen by the tool under test, so anything it silently omits is
compared on neither side and the diff goes green on less. An audit found this is not theoretical:
8 corpus files counted as "verified green" compared **zero** properties.

Every differential target now also runs `qmlvalues --verify-props`, which enumerates what the
ENGINE actually built — every QML-declared property of every reachable object, following object
and `list<>` properties and bare children — and fails if any of it has no label. Coverage is
compared by (object, property) IDENTITY rather than by path spelling, because one object is
legitimately reachable by several routes (a property-held child is also a QObject child; an
attached object is a child too).

The oracle also stopped degrading: in `--props` mode an unresolvable path, or a leaf the object
does not actually have, is now a hard error. Previously it omitted the line — and an unchecked
leaf read returns an invalid QVariant that formats as `""`, so a mismatch could look like
agreement whenever the other side also printed nothing.

Turning the gate on immediately found a real modelling error: bare children of a BOUND type were
labelled `@N` (= `children()[N]`), but the engine holds them in that type's own default property
(`data` for anything QQuickItem-derived). The two coincide only when the type creates no internal
QObject children of its own — a `TextEdit` makes a `QTextDocument` first, and the `@N` index would
have pointed at it. Bound-type default children are now labelled `data[i]`.

### Array bindings

`kids: [ QtObject{…}, QtObject{…} ]` fills a `list<>` property. Each element is compiled as an
ordinary child object and labelled at its INDEX in that property (`kids[0].hello`), which is where
the engine holds it. Nothing is appended to a D-side list — the dump reads the field directly, the
same arrangement default children already use. Fixture `ArrayBinding.qml`.

`listProperty.qml` from the corpus stays PARTIAL: it also needs `list<int>`, `myList.push(…)` and
an array of ids (`ids: [a, a1, a2]`).

## Corpus scoreboard (every number build+diff VERIFIED)

| corpus half | compile-clean | verified build+diff green |
|---|---|---|
| pure-QtQml (42) | 28 | **28** |
| QtQuick (66) | 7 | **7** |
| **total (108)** | 35 | **35** |

Three of the remaining pure-QtQml files are *correctly* not compiling: `badFile.qml` is invalid on
purpose, and `attachedPropertyDerived.qml` / `singletonUser.qml` are deliberate refusals the engine
shares. The reachable denominator is 41, not 42.

The second column is the only one that means anything, and it is checked by generating,
compiling and diffing each file against the engine — not by trusting the tool's own exit code.
Auditing it is what exposed four defects (see below); before that audit the pure-QtQml half
claimed 16 and delivered 12.

Nothing here is silently dropped: any member or binding qmltc-d can't compile is reported on stderr
and the file exits `3` (PARTIAL), never a wrong emission.

## Bugs this found

Building the D-type differential exposed two defects that no existing test could reach:

- **A `.qml` declaring `property` on a D-registered type lost it, silently.**
  `QtdMocObject::metaObject()` returned the CTFE meta-object unconditionally, so the
  `QQmlVMEMetaObject` the engine installs for QML-declared members was ignored: the property was
  never created and reading it gave an empty `QVariant`. It now returns the dynamic meta-object
  when one is installed — which is exactly what `QObject::metaObject()` itself does. The existing
  `qmlreg`/`qmltwo` tests never declared members on the instance, so this was invisible.
- **JS `+` string concatenation emitted uncompilable D.** `label + "-" + value` became
  `label ~ "-" ~ value`; QML converts the non-string side, D's `~` does not. compileExpr now
  coerces a non-string operand with `to!string`, using the in-scope type map.

Diagnostic: `QTD_QMLVALUES_DEBUG=1` makes the oracle print the meta-object chain the engine built
(class, property range, which one `metaObject()` returns) — that is what located the first bug.

Auditing the pure-QtQml half of the corpus (build+diff every file the tool called compile-clean,
instead of trusting its exit code) found four more — the half had never been audited, and claimed
16 while delivering 12:

- **`"width=" + (a + b)` summed as a concatenation.** The string target propagated into the
  parenthesised sub-expression, so the inner `+` became `~`: `"10" ~ "10"` -> `width=1010`
  instead of `width=20`. Each operand of a concatenation is now compiled with ITS OWN inferred
  type and converted afterwards.
- **A change handler missed the first change.** Handlers were connected AFTER the initial binding
  pass, so `property int p: dummy` going 0 -> 42 fired nothing and `onPChanged` never ran.
  Handlers are now connected first. (A literal-initialised property is assigned in its field
  initialiser and emits nothing, so this does not make handlers fire on init.)
- **Untyped formals were assumed numeric.** `function f(x) { stringProp = x }` emitted
  `void f(double x)`. A formal's type is now inferred from body evidence — assignment to a typed
  property, or use as a declared signal's argument — before falling back to `double`.
- **Handler/function parameters were in scope but untyped**, so a concatenation could not coerce
  them (`stringProp = x + y` with `y:int`). The scope guard now carries types too.

A fifth, from the C++ side: a base property the registry declares with a type we do not compile
against (`QJSValue`) fell through to literal inference — `jsvalue: true` was emitted as a bool
`setProp`, printing `false` where the engine printed nothing. The registry is now authoritative:
a declared-but-unsupported type is PARTIAL, never a guess.

## Tracked gaps (honest TODO)

- **Declared signals** (`signal foo(int)`), **`enum`s**, **`Component {}`**, **`Connections`**,
  **`Timer`**, grouped properties — the remaining pure-QtQml blockers (a long tail of distinct
  members).
- **Control flow inside functions** (`if`/`for`/local `var`s) and multi-statement return bodies —
  compileStmt currently handles assignments and calls.
- **Reactivity of a binding to what a no-arg function reads internally** (a binding calling a
  param-less `f()` that reads a property doesn't yet re-evaluate on that property's change;
  param'd calls are reactive through their arguments).
- **AOT / qmltc fallback (END OF FLOW — do NOT build yet)**: a tiered, literally-last-resort chain,
  applied per failing unit in order:
  1. **JS→D transpile fails** → **AOT that JS** (qmlcachegen bytecode, run by the QJSEngine); the
     rest of the class still compiles to D. Failing JS units enter AOT granularly — the compilation
     does not desist wholesale.
  2. **QML→D compile fails** (the whole document) → run Qt's own **qmltc** (QML→C++) and **wrap** the
     generated C++ for D.
  3. **Everything failed** → **give up**.

  This is deferred deliberately: building it now would MASK all the static-coverage work, because
  every gap would silently route to fallback instead of being a visible gap to fix. It happens only
  once the static D subset is called wide enough.
- Brace-block (multi-statement) handler bodies; **child-target alias reactivity**; **dynamic
  mutation of child properties** (the dump/oracle mutate only root scalars today).
- More expression coverage: general member access, string methods, more `Math.*`, `Math.floor/ceil`.
- Non-scalar property types: `color`, `vector2d/3d/4d`, `url`, `size`, `rect`, `quaternion`.
- **Cross-file / local-type compilation** — DONE (roots + children + use-site member merge,
  cycle-guarded against self-referential files). Remaining cross-file work: nested `Component {}`,
  `QtObject`-typed object properties (`property QtObject o: QtObject {}`), `list<QtObject>`.
- **Wider type discovery.** The bound-type vocabulary is DATA, not code: the generator
  auto-subclasses every discovered class deriving from `QQuickItem` that is instantiable AND exported,
  and emits `qmlmap.tsv` (QML-name → C++-class) from the module's `plugins.qmltypes`; qmltc-d reads
  it. Adding a type is purely a discovery input (its header), never code — proven by widening
  `spec_cxx_quick.json` from 5 to 27 private element headers (+ `QtQmlModels`): **6 → 29 mapped QML
  types** (`Column`/`Row`/`Grid`/`Flow`, `Repeater`, `ListView`/`GridView`/`TableView`/`TreeView`,
  `Image`/`BorderImage`/`AnimatedImage`, `Loader`, `Flickable`, `PathView`, `PinchArea`,
  `DropArea`, …) with zero per-type code. The fixture `QColumn.qml` covers one end-to-end.
  Two SCOPE RULES make that widening safe (a private element header transitively drags in the
  non-public guts of other modules):
  1. a type declared under `.../private/` or `.../qpa/` is bound only if **that header is
     explicitly listed** in the spec — otherwise QtGui's `qevent_p.h` / `qpa/qplatformwindow.h`
     and QtQml's `qqmltypeloader_p.h` get bound and emit C++ that cannot compile (protected
     ctors, incomplete forward-declared members, fn-ptr accessors, no nameable include);
  2. even in a listed header, only an **exported** (`Q_*_EXPORT`) type is bound — the
     attached-property helpers (`QQuickPositionerAttached`, `QQuickPathViewAttached`,
     `QQuickDropAreaDrag`) are hidden, so their ctors/signals/`staticMetaObject` are not in the
     `.so`. ldc2's `--gc-sections` hides the dead references; dmd's whole-program link does not.

  Widening further is still just headers + include paths.
- **Animations** (`justAnimation`): the engine runs the animation and the final value differs from
  the static binding — either read the animation's `to`/`from` or accept these as out of static scope.

## QtQuick types bound but not yet instantiable through a property

`spec_cxx_quick.json` names 11 QObject-derived QML types (State, StateGroup,
PropertyChanges, Transition, SystemPalette, FontMetrics, TextMetrics, IntValidator,
DoubleValidator, Shortcut, FontLoader), taking qmlmap from 29 to 40 of the 156 types
QtQuick exports. Being in the map is necessary but NOT sufficient to use one.

A child bound to a property — `property IntValidator iv: IntValidator { top: 99 }` —
is compiled as a bare @QObject, because that path dropped the child's QML type. The
generated `setProp(this, "top", 99)` then creates a Qt DYNAMIC property instead of setting
IntValidator::top.

This is worth spelling out because it produces a FALSE GREEN: a differential comparing
only properties the .qml assigns sees the same value on both sides (99 == 99) and passes.
Probing a property the document never sets exposes it — the engine answers
`iv.locale = pt_BR` (IntValidator's real default) while our object has no such property.
A test of that shape was written, committed, and then removed for exactly this reason.

RESOLVED. Layers 1 and 2 are in, so a child bound to a property is built as its real type and
its members are compared. QMetrics.qml proves it the way the false green could not — it compares
15 members the document never assigns (real font metrics: ascent 14.8438, height 18.6094), which
only a genuine QQuickFontMetrics produces.

Layer 3 turned out to block only TWO of the eleven: 10 have a trampoline, PropertyChanges and
Transition included. IntValidator and DoubleValidator do not, and the generator now says why —
`QValidator::validate(QString &, int &)` is a PURE virtual whose non-const reference parameters
it cannot marshal, and a trampoline missing a pure virtual would be abstract. Supporting
non-const reference parameters is a generator change, not a qmltc-d one.

Layer 4, STATES: the initial state is compiled. `states:` is read as DATA — a table of
overrides — not built as objects, the same treatment Connections gets, because a State is not
something the document reads back. `state: "big"` then applies that state's overrides after the
declarative bindings have run, which is the order the engine uses. QState.qml compares a
QML-declared property (tag) and a base C++ one (width), both matching the engine.

Switching `state` at RUNTIME works too, reversion included. Entering a state captures the
current values of every property any state touches and applies the overrides; leaving it puts
those values back. The capture happens on ENTRY rather than at compile time, because a binding
may have changed the property since the document was written. `stateChanged(QString)` — note the
parameter; connecting to `stateChanged()` would throw — drives it.

QState.qml pins the part worth pinning: with two states, switching from "big" to "wide" reverts
`tag` to its base value (wide does not mention it) while `width` moves to the new one, matching
the engine on both.

Still refused rather than half-done: a `target:` other than the enclosing object, and a `states`
table with no initial `state:` (flagged PARTIAL — a table nothing selects would otherwise look
applied). Transitions/animations between states are not compiled: a State's effect is applied
instantly, which is what the engine does with no Transition declared.

Original analysis (layers, each uncovered by fixing the one before it):
  1. carry the child's QML type through the property-binding path (done and reverted —
     it is the first of the four, and alone it only moves the failure);
  2. a property table for bound types, so a binding can READ a member — qmlmap carries
     name->class only. A generator pass emitting qmlprops.tsv (property, D type, and the
     notify's FULL signature, since Qt notifies often carry the value: topChanged(int))
     was written and reverted with it;
  3. the trampoline artifacts the QtdWidget mixin expects (`__<Class>_vnames`), which are
     not emitted for these types;
  4. for States specifically, a state subsystem: PropertyChanges holds OVERRIDES applied
     to a target on entry and reverted on exit, not properties of its own.


## Measured against Qt's own shipped QML (944 documents)

Not a corpus I wrote, so it measures what QML demands rather than what I implemented.

| | complete | partial | refused |
|---|---|---|---|
| qmltc-d over all 944 | 4 | 940 | 0 |

"Partial" means it generates code but SKIPS members. For calibration, Qt's own qmltc over the
first 120 of the same files: 66 compiled, 51 refused (it will not resolve those modules
standalone) — it takes less, but what it takes it takes whole.

Causes, aggregated over the first 400 documents (~4500 skips):

| count | cause |
|---|---|
| 583 | property with an unsupported binding/type |
| 241 | `alias` whose target is unsupported |
| 187 | root type not a bound Qt type |
| 57  | unsupported default child |

### Binding more QtQuick types does NOT move this — measured, not assumed

The obvious read of "187 unbound root types" is that the fix is more types. It is not. I bound
84 more QtQuick types (qmlmap 40 -> 124, every exported QQuick* class with a findable header) and
re-ran the same 944: complete went from 4 to **5**. The documents that were failing are mostly
QtQuick.**Controls**, Quick3D and WebEngine — different modules, not QtQuick — and the ones that
did advance simply reached their NEXT unsupported member (visible skips rose from 172 to 583 as
documents got further in before stopping).

That batch was reverted. It was not free: it uncovered four generator problems, each hidden
behind the one before it — a non-virtual redeclaration colliding with D's `final` (fixable, and
the fix must key on the CANONICAL signature or it eats legitimate overloads like
QGridLayout::addWidget); a primary base Qt does not export; the same for a secondary (MI) base;
and the unexported class still being emitted as a pending base. Landing it would have meant
carrying four half-finished generator changes for +1 document out of 944.

The honest conclusion: the remaining distance is `alias` support and the Controls/Templates
module, not more QtQuick element types.


## Vocabulary is not the bottleneck — measured three ways

Three separate attempts to move "4 complete out of 944" by binding more types:

| vocabulary | types | complete |
|---|---|---|
| QtQuick only | 40 | 4 |
| QtQuick + 84 more QtQuick types | 124 | 5 |
| QtQuick.Templates only (Controls) | 23 | 2 |
| ONE binding, QtQuick + Templates | 63 | 4 |

The Controls-only row is the instructive one: it scores WORSE, because a real document mixes
modules (Item from QtQuick, Button from Templates) and each binding is a closed D universe with
its own copy of QQuickItem. Two qmlmaps cannot simply be combined — the types would not relate.
So the vocabulary a document needs must live in ONE binding, which the merged row tests: 63 types
covering both modules still gives 4.

Causes with that full vocabulary (first 400 documents):

| count | cause |
|---|---|
| 356 | property with an unsupported binding/type |
| 244 | `alias` whose target is unsupported |
| 214 | root type still not bound (Quick3D, WebEngine, Effects, local .qml types) |
| 57  | unsupported default child |

What this says: the remaining distance is SEMANTIC — expression forms and alias targets the
compiler does not handle — plus documents rooted in modules nobody has bound. Adding element
types to a module already covered does not move it, and that is now measured rather than assumed.


### The largest remaining semantic gap: `color`

Of the 356 unsupported property bindings, the single most common shape is a DECLARED
`property color c: "white"`. Assigning a base color property already works — `color: "steelblue"`
on a Rectangle compiles to setProp with a string and Qt converts it, and QColor.qml compares it
against the engine today. What does not work is declaring one.

RESOLVED at the runtime level, and the fix was smaller than the analysis: the moc is GENERIC.
A meta-object records a property by its TYPE NAME and Qt resolves that through
QMetaType::fromName, so no per-type marshalling is needed — cppSig just had to stop refusing
non-scalars and fall back to the D struct's name, which matches the C++ one for every type the
generator emits. `@Property QColor` and `@Property QSize` now work (valuetypeprop_test.d).
What remains is the qmltc-d side: mapping QML's `color` to that type in a compiled document.

The original, wrong analysis is kept below because the shape of the mistake is worth seeing —
it assumed a per-type mechanism where the framework already had a general one:

Doing it properly means QColor in the meta-object: qtmoc's cppSig maps scalars only, so a
QColor-typed @Property needs value-type marshalling across the D/C++ boundary. The shortcut —
holding the normalised name ("#ffff6347") in a string field — was written and reverted: the
normaliser needs QColor, which lives in QtGui, and qtdmoc.cpp is shared with bindings that do not
link QtGui (the file documents why an __has_include probe cannot decide this). Putting it behind
a build define, or normalising through the binding's own QColor in generated code, are both real
options; neither is a one-liner, and doing it as a string field would leave the meta-object
claiming QString where the engine says QColor.


## `list<T>` should be a real property — measured, not yet implemented

`property list<int> nums` is currently compiled as a plain D array field, OUTSIDE the
meta-object. That was a workaround, and it is the wrong shape: lists are metatypes like anything
else (QAbstractItemModel is the same idea taken further).

Measured on Qt 6.11:

| type name | resolves by name? |
|---|---|
| `QList<int>` | NO by default — but the ENGINE registers it (id 65538, above QMetaType::User) when a document declares `property list<int>` |
| `QVariantList` | yes (builtin, id 9) |
| `QStringList` / `QList<QString>` | yes (builtin, id 11) |
| `QQmlListProperty<QObject>` | no — needs registration |

And for a document the engine builds, `QMetaProperty::typeName()` is literally `QList<int>`, the
metatype is valid, and the value `canConvert<QVariantList>()`.

So the correct implementation is: register `QList<T>` (qRegisterMetaType) and declare the
property with that type name — the generic type-name pair added in the audit batch then reaches
it with no list-specific code at all. What is missing on our side is the D type: the generator
emits `QList<T>` only for the `T` that appear in bound signatures, and `int` is not among them.

Consequence of the current workaround, and why it matters beyond tidiness: a value list has no
notify, so a binding reading it can never update, and the dead-dependency diagnostic has to
exempt it by name. As a real property it would notify like everything else.


## Q_PROPERTY from the AST — viable, verified, not yet implemented

The generator currently learns QML property types by regex-scraping `plugins.qmltypes`. That
costs: a hand-written type map, a nesting hazard in the Signal regex (which silently made every
notify parameterless until it was fixed), a fabricated `name + "()"` fallback when the signal is
not found, and coverage limited to the 40 classes that appear in a registry.

shiboken's annotation trick applies here and stays fully COMPILE-TIME. `Q_PROPERTY` expands to
`QT_ANNOTATE_CLASS(qt_property, ...)`, which qtmetamacros.h leaves a no-op unless defined.
Adding one flag to the parse the generator already runs:

    -DQT_ANNOTATE_CLASS(type,...)=static_assert("qt_" #type, #__VA_ARGS__);

puts the declaration in the AST verbatim. Verified on Qt 6.11 — a StaticAssert whose second
StringLiteral is:

    "int count READ count WRITE setCount NOTIFY countChanged"

paired with a first literal of `"qt_qt_property"` identifying the kind. That single string carries
name, type, READ, WRITE, NOTIFY **and** RESET (which the compiler wants and the .qmltypes table
does not supply), for EVERY discovered class rather than the ones in a registry. The notify's real
signature then comes from the signal cursor the generator already visits, so the type map, the
regex and the guessed fallback all go away.

libclang exposes these as CXCursor_StaticAssert; the work is reading them per class and mapping
the string onto the existing property table. `qmlmap.tsv` still needs plugins.qmltypes — the QML
ELEMENT NAME (Rectangle <- QQuickRectangle) genuinely lives only in the registry.

Not started: it replaces the extraction layer wholesale, which is not something to begin at the
tail of a session. The verification above is the part worth not losing.


## The metric: correctness of what IS translated, not percentage translated

Qt's own qmltc does not translate everything either — what it cannot compile falls back to the
AOT/bytecode path. So "document fully translated" was never the bar, not even for the reference
implementation, and measuring against it made every partial look like a failure.

The bar that matters here:

1. what IS translated must be CORRECT — verified against the engine, not against itself;
2. what is NOT translated must be REPORTED (the PARTIAL exit and a named reason per member), so a
   fallback can pick it up and so nothing silently does the wrong thing.

That reframes the audit results. It found three defects of the first kind — a binding on a base
property that never reacted, a base property typed from the assigned literal (int for a qreal),
and property writes that could not fail — plus one test of mine that asserted on the D field and
so would have passed with the meta-object broken. Those are the wins. The coverage numbers
("4 of 944 complete") measure the wrong thing.

Corrected measurement of omissions over Qt's own first 400 documents, after the audit
(stderr captured to a file — earlier figures in this repo's history counted generated stdout
lines by mistake and are not comparable):

| cause | count |
|---|---|
| `alias` whose target is unsupported | 228 |
| root type not a bound Qt type | 182 |
| property with an unsupported binding/type | 111 |
| unsupported default child | 57 |

And the alias number is not an alias gap: `<id>.<member>` aliases work and are tested, including
writes. They fail because the CHILD did not compile — DropShadowBase, SceneEffect, ssgiEffect are
types from modules nobody bound, so the alias has nothing to point at. Unbound type is one cause
wearing three hats (alias + root type + default child ~ 467 lines), and much of it is in modules
that are not targets anyway (QtQuick3D.designer, Qt5Compat, HelperWidgets, WebEngine delegates).


## What Qt's qmltc actually does — and why "it compiled, we did not" was misleading

Comparing our PARTIAL against Qt's qmltc is the right instinct. My first conclusion from it —
"Qt's qmltc does not translate bindings at all" — was WRONG, and the correction matters: I had
looked at only half the pipeline.

Ided.qml from this corpus has three bindings — `y: root.x + 1`, `z: root.y * 2`,
`label: root.tag + "!"`. Qt's qmltc emits, for each:

    bindableY().setBinding(QQmlCppBinding::createBindingForBindable(
        QQmlEnginePrivate::get(engine)->compilationUnitFromUrl(docUrl), this, 0, this, 2, -1, "y"));

That is a handle into the document's COMPILATION UNIT — the bytecode — evaluated by the QML
runtime. Same for a grouped binding (`anchors.fill: parent` becomes
`createBindingForNonBindable(..., anchors(), 16, -1, "fill")`).

So qmltc generates the STRUCTURE — classes, properties, child objects, connections — and points
every EXPRESSION at the compilation unit. But that unit is not merely bytecode: qmlcachegen
AOT-COMPILES those expressions to native code when it can type them. Qt's pipeline is two tools,
and the translation lives in the second one.

Measured with `qmlcachegen --dump-aot-stats` on the same Ided.qml — all three bindings compiled:

    {"functionName": "y",     "codegenResult": 0, "message": ""}
    {"functionName": "z",     "codegenResult": 0, "message": ""}
    {"functionName": "label", "codegenResult": 0, "message": ""}

So Qt DOES translate expressions; qmltc just is not where it happens. `codegenResult` per
function is Qt's own coverage metric, and it is the fair basis for comparison: what it declines
to AOT-compile is what falls back to the interpreter.

Consequences for how the numbers in this file should be read:

- "Qt's qmltc compiles X of these and we compile Y" still compares different things: qmltc
  succeeds by pointing at the unit, whether or not the expression inside it was AOT-compiled.
  The comparable number is qmlcachegen's per-function codegenResult against our PARTIAL.
- What this compiler does differently is emit the expression as D IN THE GENERATED SOURCE, with
  no compilation unit and no engine needed to evaluate it. Same ambition as Qt's AOT, different
  output, and the differential against a live engine is what keeps it honest.
- The constructs Qt's qmltc "handles" that we refuse (Behavior, Component, Keys attached, grouped
  anchors, enum properties) are handled BY DELEGATION. Matching it there means either translating
  them properly or building the same fallback — not a small distinction, and worth choosing
  deliberately.


## The comparable number: Qt's AOT codegenResult vs our PARTIAL, same documents

`qmlcachegen --dump-aot-stats` reports, per function, whether Qt could compile it to native code
(`codegenResult: 0`) or fell back to the interpreter, with the reason. That is Qt's own coverage
metric and the honest basis for comparison — not "did qmltc emit a file", which succeeds either
way because it can always point at the compilation unit.

Measured over this project's QtQml corpus (46 documents):

| | result |
|---|---|
| Qt AOT (qmlcachegen) | 84 functions compiled, **22 declined** |
| qmltc-d | 46 documents complete, **0 partial** |

Why Qt declined those 22 (its own messages):

    7  Functions without type annotations won't be compiled
    4  function without return type annotation returns double
    3  Cannot access value for name SingletonFixture
    2  Cannot generate efficient code for LoadClosure
    2  Cannot generate efficient code for call to untyped JavaScript

So on the same documents this compiler translates expressions Qt's AOT declines. Qt requires type
ANNOTATIONS to compile a function; qmltc-d infers the type from the property being bound and from
the declared types in the registry, which is why an unannotated `function f() { return a + b }`
compiles here and falls back there.

This is the concrete sense in which coverage here is ahead: not "we compile more documents" (Qt's
qmltc always emits one), but "fewer expressions end up interpreted". It also marks where an AOT
fallback would eventually belong — the untyped-closure and untyped-call cases are exactly what Qt
gives up on, and would be the last resort rather than the first.
