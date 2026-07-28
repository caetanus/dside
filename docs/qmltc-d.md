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
- **`function`s** with a **type-inference layer**: a QML function becomes a D method. Numeric
  parameters are typed `double` (JS number semantics), string params are detected from concat use;
  the return type is inferred bottom-up (`function times2(n){return n*2}` -> `double times2(double
  n){return (n*2.0);}`). A call in a binding is coerced to the target property (`property int d:
  half()` -> `cast(int)(half())`) and is reactive through its arguments. Void functions
  (assignments/calls) and `return`-bodied functions are both supported.
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

**The differential can now invoke methods.** A mutation argument `name()` calls a no-arg method on
both sides (the oracle via `QMetaObject::invokeMethod`). Without it there was no way to observe
anything a method does, which is exactly where imperative binding changes live. Fixtures
`Rebind.qml` / `Unbind.qml`.

## Corpus scoreboard (every number build+diff VERIFIED)

| corpus half | compile-clean | verified build+diff green |
|---|---|---|
| pure-QtQml (42) | 27 | **27** |
| QtQuick (66) | 7 | **7** |
| **total (108)** | 34 | **34** |

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
