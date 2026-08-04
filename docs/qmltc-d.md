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
- **A child object into an object-group member**: `first.handle: Rectangle {}`, how a RangeSlider
  gets its handles. Scalar writes into such a group already worked; a child object was refused by a
  gate that only knew D-registered groups, while the emission it guarded resolves the group with
  propObj at RUNTIME and never needed that gate. The child's TYPE is now carried through as well —
  it used to be dropped, so every grouped child became a bare QObject and `implicitWidth` failed at
  runtime on what should have been a QQuickRectangle subclass.
- **STILL REFUSED: attached properties of bound types**, for TWO different reasons that were worth
  separating:
  1. `Overlay.modal`, `Overlay.modeless`, `TableView.editDelegate` are **QQmlComponent** properties.
     `Overlay.modal: Rectangle {}` defines a TEMPLATE the overlay instantiates when a modal popup
     opens — it is not an instance. Compiling it as a child object would assign an instance where
     Qt expects a factory, which is wrong on its own terms, exactly like the `Component` case the
     compiler already refuses instead of instantiating eagerly.
  2. The rest (`ScrollBar.vertical`, `ContextMenu.menu`) are genuine object properties, and the
     compiler side works — the property table now carries each type's module URI (a 4th column in
     qmlmap.tsv), so `attachedObj(this, "QtQuick.Templates", "Overlay")` is emitted and our values
     are right. The ORACLE is what blocks these: an attached path is not reachable by walking
     properties, and QQmlProperty does not resolve it either, under the bare name or the document's
     own `T.Overlay`. Shipping what the differential cannot compare is how false green happens.
- **Object groups**: `border.width: 3` on a Rectangle. A grouped write whose value READS something
  is a BINDING and is wired like any other — both group paths shipped as ONE-SHOTS at first, because
  both were tested with literals, which have no dependency to go stale. The wiring is a named helper
  shared by both, not a third copy of the base-property logic. `border` holds an OBJECT (QQuickPen*), not
  a value, so the write is a plain property write on what the group holds — reached with propObj.
  The distinction is NOT recoverable from the type name (QQuickScaleGrid and QFont look alike): the
  registry marks it with `isPointer`, which the generator now records in the property table as a
  trailing `*`. The member's type comes from the value and QMetaType converts; setProp throws if
  the member does not exist, so a wrong name is loud rather than dropped.
- **A value-typed source into an object group**, including a TERNARY between two such reads
  (`border.color: control.enabled ? control.palette.mid : control.palette.dark`) — the same shape a
  base property accepts, so the two positions agree: `border.color: control.palette.dark`. The group is
  an object, so this is the same QVariant copy a base property uses with the group object as the
  destination. It is a BINDING whose first run is in the LATE phase — a child is constructed before
  its parent assigns anything, so a copy made during the wire necessarily reads a default (measured:
  #b8b8b8 where the engine had seagreen).
- **Value groups that are plain gadgets**: `icon.width: 24`. QQuickIcon has its own meta-object,
  so setVgroup does a read-modify-write through it. What made this safe to enable is telling it
  apart from the case below at COMPILE time — see the `^` marker.
- **The 8 unresolved roots on Qt's Controls are all accounted for, and none is ours to fix.** Five
  are Qt classes with NO export macro (QQuickDayOfWeekRow, QQuickMonthGrid, QQuickWeekNumberColumn,
  QQuickCalendar, QQuickCalendarModel): a subclass references the base's ctor and staticMetaObject,
  so unexported means unlinkable — the generator already refuses them for exactly that reason.
  ApplicationWindow is a Window rather than an Item; the two spinboxes are excluded by the spec for
  the private-symbol link failure recorded there. Those files account for 21% of the remaining
  diagnostics, which is worth knowing before anyone tries to close that fraction by writing
  features: there is no feature to write.
- **Refusals carry `line:col`**, so they can be JOINED with what `qmlcachegen --dump-aot-stats`
  reports per function — which is what the planned cachegen fallback has to decide per expression.
  First measurement over Qt's 69 Controls files, 968 expression sites the AOT knows about:
  749 covered by both, **121 only by us** (the AOT cannot compile them), **68 only by the AOT**
  (we refuse — these are the fallback's actual candidates), 30 by neither. The join is by LINE, and
  "not refused" is a proxy for "translated", so treat 749 as an upper bound; the two small buckets
  are the ones that matter and they are the ones that are precise.
- **Measured ceiling: ~250 declared properties per object.** Past it the GENERATED D stops
  compiling with "more than 65535 symbols with name `s`" — a D limit hit by a `static foreach` over
  signalMembers in qtmoc.d, which grows quadratically with the signal count. Verified: 250 compiles,
  300 does not. Left alone deliberately: no file in the QML Qt ships declares more than 58
  properties, so raising the ceiling would be contorting the runtime for a case that does not
  occur. Recorded so it is a known ceiling rather than a mystery if a generated document ever
  approaches it.
- **NOT supported: `font.pixelSize: 22` on a bound type.** It looks like it should work through
  the same channel — resolve the member by name at runtime, let QMetaType convert — but QFont is
  not a Q_GADGET: `QMetaType::metaObjectForType` finds nothing for it, because QML reaches font
  members through a FOREIGN value-type wrapper (QQuickFontValueType), not the plain meta-object.
  Emitting the call converted a compile-time partial into a construction-time throw, so it stays
  refused — and it is now refused BY DATA rather than by guesswork: the registry says
  `extension: "QQuickFontValueType"` on QFont and says nothing on QQuickIcon, so the generator
  records a `^` on extension-backed value types and qmltc-d routes on it. `setVgroup` now THROWS when the member does not resolve, rather than dropping the
  assignment and leaving a default that looks deliberate — which is how this was caught.
- **Enum properties by KEY**, directly or as a TERNARY between two members (`alignment: cond ?
  Qt.AlignCenter : Qt.AlignLeft`): `verticalAlignment: Text.AlignVCenter` is written as the string
  `"AlignVCenter"` and the meta-object converts it through QMetaEnum — the numeric value never has
  to be known here, which is the same reason a QColor literal works. Recognised as `Type.Member`
  where Type is a bound QML type that is not an object in scope, and Member is capitalised.
- **Diagnostics quote the expression they refused.** Reading a cluster otherwise meant matching a
  property name back to a source line, which picks the FIRST occurrence — the root's — even when
  the failure is in a child. The snippet comes from the document CURRENTLY being compiled and from
  nothing else: two things repoint that text behind your back — loading a local type, and the
  singleton prescan, which reads every `.qml` in the directory — and a "try every parsed file"
  fallback produced plausible NONSENSE (`ocale.name`) rather than admitting it did not know. Both
  now restore it; a wrong snippet in a diagnostic that exists to be read is worse than none.
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
- **Handlers for a BOUND TYPE's own signals** (`onClicked` on a MouseArea). Only notify handlers
  and signals declared by the document were connectable, because a connect needs the full
  signature and nothing carried it. The generator now emits `qmlsignals.tsv` (name -> signature,
  walked up the prototype chain, so a Button carries AbstractButton's `clicked`). This is the
  MAJORITY shape in real QML: 226 of the 373 handlers in the QML Qt ships are plain signals,
  against 147 notify handlers.
  The parameter's `isPointer` matters and cost a debugging round: Qt registers
  `clicked(QQuickMouseEvent*)` and the registry spells the type without the `*`, so the first
  version compiled cleanly and connectMeta failed at RUNTIME — the handler simply never fired.
- **Property VALUE SOURCES** (`NumberAnimation on v`, `Behavior on x`). Qt models these with ONE
  generic interface — QQmlPropertyValueSource: the object says "I drive this property", Qt hands it
  a QQmlProperty, and the object takes over. So a single runtime entry point covers every animation
  type and Behavior, and the compiler never learns what a NumberAnimation is. Two ordering details
  are load-bearing: the object must be handed its target BEFORE its own `running: true` is applied
  and before it completes (the same construction-time handoff `__outer` uses — attaching afterwards
  starts an animation with nothing to drive), and the handoff carries `qobjOf(this)`, not the D
  reference, which otherwise segfaults inside QQmlProperty. A value source is completed like any
  object but is NOT dumped as a child: the engine has no `_vs0.duration` path.
- **TIME differential.** Both sides run for the same wall time and the property is compared. An
  animation only advances when something drives it, so a compiled object can hold a perfectly
  correct animation that never ticks — invisible to a property dump (reads the initial value), to a
  frame comparison (one frame) and to a click test (an event, not time). The target also requires
  the value to DIFFER from the t=0 one, so it cannot pass on a frozen document.
- **BEHAVIOUR differential.** A real click is delivered to both sides and the resulting property
  compared. Nothing else in the suite can see this: a MouseArea whose handler never runs renders
  PIXEL-IDENTICALLY and does nothing. The target also asserts the click MATTERED — it re-runs
  without the click and requires a different value — so it cannot pass on a document that ignores
  input.
- **Wire order: BINDINGS live before the initial assignments, USER HANDLERS after.** These are
  different things and sharing one stream was a real bug. `padding: 12` on a Pane fires
  leftPaddingChanged, which is what recomputes `implicitWidth: ... contentWidth + leftPadding +
  rightPadding ...` — but the connect was made after the assignment, so the notification arrived
  with nobody listening and the Pane kept an implicit width of 0 FOREVER. The engine draws it
  24x24; we drew 1x1. Moving every connect earlier then broke the other half: QML does NOT fire
  `on<Signal>` for assignments made while the object is being created, so `onWidthChanged` started
  reporting seen=1 where the engine reports 0. A binding is not an observer — it IS the value —
  and a handler is an observer of changes after creation. Found by rendering a real Qt Controls
  file; no property comparison in the corpus could have shown it, because Pane is not in the
  corpus.
- **RENDER differential.** The bar is not "the property values match" — it is *renders and behaves
  like the interpreted version*, and until this existed nothing in the suite drew a pixel. Both
  sides are now rasterised headless (software backend, deterministic, no GPU) and compared frame to
  frame: the engine through QQuickView, ours through a `--render <png>` mode the generated main
  gains when its root is an Item. 9 files, 18 targets, pixel-identical — including text
  (82-149 distinct colours), which means fonts, colours and item geometry all agree.
  Two things keep it honest. The comparator REFUSES a frame with no area or a single flat colour,
  because most of this corpus was written for a property differential and its roots have no visual
  size — a 1-pixel window compares equal no matter what the compiler emits, and comparing such an
  image WITH ITSELF fails the gate. And it is verified to detect a real difference: two frames of
  the same size with a different colour report the first differing pixel.
  What is still NOT measured: behaviour over time (animations, transitions) and interaction (click,
  hover, focus). A CheckBox that never toggles would pass everything here.
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
- **An object-valued property as a truth value**: `control.indicator ? a : b`, which Qt's Controls
  use to guard padding. In QML that is a null test, and the object comes through the meta-object,
  so it needs no type knowledge — only that the property is a pointer, which the `*` marker says.
  Applies to a bool target only: as a value the expression would be the object itself. It has to be
  tried BEFORE the self-reference and enclosing-object reads, both of which resolve the member as a
  scalar and fail first. Both SPELLINGS work — `control.background` and plain `background` — as do
  both spellings of a read THROUGH one (`control.indicator.width`, `background.implicitWidth`);
  Qt's Controls use them interchangeably, and supporting only the dotted form made the feature look
  arbitrary.
- **A Component-typed property is NOT a child object.** `delegate: Item {}` on a Repeater, or
  `sourceComponent:`, takes a TEMPLATE that the type instantiates itself; building it eagerly
  assigns one instance where Qt expects a factory. The registry says which properties those are
  (16 of them in the quick binding alone), so this is data, not a list of names. Found by an audit,
  and only because the eager child ALSO failed to compile — see below.
- **QML names that are D keywords.** `delegate` and `scope` are ordinary QML names and D keywords.
  A CHILD field can be renamed (it is not a property); a DECLARED property cannot, because the
  meta-object exports it under its field name and Qt would stop knowing it — that one is refused.
  Worth knowing: after the Component rule above, no keyword-named object property remains reachable
  in Qt's own types, so the rename is defensive. The compile error it caused is what exposed the
  Component bug, which would otherwise have been silently wrong.
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

## Does it RUN? Auditing Qt's Controls corpus at runtime (2026-07-29)

"Compile-clean" is not the bar — *renders and behaves like the interpreted version* is. Applying
that to Qt's own `QtQuick/Controls/Basic/*.qml` (69 files) meant, for each: generate, LINK, and
**construct the object**. That single step found six defects that every compile-time metric missed,
because each one produces D that compiles and then dies (or lies) at construction.

| | before this round | after |
|---|---|---|
| files that produce a constructible object | 38 | **61** of 69 |
| of those, constructing without error | 24 | **61** |
| files reported clean that could not run | 1 (`ProgressBar`) | 0 |
| files that ABORTED the compiler | 3 | 0 |

The eight remaining emit no root at all — a root type we refuse, reported on stderr.
The gate is a build target (`qmltc-controls-runtime-<dc>`), and it carries a FLOOR on the count:
refusing every root would otherwise pass it.

**What it found, all eight — six of them the same shape: something we could not bind became a bare `@QObject`,
and every property the document set on it was written to an object that has no such property.**

- **An unbound child TYPE was silently built as a bare object.** `contentItem: ProgressBarImpl {}`
  in Qt's ProgressBar: `ProgressBarImpl` is not a bound type, so the child had no `implicitHeight`
  and construction threw — while the file was reported CLEAN. Now refused with a diagnostic, on
  the property-bound path AND the list path (`transform: [ Translate { y: … } ]` in Dial, which
  was the same bug in a different position). One helper, `unboundChildType`, is used by both.
- **No `QQmlContext` at all.** Anything that builds children THROUGH the engine —
  `QQmlDelegateModel` behind every view, Loader, delegates — calls `QQmlContext::engine()` in
  `componentComplete()` and segfaults on a null context (ComboBox's popup contentItem is a
  ListView). Qt's own qmltc takes a `QQmlEngine*` in every generated constructor for this reason:
  the win is not parsing QML, not doing without an engine. `classBegin` now attaches a context
  from a lazily-created process-wide engine — **measured cost: 1.7 ms, once per process** — and
  declines when there is no QCoreApplication, since a QQmlEngine qFatals rather than fail there.
- **A dependency reached THROUGH an object property connected once, to null.** `x: (parent.width
  - width) / 2` on a ROOT: `parent` is assigned by whoever instantiates it, after the wire runs,
  so the connect threw (ToolTip; HeaderView's `syncView` likewise — 45 sites corpus-wide). QML
  re-binds such a dependency when the property changes, and now so do we: `connectNotify` follows
  the PROPERTY, and `bindLeaf` re-subscribes to the leaf signal from inside the slot, dropping the
  previous subscription.
- **A REFUSED property stayed visible to its dependents.** RangeSlider's `handleBorderColor` was
  refused, so the class had no field and no notify — but a child still emitted
  `connectMeta(__outer, "handleBorderColorChanged()")` and threw. A refusal now erases the name
  from both the property table and the scope, so dependents take the ordinary refusal path.
- **A declared property with NO value was refused** (`property string s`, and `required property
  string shortName` whose value comes from the view's model). In QML it exists and holds the
  type's default; refusing it left the name in scope with no field behind it, so the generated D
  referenced an undefined identifier and did not compile at all (DayOfWeekRow, WeekNumberColumn).
- **The compiler ABORTED on three files** (SpinBox, DoubleSpinBox, TableViewDelegate).
  `wire.find("classBegin(this);\n") + 18` on a wire that has none: `npos + 18` wraps to 17, and
  `insert` threw `out_of_range`. An object whose every member was refused had an empty wire and
  still needed the `__outer` handoff — it now gets a constructor body for exactly that reason. The
  suite could not see it because a crash and a PARTIAL are both "non-zero"; the gate now
  distinguishes them (0 clean, 3 partial, anything else is the compiler failing).
- **qmlmap advertised types the binding could not back.** `IntValidator`/`DoubleValidator` were in
  the QML vocabulary, so `mixin QtdWidget!QQuickIntValidator` was emitted against an undefined
  `__QQuickIntValidator_vnames`. A class the generator asked to subclass but then SKIPPED (no
  overridable virtual with a marshalable signature) now leaves the subclass set, so the map
  promises only what the binding delivers. qmlmap: 116 -> 114 types.
- **A refused ROOT still emitted a runnable `main`.** `new IMonthGrid` handed back a bare QObject
  standing in for `AbstractMonthGrid`, built real `QQuickText` children under it, and looked like
  a working program. The classes are still emitted; the entry point is not.

### The frame differential on this corpus, and why most of it is inapplicable

Of 31 comparable files, **22 comparisons the comparator REFUSES** — 13 render 1×1 on the ENGINE
side too and 9 are a single flat colour. Qt's style files are abstract templates: a `Control` with
no content paints nothing, on either side. That is not a passing test and is not counted as one.
The 9 measurable differences are all in PARTIAL files and every one is explained by a diagnostic
that file already emits (`Qt.styleHints.*`, which is dynamic and out of scope by decision; `Math.max`
on implicit sizes; `ContextMenu.menu`; `Color.blend`).

### One ceiling, verified rather than assumed

`QtQuick.Controls.Basic.impl` (`ProgressBarImpl`, `BusyIndicatorImpl`, `DialImpl`) **cannot** be
bound: `qquickbasic*_p.h` declare their classes with no export macro and
`libQt6QuickControls2BasicStyleImpl.so` exports zero symbols for them (`nm -D`), so a trampoline
would link against nothing. `TumblerView` is the counter-example — it lives in
`QtQuickControls2Impl`, is exported, and IS now bound, along with `Translate`/`Rotation`/`Scale`
(reached by sweeping from `QQuickTransform`, not just `QQuickItem`). qmlmap: 110 -> 114 types.

## Same VALUES as the interpreted document — Qt's Controls, second axis (2026-07-29)

Construction is the floor; the criterion is behaviour. With 61 of Qt's Basic files producing an
object, the oracle can be pointed at them and asked the real question: does the compiled object
hold the same property values as the one the ENGINE builds? Two defects, both silent — clean
files, constructing fine, disagreeing with the engine:

| | before | after |
|---|---|---|
| CLEAN files whose values match the engine | 6 of 9 | **9 of 9** |
| PARTIAL files whose values match | 8 | **24** |

- **A compiled Control had no theme, so its palette was wrong.** `Label.color` came out `#000000`
  against the engine's `#26282a`; `Pane.background.color` `#efefef` against `#ffffff`. A Control
  reads its palette from the `QQuickTheme` that its STYLE module installs *on import*, and a
  compiled program imports nothing. Measured which import does it: not `QtQuick.Templates`, not
  `QtQuick.Controls` — the style module (`QtQuick.Controls.Basic`). Resolution is lazy, so a
  control built BEFORE the import still picks the theme up; only the first READ has to come after.
  The URI is not written anywhere in the compiler: it is read from the `qmldir` beside the
  document, so the file gets exactly the module the engine gives it. ~1.8 ms, once per module.
- **A bare child was placed by hand, and `data` is not always where it goes.** The registry
  publishes `defaultProperty` per type: `contentData` for Pane/Popup/ScrollView (the child is held
  by the contentItem), `flickableData` for Flickable, `data` for Item and — explicitly — ListView.
  Proof that the old behaviour was wrong, from the engine itself on `Pane { Rectangle {} }`:
  `contentData[0].objectName` is the Rectangle, while `data[0]` is a `QQuickContentItem` that has
  no `color` at all. So the old label named a different object and the child was linked in the
  wrong place. The property now comes from a 5th qmlmap column (resolved up the prototype chain by
  the generator) and the child is APPENDED through it with `QQmlListReference` — one channel, each
  type applying its own rule. Fixture: `CDefaultProp.qml`.
- **...and no fallback.** 14 bound types (Action, FontLoader, Translate, Rotation, …) declare no
  default property at all; assuming `data` for them invented a path neither side has. A bare child
  under such a type is now REFUSED with a diagnostic.

Still open on this corpus, recorded rather than hidden: 7 PARTIAL files the ORACLE cannot load or
resolve. One cause is ours and is a LABEL problem, not a tree problem — the engine's ListView
already holds an internal item at `data[0]`, so a declared child lands at `data[1]`, while a
static label assumes the list starts empty (ComboBox). The rest are files the engine itself
refuses standalone (TreeViewDelegate needs a TreeView).

Method note: the suite runs in ONE `./build` invocation with all targets (472 green in ~4 min).
Invoking `./build` once per target instead costs about an hour — the overhead is per invocation.

### A bare name cannot come from an alias-only import (2026-07-29)

Qt's Controls files write `import QtQuick.Templates as T`, so a BARE name in them is never a
Templates type — `footer: DialogButtonBox {}` in Dialog.qml names the styled `.qml` file sitting
next to the document. Resolving the bare name through the registry built an unstyled Templates
control instead, and Dialog's footer came out with every padding, size and offset at ZERO against a
fully built engine one, with no diagnostic saying anything. `boundTypeFor` now refuses a name whose
module was imported only under an alias (the URI is the 4th qmlmap column; a name that arrived
qualified stays exempt).

That exposed two more, both invisible while the wrong resolution masked them:

- **A property-bound child never resolved a local `.qml` type.** Only the default-child path did.
  `header: Label {}` became a bare object instead of Basic/Label.qml's own root. Both paths now
  resolve and splice identically.
- **A use-site binding was APPENDED to the local definition's, not substituted for it.** `Label {
  color: … }` over a definition that also binds `color` emitted two recompute slots with the same
  name and the D did not compile (HorizontalHeaderViewDelegate). In QML the use site wins; one
  `spliceUseSite` helper now serves both paths, so they cannot drift apart again.

Result on Qt's own files: `Dialog` went from 16 differences in 155 compared properties to **0 in
267** — the styled header/footer brought far more surface to compare AND agreed on all of it.

Negative zero is normalised on both sides (`+ 0.0`): `-0.0 == 0.0`, and only `%.17g` distinguishes
them, so comparing them as text reported a difference that does not exist. Any non-zero difference
still shows. PARTIAL files whose values match the engine: 24 -> 28 of 46 measurable.

### Attributing a difference to its CAUSE (2026-07-30)

The value differential over Qt's own Controls leaves 18 PARTIAL files whose properties differ. Counting
those differences is not the same as counting defects, and treating them as equivalent produced three
wrong conclusions in a row here. A difference must be attributed to a cause before it is classified:

- **Explained by a diagnostic on the same object.** Most are. `Menu`'s `contentItem.interactive` is
  reported (`interactive: Window.window ? … : false` reads an attached property the compiler refuses),
  and `keyNavigationEnabled` is a CONSEQUENCE — Qt couples it to `interactive`. Grepping for the leaf
  name finds the consequence and not the cause, which reads as a silent defect and is not one.
- **Explained arithmetically by a refused CHILD.** `BusyIndicator` has exactly one diagnostic (its
  `contentItem` is `BusyIndicatorImpl`, a verified unexportable type) and exactly two differences: the
  root's implicit size, 12x12 against 60x60. 12 is a Control with no contentItem, 60 is
  BusyIndicatorImpl's own implicit size. `Dial` has the same shape. Path-matching cannot attribute these
  — a root property has no segment to match against the child's diagnostic — but the numbers can.
- **Explained by ORDER, not by a missing value.** `contentItem.baselineOffset` on CheckBox, RadioButton
  and Switch is 19.34375 against the engine's 14.84375 — a constant 4.5 — with every input identical:
  same height (28), contentHeight (19), font, y, and the same `verticalAlignment` (AlignVCenter, 128,
  measured on both sides). 14.84375 is the font ascent: the engine's Text computed its baseline BEFORE
  the control resized the contentItem from 19 to 28 and never recomputed; ours computes it after, so it
  carries the centring offset.
  **This is OURS to fix, not a decision to weigh.** The contract of a transpiler is identity with the
  interpreted document: whatever state the engine produces IS the specification, including a value that
  looks stale and including a default that is merely configurable (QQuickMenu does not capture the
  keyboard by default and can be told to — so that default is observable behaviour a translation must
  reproduce, not an opinion). An earlier version of this section framed the baseline as "which one is
  right is a decision". That was wrong: a difference from the engine is a defect on our side.

After attribution, no silent defect remains proven in that corpus. The method matters more than the
tally: match a difference to a cause, and when the cause is a refused member on ANOTHER object, expect
to need arithmetic rather than a name.

## Comparing EVERY property, and comparing after a CHANGE (2026-07-30)

The differential above dumps the properties the compiler RECORDED for each object — which is
exactly the set it also chose to translate. A document could differ from the engine in any
property no binding mentions, and the comparison would never look. Enum properties were excluded
outright (they have no D scalar type), so `elide`, `verticalAlignment` and every other enum had
never once been compared.

`--dumpall` (compiled side) and `--dumpall <objpaths>` (oracle) now enumerate every property each
object's meta-object declares, over the object set `qmltc-d --objpaths` emits so both sides walk
the same tree. The oracle keeps its own copy of the enumeration rather than sharing ours: it uses
only public Qt API on purpose, and a formatter shared with the side under test could agree with it
while both were wrong.

A second axis mutates before dumping: `--set:<prop>=<value>` on our side, the oracle's existing
`name=value` on its side, both written through the meta-object as text. Until this existed, every
connection the compiler emits was untested — a binding wired to nothing is indistinguishable from
a correct one until something changes. It found a real defect on its first run (a dependency on
`control.palette.<role>` that was silently dropped, so a colour was copied once and never again).

Two harness rules that are not optional: mutate only where the property EXISTS on the root (Action
and ButtonGroup are not Items; writing `width` to one is the test's error, and our side reports the
failed write by throwing while the engine ignores it), and regenerate BOTH sides before comparing,
or a stale binary is compared against a fresh oracle.

Numbers on Qt's Basic corpus at the end of that day: 34 of 57 files identical to the engine in
EVERY property, 101 divergences over 8914 properties compared, 153 diagnostics, 61 of 61
constructing with 0 failures, and no file that matches at construction failing after a mutation.

### What the remaining divergences are, by cause

- `delegate`/`model` left null: a `Component` is a template the type instantiates itself, which is
  not yet built. Refusing it is honest; faking it with a component whose bindings cannot resolve
  the enclosing document's ids would improve the metric and damage the product.
- `Behavior on x` (SwitchDelegate): animation is not implemented and is reported as such. Our final
  value is right; the engine's, read at that instant, is mid-transition.
- `baselineOffset` (CheckBox/TextField placeholders): NOT a binding bug. The objects are identical
  on both sides — same font, geometry, elide, colour. Qt computes
  `ascent + (height - contentHeight)/2`; ours is `14.84 + (28-19)/2 = 19.34`, the engine's is
  `14.84 + (0-19)/2 = 5.34`, i.e. the engine computed it while the item still had height ZERO and
  never recomputed. A layout-ordering difference in a derived value, stable on both sides.
- `DialImpl`: a type from QtQuick.Controls.impl that this binding does not cover. Building it as a
  bare object would drop every property set on it, so the whole `background` is refused.

### Before `Component` is implemented: what its test has to prove

`delegate`/`model` are left null today and reported as refused. 16 properties of the Basic corpus
differ because of it, and there is an obvious way to make all 16 match that would make the product
WORSE: build a `QQmlComponent` from the delegate's source text at runtime. `delegate` would stop
being null immediately, and the metric would move — while a delegate whose bindings cannot resolve
the enclosing document's ids would instantiate and behave wrongly, which is strictly worse than a
document that admits it has no delegate.

So the acceptance criterion is not "delegate is non-null". It is:

1. the view INSTANTIATES the delegate — for a model of N, the same number of items exists on both
   sides, at the same paths;
2. each instantiated item matches the engine property-for-property under `--dumpall`, which means
   the delegate's own bindings resolved;
3. a binding inside the delegate that reads the ENCLOSING document (`control.something`, the shape
   Qt's own delegates use constantly) has the same value on both sides — this is the one that
   distinguishes a real Component from a detached one;
4. it still holds after a mutation (`--set:`) that the delegate's bindings depend on.

Points 3 and 4 are the whole test. A Component implementation that passes 1 and 2 and fails 3 has
produced items that look right at construction and are not connected to anything, which is the
failure mode this compiler has hit more than once and which no value dump at construction can see.

### The Component test, and its measured baseline (2026-07-31)

`tests/qmltc/controls/CDelegate.qml` is the acceptance fixture written BEFORE the feature, per the
criterion above. A Repeater with `model: 3` and a delegate whose bindings read the enclosing
document (`root.tag`, `root.bump`) — point 3 of the criterion, the one that separates a real
Component from a detached one.

Measured today, with the engine on one side and the compiler on the other:

| path | engine | compiled |
|---|---|---|
| data[0..2] | three QQuickText, `outer-0/1/2`, x = 1/11/21 | absent |
| the Repeater | data[3] | data[0] — the only child |

So the bar is concrete: the compiled document must produce those three items, at those paths, with
those values — `x` proving the index arithmetic and `text` proving the read of the enclosing
document. The refusal today is honest (`'delegate' ... takes a Component ... not an object`).

The fixture IS wired into the build, but as the refusal rather than as the differential
(`pendingFeature` in reggaefile.d): the target asserts that the compiler emits a diagnostic for
this file. A differential target here would leave the default build red, and a permanently red
build hides every other regression behind it. The day the feature lands the refusal stops, that
target fails, and the file moves out of the list into the normal differential.

### What blocks it: an engine-created D object is not a QQuickItem (2026-08-01)

The route was measured, not guessed, with a probe that builds the pieces by hand: register the
delegate class with `qmlRegisterType`, build a one-line QQmlComponent that instantiates it
(`qtd_make_component`, on the same engine every compiled object already uses), hand it to a
Repeater. Three findings, in order:

1. **The C++ half works.** With a stock `Text` as the registered type, the Repeater creates its
   three items and they land exactly where the engine puts them: `data[0..2]`, then the Repeater at
   `data[3]`. So driving a Repeater from compiled code — context, parenting, completion order — is
   not the problem. (One real trap on the way: `QQmlDelegateModel::componentComplete` dereferences
   the object's QQmlContext, so a Repeater whose `model` is set before `classBegin` SEGFAULTS.)
2. **The component instantiates our compiled class.** `QQmlComponent::create` on the registered D
   type returns an object whose meta-object class name is the D class. Registration reaches QML.
3. **...but Qt does not see it as an Item.** `qt_metacast("QQuickItem")` on that engine-created
   instance returns null, and a Repeater silently drops a delegate that is not an Item — which is
   why the items never appeared. `qmlRegisterType` registers a QObject-derived shell and wires the
   D object to it; a `QtdWidget!QQuickText` subclass constructed with `new` DOES metacast to
   QQuickItem (tests/qml/subclasscast_test.d), so what is missing is the shell's C++ BASE.

That is the next piece of work, and it is a registration feature rather than a compiler one: the
registered type has to be created as the bound C++ base (its trampoline), which the shim already
knows how to build for `new` — the engine's `create` is a placement-new into memory it sized
itself, so the shim needs to publish the size and a placement constructor per bound class. Driven
by the bound class NAME, so it stays one mechanism rather than one per type.

### DONE (2026-08-01): the fixture matches the engine property for property

`CDelegate.qml` is out of `pendingFeature` and is an ordinary differential target. Both gates pass:
the recorded-label dump is identical, and `--dumpall` compares 95 properties of the root and of the
first delegate item with **zero** differences. The table above is met — three items at data[0..2]
with text `outer-0/1/2` and x 1/11/21, the Repeater at data[3].

What it took, beyond the registration feature above:

- **The enclosing object is FOUND, not handed over.** A compiled child gets a back-reference at
  construction; a delegate is built by the view, so it finds each level it reads by CLASS, walking
  the visual parent first (a Repeater's items are shown under the Repeater's own parent). Only the
  levels actually read get a field — a level that is not an ancestor cannot be found this way, and
  gating the wire on it would wire nothing. The wait is `parentChanged`, through the meta-object.
- **`index` is a CONTEXT name, and it is reactive.** The view publishes it on the per-item
  QQmlContext, so it belongs to no object the document names — but that context carries an object
  that publishes it as a property WITH a notify, so the binding connects like any other. Read via
  the context, connected via the context object: same channel, no new mechanism.
- **The component carries the DOCUMENT's url**, so a relative path inside a delegate resolves where
  the engine resolves it. The differential caught this as a single `baseUrl` difference.
- **A view-decided index is not a label.** Qt's Repeater inserts its items BEFORE itself in `data`,
  so a statically numbered `data[N]` label is a guess. The recorded-label dump drops such labels in
  a document that binds a Component; `--dumpall` keeps them, because there both sides resolve the
  same index through the same list — which is a comparison rather than a guess.

### Fusion, and the next step it made concrete (2026-08-01)

Qt's FUSION style — 55 documents this compiler had never seen — was compiled for the first time and
found four defects in one run, three of them construction failures (fixed and committed: the value
source's missing back-reference, one URI per style for the impl types, the dump path through an
engine child, and the versionless import). It stands at **52 of 55 constructing, 0 failures**, 183
diagnostics.

Its largest refusal cluster is 26 types Qt writes in QML inside the style's own module directory
(`QtQuick/Controls/Fusion/impl/ButtonPanel.qml`, `CheckIndicator.qml`, `SliderGroove.qml`, …). They
are refused as "not a bound Qt type" because only the DOCUMENT's own directory is searched for a
local type.

**Two of the three prerequisites now exist** (committed, both corpora green):

- a declared OBJECT property (`property Item control`) is a real property: the meta-object records
  it as `X*` and the D field is the bound wrapper class, so whoever instantiates the type can write
  it. What is still refused is an object property with an initial BINDING;
- a declared SCALAR property whose initial binding is refused is still DECLARED, with its default —
  the property exists in QML whether or not we can evaluate its first value, and dropping it made
  the use-site's write throw. Restricted to scalars and objects on purpose: a value type
  (`property color x`) declared as a D struct field changes how every READ of it compiles, and the
  refusal path takes the name out of scope so reads fall back to the meta-object (measured: 8 link
  failures in Fusion and 1 in Basic when it was not restricted).

**The silent drop is FOUND and fixed** (the third prerequisite): the merge of a local type with its
use site dropped any definition member the use site also binds — right for a binding, wrong for a
DECLARATION. `property bool highlighted: <expr>` both declares the property and gives it a first
value; the use site only replaces the value. Dropping it whole removed the property, so the
use-site's own write then threw at construction with no diagnostic anywhere. The declaration is kept
and its binding stripped (two bindings for one name is what that dedup exists to prevent).
Reproduced first in eight lines of QML, which is what made it findable.

**LANDED, once the blocker turned out to be a registration bug of ours.** The failing append was
not about ButtonPanel at all: `qmlRegisterType` for a bound subclass registered the delegate type
with `typeId = QMetaType::fromType<QObject*>()`, which tells Qt that the QObject* metatype IS that
type. `data` is a `QQmlListProperty<QObject>`, so from the first delegate registration onward every
QQmlListReference over any `data` list resolved its element type to the last registered delegate
class and refused every append — silently, because the generated code falls back to parenting.

Five reproductions failed to reproduce it (ButtonPanel copied next to a document, with the style
imported, as a Control's background, with the use-site body, after an engine-created object), which
is what said the difference was not in the DOCUMENT. Tracing the call printed `elem=ICB_delegate`
for a list of QObject and named the cause in one line. An invalid metatype is not the fix — Qt's
type loader dereferences it and segfaults on the QQmlThread; the carrier's own metatype is.

With that fixed, imported-module resolution lands: **Fusion 52 of 55 constructing, 0 failures**, and
its diagnostics go 183 -> 446 because those 26 types now compile and report their own gaps instead
of being one refusal each. Basic is unchanged on every axis.

### The next Fusion cluster is a SCOPING defect, not a missing feature (2026-08-01)

With imported-module types compiling, Fusion's largest remaining clusters are `color:
Fusion.buttonColor(...)` (76 — a singleton call returning a value type) and `control: control` (20).

The second one is not a feature gap. Qt writes, in Button.qml:

    background: ButtonPanel { control: control }

and ButtonPanel itself declares `property Item control`. In QML the two `control`s are different
things: a binding written at the USE SITE is evaluated in the scope of the document that wrote it,
so the right-hand `control` is Button.qml's own id — while the left-hand one is the property being
assigned. This compiler merges the local type's body with the use site into ONE class, and with it
the two scopes: the right-hand `control` resolves to the class's own property and the assignment is
refused.

Refused is the lucky outcome. The same merge makes a use-site binding that reads any name the local
type also declares resolve to the WRONG one — and for a scalar it would compile and be silently
wrong. So the fix is a scoping one (members spliced from the use site must resolve names without the
local type's declared properties shadowing the enclosing document), and it is worth doing for
correctness even before the 20 refusals it unblocks.

Tried and removed rather than left in: an assignment path for declared object properties. It is the
right rule and it cannot fire until the scoping is fixed — every `control:` in this corpus is the
shadowed form — and untested code that never runs is worse than no code.

### The rest of that cluster is a NOTIFY lookup, not a read (2026-08-01)

After the assigned-type rule (`<id>.control.<member>` refusals 80 -> 60), the Fusion Button's
gradient stops still refuse. Bisecting the argument list of
`Fusion.buttonColor(panel.control.palette, panel.highlighted, panel.control.down, panel.enabled && …)`
one argument at a time: `panel.control.palette` compiles, `panel.control.down` compiles,
`panel.highlighted` compiles — `panel.enabled` does not.

Reduced to five lines (`Rectangle { id: panel; Item { Text { visible: panel.enabled } } }`) the
message is precise and is NOT about the read: *"depends on 'enabled' of the enclosing object, which
has no known notify"*. The read compiles; the DEPENDENCY does not resolve, so the binding is refused
rather than emitted dead. So the remaining work here is in the notify lookup for a base property of
an enclosing frame reached at depth — not in the expression compiler, where the last three fixes
were.

(Method note, since it cost two wrong turns: `grep -c` through the rtk proxy does not print a count
in the format the caller expects — bisecting on it read "10" as ten diagnostics for a file that had
none. Read the diagnostics with python.)

### Fusion's biggest cluster, diagnosed: a declared type WEAKER than the object it gets (2026-08-01)

About 80 of Fusion's remaining refusals are one shape: `indicator.control.checkState`, where the
indicator declares `property Item control` and the use site assigns a CheckBox. The path is typed
now (a declared object property can be walked through), and the read still fails — because `Item`
has no `down`, no `checkState`, no `visualFocus`. QML does not care; a typed walk does.

Isolated in six lines: the same read against a member `Item` DOES have (`enabled`) compiles and
emits `propBool(propObj(__outer, "control"), "enabled")`. So the machinery is right and the TYPE is
the problem.

Two ways out, and only one of them is honest here:

- read the member untyped through the meta-object. Tried before for a different cluster and
  REVERTED by measurement: it also accepts a model ROLE as if it were a property, which is how
  TreeViewDelegate died on `display`. Not this.
- take the type from the ASSIGNMENT instead of the declaration: the use site writes
  `control: control`, and the compiler knows exactly what that is (it is the enclosing document's
  root, whose type it has). The document already says what the object is — the same pattern that
  fixed `background.border` and the delegate's enclosing scope.

The second is the next step. It needs the use-site assignment to record the assigned type against
the declared property, which is one map away from what `g_declObjProps` already holds.

## A SECOND corpus, measured the same way (2026-08-01)

Qt's FUSION style — 55 documents this compiler had never seen when the day started — now runs the
same axes as Basic:

| | Basic | Fusion |
|---|---|---|
| constructs | 61 of 61 | 52 of 55, 0 failures (3 have no visual root) |
| files IDENTICAL to the engine in every property | 47 of 57 | 41 of 49 |
| value differences | 21 (all attributed) | 20 |
| diagnostics | 67 | 60 |

Fusion started the day at 183 diagnostics with 26 whole TYPES refused; it is at 90 with those types
compiling and reporting their own gaps, which is the trade this compiler makes on purpose. What that
cost and bought, in the order it happened: the value source's missing back-reference, one URI per
style, the dump path through an engine child, versionless imports, the silent drop of a declaration,
the QObject* metatype hijack, imported-module types, Gradient/GradientStop bound, object arguments
to a singleton call, overload selection by argument count, use-site scoping, declared object
properties (declared, assigned, and walked through), the registry rows a local type inherits, and
singletons that are not dependencies.

The largest remaining Fusion clusters, measured — and one of them is now cut in half by isolation:

- a singleton call whose argument is a COLOUR READ (`Color.transparent(indicator.checkMarkColor)`,
  28; `FusionControls.Fusion.gradientStart(backgroundRect.color)`, 8). The IMPORT ALIAS half of the
  second one is done (both the gate that decides to compile the call as text and the compiler that
  does it step past the alias), and three isolations put the line exactly: `color: bg.color`
  compiles (a direct copy), `FC.Fusion.gradientStart("#abcdef")` compiles (aliased call, literal
  argument), and `FC.Fusion.gradientStart(bg.color)` does NOT. So what is missing is reading a
  QColor property through an id AS A STRING ARGUMENT — not the alias, not the call;
- `indicator.control.checkState === …` (12);
- a declared VALUE-TYPE property (`readonly property color pressedColor: …`, 20). The property is
  built now — it is declared with the value type so the meta-object records it, its initial value is
  written as TEXT through the meta-object, a read of it compiles to `propStr`, and a colour-typed
  target accepts anything that compiles as text. Proven by isolation, and the corpus did NOT move:
  Qt writes the BARE head (`control.palette.base`, not `indicator.control.palette.base`), and a bare
  name that is a declared OBJECT property of the same object still does not resolve as the head of a
  path. The qualified form compiles; that one line is the whole difference.

  DONE, and the trace is what did it after three guesses had failed: a print at the top of
  `objPathHead` never fired, which said the bare name never reaches that function at all — the path
  walker `objPathExpr` keeps its OWN copy of the identifier resolution, with its own scope guard.
  Fixing the other one could not have worked. With the rule in the copy the walk uses, the read
  compiles.

  It cost one runtime fix on the way: reading through a declared object property that nobody has
  assigned yet is a NULL wrapper, and `qobjOf` called through it — Qt's Fusion Button, DelayButton
  and ToolButton segfaulted in `checkAlive` the moment those reads started compiling. A null
  reference has no object to ask; it yields null, which is how QML's `undefined` travels here.

### `Qt.darker` / `Qt.lighter` — and the three defects they exposed

The colour globals were the gate under the biggest cluster, not a cluster of their own: they appear
34 times across Fusion, and the properties they FEED — `readonly property color checkMarkColor:
Qt.darker(control.palette.text, 1.2)` and every `Color.transparent(indicator.checkMarkColor, …)`
argument taken from one — were refused for want of them. Unlike `Qt.styleHints` there is no object
behind `Qt`, so the meta channel cannot reach them and the runtime implements what the engine
implements (`QColor::darker`/`lighter` with the factor as a percentage). Colours travel as text
here, so it is string-in/string-out and composes with everything else.

The fixture (`tests/qmltc/quick/QColorShade.qml`) is byte-identical to the engine on the default
factors, a factor below 1, an alpha colour (`#8024496d` — QVariant's own spelling, which is why the
result is formatted by QVariant and not by us), both argument shapes, and a nested call.

Landing them turned three latent defects into failures, which is the point of running Qt's own QML:

- a **bound value-type property** could not be stored. A colour computed as text cannot be assigned
  to a `QColor` field; it goes back through the meta channel, which converts it and fires the notify
  itself. Which branch applies is decided from the expression's own type, so `property color a: base`
  still assigns the field directly. This is what Fusion's `readonly property color` needed all along;
- **binding evaluation order**. In QML a binding is lazy, so every direct assignment on the same
  object has happened before it runs — `control: <the enclosing Button>` is in place when
  `color: control.palette.base` evaluates. Our initial pass is eager and in document order, so five
  of Qt's Fusion documents read through a null `control` and wrote an empty colour. The assignments
  whose value is the ENCLOSING object now run first; a child field cannot move with them, because it
  does not exist yet;
- **D initialises a `double` field to NaN; QML's default for `real` is 0.** CheckIndicator computes
  `Qt.lighter(base, baseLightness)` before `baseLightness` is assigned, and Qt's `qRound` ASSERTS on
  NaN — a hard abort, found with gdb (`!std::isnan(value)`, qnumeric.h:508). Two fixes, both real:
  the field is initialised to QML's default, and a non-finite factor yields the colour unchanged
  instead of killing the process.

An invokable argument that is a COLOUR came with them: `Fusion.buttonColor(palette, …, tint)` mixes
an object and a value in one call, and a value crosses as text like every other value here.

Measured after: Fusion **199 → 123 diagnostics**, 52 of 55 constructing with **0 failures**,
**29 of 49 documents identical** (was 26) and **56 value differences** (was 63). Basic unchanged.

### The object write that never happened (2026-08-02)

Four gaps, found by pulling on one thread: `indicator.control.checkState`, 40 of Fusion's 123
diagnostics and the largest cluster left.

- a **QUALIFIED declared type** (`property T.AbstractButton control`, which is how every Fusion
  indicator declares its back-reference) is a UiQualifiedId whose `name` is only its FIRST segment
  — the alias. Reading that alone typed the property as "T" and every path through it stopped
  there. `typeName()` already strips aliases; four sites were not using it. Fusion 123 → 97;
- the type used to walk through a declared object property is now the **ASSIGNED** one, not the
  declared one, when the document assigns it. QML is dynamically typed here and Qt relies on it:
  `AbstractButton` has no `checkState` and the CheckBox actually put there does. The declaration is
  a lower bound on the object; the assignment names it;
- `x === undefined` asks whether the object HAS the property at all — the same guard, for the case
  where it is not a CheckBox. The meta channel answers exactly that: a property the object does not
  declare reads as empty, one it does reads as its key;
- ...and the enum comparison itself now accepts a path of ANY depth, since `objPathExpr` reports
  both the object and its QML type.

Then the fixture built for those (`tests/qmltc/quick/QDeclObjType.qml`) failed on something else
entirely, and it was the biggest defect of the day: **an object write into a declared object
property had never worked.** The property is declared by its precise type (`QQuickItem*`) and that
name only resolves to a QMetaType if something in the process instantiated one — QtQuick registers
its QML types, not a metatype under every pointer name. A property with no metatype cannot be
written at all, so `control: control` on every Fusion indicator silently left it null and every
read through it came back empty. Three parts:

- the meta-object falls back to `QObject*` when the precise pointer name has no metatype. Every
  read here goes through the meta-object by NAME, which never consults the declared type;
- the write builds the variant AS the property's declared metatype — and only after checking the
  object really is one, on the meta-object chain. Forcing it without that check handed a plain
  QObject to `QQuickItem::setParentItem` and segfaulted (gdb, RangeSlider);
- a property declared `QJSValue` takes a SCRIPT value, not a variant. Qt's Rectangle declares
  `gradient` that way, so `gradient: Gradient { … }` — which most Fusion controls write — did
  nothing and the shape drew flat. The engine turns the object into a script value.

The failure is now REPORTED rather than swallowed, and that is what exposed the last one: a grouped
property whose child is a LOCAL `.qml` type (`first.handle: SliderHandle { … }`) was built as a bare
`@QObject`, because the local-type resolution existed only on the default-child path. Same three
steps there now — base from the local definition's root, adopt its registry rows, splice the use
site's members.

Measured across the four: Fusion **123 → 90 diagnostics**, 52 of 55 constructing with 0 failures,
value differences **56 → 45**, and the `only-engine` bucket — paths the ENGINE has that we do not —
**82 → 0**. Basic unchanged at 79 diagnostics and 47 of 57 identical.

### Four value defects, all about WHEN and with how many digits (2026-08-02)

With `only-engine` at zero, the honest axis left is VALUES — properties both sides have, spelled
differently. Four fixes took Fusion from 45 differences to 25, and 29 of 49 identical documents
to 38:

- **binding order, one level deeper.** The assignments a binding reads through now run before the
  CHILDREN, not just before this object's own bindings. Fusion's ButtonPanel holds a Gradient whose
  stops compute `panel.control.palette`, and a child is fully wired at construction — so the stops
  ran with `control` still null, produced black, AND connected their notify to a null object, so
  nothing ever recomputed them. 45 → 36;
- **a real crossing as TEXT has to round-trip.** `to!string` formats a double with six significant
  digits: `Color.transparent(c, 210 / 255)` arrived as 0.823529, which is 209.99989 alpha steps —
  one short of the engine's 210 on every checkmark Fusion draws. 36 → 30, and six more documents
  became identical;
- **a colour crossing as text has to carry the precision QColor holds.** `#rrggbb` is 8-bit and
  `Fusion.buttonColor(...)` does not return an 8-bit colour: spelled and parsed back it shifts one
  step, which is what every `gradientStop(buttonColor(...))` showed. Proven inside the ENGINE, in
  one document — `gradientStop("#e8e8e8")` is `#ededed` and `gradientStop(bc)` is `#ececec` where
  `bc` PRINTS as `#e8e8e8`. `#rrrrggggbbbb` is Qt's own 16-bit spelling and QColor parses it back
  exactly (there is no such form with alpha, so a translucent colour keeps the 8-bit one). 30 → 25;
- ...and the same NaN-vs-0 rule as before, for a declared property whose initial binding was
  REFUSED: it kept D's NaN and reported it as the value where the engine reads 0.

The first isolation of the colour one was wrong and said so: `gradientStop("#e8e8e8")` matched our
output exactly, which looked like a clean bill. Feeding a colour PROPERTY instead of a literal is
what separated them — the literal is 8-bit by construction, so it could not have shown the loss.

### A global keyed by name alone, and what "undefined" writes (2026-08-02)

Two more, both found by asking why the SAME panel compiled in one of Qt's files and was refused in
another:

- the declared type of a base property came from `g_baseProps`, a global keyed by property NAME —
  so whichever type was prescanned last decided. `color` on Fusion's ButtonPanel was typed QColor
  in Button (the last local type that document loaded) and untyped in ComboBox, where a later one
  overwrote it. Same panel, same property, compiled in one file and refused in the other. The
  registry is per-type and does not care about order; the `^` marker on it means "reached through
  an extension" and says nothing about the type, so it is stripped before the branches match;
- an EMPTY string is how this channel spells `undefined` — a read through an object that is not
  assigned YET comes back empty. QML leaves a property alone when a binding evaluates to undefined,
  so a non-string target now takes no write instead of a failed conversion. Reporting it as an
  error aborted two of Qt's documents whose only fault was that the engine would have evaluated the
  binding later.

That second one names what is left. The remaining ComboBox, Switch, ProgressBar and TabButton
differences are all one shape: our initial pass is EAGER and in document order, where QML builds
the whole tree, then evaluates bindings, then completes. `earlyWire` moved the assignments a
binding reads through ahead of the children, which is as far as that gets without the real model.

### A sibling's id, and an attached property on another object (2026-08-02)

Two more shapes out of the remaining value differences, both structural rather than incidental:

- **an ATTACHED property read on ANOTHER object, as an enum.** `control.TabBar.position !== T.TabBar.Header`
  (Fusion's TabButton, deciding its own `y`). The typed attached path already existed; an ENUM
  cannot use a typed reader, and the key channel — the one every other enum comparison here uses —
  answers it. TabButton is now identical to the engine in every property;
- **a SIBLING's id.** QML resolves an id anywhere in its component, so a child reads the child next
  to it by name — `handle.x + handle.width` in Fusion's SwitchIndicator, and the same in TabButton,
  ProgressBar and Slider. None of it compiled: a name that was neither a property of this object,
  of an enclosing one, nor a child of THIS one simply did not resolve. A sibling is a FIELD of the
  enclosing object, so the hop is the ordinary one — and it is looked up LAST, after every property
  lookup has failed, so nothing that already resolved changes.

  The second half is order. The enclosing object builds its children IN ORDER, so a sibling
  declared later is still null while our own wire runs: connecting there connects to nothing and
  the first value is wrong forever. Both the connect and the first evaluation go to the late phase
  the root triggers once the whole tree exists — the mechanism that already existed for reads
  through an object a Control creates during its own completion.

`tests/qmltc/quick/QSiblingId.qml` covers both directions on purpose: the BACKWARD reference is the
easy case, the FORWARD one is what exposes the eager order.

Fusion: 88 → 83 diagnostics, 39 → 41 of 49 documents identical, 24 → 22 value differences.

### Reading through an object assigned later, and the header views (2026-08-02)

- a path that goes THROUGH a property-held object (`control.popup.palette.window`) reads something
  the enclosing wire has not assigned yet. QML would have evaluated the binding later, when it is
  there. Those bindings are re-evaluated in the late phase the root triggers once the whole tree
  exists; a recompute only emits on an actual change, so a redundant one costs nothing. Fusion's
  ComboBox and SearchField popup backgrounds match the engine now: 22 → 20 differences;
- the wire is emitted UNCONDITIONALLY. The engine attaches a context and calls
  classBegin/componentComplete on every object it creates, members or not; we skipped the whole
  body when a document said nothing about an object.

That second one was written to fix the header views and **did not**. The finding is worth more than
the fix would have been: `T.HorizontalHeaderView { }` — two lines, no members, nothing to compile —
already reproduces the whole difference. `model` is null and `rows` is -1 on our side where the
engine reports 0 and 1, and neither completing the object nor running the event loop changes it. So
those 10 of the remaining 20 Fusion differences are not about compilation at all: they are about how
the object is CREATED, and the compiler cannot be the place to look. The unconditional wire stays
because it is what the engine does, not because it moved a number.

### Two that moved, one gate re-measured and left shut (2026-08-02)

- **a VALUE-GROUP member read inside an expression.** `control.locale.name` (Qt's SpinBox hands its
  validator the control's locale) and `control.font.family`. The group is a value, not an object —
  the registry types it with a C++ name that does NOT end in `*`, which is exactly what separates
  it from `control.palette.text`. Reading it as an object path walked into a null propObj, so the
  whole binding was refused. The COPY form of the same read (as a whole binding) already worked and
  the read inside an expression did not: the asymmetry that keeps turning up here;
- **two types the binding never generated.** `SmoothedAnimation` and `PathLine` are ordinary
  QtQuick types whose headers were simply not in the controls spec; `subclass_derived` already
  covers everything under `QQuickAbstractAnimation`, and `QQuickPathElement` joins it. Six of Qt's
  documents stopped refusing a child outright. (309 newly bound symbols came with them, and 5 new
  drops on `QQuickPath`'s own list-typed methods — the manifest baseline is regenerated, which is
  what the gate asks for when the drops are new symbols rather than lost ones.)

Fusion 83 → 78 diagnostics, Basic 79 → 74. Values unchanged on both.

**The attached-child gate, re-measured and left shut.** The earlier note asked for exactly this
measurement once the prerequisites landed, and they have. Opening it: Fusion 83 → 171 diagnostics,
41 → 39 documents identical, 20 → 26 value differences, 0 → 21 paths the engine has and we do not,
and four documents throwing at construction. Adding a general rule — compile the attached child only
if it compiles WHOLE — removes every one of those regressions, and then NOTHING is emitted: all 11
attached children in that corpus are partial, so the corpus is byte-identical to the gate being
shut, at the cost of 98 diagnostics for work that is thrown away. That is the useful finding: the
blocker is not the attachment, it is the children. `ContextMenu.menu` is a Menu of Actions with
script bindings we do not compile. Re-open when those compile, not before.

### `Qt.alpha`, an extension value type, and an attached object as a question (2026-08-02)

Four, and the first one is the registry again:

- **`easing.type: Easing.OutCubic` was refused because a whole qmltypes file was missing.**
  QEasingCurve is declared `accessSemantics: "value"` with `extension: "QQmlEasingValueType"` — in
  the **QML** module's plugins.qmltypes, which the controls spec did not read. Without that row the
  type looked like a plain gadget, and QEasingCurve is not a Q_GADGET: `writeOnGadget` had nothing
  to write through. With it the member goes down the extension channel (QQmlProperty, QML's own
  value-type registry), which is the same channel `font.pixelSize` uses;
- a value with NO inferred type is not necessarily unusable: an enum member crosses this channel as
  an INT (`Easing` is a real QML singleton and its members have numeric values) or, failing that,
  as its KEY. The key is the last resort, for a namespace the registry does not export at all;
- **`Qt.alpha`** joins darker/lighter — the third colour global, the same string-in/string-out shape,
  and the one Fusion's Switch draws both of its gradient stops with;
- **an ATTACHED object as a TRUTH VALUE.** `indicator.Window ? … : …` asks whether the object is
  under a window at all, and `qmlAttachedPropertiesObject` returns null when it is not — exactly the
  question. It has to be answered FIRST: the ordinary member paths decline a capitalised member and
  never reach the object-path test at the end. And it is not a DEPENDENCY: whether an object has an
  attached object of some type does not change over its life, so recording it reported "depends on
  'Window', which has no known notify" for a test that can never go stale.

Fusion 78 → 75 diagnostics, Basic 74 → 69. Values unchanged on both, 0 construction failures.

### The gradient switch, and Fusion's RENDER axis measured for the first time (2026-08-02)

`gradient: control.down || control.checked ? null : buttonGradient` is how every Fusion panel turns
its gradient off when pressed: an OBJECT-or-null ternary written into a property Qt declares as a
QJSValue. The write channel for that landed earlier (the runtime turns an object into a script
value); what was missing was compiling the ternary as an object expression. Fusion 75 → 70
diagnostics.

The property differential could not see it — a gradient is not a property value — so
`render_corpus.sh` now takes the style and output directory, for the same reason
`values_corpus.sh` does: a gradient only Fusion draws is invisible to a Basic-only render pass.

| axis | Basic | Fusion |
|---|---|---|
| RENDER, PNG byte for byte | **48 identical**, 1 differing, 12 the engine cannot render either | **39 identical**, 5 differing, 8 the engine cannot render either |

Fusion's five: ComboBox, Dial, RangeSlider, Switch, ToolBar — and three of them are the same
documents the value differential already names, so the two axes agree about where the work is.

### A property the type does not have (2026-08-02)

QML is dynamically typed and Qt relies on it in both directions. Fusion's CheckIndicator is used by
CheckBox AND by MenuItem, and it reads `indicator.control.checkState` — a property CheckBox has and
MenuItem does not. The engine evaluates that as `undefined`, and `undefined === Qt.PartiallyChecked`
is false. Two halves, and only both together compile the file:

- the READ. The meta channel gives exactly the engine's answer: a property the object does not
  declare reads as the empty string, and no enum key equals it. Correct too if the object turns out
  to BE a CheckBox at runtime, which the declared type cannot promise either way. Offered only
  against an enum KEY, which is what makes a bare path unambiguous there;
- the DEPENDENCY. `<obj>.<leaf>` where the registry HAS rows for the object's type and none of them
  is the leaf is a different statement from "we do not know this type": the type is described and
  simply does not declare that member, so the ENGINE has nothing to connect to either. Best effort
  on Qt's own notify convention, null-safe AND signal-safe — live if the object turns out to have
  it, silent if not, which is what the engine does with the same document. Reporting it as "would
  not update" was calling the document's own shape our defect.

It took two edits because the dependency wiring has TWO consumers with the same fallback, and the
first patch went into the one this shape does not use — which a print at the decision point showed
in one run, after re-reading the code had not.

Fusion 70 → 66 diagnostics. Values and render unchanged on both corpora.

### Reading an extension value type, and `undefined` inside a chain (2026-08-02)

Both are the same correction applied where it was missed:

- **`^` means "not writable through the plain channel", not "not readable".** `control.locale.name`
  (Qt's SpinBox hands its validator the control's locale) reads a QLocale, which the registry marks
  with `^` because its MEMBERS are written through QML's value-type registry. It is a Q_GADGET all
  the same, so the reader resolves the member by name like any other. The mark was being used as a
  blanket refusal;
- **the `=== undefined` test needed the same loose read the enum-key test got.** `checkState ===
  Qt.Checked || (checked && checkState === undefined)` is one expression; the first half compiled
  and the second did not, so the whole binding was refused. Reordering the two lambdas so the
  undefined branch can use the loose read is the entire change.

Fusion 66 → 60 diagnostics, Basic 69 → 67. Values, render and construction unchanged on both.

### Two experiments that were reverted, and what they settled (2026-08-02)

Neither shipped. Both are worth more written down than the code would have been.

**SpinBox and DoubleSpinBox are not bindable.** Their headers were missing from the controls spec,
and adding them DOES map both types — and then every subclass fails to LINK.
`QQuickAbstractSpinBox` is a TEMPLATE whose inline `handleComponentComplete` calls
`QQuickIndicatorButtonPrivate::executeIndicator(bool)`, which libQt6QuickTemplates2 does not export,
so the trampoline instantiates code against a symbol that is not there. Same shape as the Basic
style impls. A compiled-but-unlinkable root is worse than an honestly refused one: the
controls-runtime gate went from 0 failures to 2. ApplicationWindow, Calendar, CalendarModel,
DayOfWeekRow, MonthGrid and WeekNumberColumn were added in the same experiment and are INERT —
their classes generate but nothing maps them, because none is a QQuickItem and `QQuickCalendar` has
no export macro at all. The reason is now in the spec, next to the one for the Basic impls.

**The attached-child gate, measured a second time.** The first measurement was taken at 83
diagnostics; this one at 60, after every fix of the day. The result is identical: opening the gate
plus the general "compile it only if it compiles WHOLE" rule gives 158 diagnostics and emits ZERO
attached children, because every one of them is still partial. The number to watch is not the gate —
it is whether `ContextMenu.menu`'s Actions compile.

### The fourth axis on Fusion, and the defect it found (2026-08-02)

`react_corpus.sh` now takes the style and output directory too — the last of the three scripts to
get them, and the reason is the finding: **a declared VALUE-TYPE property was written once and never
again.** Qt's Fusion RadioIndicator computes

    readonly property color pressedColor: Fusion.mergedColors(control.palette.base, …)

and disabling the control switches which palette GROUP `control.palette` resolves to. The engine
repaints; we kept the enabled colour (`#e7e7e7` against the engine's `#d8d8d8`). The property is
written through the meta channel as text, and that path had no dependency wiring at all — the value
is correct at construction, which is exactly why three axes could not see it and only a mutation
could.

The fix is the wiring every other binding already gets, applied to that path. Measured after, on
BOTH corpora, six mutations each (`enabled`, `width`, `visible`, `padding`, `spacing`, `focus`):

| axis | Basic | Fusion |
|---|---|---|
| REACTIVITY: documents identical at construction that differ after a mutation | **none**, 6 of 6 | **none**, 6 of 6 |

Fusion's fourth axis had never been run. It found one defect, in the one place the other three are
blind by construction.

### A FIFTH axis: the frame after a CLICK (2026-08-02)

The plain render compares a document at rest. The value differential compares it after a MUTATION
written from outside. Neither sees what a control looks like once it has been PRESSED — which is the
half of "behaves like the interpreted version" a user actually touches, and it was unmeasured on
both corpora.

`tests/qmltc/click_corpus.sh` clicks the CENTRE of each document and compares the frame byte for
byte. Nothing picks a property, so nothing chooses what counts as behaviour. The click point is the
centre of the ENGINE's frame from the render pass — the only place the document's real size is
already written down — and a document the two sides already draw differently is SKIPPED and counted,
not compared, so a difference here is always about the click. The engine side is a new
`qmlrender --clickrender` mode; ours needed nothing, since `--click` already precedes `--render`.

| | Basic | Fusion |
|---|---|---|
| frame after a click, byte for byte | **26 identical**, 7 differing | **23 identical**, 7 differing |
| skipped: differ at rest already | 1 | 5 |
| skipped: no frame to click into | 15 | 9 |

Basic's seven: ComboBox, ScrollBar, SearchField, SwitchDelegate, Switch, TextArea, TextField.
Fusion's: ScrollBar, SearchField, Slider, SwitchDelegate, TabButton, TextArea, TextField.

They are NOT one cause, and saying so is the point of writing them down: only Basic's Switch and
SwitchDelegate carry a `Behavior`, so "we jump where the engine animates" explains two of fourteen
at most. The click reaches our objects — a compiled Basic Switch toggles `checked` to true and
`position` to 1 — so this is about what happens after, not about delivery. Unlike the value
differences, none of these is attributed yet.

### What the click axis found in its first hour (2026-08-02)

Two things, and one of them was the harness measuring its own artefact — the recurring blind spot,
caught this time by an axis that had just been built.

- **an object-group member written through the TEXT channel was never connected.**
  `border.color: control.activeFocus ? palette.highlight : palette.mid` on Qt's TextField is a
  colour, so it takes the fallback that crosses as text; that path emitted a recompute slot, called
  it once in the late phase, and wired NO dependencies. Clicking into the field left the border grey
  where the engine paints it with the accent colour. The mutation sweep could not have found it —
  `activeFocus` is read-only and is never mutated — and neither could the render-at-rest pass;
- **and then the frame still differed, because `--render` moved the item to a NEW window.**
  activeFocus is per-window: `--click` put the item in a window and focused it, and the render call
  reparented it away, so the frame showed an unfocused control while the object itself reported
  `activeFocus` true. An item already in a scene is grabbed from THAT scene now.

| frame after a click | Basic | Fusion |
|---|---|---|
| before | 26 identical, 7 differing | 23 identical, 7 differing |
| after | **29 identical, 4 differing** | **24 identical, 6 differing** |

Basic's four: ScrollBar, SearchField, SwitchDelegate, Switch. Fusion's six: RoundButton, ScrollBar,
SearchField, Slider, SwitchDelegate, TabButton. RoundButton is one step of one colour on one pixel
and is identical at rest; the ScrollBars are attributed — Qt's ScrollBar hides its contentItem with
`opacity: 0.0` and reveals it from a `State` with a `when:` condition and a dotted
`PropertyChanges { control.contentItem.opacity: 0.75 }`, neither of which is compiled (the four
`states` diagnostics). That is the first cluster the click axis has named for itself.

### `when:` and a PropertyChanges that names its own target (2026-08-02)

The click axis named this cluster on its first run and it is now compiled. Two halves, both small
once the shape was clear:

- **`when:` is an ordinary binding on `state`** — which is exactly what the engine does with it, so
  entering AND leaving both go through the save/apply/restore machinery that already existed, with
  no new case at all;
- **`PropertyChanges { control.contentItem.opacity: 0.75 }`** — Qt 6 spells the target in the NAME
  instead of in a `target:` line. The path is resolved where the scope is complete and accepted only
  when it lands on THIS object, which is the same rule the `target:` form enforces. Knowing that it
  does requires knowing which property of the enclosing object holds us, so a compile now carries
  that name.

It took one relocation to work: the `when` wiring was written next to the rest of the state
machinery, which runs AFTER `bindWire` has been folded into the constructor — so the connects went
into a buffer nobody reads again, and the slot was called once and never more. The symptom was
exactly the bug it was meant to fix, which is what made it easy to miss.

| | Basic | Fusion |
|---|---|---|
| diagnostics | 67 → **65** | 60 → **58** |
| frame after a click | 29 → **30 identical**, 3 differing | 24 → **25 identical**, 5 differing |

Qt's ScrollBar and ScrollIndicator hide their contentItem with `opacity: 0.0` and reveal it from
that state; both are byte-identical after a click now, in both styles.

### The same defect in the other branch (2026-08-02)

An object-group member whose value is a TERNARY BETWEEN TWO READS takes its own branch — the one
that emits a copy rather than a computed value — and that branch connected only what the colour
SOURCE hangs off, never the CONDITION. Qt's SearchField paints its border with the accent colour
while `control.activeFocus || control.contentItem.activeFocus` holds; clicking into the field left
it grey. Exactly the defect fixed an hour earlier in the text-channel branch beside it, and the
click axis found both.

Basic's frame after a click: **31 identical, 2 differing** — and both of those are named: `Switch`
and `SwitchDelegate` carry `Behavior on x { SmoothedAnimation }`, so the engine's handle is caught
mid-flight where ours has already arrived. That is the one remaining cause in Basic, and it is the
`Behavior` cluster the diagnostics already report.

### Letting the click SETTLE, and why that is not hiding anything (2026-08-02)

The click axis grabbed its frame immediately, and for a document with a `Behavior` that compares two
stopwatches rather than two renderers: the animation phase depends on how long each side took to get
there, which is not a property of the compiler. Both sides now let the click settle for the same
400ms. The END state is the well-defined thing, and it is what "behaves like the interpreted
version" means for a toggle.

This does not pretend the transient away. A document that never settles still shows up as a
difference — Fusion's BusyIndicator spins forever and is now the clearest entry in the list. And the
axis is deterministic: two consecutive runs give the same set on both corpora, which a
time-dependent comparison has to be before it is worth anything.

| frame after a click | Basic | Fusion |
|---|---|---|
| immediate | 31 identical, 2 differing | 25 identical, 5 differing |
| settled | **32 identical, 1 differing** | **26 identical, 4 differing** |

What is left is four documents and one perpetual animation: Basic's ComboBox (`#bdbdbd` against our
`#e0e0e0` at the corner), Fusion's Slider and SwitchDelegate (a different shade of the same blue),
Fusion's TabButton (one step of one colour), and BusyIndicator, which cannot settle by construction.

### One scene, and Basic's click axis goes to zero (2026-08-02)

The same harness artefact, a third time, and this one made the last Basic difference disappear.

Every input entry point — click, key, run — created a NEW QQuickWindow and reparented the item into
it. Reparenting an item out of a scene drops what the scene holds: focus is per-window, and so is an
open Popup. `--run` after `--click` therefore CLOSED the ComboBox's popup, and the settled frame
showed a ComboBox at rest where the engine showed one with its popup open and `down` still true.
Our object was right at the moment of the click — `down` true, `popup.visible` true — and the
harness undid it before the frame was taken.

An item already in a scene stays in it now, in all three entry points.

| frame after a click | Basic | Fusion |
|---|---|---|
| before | 32 identical, 1 differing | 26 identical, 4 differing |
| after | **33 identical, 0 differing** | 24 identical, 6 differing |

**Every Basic document that can be clicked is byte-identical to the engine after a click.**

Fusion's six: BusyIndicator (a perpetual animation, which cannot settle by construction), Slider and
SwitchDelegate, TabButton, and RoundButton and SearchField — the last two differ by ONE step of one
grey on one pixel and are identical at rest, which puts them on the line between a defect and
antialiasing and earns an isolation before any code. The set is deterministic across runs.

### The comparator was reporting the first pixel, not the difference (2026-08-02)

`--compare` printed where its scan happened to stop. That reads as "one step of one grey on one
pixel" for a difference covering two thirds of the frame, and it is how Fusion's RoundButton and
SearchField got written down as noise twice. It reports the EXTENT and the DEPTH now — how many
pixels differ and by how much — which is what tells a wide shallow difference from antialiasing:

    RoundButton   696 of 1024 pixels differ, max channel delta 9
    TabButton      18 of  168 pixels differ, max channel delta 1

The first is a defect and the second is antialiasing, and the old message made them look alike.

**And the defect was the harness again.** A click was press+release with no MOVE, so the control was
pressed by a pointer that had never been over it: Qt derives `hovered` from hover delivery, which
only runs off a move, and Fusion's ButtonPanel colours everything from `control.hovered`. Both sides
send the same three events now. RoundButton and SearchField are byte-identical after a click.

| frame after a click | Basic | Fusion |
|---|---|---|
| now | **33 identical, 0 differing** | **26 identical, 4 differing** |

Fusion's four, measured rather than guessed and stable across runs: BusyIndicator (431 pixels, delta
171 — a perpetual animation, which cannot settle by construction), Slider (336, delta 217),
SwitchDelegate (266, delta 65), TabButton (18, delta 1 — antialiasing). Two real ones left.

### `Math.round` (2026-08-02)

The Math branch compiled `max`, `min` and `abs`. Qt's Fusion Slider places its handle with

    x: control.leftPadding + Math.round(control.visualPosition * (control.availableWidth - width))

so the whole binding was refused and the handle sat at the left edge forever — **identical at rest**,
which is why four axes had nothing to say about it, and wrong the moment the slider is clicked. The
click axis is what found it.

JS's `Math.round` is `floor(x + 0.5)`, not D's `round()`, which sends a half away from zero in both
directions; `ceil` and `floor` come with it, refused until now for the same reason (Qt's Tumbler and
ScrollView use them).

One three-line branch, measured across four axes at once:

| Fusion | before | after |
|---|---|---|
| diagnostics | 58 | **51** |
| documents identical in every property | 41 of 49 | **43 of 49** |
| value differences | 20 | **17** |
| render at rest, byte for byte | 39 | **40** |
| frame after a click | 26 identical, 4 differing | **28 identical, 3 differing** |

Basic is unchanged and remains at 33 identical / 0 differing after a click. Fusion's three:
BusyIndicator (a perpetual animation), SwitchDelegate (266 pixels, delta 65) and TabButton
(18 pixels, delta 1 — antialiasing).

### `Window.active` cannot be made to agree, and that is the answer (2026-08-02)

Fusion's SwitchDelegate is the last click difference with a real cause: its indicator dims the
highlight by half when `indicator.Window.active` is false, and the two harnesses disagree about
whether their window is active. Both attempts to fix it were REVERTED by measurement:

- activating OUR window took Fusion from 28 identical to 25 (RangeSlider, RoundButton and Slider
  joined the differing list);
- activating BOTH gave the same 25 — under the offscreen platform a bare QQuickWindow becomes
  active on `requestActivate` and a QQuickView does not, so the asymmetry is the platform's and not
  something either side chose.

So a document that reads `Window.active` is unmeasurable on this axis, the way a Transition's empty
`animations` list is unmeasurable on the value axis. It stays in the differing list rather than
being papered over, and the reason is written next to the script.

One process note, because it nearly became a false finding: the corpus binaries LINK `qtd_render.o`.
Re-running only the comparison after reverting reported three regressions that were nothing but
stale binaries — the same "build nodes missing their real inputs" trap this project has hit before.

### A block-valued declared property, and Basic goes to zero on two axes (2026-08-02)

`readonly property color handleBorderColor: { if (activeFocus) return palette.highlight; else … }`
— Qt's RangeSlider. A script binding that is a BLOCK is folded into the equivalent conditional by
`blockToExpr`, which the base-property path has used since it was written; the DECLARED-property
path never learned, so the whole property was refused for the SHAPE of its value and both handles
drew their border with the type default.

This is the defect the earlier notes name twice — "the single missing path and the single render
difference are the SAME defect" — and it closes both:

| Basic | before | after |
|---|---|---|
| documents identical in every property | 47 of 57 | **48 of 57** |
| render at rest, byte for byte | 48 identical, 1 differing | **49 identical, 0 differing** |
| frame after a click | 33 identical, 0 differing | **34 identical, 0 differing** |
| diagnostics | 65 | **64** |

**Qt's entire Basic style now renders byte-identically to the engine, at rest and after a click.**

Fusion is unchanged by it (51 diagnostics, 43 of 49 identical, 40 renders, 28 clicks). Its four
render differences, measured: ComboBox (2949 of 3240 pixels, delta 19 — the largest open defect
left anywhere), Dial (390, delta 75), Switch (19, delta 1) and ToolBar (72, delta 1), the last two
antialiasing.

### Two attempts at the same defect, both reverted, and what they narrowed it to (2026-08-02)

Fusion's ComboBox is the largest render difference anywhere (2949 of 3240 pixels, delta 19) and the
cause is known: Qt's ButtonPanel asks `control.down || control.checked` about a ComboBox, which has
no `checked`. The engine reads the whole expression as `down`; we refuse the read, and the panel
loses its colour AND its gradient.

- **The read alone** — compile it as the meta read, which answers false/0/empty exactly as QML's
  `undefined` does in each target type. Fusion 51 → **149** diagnostics: 98 of them dead
  dependencies, because a member the type does not declare has no notify either. 43 → 41 documents
  identical, 17 → 22 value differences.
- **The read plus the dependency spelled as a PATH** (`control.down` instead of the bare `control`),
  which needed the declared-object-property rule added to `objPathHead` as well — the copy the
  WIRING re-resolves through, as opposed to `objPathExpr`, which the READ uses. That took the 98
  away, and left Fusion at **55**: four bindings that used to connect to the head now report a dead
  dependency on the member, and the ComboBox colour still does not compile. Every other number
  unchanged.

So it is not the read, and not the dependency spelling. The missing piece is the wiring answering
"the engine has nothing to connect to there either" in the consumer THIS shape reaches — the third
of three parts, with the other two written down in the code where the branch would go.

The pattern is the one this file keeps recording: **two halves have to land together.** Here there
are three, and shipping any two is worse than shipping none.

### A member the type does not declare — the third attempt, landed (2026-08-02)

Two earlier attempts were reverted; this one holds, and the difference is that it took FOUR parts,
not two. Qt's Fusion ButtonPanel asks `control.down || control.checked` and is used by a ComboBox,
which has no `checked`. The engine reads the whole expression as `down`; refusing the read cost that
panel its colour AND its gradient — 2949 of 3240 pixels, the largest render difference anywhere.

- **the READ**, when the registry describes the type and the member is simply not in it. QML answers
  `undefined` and the meta channel answers the same in the target's own terms: false, 0, empty;
- **the neutral hint.** `a || b` compiles its operands with NO target type, and the truthiness of a
  member the type does not declare is false — so the bool reader is the answer there, which is also
  what `__qmltcOr` wants. Without this the branch was never even reached for `control.checked`;
- **the DEPENDENCY spelled as a path** (`control.down`, not the bare `control`), which needed the
  declared-object-property rule added to `objPathHead` too — the copy the WIRING re-resolves
  through, as opposed to `objPathExpr`, which the READ uses;
- **the wiring answering "the engine has nothing to connect to there either"** in all THREE
  dependency consumers. Two of them already had it; the one a declared property's binding reaches
  did not.

And the branch that actually refused was none of the four: `control` is BOTH ButtonPanel's own
declared property and the enclosing ComboBox's id, so the read went down the enclosing-object path
and hit its "unknown member of that enclosing object: refused, not guessed" — which was right while
the registry could not tell "absent" from "unknown", and `typeKnownWithoutMember` can.

| Fusion | before | after |
|---|---|---|
| diagnostics | 51 | **48** |
| value differences | 17 | **16** |
| render at rest, byte for byte | 40 identical, 4 differing | **41 identical, 3 differing** |

ComboBox is identical at rest now and moves into the click axis, where it differs — an honest
comparison it could not take part in before. Basic is unchanged and still zero on both frame axes.

### What is left on the render axis, and a blind spot it exposes (2026-08-02)

Fusion's three remaining render differences, measured:

- **Switch** (19 of 1798 pixels, max channel delta 1) and **ToolBar** (72 of 312, delta 1) — one
  step of one channel at an edge. Antialiasing;
- **Dial** (390 of 10000, delta 75) — and this one has ZERO diagnostics and a value dump that is
  IDENTICAL to the engine's, line for line. The differing pixels are confined to a 24x34 box at
  (16,46)–(39,79) of a 100x100 frame: the quadrant the knob occupies at the default angle. Both
  sides agree on `handle.x/y/width/height/opacity/visible/rotation/scale` and on both entries of
  `handle.transform`. Whatever differs is inside a C++-painted item (`KnobImpl` is a
  QQuickPaintedItem), driven by something neither dump exposes.

That last sentence names the blind spot: the value differential compares the property paths the
DOCUMENT mentions, so a value group under an object we build — `handle.palette.button` and its
siblings — is never compared unless some binding writes it. The engine reports `#efefef` there for
the Dial; our side cannot be asked the same question through the same tool. Widening the dump to
descend one level into a value group is the next honest step on that axis, and it would be a
measurement change rather than a compiler one.

### Widening the dump: tried, reverted, and what it costs to do properly (2026-08-02)

The previous note called descending one level into a value group "a measurement change rather than a
compiler one" and the next honest step. It was tried and REVERTED, and the reason is worth the note:

**there are TWO walkers, not one.** The compiled side dumps through `qtd_dump_object` in the shared
runtime; the oracle has its own in `qtd_qmlvalues.cpp` and does not link the runtime at all — the
earlier claim in this file that "both sides call THIS function" is true of the FORMATTER, not of the
walk. Adding the descent to the runtime alone put 11704 rows on our side that the engine's had never
heard of. Adding it to the oracle's `--dumpall` loop as well brought that to 805 and 629, still not
level: `--dumpall` reaches its objects through a different path than the loop that was patched.

Both corpora are back to where they were (Fusion 43 of 49 identical / 16 differences, Basic 48 of 57
/ 21). The step is still the right one — the Dial's difference cannot be seen any other way — but it
is a reconciliation of two walkers, not a one-line descent, and half of it is worse than none of it.

### A declared object property with an initial value (2026-08-02)

"Only the UNBOUND form: an initial binding to an object is still refused" — the note that stood
beside that branch since it was written. Qt's SelectionRectangle writes
`property Item control: SelectionRectangle.control`, and the whole property was refused for HAVING a
value, which took the declaration with it: nothing that wrote to `control` afterwards had anything
to write to.

The property is declared the same way now and an object-valued initial binding is written through
`setPropObj`, the channel a use-site assignment already uses. The value here is an ATTACHED read and
`SelectionRectangle` is not a bound type, so its own initial value is still reported — one honest
message replacing a harsher one, with the property now existing either way.

Neither corpus moves on any axis, which is the expected shape for a file whose root is unbound. It
is recorded because the branch's comment no longer matches the code.

### `Qt.platform.pluginName`, and what the ContextMenu actually needs (2026-08-02)

`ContextMenu.menu` is the largest single cluster left (12 refusals across the two corpora) and the
gate note says the blocker is "the children". Reading them says exactly which:

- the Action types (`UndoAction`, `CutAction`, …) are **local `.qml` files** in
  QtQuick.Controls.impl, so they resolve like ButtonPanel does — not a missing binding;
- `required property Item editor` already compiles: `required` is a modifier the declaration path
  never had to care about;
- `popupType: Qt.platform.pluginName !== "wayland" ? Popup.Window : Popup.Item` did NOT. That is the
  third QML global with no QObject behind it, after the colour helpers and `Qt.styleHints`, and the
  runtime returns what the engine returns there: `QGuiApplication::platformName()`. It is also a
  CONSTANT for the life of the process, so it must not be recorded as a dependency — the other half,
  and the one that would otherwise report a dead dependency on an object called `Qt`.

`tests/qmltc/quick/QPlatform.qml` compares the value, the comparison Qt writes, and a concatenation.

**Neither corpus moves**, and that is the expected shape: the only place either style writes it is
inside the ContextMenu's Menu, which the attached-child gate still holds shut. This is a prerequisite
landing before the thing it is a prerequisite for, measured and said plainly rather than counted as
progress.

### What `ContextMenu.menu` needs, counted (2026-08-02)

The gate note has said "the blocker is the children" for two measurements. Compiling those children
one by one turns that into three named items — and the Actions turn out to be nearly finished
already. `UndoAction.qml` compiles its text (through `qsTr`), its whole `icon` group, and its
`enabled: editor.canUndo` binding WITH the connect. What is left, across all seven:

1. **`onTriggered: editor.undo()`** — a no-argument METHOD call on a declared object property. The
   registry publishes properties and signals per type but NOT methods: `qmlmethods.tsv` has 139 rows
   and all of them are singletons. So this is a generator change (publish per-type methods) before
   it is a compiler one, and `qtd_invoke0` is already in the runtime waiting for it. Seven of seven.
2. **`shortcut: StandardKey.Undo`** — an enum member of a namespace assigned into a property Qt
   declares as `QVariant`. This was written down as "same shape as `Easing.OutCubic`, which is
   solved"; checking rather than assuming says otherwise. `Easing` IS a singleton (the QML module
   exports it, and its members are read as ordinary properties); `StandardKey` is an UNCREATABLE
   type — `QKeySequence` with an `Enum` block — so there is no object to read from. The KEY string
   is no use either: Qt would parse `"Undo"` as three letters, not as the standard key. What is
   needed is the enum's VALUE, which qmltypes lists right there and the registry does not carry.
   Seven of seven.
3. **`editor.hasOwnProperty("cut")`** — a JS built-in on an object. Three of seven (Cut, Copy,
   Paste). The meta channel can answer it exactly: whether the object's meta-object declares that
   property, which is what `typeKnownWithoutMember` already asks in the other direction.

So TWO of the three are the same job before they are three jobs: **the registry does not publish
per-type methods or enum values**, and both are sitting in the qmltypes the generator already
parses. None of the three is the ATTACHMENT — which is what the gate has been saying since it was
first measured — and the first move is in the generator, not the compiler.

### The enum of a type exported for its enum alone (2026-08-02)

Second of the three the ContextMenu needs, and the note that named it was itself corrected on the
way: `StandardKey` is not a singleton (`Easing` is), it is `QKeySequence` — uncreatable, exported
for its `Enum` block. There is no object to read `StandardKey.Undo` from, the key as TEXT is no use
(Qt parses `"Undo"` as three letters), and qmltypes lists the enum's KEYS without their numbers.

The number is what QML assigns there, and `QMetaEnum` on the C++ type is where it lives — resolved
at RUNTIME, so no table of enum values is needed anywhere and the lookup works for any such type
without naming one. The registry already carried the C++ name (`qmlcxxnames.tsv` has
`QKeySequence → StandardKey`); only the reverse direction was missing.

`tests/qmltc/quick/QEnumOnlyType.qml` writes `Shortcut { sequence: StandardKey.Copy }` and reads
`nativeText` back: **Ctrl+C**, identical to the engine. A wrong number would show up as a different
shortcut rather than as a silent no-op.

Qt's seven editing Actions now compile everything except their `onTriggered` handler — text through
`qsTr`, the whole `icon` group, `enabled: editor.canUndo` with its connect, and the shortcut. The
last one needs per-type METHODS in the registry, which is the same generator job.

Neither corpus moves, for the same reason `Qt.platform` did not: the only place either style writes
this is inside the ContextMenu's Menu, behind the gate.

### Per-type methods in the registry, and five of the seven Actions (2026-08-02)

Third of the three, and the generator half was the whole of it: `qmlmethods.tsv` collected methods
only inside the `isSingleton: true` branch — 139 rows, all singletons. Lifting that loop out of the
branch publishes them for **every exported type**: 675 rows, and `TextInput undo` is one of them.

With the rows, `<objPath>.<method>()` in a handler body compiles to `invoke0`, which the runtime has
had all along. Two cases, and the second is the one Qt's own code needs:

- a method the type DECLARES and that takes no parameters — a row lookup, not a guess;
- a method the DECLARED type does not have. The editing Actions declare `property Item editor` and
  call `editor.undo()`, which no Item has: the object put there is a TextInput. `invoke0` resolves
  by name at runtime and returns false when there is nothing to call, which is the engine's own
  outcome for the same line.

**Five of Qt's seven editing Actions now compile with ZERO diagnostics** — text, icon group,
`enabled` with its connect, the shortcut, and the handler. The two left need one more thing each:
`DeleteAction` calls `editor.remove(a, b)` (a method WITH arguments, which is the invokable path),
and Cut/Copy/Paste ask `editor.hasOwnProperty("cut")` (a JS built-in the meta channel can answer
exactly, since it is the question `typeKnownWithoutMember` already asks in the other direction).

Neither corpus moves — the Actions are still behind the attached-child gate — and both are
unchanged at 64 and 48 diagnostics with every axis intact.

### All seven Actions, and a bug the fixture caught on its way (2026-08-02)

The last two of Qt's editing Actions needed one thing each, and both landed:

- **a method WITH arguments.** `editor.remove(editor.selectionStart, editor.selectionEnd)` goes
  through the same channel a singleton call uses — each argument crosses as text, QMetaType converts
  it to the parameter's own type — and the PARAMETER TYPES come from the registry row, which now
  exists. Typing them per-argument instead put a `double` where `invokeMixed` wants a string and the
  generated D did not compile;
- **`hasOwnProperty("name")`.** JS asking whether an object HAS a member; the meta channel answers
  exactly that, and it is the question `typeKnownWithoutMember` already asks at compile time. Cut,
  Copy and Paste guard on it because the editor they are handed may be a TextInput or a TextEdit.

**All seven of Qt's editing Actions now compile with zero diagnostics.**

`tests/qmltc/quick/QCallMethod.qml` then failed — and it was right to. `field.selectedText.length`
had compiled to `vgroupInt(field, "selectedText", "length")`: the value-group read added earlier
treated a STRING as a group and asked a gadget for a member it does not have, giving 0 where the
engine reads 5. A scalar is not a value group; the string-length rule beside it already answered
that shape. Neither corpus writes it, so only a fixture could find it — which is what fixtures are
for.

The Menu those Actions live in is the next layer and has its own list (its contentItem's `model`,
`interactive` and `currentIndex`, its background colour, and the attached children inside it). The
three prerequisites the gate note asked for are done.

### The attached-child gate, measured a third time — and the number finally moved (2026-08-02)

With all three prerequisites landed and all seven of Qt's editing Actions compiling whole, the gate
was re-measured. **Three attached children are emitted in Basic** where the two earlier measurements
emitted zero — the "compile it only if it compiles WHOLE" rule finally has something to let through.

It is still net negative and still shut:

| Basic, gate open + compile-whole | shut | open |
|---|---|---|
| documents identical in every property | 48 of 57 | 47 |
| paths the engine has and we do not | 0 | **21** |
| diagnostics | 64 | 107 |
| render at rest / frame after a click | 49 / 34, zero differing | 49 / 34, zero differing |

The diagnostics rise because the children compile and report their own gaps before being discarded;
the 21 are the real cost. But the blocker has moved up a layer and is named: it is the MENU those
Actions live in. Compiled on its own, Qt's `Basic/Menu.qml` has only the three attached-child
refusals; compiled as the ContextMenu's Menu — spliced, with a different enclosing scope — its
contentItem also refuses `model`, `interactive` and `currentIndex`. The same document, two scopes,
two answers, which is the shape this file has recorded a dozen times and the next thing to isolate.

### The Menu's two scopes — and a null result that was my own measurement error (2026-08-02)

The gate note names the next blocker as "the same document, two scopes, two answers": Qt's
`Basic/Menu.qml` compiles with three refusals on its own and adds three more when spliced as the
ContextMenu's Menu (`model`, `interactive`, `currentIndex` on its contentItem).

The obvious hypothesis was IDS. A spliced local type has two — the definition's (`id: control`) and
the use site's (`id: menu`) — and the pre-scan kept only the last, so `control.contentModel` would
stop resolving. Every place that compares against the self id was changed to consult a SET, and
`OuterFrame` was given one too so a child reaching up by name can use either.

It was reverted as "changed nothing", and **that conclusion was wrong** — the corpora cannot see it.
`TextEditingContextMenu.qml` is reached only THROUGH the attached-child gate, which is shut, so no
corpus number could have moved whatever the change did. Measuring the corpora and concluding "no
effect" measured the gate, not the fix.

Compiled directly, which is the only place it shows: **the spliced ContextMenu goes from 15
refusals to 10**, and every one of the Menu's own — `model`, `interactive`, `currentIndex`, the
background colour and its border — is gone. The hypothesis was right the first time.

What is left there is the three attached children and the seven Actions' `onTriggered` handlers,
which compile cleanly when those documents are compiled on their own and refuse as CHILDREN — the
same two-scopes shape, one layer down, and the next thing to trace.

The lesson is the one this file keeps writing down in different words: a null result is only
evidence if the measurement could have shown the effect. This one could not.

### A local type inherits its base's SIGNALS too (2026-08-02)

`adoptLocalTypeRows` copies the base's properties, notifies and C++ types onto a local `.qml` type's
name — the change that was once worth 93 diagnostics in one go. It did not copy the SIGNALS, and a
handler written on such a type was refused for want of a signature: Qt's `UndoAction.qml` compiles
`onTriggered:` cleanly on its own, where the type IS `Action`, and refused as a CHILD, where it is
`UndoAction`. Methods are adopted with them, for the same reason.

Two lines, and the spliced ContextMenu goes from **10 refusals to 3** — all three the attached
children, which are the gate itself. Everything Qt writes in that document now compiles.

**The gate, measured a fourth time.** Nine attached children are emitted in Basic (three before),
and the diagnostics IMPROVE for the first time: 64 → 59. What disqualifies it is four documents
THROWING at construction — ComboBox, SearchField, TextArea, TextField — all on one line:

    setProp failed: no writable property "parent" taking a QObject*
    on IComboBox_contentItem_ContextMenu_menu_dc2

That is the FALLBACK the child-append takes when `listAppend(this, "data", child)` fails. A Menu's
default property is `contentData`, not `data`, and the registry publishes it — qmlmap's fifth
column. Appending through the type's own default property is the next step, and it is not about the
gate at all.

### The gate, a fifth time: the append that falls back (2026-08-02)

Adopting the base's DEFAULT PROPERTY onto a local `.qml` type as well — a Menu holds its items in
`contentData`, not in `data` — is the same fix as the signals, in the same function, and it changed
nothing: the same nine attached children, the same four documents throwing on

    setProp failed: no writable property "parent" taking a QObject*

The refinement is worth more than the change. The generated Menu emits **no `listAppend` at all**
for its bare `MenuSeparator` children — only the hand-parenting fallback — so the label is not
reaching that object from the registry in the first place, and adopting a row it never consults
could not have helped. The registry has `Menu → contentData` in qmlmap's fifth column; what does not
happen is the lookup. That is where the next print goes.

The adoption stays: a local type inheriting its base's default property and list-property markers is
right whatever this particular append does with it.

Tracing beat guessing twice here, in opposite directions: the alias branch was written first from
assumption and did not fire (the gate that never asks for a string is in the base-assign path, not
in compileExpr), and then the argument turned out to be a separate gap that the same trace found in
one line.

## Where the four axes stand (2026-08-01, end of day)

Over Qt's own 57 Basic control documents, with the engine as the specification:

| axis | result |
|---|---|
| constructs | 61 of 61, 0 failures |
| VALUES, every property of every object | **47 of 57 documents identical**; 21 differences, 1 path the engine has and we do not, 121 unmeasurable |
| REACTIVITY, mutate then compare | six properties swept (`enabled`, `width`, `visible`, `padding`, `spacing`, `focus`); **no document that matches at construction and differs after a mutation** |
| RENDER, PNG byte for byte | **48 identical**, 1 differing, 12 the engine cannot render either |

The 21 value differences are attributed, not open: 10 are the header views (Qt's QML-instantiation
path, below), 9 are the `baselineOffset` layout-order difference, 2 are a popup `model` where the
engine keeps an empty variant and we keep a null object. The single missing path and the single
render difference are the SAME defect — RangeSlider's `readonly property color`, still refused.

The "unmeasurable" bucket is new and deliberate: Qt leaves a Transition's public `animations` list
empty at construction while holding the animations internally, so the oracle cannot read what our
side exposes there. Counting those as differences would have said 121 defects where there is no
comparison to make; counting them as matches would have hidden the same thing. They have their own
line.

What the day's measurements bought, in order of how much they moved:

- a TYPED list append needs the module imported, or QQmlListReference's type check fails silently:
  Transitions and transforms were built, wired and never linked (48 -> 47 identical was the cost of
  finding it, and 44 -> 47 the result of fixing it);
- a child is completed by its PARENT, once, after it is in the tree (popup.parent);
- a value group can change what it RESOLVES to with no member signal (palette, on `enabled`);
- a bare dependency resolves in the NEAREST scope, like the read does (SwipeView, TabBar);
- a QML type that cannot be subclassed can still be USED (the *Impl ceiling, 24 defects);
- `component X : Base {}` is a type, and a Component can be built from it (SelectionRectangle).

### OPEN, and SILENT: the header views differ with no diagnostic (2026-08-01)

`HorizontalHeaderView.qml` and `VerticalHeaderView.qml` compile with ZERO diagnostics and still
differ from the engine in five properties each — the worst class of difference this compiler can
produce, because nothing reports it:

| property | ours | engine |
|---|---|---|
| rows | -1 | 1 (H) / 0 (V) |
| columns | -1 | 0 (H) / 1 (V) |
| contentWidth / contentHeight | -1 | 0 |
| model | `<null>` | 0 |

Ruled out by measurement, so the next attempt does not redo it:

- **Not the type.** `__class` is `QQuickHorizontalHeaderView` on BOTH sides.
- **Not the delegate.** Ours holds one (`delegate=true`); the Component compiles and binds.
- **Not completion or the event loop.** rows/columns stay -1 after a second `componentComplete`
  and after 50 ms of event processing.
- **Not a missing `model` assignment.** Writing `model = 0` (the engine's own value) leaves
  rows/columns at -1, and the value does not even read back.

RESOLVED as to CAUSE the same day, and it is not the document and not the compiler. Three objects,
one process, one engine:

| built by | rows | columns | model |
|---|---|---|---|
| the engine, from the styled type | 1 | 0 | 0 |
| the engine, bare `T.HorizontalHeaderView {}` with an EMPTY body | 1 | 0 | 0 |
| plain C++ `new QQuickHorizontalHeaderView()` + classBegin + componentComplete | -1 | -1 | (empty) |

The bare instantiation already has the engine's numbers, so nothing in `HorizontalHeaderView.qml`
explains them — and a plain C++ construction with a QML context and an engine attached (`qmlContext`
non-null, `engine()` non-null) does NOT get them. Our compiled object behaves exactly like the plain
C++ one, which is the honest baseline: this is Qt's own QML-instantiation path doing something
C++ construction does not (the table's instance model is set up there).

It is still a divergence we own — the engine is the specification — but it cannot be closed by
compiling anything differently. The one route that would close it is the one the *Impl work built:
create the object THROUGH the engine and wire it from outside. For a document's ROOT that is a
different shape of compiler output, so it is written down here rather than attempted.

### The "unexportable *Impl" is NOT a ceiling — it is a ceiling on SUBCLASSING (2026-08-01)

Twenty-four of the 54 remaining value defects are one story: Dial's `background: DialImpl {}`,
BusyIndicator's and ProgressBar's `contentItem`. Those types export ZERO C++ symbols (`nm -D` on
libQt6QuickControls2Impl finds none, while it does export QQuickIconLabel, QQuickColorImage,
QQuickCheckLabel and friends), so no D subclass of them can exist and the compiler refuses them —
recorded for weeks as a verified ceiling.

Measured today, and the recorded belief is too strong. They are registered QML TYPES, and the
engine builds them by name:

    DialImpl:           class=QQuickBasicDial            isItem=true, implicitWidth writable
    BusyIndicatorImpl:  class=QQuickBasicBusyIndicator   isItem=true, implicitWidth writable
    ProgressBarImpl:    class=QQuickBasicProgressBar     isItem=true, implicitWidth writable

(one-line component from `QtQuick.Controls.Basic.impl 2.0`, created, then written through the
meta-object). So what is impossible is SUBCLASSING one; a document that instantiates and configures
one does not need a subclass. The shape that fits: the generated child is a plain `@QObject` that
holds the engine-created instance and writes it BY NAME — its reactive bindings are slots on that
helper, its connects are made on the instance, and the parent assigns the instance to the property.
Every piece already exists (the delegate work built the component + registration path).

DONE the same day. The generated class holds the instance in `__inst` and every self read, write
and connect goes to it — the emitter's own text, rewritten at class assembly: `(this` is always the
first argument of a self operation, and a RECEIVER is always `, this, "slot()"`, told apart from a
DESTINATION (`copyProp(src, "p", this, "q")`) by the signature's trailing `()`. Getting that
distinction wrong is silent — the value lands on the wiring object and the instance keeps its
default — so it is spelled out in the code. The dump follows the same rule: an engine-created child
is dumped (and its linkage asserted) through `.__inst`, because the wiring object is not what the
property holds.

Prerequisite, and the recurring pattern again: the compiler could not know the URI because the
generator never scanned `QtQuick/Controls/Basic/impl/plugins.qmltypes`. Adding it to the spec gave
`DialImpl -> QtQuick.Controls.Basic.impl` plus 52 property rows for it — the fact was published, we
were not reading it.

Measured on Qt's own Basic controls: **value-diff defects 54 -> 29**, files identical 39 -> 42,
diagnostics 78 -> 76, 61/61 construct, 0 link/run failures, full build green.

Not covered by this and still true: an engine-created child cannot have CHILDREN of its own yet
(they would take the wiring object as their enclosing scope, not the instance). Qt's three uses are
leaf objects, so nothing in this corpus exercises it — but a document that nests inside one would
be wrong, so that is the next thing to close here.

### LANDED, after the two findings below were fixed: `font.bold` / `origin.x` (2026-08-01)

Both blockers turned out to be real bugs elsewhere, which is why the first attempt was reverted
rather than patched:

1. **The write needed the module IMPORTED.** Measured with a probe: on a plain QQuickText created
   in C++, `QQmlProperty(obj, "font.bold", ctx)` is not even VALID (while `text` is) — and after
   `import QtQuick` it is valid, writable and typed `bool`. QML's value-type registry is populated
   by the import, and importing the STYLE module is not enough. The write helper asks for QtQuick
   by name, once.
2. **The deep-read accumulator leaked across objects** — fixed separately (see the commit "a deep
   read belongs to the binding being compiled"). That is what made compiling ONE more expression
   put `bindLeaf(__outer.__outer, ...)` in a ROOT class and break the link.

Measured after landing: diagnostics 83 -> 78, value-diff defects 56 -> 55, 0 link/run failures, and
Qt's Dialog now differs from the engine in exactly ONE property (`header.baseUrl`) where it
previously differed in the header's FONT as well.

That remaining one is fixed too, and it inverted a deliberate decision: a child compiled from a
LOCAL `.qml` type used to emit its own file's url as the context baseUrl (`Label.qml`), on the
reasoning that a class should carry ITS document's. The engine reports the INSTANTIATING document
(`Dialog.qml`), so a relative url inside a local type resolves against the file that USES it — and
the engine is the specification. Measured after the change: files identical 38 -> 39, value-diff
54, nothing else moved, full build green. **Qt's Dialog is now byte-identical to the engine.**

### (superseded) Attempted and REVERTED: `font.bold` / `origin.x` through QQmlProperty

A value type reached through an EXTENSION (QFont via QQuickFontValueType, marked `^` in the
registry) has no meta-object, so the gadget read-modify-write cannot reach it — the compiler
refuses those, deliberately. The obvious channel is `QQmlProperty(obj, "font.bold", qmlContext(obj))`,
which is how QML itself resolves value-type members. It was built end to end and measured, and it
produced two findings, both worth keeping:

1. **The write does not take on our objects.** `QQmlProperty` reports the path as not valid /
   not writable, so the runtime's honest error fired (`setProp failed: no writable property
   "font.bold"`) and Dialog went RUNFAIL. Whatever the channel is, it is not QQmlProperty against
   the context we attach — that needs to be understood before writing any more of it.
2. **It exposed a hazard in the LATE wiring.** With `origin.x` compiled (Dial's `transform:
   Rotation { origin.x: handle.width / 2 }`), Dial stopped LINKING: the ROOT class gained four
   `__outer.__outer` references in its own late wire — `bindLeaf(__outer.__outer, "handle", ...)`
   for the root's `__rcb_implicitWidth` — and a root has no enclosing object at all. Counted per
   class: the transform children legitimately hold such chains (10 and 3); the root held none
   before and four after. So a deep-read late connect can be resolved against an outer chain that
   belongs to a CHILD, and it took compiling one more expression to make it visible.

Reverted whole (compiler and runtime), corpus back to 83 diagnostics and 0 link/run failures. The
next attempt starts with finding 2, not with the feature: a root that connects through
`__outer.__outer` is wrong however the value gets written.

### One bug this exposed: every object was completed TWICE

Each generated object ran `classBegin`/`componentComplete` on itself AND again from its parent's
wire. Recorded earlier as "harmless in every measurement so far"; it is not. A Repeater
re-completed after it has created its items releases them through an already-completed
QQmlDelegateModel, and Qt segfaults in `QQuickRepeater::clear()`. Each object now completes itself
exactly once, at the end of its own wire — children are constructed during the parent's wire, so
they still complete first, which is the order this was for.

Measured over Qt's own Basic controls, this one fix moved more than the feature did: files
IDENTICAL to the engine in every property 33 -> 38, value-diff defects 74 -> 63.

### The label fix, and what it revealed

Resolving an INDEXED dump path through the meta-object list (as the oracle does) rather than
through the D field that happens to hold that child: paths "absent in the engine" 135 -> 11, and
paths "absent in ours" 1 -> 23. The 135 were almost entirely a harness artefact — our field and the
engine's `data[0]` were two different objects under one label. The 23 are real and already
attributed: the unbound `*Impl` ceiling (BusyIndicator, Dial), the documented baselineOffset
layout-order difference, and one new one worth chasing — DelayButton's `contentItem.data[0]` and
`data[1]` are SWAPPED relative to the engine.

### The attached-child gate, measured a sixth time — the blocker is finally NAMED (2026-08-02)

Five measurements of this gate had produced numbers and no cause: open it and the corpus gets worse,
close it and the ContextMenu never compiles. The sixth one asked a different question — not "what
does the corpus do", but "what does the compiler SEE at the moment it decides". With the gate open,
a print at the default-child label branch in `compileObject` shows the attached Menu compiled as:

    QTDDBG defkids cls=ITF_ContextMenu_menu selfQml=TextEditingContextMenu boundBase= label=[] dpSelf=[contentData]

**No bound base.** Qt's `TextEditingContextMenu` is a `Menu`, and inside a *style* document that
`Menu` is the STYLE's own `Menu.qml` — not the Templates type. One `loadLocalType` stops at a root
that is ITSELF a local type, so the chain to a C++ base is never walked and `boundBase` comes back
empty. The label branch requires a bound base, so it never runs; the append falls through to
hand-parenting, and that is the `parent` write that throws at run time. Every earlier measurement
was watching the consequence.

Following the chain was tried and does not resolve it on its own: `boundTypeFor` depends on the
import state of the document currently being parsed, and `loadLocalType` swaps that state out
underneath it. The fix is a local-type resolution that CHAINS and manages the import state the way
the root path already does — a refactor, not a branch, which is why it is written down here rather
than attempted as a seventh measurement.

The method note is the one worth keeping: five measurements of the OUTPUT could not name this, and
one print at the DECISION did. When a number refuses to move, the next measurement belongs inside
the branch, not around it.

### The chain: a local type can derive from another local type (2026-08-02)

The blocker the sixth measurement named, fixed. `resolveLocalChain` replaces the one-hop
`loadLocalType` at all FIVE places that resolved a local `.qml` type — default child,
property-bound child, delegate/`Component`, grouped-property child, attached child. It follows the
derivation until it reaches a bound C++ base, splices every level's members in definition order
(base first, use site last, so QML's last-wins override still holds), adopts the registry rows
DEEPEST FIRST (each level inherits from the one below it, so adopting shallow-first would copy rows
that do not exist yet), and records every file it visits so the cycle guard covers the whole chain
rather than only its first link.

Qt's `TextEditingContextMenu` is two hops: it is a `Menu`, and inside a style directory that `Menu`
is the style's own `Menu.qml`, whose root is `T.Menu` — the bound one.

**Measured with the gate OPEN, which is the only place it can show.** Before, four documents in each
corpus threw at construction on the same line (`setProp failed: no writable property "parent"`);
after, **zero** — Basic and Fusion both come out with exactly the instantiation profile they have
with the gate shut. At the SHUT gate the change is inert, and that was verified rather than assumed:
both corpora's diagnostics are byte-identical to the previous build.

It also exposed one real hole of its own. The `import <pkg>.qcolor` a `property color` needs was
derived from the ROOT's bound module, and Fusion's `SpinBox` has none (QQuickSpinBox is not in the
binding) — so once its ContextMenu subtree compiled, two documents came out with a `QColor` field
and no module, which is a compile error in the generated D rather than a diagnostic. The package now
falls back to any bound type the document already imports.

### The attached-child gate, measured a SEVENTH time — still shut, and now for a different reason

With the chain in place the four throws are gone, so the gate could finally be judged on its output
rather than on a crash. It is still net negative, by a wide margin:

| Basic, gate open + compile-whole | shut | open |
|---|---|---|
| documents identical in every property | 43 of 57 | 40 |
| value differences | 21 | 95 |
| paths the engine has and we do not | 14 | **2651** |
| paths we have and the engine does not | 155 | 155 |
| diagnostics | 64 | 79 |

The gate stays shut, and the reason has moved from "it crashes" to "it is incomplete". But the 2651
was NOT all the compiler, and attributing it took one more measurement — see the next two sections.

### The two dump walkers disagreed about an attached path (2026-08-02)

`--objpaths` and `--dumpall` share `collectDump`, so it looked impossible for them to enumerate
different objects. They do not share how an INDEXED path is RESOLVED. The non-indexed branch reuses
the D expression the compiler already built (which knows how to reach an attached object); the
indexed branch rebuilds the path segment by segment out of `propObj` calls, and `ContextMenu` is not
a property of anything — it is a type name resolved through Qt's registry. So `--objpaths` listed
`ContextMenu.menu.contentData[0]`, the oracle walked it and dumped 78 properties, and our side
resolved a null and printed nothing.

Measured on `TextField` with the gate open: **664 of the paths counted as "the engine has and we do
not" were this**, not the compiler. The indexed walker now emits `attachedObj(...)` for a segment
the registry knows as an attached type, and TextField's total drops from 664 to 507. At the SHUT
gate the change is inert — the corpus is identical property for property (43 identical, 21 value
differences, 155 only-ours, 14 only-engine) and both corpora's diagnostics are byte-identical.

The lesson has a name in this file already: the harness lies as much as the compiler. Two walkers
built from one tree are still two walkers.

### What is actually left behind the gate: the Menu never wraps an Action

With both of those out of the way, the remaining difference under the attached ContextMenu is a
single fact. Qt's Menu turns an `Action` child into a `MenuItem`: `contentData_append` sees a
non-Item and asks `createItem(action)`, which instantiates the Menu's `delegate` component and binds
the action to it. The engine's `contentData[0]` is a `QQuickMenuItem` with 78 properties; ours is the
`QQuickAction` itself, with the two the engine's MenuItem does not have.

So the blocker is the DELEGATE: our compiled Menu has no `QQmlComponent` in `delegate`, so Qt cannot
wrap anything, and every one of those nine children is the wrong class. That is a concrete,
single-cause target — and it is the same `Component`-as-a-template machinery the delegate path
already has, pointed at a property the Menu reads rather than at a view.

### Every remaining "path we have and the engine does not" was ONE fact (2026-08-02)

The value differential counted 155 paths in Basic (125 in Fusion) that we emit and the engine does
not. Attributed by document, they are not scattered: StackView 60, Drawer 30, ScrollBar 19,
ScrollIndicator 19, SwipeDelegate 15, DelayButton 12 — and **every one of them is a
`Transition.animations[...]`**.

Qt's `QQuickTransition` declares `Q_CLASSINFO("DeferredPropertyNames", "animations")`. The engine
does not create a transition's animations until the transition RUNS; `QQuickTransition::prepare()`
calls `qmlExecuteDeferred` on itself. Probed directly against the engine, `popEnter.animations` on a
Basic StackView has **count 0** at rest. We create them eagerly, so at rest our object graph has
objects the engine's does not — and both animate identically once the transition runs.

So the difference is in WHEN, not in what, and at rest it is not comparable at all. The oracle
already said so in its own output: it prints `<path>.<missing>` for a path it cannot walk, and
there are exactly 14 of those in Basic — one per deferred transition, matching the six buckets above.

`tools/qmltc-value-census.py` makes that distinction a bucket instead of a footnote. It reads the
same `.dall.s`/`.qall.s` pair the comparison script writes and splits the differences into
value-diff / only-ours / only-engine / **unmeasurable** (ours under a path the oracle marked
`<missing>`). Measured on both corpora:

| | Basic | Fusion |
|---|---|---|
| documents | 57 | 49 |
| identical | **48** | **43** |
| value differences | 21 | 16 |
| paths we have, engine does not | **0** | **0** |
| paths the engine has, we do not | **0** | **0** |
| unmeasurable (deferred transitions) | 155 | 125 |

The whole residue is 37 value differences across four causes, all already named: the
`baselineOffset` layout-order difference (CheckBox, RadioButton, Switch, TextField), DelayButton's
swapped `contentItem.data[0]`/`[1]`, the two HeaderViews' uninitialised `rows`/`columns`/
`contentWidth`/`contentHeight`/`model`, and ComboBox/SearchField's `popup.contentItem.model`.

### The THIRD construction phase: QQmlFinalizerHook (2026-08-03)

Two of the four remaining value-difference causes were the HeaderViews, and they turned out to be
one fact that applies far beyond them. The engine gives a bound type **three** construction phases,
not two:

1. `QQmlParserStatus::classBegin()` — before its properties are set,
2. `QQmlParserStatus::componentComplete()` — once the tree is built,
3. **`QQmlFinalizerHook::componentFinalized()`** — from `QQmlComponent::completeCreate()`, once the
   whole component is finalized.

We implemented the first two and not the third. A `QQuickTableView` does all of its work in the
third: measured on Qt's own `HorizontalHeaderView`, after `classBegin` + `componentComplete` the
object still reports `rows`/`columns`/`contentWidth`/`contentHeight` all `-1` and an unset `model`,
where the engine reports `1`/`0`/`0`/`0` and `model` as int `0`. Calling `componentComplete()` a
second time changes nothing; nor does an event-loop turn; one call to `componentFinalized()`
reproduces the engine's state exactly. That isolation was done against the engine itself
(`beginCreate` → hand calls → `completeCreate`), so it is the engine's own answer, not a guess.

It is not a per-type mechanism, and nothing about TableView is written down anywhere: the registry
publishes it (`interfaces: ["QQmlFinalizerHook"]` on `QQuickTableView`, on `QQuickWindow`, and on
whatever else declares it), `Q_INTERFACES` puts it in the meta-object, and the runtime finds it by
IID for any type that has one. The interface is *declared* in the runtime rather than included from
`QtQml/private` — it is a virtual destructor followed by one pure virtual, and the cast resolves it
by IID string, so a matching declaration is ABI-compatible without depending on a header Qt says
"may change from version to version without notice". Qt5 has no such phase at all, so doing nothing
there is the parity.

The generated code gets a `__qmltcFinal()` pass beside `__qmltcLate()`, fired by the root after it.
Order is the engine's: hooks are registered as objects are CREATED, so an object is finalized before
its children — the opposite of `componentComplete`, which the engine runs in reverse.

Measured over both corpora:

| | Basic before | Basic after | Fusion before | Fusion after |
|---|---|---|---|---|
| documents identical in every property | 48 of 57 | **50** | 43 of 49 | **45** |
| value differences | 21 | **11** | 16 | **6** |
| render at rest | 49, 0 differ | 49, 0 differ | 41, 3 differ | 41, 3 differ |
| frame after a click | 34, 0 differ | 34, 0 differ | 28, 4 differ | 28, 4 differ |
| diagnostics | 64 | 64 | 48 | 48 |

`tests/qmltc/quick/QFinalize.qml` pins it, and the fixture was verified to be able to FAIL: with the
`__qmltcFinal()` call stripped from the generated D, five of its nine values diverge (`-1` against
the engine's computed ones). A differential that cannot fail is the recurring way this project has
produced false green, so the negative control is part of the work, not an afterthought.

What is left is 17 value differences over both corpora and three causes: the `baselineOffset`
layout-order difference, DelayButton's swapped `contentItem.data[0]`/`[1]`, and
ComboBox/SearchField's `popup.contentItem.model`.

### Children come AFTER the object's own assignments (2026-08-03)

The `baselineOffset` difference, which this file has carried as "a layout-order difference" for
several rounds, is now identified and fixed. It was an ORDERING defect on our side.

The engine assigns everything written in a document body first and creates `background`,
`contentItem` and `indicator` inside `componentComplete` — they are DEFERRED properties
(`Q_CLASSINFO("DeferredPropertyNames", …)` on `QQuickControl` and friends). We built the children
first. What that changes is not the child's final state but **how many times the parent makes it
re-lay out**: Qt's CheckBox writes `spacing: 6` and a contentItem whose `leftPadding` reads
`indicator.width + control.spacing`. Built child-first, that binding settles at 28 (spacing still
0), the Control sizes the text, and the later `spacing: 6` re-runs it to 34 — a second text layout,
this time with a valid height, which is what moved `baselineOffset` from 14.84375 to 19.34375.
`leftPadding` ends at 34 either way, so only the baseline showed it.

Getting there took isolating the case against the engine itself. Nine reconstructions of the shape
(a Control with a Text contentItem, assigned in the document, assigned from C++ afterwards, with a
CheckLabel, with implicit sizing) all produced OUR number; only Qt's own file produced the engine's,
and the discriminating fact turned out to be that a bare CheckBox has **empty text** — an empty Text
does not re-lay out on a width change, so its baseline stays from the first layout. That is also
why the first version of the fixture below passed with the defect still in place.

Three parts had to land together:

1. **Order.** `baseWire` (this object's own property assignments) now precedes `dcWire`/`childWire`.
2. **Assignments that NAME a child** move back after them — the mirror of the existing `earlyWire`,
   which moves up the assignments the children READ. `probe: label` was assigning null; the
   `QDeclObjType` fixture caught it.
3. **Dependencies on a child** go to the late phase, like a sibling's. `connectMeta(_dc0, …)` in the
   wire now runs before the child exists and threw — Qt's TextField reads
   `placeholder.implicitWidth`. The late phase already existed for exactly this shape and
   re-evaluates once after connecting.

Measured over both corpora:

| | Basic before | Basic after | Fusion before | Fusion after |
|---|---|---|---|---|
| documents identical in every property | 50 of 57 | **54** | 45 of 49 | **46** |
| value differences | 11 | **4** | 6 | **5** |
| render at rest | 49, 0 differ | 49, 0 differ | 41, 3 differ | **42, 2 differ** |
| frame after a click | 34, 0 differ | 34, 0 differ | 28, 4 differ | **29, 4 differ** |
| diagnostics | 64 | 64 | 48 | 48 |

`tests/qmltc/controls/CAssignOrder.qml` pins it, and — as with the finalize hook — the fixture was
verified able to FAIL: with the two assignments moved back after the children in the generated D,
`contentBaseline` reads 5.34375 against the engine's 14.84375 and `ownBaseline` 11.34375 against
20.84375.

What is left is nine value differences over both corpora and two causes: DelayButton's two
`contentItem.data[i].baselineOffset` (the same family, inside an `ItemGroup` whose children are
built by a C++ type rather than by us) and ComboBox/SearchField's `popup.contentItem.model`.

### The last two causes are ONE fact, and the engine confirmed it (2026-08-03)

Nine value differences remain over both corpora. Traced, they are not two problems but one, and it
is the same mechanism the previous section only half-applied.

**Fusion ComboBox: `popup.contentItem.highlightRangeMode` reads `NoHighlightRange` where the
document says `ListView.ApplyRange`.** The write is emitted, and it works — writing the key after
construction gives `ApplyRange`. Bisected with a print at each step of the generated wire, the value
survives the ListView's own wire, survives `setPropObj(popup, "contentItem", …)`, survives
`componentComplete(contentItem)` — and is gone one statement later, at
`setPropObj(this, "popup", popup)`.

That is `QQuickComboBox::setPopup`, and it is not our code. Reproduced against the engine alone: build
a `T.Popup { contentItem: ListView { highlightRangeMode: ListView.ApplyRange } }`, read
`ApplyRange`, assign it to a `T.ComboBox`, read `NoHighlightRange`. The engine escapes it only
because `popup` is a DEFERRED property of the ComboBox **and `contentItem` is a deferred property of
the Popup**: when `setPopup` runs, the ListView does not exist yet.

So the rule the previous fix applied WITHIN an object has to apply BETWEEN them as well: an object's
children belong after the object is assigned to its parent's property, not inside its constructor.
Our order is

    popup = new IComboBox_popup();   // ...which builds its contentItem too
    setPropObj(this, "popup", popup);

and the engine's is the reverse. DelayButton's two `contentItem.data[i].baselineOffset` are
consistent with the same fact one level down: its `ItemGroup` and the two `ClippedText`s inside it
are built before the Control ever sizes the group, so the texts get a resize the engine's never see.

The change that follows is real work rather than a branch: each class's wire has to split into "my
own properties" and "my children" — the split already exists in the emitter as
`baseBeforeKids` / `dcWire`+`childWire` / `baseAfterKids` — with the second half exposed as a method
the PARENT calls between assigning the object and completing it. Written down here with its evidence
rather than attempted at the end of a session.

### DONE: an object's children are built after it is ASSIGNED (2026-08-03)

The restructuring the previous section named, done. Each generated class's wire splits in two:

- `__qmltcWire()` — what the object does to ITSELF: context, `classBegin`, its bindings' connects,
  its own property assignments.
- `__qmltcKids()` — its children, the assignments that name one, its handlers, the initial binding
  pass, and its completion.

The PARENT calls `__qmltcKids()` between assigning the child to its property and completing it. The
root calls its own at the end of its wire — as do the group, attached and value-source children,
which is exactly the set that already completes itself because nobody else can.

The split point was not invented for this: the emitter already computed it for the previous fix
(`baseBeforeKids` / `dcWire`+`childWire` / `baseAfterKids`), so the change is one offset recorded
while `wire` is assembled and one `substr` at the end.

Measured: **Fusion's value differences 5 → 4** — `popup.contentItem.highlightRangeMode` now reads
`ApplyRange` on both sides, which was `QQuickComboBox::setPopup` resetting a ListView that, in the
engine, does not exist yet when it runs. Basic stays at 4, both corpora keep 0 only-ours and 0
only-engine, render (49/0 and 42/2) and click (34/0 and 29/4) are unchanged, and so are the
diagnostics (64 and 48) and the instantiation profile.

`tests/qmltc/controls/CDeferKids.qml` pins it, verified able to FAIL: with the popup's contentItem
moved back into the popup's constructor, it reads `NoHighlightRange` against the engine's
`ApplyRange`.

Eight value differences remain over both corpora: DelayButton's two
`contentItem.data[i].baselineOffset` in each style (its `ItemGroup` sizes its texts itself, so the
same order argument applies one level further down than any property the compiler assigns) and
ComboBox/SearchField's `popup.contentItem.model`, where the engine leaves an invalid QVariant and we
write a null QObject.

### A null object copied into a `QVariant` is QML's `null` (2026-08-03)

`copyProp` carries a property between objects as a QVariant and lets QMetaType convert on write —
which is what makes `font: control.font` compile without the generator knowing QFont. When the value
is a null OBJECT and the target is a `QVariant` property, that is one conversion too few: the engine
leaves `std::nullptr_t` there and we left the source's own pointer type.

Qt's ComboBox binds `model: control.delegateModel`, and `delegateModel` is null until a model is
set. The dump read `<null>` on our side (a `QQmlInstanceModel*` that is null) and empty on the
engine's (a `nullptr_t`) — the same value, spelled as a different type, and nothing else would have
shown it because the write succeeds either way. Probed against the engine: a bare `ListView {}`
leaves the property INVALID, `model: null` leaves `std::nullptr_t`, and a straight QVariant copy of
`delegateModel` leaves `QQmlInstanceModel*`.

Only for a `QVariant` target — a typed object property must keep taking a typed null or the write
would simply fail — and `QMetaProperty::metaType()` is Qt6, so Qt5 asks `userType()` instead.

Measured: **Basic 54 → 56 documents identical (4 → 2 value differences), Fusion 46 → 48 (4 → 2)**.
Render, click, diagnostics and the instantiation profile all unchanged.

`tests/qmltc/controls/CNullModel.qml` pins it. Its negative control is not synthetic: the same shape
in Qt's own ComboBox and SearchField, in both styles, read `<null>` against the engine's empty in the
measurement immediately before this change.

**What is left is one difference, in one document, in each style**: DelayButton's
`contentItem.data[0]` and `[1]` `baselineOffset`, which are each other's. Its `ItemGroup` sizes the
two `ClippedText`s itself, so the ordering argument that fixed the rest applies one level below any
property the compiler assigns.

### The last difference, characterised: which ItemGroup child gets resized (2026-08-03)

One value difference remains, in one document per style: Qt's DelayButton, whose contentItem is an
`ItemGroup` holding two `ClippedText`s. Ours reads `data[0].baselineOffset` 5.34375 and
`data[1]` 14.84375; the engine reads them the other way round. Every other property of both objects
matches — same class, same clip, same colour, same `visible`, same geometry.

Both texts are EMPTY (a bare DelayButton has no text), and an empty Text never re-lays out on a
width change, so each keeps the baseline from its one and only layout. 14.84375 is that layout with
the height still implicit; 5.34375 is the same layout after the group has assigned the child a
height. So the whole difference is WHICH child the group resized.

Probed against the engine, with no compiler in the picture:

| document | result |
|---|---|
| Qt's `Basic/DelayButton.qml` | `[0]=14.84375  [1]=5.34375` |
| `Control { contentItem: ItemGroup { Text Text } }` | `[0]=14.84375  [1]=5.34375` |
| ...with ONE child | `[0]=5.34375` |
| ...with THREE | `[0]=14.84375  [1]=14.84375  [2]=5.34375` |
| a bare ItemGroup, appended one at a time | `[0]=5.34375  [1]=14.84375` |

The engine resizes the **last** child appended; appending one at a time resizes the **first** — the
group's implicit height goes 0 → 19 on that append, its own height follows, and the resulting
`geometryChange` sizes the children it has so far. The compiled side appends one at a time, so it
gets the second pattern; nothing the compiler assigns is involved, and no reordering of OUR
statements reproduces the engine's, because the trigger is inside `QQuickItemGroup`'s implicit-size
propagation and fires on a different append.

Left as a difference rather than papered over. It is one read-only property, on one document per
style, that no binding in either corpus reads, and both the frame at rest and the frame after a
click are byte-identical for DelayButton on both sides. Recorded here with the probe that
characterises it so the next attempt starts from the table rather than from the symptom.

### A `QJSValue` property still holds an object — and it hid the gradients (2026-08-03)

`Rectangle.gradient` is a `QJSValue` property: it takes either a `Gradient` object or a preset name.
Read as `QObject*` it comes back null, and BOTH sides did exactly that — the oracle answered
`<missing>` for `background.gradient` and for every stop under it, and our `--dumpall` walker
resolved a null and printed nothing. So a Fusion ToolBar's two `GradientStop`s, which decide the
whole frame, were emitted by neither side and compared by nobody, while the render differed by one
step of grey with nothing in the value differential to show for it.

Unwrapped on both sides — `QJSValue::toQObject()`, public API, null for a non-object, which lands on
the same failure path as before. The oracle was fixed first, on purpose: with only that half, Fusion
went from 0 to **227 paths the engine has and we do not**, in 13 documents, which is the honest size
of the hole. With our side unwrapped too it is back to 0 — and the paths are now COMPARED rather
than absent: Fusion's unmeasurable bucket drops 125 → 95, and all 30 of those paths match, including
the ToolBar stops (`#f9f9f9`, `#efefef`) on both sides.

Nothing else moved: Basic and Fusion stay at 56 and 48 documents identical with 2 value differences
each, render at 49/0 and 42/2, diagnostics at 64 and 48.

This is the same lesson as the indexed attached path, in a different property type: two walkers built
from one tree are still two walkers, and a path neither of them can reach reports as agreement.

### `Qt.lighter` lost 8 bits, and it cost two frames and four clicks (2026-08-03)

With the gradient stops finally in the comparison and MATCHING, Fusion's ToolBar still rendered
differently. Mapped pixel by pixel: six full rows of its 26 — rows 0, 3, 8, 11, 16, 19 — one grey
step brighter on our side, and one row of Fusion's Switch the same way. Six rows is a gradient
rounding boundary, not a colour someone wrote.

The stop colours compare equal because the comparison reads `#f9f9f9`, and that is the whole
problem: a QColor holds 16 bits per channel and `Qt.lighter(control.palette.window, 1.04)` produces
a value that is not 8-bit. The invoke path already knew this — `qtd_var_text` spells a colour
`#rrrrggggbbbb` for exactly this reason, and the note there says it was the difference "the engine
showed on every gradient stop". The `Qt.*` colour helpers did not use it: `Qt.lighter`, `Qt.darker`,
`Qt.alpha` and `Qt.color` each spelled their result with `QVariant::toString()`, so the colour was
truncated on the way out and parsed back one step off.

One line each, and the differential could not have caught it — both sides were reading the same
truncated spelling.

| | before | after |
|---|---|---|
| Fusion render at rest | 42 identical, 2 differ | **44 identical, 0 differ** |
| Fusion frame after a click | 29 identical, 4 differ, 2 unmeasurable-at-rest | **33 identical, 2 differ, 0 at rest** |
| Basic render / click | 49 / 34, zero differing | unchanged |
| values, diagnostics, instantiation | — | unchanged |

The two clicks that still differ are BusyIndicator and ComboBox. Everything else in Qt's Fusion
style that this compiler can build now draws the same frame as the engine, at rest and after being
pressed.

### `gradient: cond ? null : <object>` is a BINDING (2026-08-03)

The last click difference that was not the BusyIndicator ceiling. Fusion's ComboBox, after being
pressed, differed in **2714 of 3240 pixels** — every row of the panel — with **every readable
property of both sides already equal**. Ruled out first, one probe each: the state (696 dotted keys
read back from the engine's object after the same click: no difference), window activation (the
engine's window is active too, and forcing it changes nothing), and the harness shape (the engine
built in a bare `QQuickWindow`, exactly as ours is, gives a frame identical to the `QQuickView` one
and still differs from ours).

What was left was a pixel map: rows 0, 6, 7 and 26 identical, every other row different across the
full width, ours `#f9f9f9` where the engine had a flat `#dbdbdb`. A flat colour where we draw a
gradient — and `ButtonPanel.qml` says why:

    gradient: control.down || control.checked ? null : buttonGradient

The compiler already handled the object-or-null ternary; it emitted it as a one-shot and `continue`d
past the binding path. So the panel kept the unpressed gradient forever, and the flat pressed colour
underneath never showed. It now falls through to the same recompute-and-connect the scalar bindings
take.

Two smaller things had to come with it:

- A bare CHILD ID as a dependency (`buttonGradient`) is a field that never changes, so it is a
  constant, not an unwired dep. Without that the fix added six diagnostics calling a correct
  translation incomplete.
- **A `QJSValue` property that holds a QObject is an object slot**, and both formatters said nothing
  for it — so `background.gradient` compared as blank on both sides whether it held a Gradient or
  null, which is why only the pixels could see this. Both now report `<object>`; a QJSValue that is
  NOT a QObject is still skipped, deliberately: `Text.fontInfo` is a plain JS object on the engine's
  side and nothing on ours, and spelling it `[object Object]` added eleven differences that are a
  spelling rather than a defect. (Measured both ways — that is where the eleven came from.)

| | before | after |
|---|---|---|
| Fusion frame after a click | 33 identical, 2 differ | **34 identical, 1 differ** |
| everything else | — | unchanged |

The one remaining click difference in either corpus is BusyIndicator, which is the documented
unbound-`*Impl` ceiling: its animation lives in a QML type the style plugin exports without a C++
symbol we can subclass.

No fixture: the value protocol reads `background.gradient` through `propStr`, which is empty for a
QJSValue either way, so a fixture built on it would pass with the defect in place. The guard is the
click render on the corpus — which is what found it.

### A Component property is a TEMPLATE, so it comes before the children (2026-08-03)

With the value and frame axes saturated, the diagnostics became the biggest pool — and 41 of the
112 across both corpora are one category: an attached-property child, i.e. the gate. So the gate was
measured an **eighth** time, the first time since four ordering and colour fixes landed.

It no longer crashes and it no longer loses paths to the walkers. What was left was one thing, and
attributed by leaf it was unmistakable: `contentItem.ContextMenu.menu.contentData[i]` — 144
properties per item that the engine has and we do not, on seven of the nine children, in every
document with a context menu. **2016 of the 2034.**

Qt's Menu wraps an `Action` put in `contentData` into a `MenuItem` built from its `delegate`. Our
generated Menu bound the delegate at line 1297 and appended the children at 1236–1292 — the
`bindComponent` went into the property-bound-children buffer, which the emitter flushes AFTER the
default children. With the delegate still null, `createItem(action)` returns nothing and the Action
is appended raw.

A `Component` is not a child; it is a template the type builds children FROM. It now goes into its
own buffer, emitted before both kinds of child. Measured with the gate open:

| Basic, gate open | before | after |
|---|---|---|
| paths the engine has and we do not | 2034 | **18** |
| paths we have and the engine does not | 56 | **0** |
| value differences | 167 | 247 |

The value differences go UP because the objects now exist on both sides and are compared; before,
they were simply absent. What they are is now a single cause too: the Menu's `contentItem` reports
`count` 0 where the engine reports 9, so nothing under it is laid out (heights 0, `y` 0, `parent`
null). The items are in `contentData`; they have not reached the ListView's model. That is the next
thing behind the gate, and it is one statement, not a class of problems.

At the SHUT gate the change is inert — both corpora unchanged on every axis (56 and 48 documents
identical, 2 value differences each, render 49/44 with zero differing, click 34/34 with one, and
diagnostics 64 and 48).

`tests/qmltc/controls/CDelegateFirst.qml` pins it, verified able to FAIL: with the `bindComponent`
moved back after the appends in the generated D, `count` reads 0 against the engine's 2. It is the
only observable that moves — a closed menu lays nothing out and the Action's own `text` reads the
same either way, both checked rather than assumed.

### What is left behind the gate, traced to one identifier (2026-08-03)

With the delegate ordering fixed, the 247 value differences behind the open gate are one cause, and
it is now named. The attached Menu reports `contentItem.count` 0 where the engine reports 9, so
nothing under it is laid out — heights 0, `y` 0, `parent` null, which is every one of those
differences.

The generated line says why:

    copyProp(__outer.__outer, "contentModel", this, "model");

Qt's `Menu.qml` binds its ListView with `model: control.contentModel`, and `control` is the MENU's
own id. Two hops out is the TextField — which also writes `id: control`, and has no `contentModel`,
so the copy fails and the model is never set. Compiled on its own,
`Basic/impl/TextEditingContextMenu.qml` gets this right: `count` 9, `contentHeight` 293, matching
the engine exactly. As an attached CHILD it does not, because the spliced local type's own `control`
is not in its `OuterFrame`'s id set and the lookup walks past it to the enclosing document's.

That is the "same document, two scopes, two answers" shape this file has recorded before, and it is
now a single identifier rather than a class of problems. One thing more is unexplained and worth
keeping in view: with the gate open the attached menu reports `count` **10** where the engine reports
9 — the document has seven Actions and two MenuSeparators — so something is appended one time too
many.

Both are behind the shut gate and neither is measurable from the corpora as they ship. Written down
with the evidence so the next attempt starts from the identifier.

### ...and why that identifier cannot simply be added (2026-08-03)

The entry above says the spliced Menu's `control` "is not in its `OuterFrame`'s id set", which is
true and reads as a one-line fix. It is not, and the reason is worth having written down.

The same name means two different objects in the two halves of a spliced object:

- from the DEFINITION (`Basic/Menu.qml`): `model: control.contentModel` — `control` is the Menu.
- from the USE SITE (`TextField.qml`): `ContextMenu.menu: TextEditingContextMenu { editor: control }`
  — `control` is the TextField, and that one compiles CORRECTLY today (`setPropObj(this, "editor",
  __outer)`).

Making `control` a self-id of the merged object fixes the first and breaks the second. QML has no
such conflict because the two bindings live in two components; our splice merges them into one
class and merges the scopes with them.

The machinery to tell the halves apart already exists and is already used for exactly this problem
one level down: `spliceUseSite` records every use-site member in `g_useSiteMembers`, and
`g_useSiteShadowed` puts the local type's own DECLARED PROPERTIES out of scope while a use-site
binding is compiled. The IDS do not consult it. That is the shape of the fix — the id set has to be
split the way the property set already is — and it is the next thing behind the gate.

### DONE: `id` is not a property and does not override (2026-08-03)

The identifier the last two entries traced, fixed — and the cause was one line in the dedup, not the
scope machinery.

`spliceUseSite` makes the use site win for any name the definition also binds; that is what QML does
for a property. It was doing it for `id` too. Qt's style files all write `id: control`, so a spliced
`Menu` answered only to the use site's `menu`, and `Menu.qml`'s own `model: control.contentModel`
resolved two frames out to the enclosing TextField — which also writes `id: control` and has no
`contentModel`. The menu's ListView never got a model, and everything under it stayed unlaid-out.

`id` is now exempt from the override. Which half a binding was WRITTEN in is what decides its scope,
and that is `g_useSiteMembers`' job, not the dedup's — so the id set is split the same way the
property set already is: `g_selfIdsDefn` holds the ids the DEFINITION gave, and they are taken out
of scope for the length of a use-site binding, exactly as the local type's declared properties are.

Both halves now resolve to different objects, which is the point:

    copyProp(__outer, "contentModel", this, "model");    // Menu.qml's `control` -> the Menu
    setPropObj(this, "editor", __outer);                 // TextField.qml's `control` -> the TextField

Measured with the gate open: **value differences 247 -> 127**, paths the engine has and we do not
18 -> 14, diagnostics 79 -> 75. At the shut gate it is inert — both corpora unchanged on every axis
(56 and 48 identical, 2 value differences each, render 49/44, click 34/34, diagnostics 64/48).

`tests/qmltc/controls/CIdScope.qml` + `CIdScopeInner.qml` pin it, verified able to FAIL: with the
exemption removed, `fromDefn` reads `outer` against the engine's `inner`, and the target fails. The
fixture reads BOTH halves on purpose — `fromUse` must stay `outer` — because a fix that makes the
definition's id win everywhere breaks the other direction, and that is the trap this took two
attempts to see.

What is left behind the gate is now geometry: the menu reports `count` 10 where the engine reports 9
and a content height of 1293 against 306, so an extra item is appended and the items are about four
times too tall.

### The extra menu item is the ScrollIndicator (2026-08-03)

With the id scopes fixed, the menu behind the open gate reports `count` 10 where the engine reports
9, and a content height of 1293 against 306. Probed by dumping one index past the end:

    PROBE.contentData[9].__class    QQuickScrollIndicator
    PROBE.contentData[9].height     1000

Qt's `Menu.qml` gives its ListView contentItem a `ScrollIndicator.vertical: ScrollIndicator { }`. On
our side that indicator becomes a child of the ListView and the Menu counts it as an ITEM — one
extra entry in `contentModel`, and its 1000-pixel height is almost all of the 987 the content height
is over. On the engine's side it does not.

Dropping our `setQtParent(<attached child>, this)` was tried and changes nothing — the indicator is
still there, so it is Qt's own attached setter that parents it into the flickable, and what differs
is something about WHEN. That is where the next attempt starts; the count and the height are one
object, not a class of problems.

Both remain behind the shut gate, where the corpora are unchanged: Basic 56 of 57 and Fusion 48 of
49 documents identical in every property, 2 value differences each, render 49 and 44 with none
differing, click 34 and 34 with one, diagnostics 64 and 48.

### A group or attached child is the object's OWN body, not a deferred one (2026-08-03)

The extra menu item, fixed — and it refines the deferred-children rule rather than contradicting it.

The engine defers `background`, `contentItem`, `indicator` and friends: those are properties OF the
object, created inside its `componentComplete`, after it has been assigned. A `first.handle:` or a
`ScrollIndicator.vertical:` is not one of those. It is an assignment on ANOTHER object — a group, or
an attached one — written in this object's body and executed with the rest of it, BEFORE the object
is assigned anywhere.

We had moved all of them together. The Menu is where it showed: its ListView contentItem carries
`ScrollIndicator.vertical: ScrollIndicator { }`, and created after the ListView had already become
the Menu's contentItem, the Menu counted the indicator as a menu ITEM — `count` 10 against 9, with
its 1000-pixel height most of a content height of 1293 against 306. Dropping our own `setQtParent`
for it changed nothing (measured), because it is Qt's attached setter that parents it; what differed
was WHEN.

Group and attached children now go into their own buffer, emitted at the END of the object's own
wire — still before the split, so still before the object is assigned.

| Basic, gate open | before | after |
|---|---|---|
| documents identical in every property | 50 | **51** |
| value differences | 127 | **77** |
| `ContextMenu.menu.count` | 10 | **9**, the engine's |

At the shut gate it is inert: both corpora unchanged on every axis (56 and 48 identical, 2 value
differences each, render 49 and 44 with none differing, click 34 and 34 with one, diagnostics 64 and
48). No fixture, and the reason is worth stating: an attached child is refused at the shut gate, so
nothing built there can observe the difference — the guard is the gate-open measurement above, run
before and after.

What is left behind the gate is now 293 against 306 — exactly one MenuSeparator's 13 pixels — plus
one `enabled` and a ScrollIndicator transition. Small enough to name individually next time.

### Loading a local type contaminated the import state for its SIBLINGS (2026-08-03)

The last of the menu's geometry, and it is a general bug that had nothing to do with menus.

Qt's `TextEditingContextMenu` has two `MenuSeparator {}` children. Compiled, the first came out 13
pixels tall and the second 0 — same type, same document, two different classes. The generated D says
it plainly: `ITF_ContextMenu_menu_dc2` is a full `MenuSeparator` with a contentItem and three
recompute slots, and `dc7` is an empty class with a `classBegin` and nothing else.

`g_qualifiedTypes` accumulates every bare name that arrived through an import alias, and Qt's
`MenuSeparator.qml` is rooted in `T.MenuSeparator`. Loading it for the first child put
"MenuSeparator" in that set, so `boundTypeFor("MenuSeparator")` answered the Templates type from then
on and the second child was compiled as a bare bound object with none of the style's body. The other
three local-type sites already saved and restored `g_bareImports`/`g_qualifiedTypes` around the
compile; the DEFAULT-CHILD one did not.

Measured with the gate open: **value differences 77 -> 21**, and `ContextMenu.menu.contentHeight`
becomes 306 — the engine's, exactly. At the shut gate it is inert, both corpora unchanged.

`tests/qmltc/controls/CSepShadow.qml` + `MenuSeparator.qml` pin it, and the FIRST version of that
fixture was false green — worth writing down because it is the same trap as always. It read the two
children's own `implicitHeight`, and with the defect in place the second child produces no labels at
all, so the oracle is handed the shorter list and the comparison passes. A label the compiler records
per child disappears WITH the child. The fixture reads the Column's implicit height instead, which
sums what the children actually are: 26 with the fix, 13 without, against the engine's 26.

Behind the gate what is left is: `popup.contentItem.data[1]` is our ScrollIndicator where the engine
has a Rectangle (an ordering difference in the ListView's `data`), `contentData[5].enabled` false
against true, and the menu's own `editor` and `parent` reading null.

### Where the remaining diagnostics are (2026-08-03)

With the value and frame axes saturated at the shut gate, the 112 diagnostics across both corpora are
worth a census rather than a guess. 41 are the attached-child gate. Of the rest, the largest single
cluster is one FEATURE, not a scatter:

**15 of them are `text`, and every one is a model role read by a computed key** —
`text: model[control.textRole]` (ComboBox, SearchField), `control.model[control.headerView.textRole]`
(both HeaderViews and their delegates), `modelData` (Tumbler), `model.day` (MonthGrid). That is a
subscript into the per-item context object with a role name that is itself a binding, and the
context channel already exists (`contextStr`/`contextInt` read a delegate's `index` and `model` by
name). What is missing is the INDEXING, not the channel.

The next four clusters are much smaller and unrelated to each other: `opacity` 5, `highlighted` 4,
`loops` 2 (`Animation.Infinite`), and single instances of `x`/`y`/`width`/`visible`/`implicitWidth`/
`height` on one ComboBox popup child.

Written down so the next session picks the cluster rather than the first message it reads.

### Correction: a GROUP child is not an attached one, and I shipped a regression (2026-08-03)

The entry two above moved group AND attached children into the object's own body together. The
attached half was right; the group half was not, and it broke the frame after a click on Qt's own
`SearchField` — 56 pixels, stable across runs. It shipped because after that change I re-ran Basic's
RENDER and Fusion's render and click, and not Basic's click. Measuring selectively is how this
project has produced every false green it has recorded, and this time it produced a real one.

Bisected by moving each half back one at a time: the templates ordering is not it, the import-state
restore is not it, the group children are.

The distinction is in Qt's own headers. An ATTACHED assignment (`ScrollIndicator.vertical:`) is
never a deferred property — it is a write on an object the registry hands out. A GROUP member CAN
be: `QQuickIndicatorButton` declares `Q_CLASSINFO("DeferredPropertyNames", "indicator")`, and
`searchIndicator.indicator:` is exactly that. So the attached children stay in the object's own body
and the group children go back with the deferred ones.

Both measurements hold at once: Basic's click is back to 34 identical with none differing, and behind
the open gate the menu still reports `count` 9 and `contentHeight` 306 — the engine's — with the
same 21 value differences. Everything else unchanged on both corpora.

### The strongest comparison this project has is NOT in the build gate (2026-08-03)

Worth stating plainly, because every number in this file comes from it. There are two property
protocols:

- `--labels` / `--props`: the compiler writes down the paths it translated and the oracle is asked
  for those. **This is what every build target uses.**
- `--objpaths` / `--dumpall`: both sides enumerate EVERY property of every object in the tree. This
  is what the corpus scripts use, and it is the one that found the deferred transitions, the
  gradients, the QJSValue slots and the ordering defects.

`grep -n "dumpall\|objpaths" reggaefile.d` returns nothing. The gate compares what the compiler chose
to record — which is exactly the failure mode this file has documented over and over, sitting in the
one place nobody re-reads.

Measured before proposing it: run the strong protocol over the 23 controls fixtures and **22 pass**.
The one that fails is `CWidgets`, and the difference is already known and named: `property CheckBox
cb: CheckBox { … }` becomes a plain D field, not a `@Property`, so it is absent from our meta-object
while the engine has `cb  <object>`. Every binding that reads it through the field works; a read
through the META channel would not, and the engine's dump shows the property and ours does not.

So the next step is two moves, in this order: make a declared OBJECT property a real meta-object
property, then add a `--dumpall` phony beside every `--props` one. The second is a dozen lines in
`reggaefile.d`; the first is the actual work, and it is worth doing for its own sake — a document
that reads `control.cb` through anything but the D field is compiling against something the object
does not have.

### ...and what the first of those two moves actually costs (2026-08-03)

Tried, and reverted, because the estimate above was wrong in an instructive way. Marking a declared
object property with `@Property` so it lands in the meta-object is one line in the emitter — and it
is necessary but not sufficient.

`qtmoc.callProp` marshals a CLASS-typed property like this:

    __traits(getMember, o, m) = pv is null ? null : X.wrap(pv);

`X.wrap(ptr)` is a BOUND WRAPPER's constructor from a C++ pointer. A generated `@QObject` class —
which is what a compiled `property CheckBox cb: CheckBox { }` produces — has no `wrap`, so the
fixture that exercises it (`CrossCall`, whose `kid` is exactly this shape) stopped compiling:
`no property 'wrap' for type CrossCall.CrossCall_kid`.

So the work is in the MOC, not in the compiler: writing a class-typed property from C++ has to
resolve the pointer back to the D object that owns it, which is the registry's job and not
`X.wrap`'s. Until that exists, marking these properties only moves the failure from a missing dump
line to a build error — and the dump line is the honest one.

Reverted whole; both corpora and every fixture unchanged. The `--dumpall` gate still wants this
first, and now the estimate is right: it is a moc change with a reverse lookup in it, not a UDA.

### DONE: the strong protocol is in the build gate (2026-08-03)

Both halves, and the estimate two entries up was right about which was the work.

**The moc.** `callProp` rebuilt a class-typed property from the incoming pointer with `X.wrap(pv)`,
which only a BOUND wrapper has. `_reg` maps a D object to its QObject; the reverse question — given
a QObject*, which D object owns it — had no answer, and there is exactly one D object per
QtdMocObject, so it is a lookup and not a construction. `_byQObj` is that table, made and dropped
with `_reg` in the same two places, holding a raw pointer rather than an `Object` so an entry cannot
change any compiled object's lifetime. `dObjectFor` reads it, and the class-write path picks by
`__traits(hasMember, X, "wrap")`.

**The emitter.** A declared object property now carries `@Property`, so `property CheckBox cb:
CheckBox { }` is in the meta-object where the engine has it. A BASE object property (`contentItem:`)
is excluded — it is already in the C++ meta-object and a second one would shadow it.

**The gate.** A `-all-` phony beside every `--props` one, running `--objpaths` and `--dumpall` on
both sides. **258 targets**, over 98 fixtures, in `./build`.

Seventeen fixtures are named exclusions, with a `known_gap` entry in `tests/expected-fails.json`
carrying the list and the cause: a QML member that is not a plain scalar property — an alias, a
default-property holder, a list property — is still a D field and not a meta-object property, so the
engine's dump has `inner`, `child` or `kids[0]` and ours has no such key. Measured: controls 23 of
23, quick 42 of 46, corpus 33 of 46. The object-property half is done; aliases, default-property
holders and list properties are what is left, and the skip list goes away when they land.

Both corpora unchanged on every axis: Basic 56 of 57 and Fusion 48 of 49 identical, 2 value
differences each, render 49 and 44 with none differing, click 34 and 34 with one, diagnostics 64
and 48.

### The 17 exclusions are FOUR unrelated things, not one (2026-08-03)

The entry above lumped them together. Classified by reading every diff, they are:

1. **Aliases** (5) — `property alias inner: kid.value` compiles to a read/write expression, not a
   meta-object property, so the engine's dump has `inner`, `mirror`, `aliasToOrigin`, `kidSum` and
   ours has no such key. AliasBare, Aliased, AliasRebind, ChildAlias, ChildReactive.
2. **Default-property holders** (4) — a declared `default property QtObject child` names the bare
   child in the engine's meta-object and is a plain D field in ours. AliasHolder, DefaultHolder,
   UsesAliasDefault, UsesDefault.
3. **List properties** (2) — `property list<T>` is a D array field, so `kids[0]`/`items[0]` are
   absent. ArrayBinding, UsesList.
4. **A deliberate structural difference** (2) — a `Connections` element is desugared into connects
   and no object is built, while the engine holds one in `conn`. Both fixtures say so in their own
   headers. Connect, CrossCall. Permanent for this protocol.
5. **A harness heuristic** (4, the quick set) — the `__class` walk stops at the first class whose
   name starts with `Q`, and every fixture in that directory is named `Q…`, so it stops on OUR
   generated class (`QNested_dc0`) instead of the Qt base (`QQuickItem`). Not a compiler gap at all.

The declared OBJECT property is done and measurable: `CrossCall` now reports `kid` and `kid2` as
`<object>` exactly like the engine, and only the Connections pair keeps it out of the gate.

Five families, four of them real, and each with a different fix. That is worth more than the single
number the previous entry gave, and it is why the count is in the registry with the classification
rather than as a list of names.

### `__class` agreement is a name coincidence (2026-08-03)

Tried to close the smallest of the five families — the four `quick` fixtures whose `__class` reads
our generated class where the engine reads the Qt base — and reverted, because the attempt showed
the label is weaker than it looks.

The walk stops at the first class whose name starts with `Q` and declares properties of its own.
"Starts with Q" was standing in for "is a Qt class", so I replaced it with the real question — does
the class have a REGISTERED metatype for its pointer — on our side, then on the oracle's. Each move
broke a different fixture:

- ours only: `QItemParent` went to `QQuickItem` while the engine kept `QItemParent`;
- both: `QDeclObjType` went to `QQuickRectangle` while the engine kept `QDeclObjType`, because a
  document-defined QML type IS a registered metatype on the engine's side.

Which is the finding. The engine names a class after the DOCUMENT wherever the document defines a
type — the root, and any local type. We name every generated class after the document, root and
nested children alike. So `__class` matches whenever those two namings happen to line up, and the
four `quick` fixtures are simply the case where they do not (`QNested_dc0` against `QQuickItem`).

No runtime walk can fix that, because at runtime both names are just names. The label has to be
decided where the distinction exists: at COMPILE time, where the root (and a spliced local type)
keeps the document's name and a nested child reports its bound base. That is the fix, and it is in
the emitter, not in either dumper.

Reverted whole; the gate and both corpora are unchanged.

### A declared object property with NO value is still a property (2026-08-03)

First of the four real gate-exclusion families, partly closed. `DefaultHolder.qml` is two lines —
`property string tag` and `default property QtObject child` — and the engine's dump has `child
<null>` where ours had no such key at all: the property did not exist, so a use site assigning it
wrote a name the object does not have.

The cause was narrow. A declared object property is only kept when `boundTypeFor(<its type>)` maps
it to a D wrapper, and QML's own `QtObject` maps to nothing. It is still an object slot, and that is
all the channel needs: `Object` is the D type, `cppSig` spells a class as `X*`, and the meta-object
builder falls back to `QObject*` when that name has no metatype — which is exactly this case.

Two things had to come with it, both caught by the gate rather than by reading:

- a LIST is not an object slot. `default property list<QtObject> items` keeps `list` in the parser's
  `typeModifier`, so the name alone does not say so, and declaring it as an object made `items` read
  `null` against the engine's empty list.
- an object slot has no TEXT on either side. The oracle's `--props` reads the property as a QVariant
  and `toString()` of a `QObject*` is empty, filled or not; printing the D reference gave `"null"`
  against that empty. `--dumpall` is where the two are actually distinguished, as `<object>` and
  `<null>`.

`DefaultHolder` now passes the strong protocol — corpus 33 of 46 to 34. What is left in this family
is the other half: the bare child has to be ASSIGNED to the declared default property, which is why
`UsesDefault` still reads `child <null>` where the engine has `<object>`.

### ...and a single-object default property is ASSIGNED, not appended (2026-08-03)

The other half of that family. The label already named the property — that is how the dump reaches
the child — but nothing ever wrote it, so `default property QtObject child` read `<null>` on our side
against the engine's `<object>`: the property existed and held nothing.

One line beside the append, taken only when the default property is a SINGLE object (a list keeps
`listAppend`, which is what a list means). `UsesDefault` passes; corpus 34 of 46 to **35**, and both
it and `DefaultHolder` come out of the gate's exclusion list.

Nothing else moved: controls 23 of 23 and quick 42 of 46 as before, both corpora identical on every
axis (Basic 56 of 57, Fusion 48 of 49, 2 value differences each, render 49 and 44 with none
differing, click 34 and 34 with one, diagnostics 64 and 48).

Of the four real families, one is now down to its ALIAS half (`AliasHolder`, `UsesAliasDefault` —
`property alias child: inner.something` on a default-property holder), and aliases are the family
that has to land next anyway.

### What an alias needs, precisely (2026-08-03)

The last family, scoped rather than started, because it is a moc feature and not an emitter change.

A QML alias is a REFERENCE. `property alias inner: kid.value` is compiled today into no class member
at all — the dump reads `o.content.value` and a mutation writes `setProp(o.content, "value", …)`.
That is the right semantics (nothing is stored, so nothing can drift) and it is why the engine's
meta-object has `inner` and ours has no such key.

qtmoc discovers properties by `hasUDA!(__traits(getMember, T, m), Property)` over the class's FIELDS,
and `callProp` reads and writes `__traits(getMember, o, m)` directly. Neither fits a forwarding
property:

- a real field would hold a COPY, which is exactly what an alias is not;
- a D `alias inner = kid.value;` at class scope loses the UDA — `getMember` yields the aliased
  symbol, not the declaration.

So the shape is a second UDA — `@PropertyAlias` on a getter/setter pair, with `propMembers` and
`callProp` extended to route through them. That is a contained change in `runtime/qtmoc/qtmoc.d`
with a matching one in the emitter, and it closes seven fixtures at once: the five alias ones
(AliasBare, Aliased, AliasRebind, ChildAlias, ChildReactive) and the two that are the alias half of
the default-property holder (AliasHolder, UsesAliasDefault).

Written down here rather than begun, because starting a moc feature is not something to do at the
end of a session — and because the shape above is the part that took the reading.

### DONE: an alias is a FORWARDING property (2026-08-03)

The design in the entry above, built. qtmoc gained `@PropertyAlias`: a property backed by a getter
and a `<name>_set` beside it rather than by a field, because a field would hold a COPY and that is
precisely what an alias is not. Discovery, the three build paths (free `newQObject`, the QML factory
and the trampoline subclass) and the property dispatch all take the forwarding ones AFTER the stored
ones, so an index below `propMembers.length` is still a field and above it is a forwarder.

The emitter emits the pair from the alias line it already had — the same read expression the dump
uses, with the self marker resolved to `this` because these members live in the object itself.

**Corpus 35 of 46 to 40**: AliasBare, Aliased, AliasRebind, ChildAlias and ChildReactive all pass
the strong protocol and come out of the gate's exclusion list. Nothing else moved — controls 23 of
23, quick 42 of 46, both corpora identical on every axis (Basic 56 of 57, Fusion 48 of 49, 2 value
differences each, render 49 and 44 with none differing, click 34 and 34 with one, diagnostics 64
and 48).

Six exclusions left, and the four families are down to three: an alias whose target is an OBJECT
(AliasHolder, UsesAliasDefault — the emitter accepts those today and emits no dump line, so they
need the object marshalling the scalar pair does not do), list properties (ArrayBinding, UsesList),
and the deliberate `Connections` pair.

### ...and an alias whose target is an OBJECT (2026-08-03)

The rest of that family. The alias resolution already TYPED an object target — a declared
`property QtObject someObject` now has a D type, so `atype` came back non-empty — and the emission
was gated on the four scalar names, so the forwarding pair was simply never written for it.

Two lines: the guard becomes "any type we resolved", and an OBJECT target is assigned through the D
FIELD rather than through `setProp`, because the target is a member of this same class and the meta
channel would only re-enter the property being defined. `callPropAlias` gained the pointer path a
stored object property already had — `X.wrap` for a bound wrapper, the registry lookup for a
D-defined `@QObject`.

`default property alias child: self.someObject` is the shape this matters for, and it is how a bare
child of a user of the type reaches its target at all.

**Corpus 40 of 46 to 42.** AliasHolder and UsesAliasDefault pass; the alias family and the
default-property-holder family are both closed. Nothing else moved.

Four exclusions left, in two families and one deliberate pair: list properties (ArrayBinding,
UsesList) and the `Connections` desugaring (Connect, CrossCall) — plus the four `quick` fixtures
whose `__class` is the harness name coincidence, which is an emitter decision and not a gap.

### What a list property needs, and where this leaves the gate (2026-08-03)

The last real family, scoped. `property list<QtObject> kids` with an array binding: the elements are
ordinary child objects and we build them, but the engine reaches each one at its INDEX in that
property and we expose no such path — `listAt(o, "kids", 0)` resolves nothing because `kids` is a D
array field, not a meta-object list.

That is not a variation on anything already here. A meta-object list property is a
`QQmlListProperty` with `append`/`count`/`at`/`clear` callbacks and a registered element type; the
moc would have to build and hand out one, and `QQmlListReference` on the other side would then find
it. Real work, and unlike `@PropertyAlias` it is a new mechanism rather than a second shape of an
existing one — so it is written down rather than started.

Where the strong protocol stands after this session:

| set | passing |
|---|---|
| controls | 23 of 23 |
| quick | 42 of 46 |
| corpus | **42 of 46** (33 when the gate was added) |

Four exclusions, each with its own removal condition in `tests/expected-fails.json`: list properties
(2), the deliberate `Connections` desugaring (2, permanent), and the four `quick` fixtures whose
`__class` is the harness name coincidence — an emitter decision, not a compiler gap.

### DONE: the `__class` label, decided in the emitter (2026-08-03)

The entry above said no runtime walk could fix this and the label had to be decided at compile time.
It was, and it took three measurements to get right — each one a wrong answer the corpora or the
fixtures pointed at:

1. **The hint as the ANSWER** broke `CSepShadow`: ours said `QQuickMenuSeparator` where the engine
   said `QQuickControl`. The engine applies "skip a class that declares no properties of its own"
   above whatever it finds, and a MenuSeparator declares none. So the hint is where the walk
   STARTS, not what it returns.
2. **The hint on an INDEXED path** broke `CDelegate`: ours said `QQuickRepeater` where the engine
   said `QQuickText`. The object at `data[0]` is the one the LIST holds, and a Repeater's items are
   SIBLINGS of the Repeater — the field and the element are different objects. The generated code
   now asks at runtime (`__o is qobjOf(<field>)`) and hints only when they are the same.
3. **`QObject` for an unbound child** broke four corpus documents: BusyIndicator, Dial, ProgressBar
   and Tumbler report a real `QQuickBasic*` class, because those objects are ones the ENGINE built —
   a style's `*Impl`, which exports no symbol to subclass. `ObjNode::engineInst` already knew, so
   they pass no hint and the walk answers, correctly.

**quick 42 of 46 to 46 of 46** — the whole set passes the strong protocol — with both corpora
unchanged (Basic 56 of 57, Fusion 48 of 49, 2 value differences each, render 49 and 44 with none
differing, diagnostics 64 and 48).

Four exclusions left: list properties (ArrayBinding, UsesList) and the deliberate `Connections`
desugaring (Connect, CrossCall).

One thing to record while it is fresh: **BusyIndicator's CLICK is flaky**. It differed on one run and
matched on the next with nothing changed in between — its animation never settles, so the frame after
the fixed 400 ms depends on where the stopwatch landed. It is the one document in either corpus whose
click cannot be compared deterministically, and a "1 differ" there is not automatically a regression.

### The list property is smaller than it looked (2026-08-03)

Re-scoped after reading the generated D, which is worth more than the estimate it replaces.

`property list<QtObject> kids` with an array binding already emits

    _al_kids_0 = newQObject!ArrayBinding_kids_0();
    setQtParent(_al_kids_0, this);
    listAppend(this, "kids", _al_kids_0);

— the append through the meta-object list property is ALREADY there. It simply does nothing,
because `kids` is not a property of our object, and the result is discarded. So the missing piece is
one thing and not two: the PROPERTY. Nothing about how the elements are built has to change.

And the storage need not be on the D side at all. `listAppend` goes through `QQmlListReference`, so
if our meta-object exposes `kids` as a real `QQmlListProperty<QObject>` whose callbacks read and
write a side table keyed by (object, property name), the existing append lands there and
`listAt(o, "kids", 0)` — and the oracle's `QQmlListReference` — both find it. The runtime owns the
list; the generated class keeps only the fields it already has.

That is the shape: a declared list property becomes a meta-object property typed
`QQmlListProperty<QObject>`, `callProp`'s read fills one with append/count/at/clear bound to the
side table, and the emitter marks the property. Contained in `runtime/qtmoc/` plus one line in the
emitter — smaller than the "new mechanism" the previous entry called it, because the caller already
exists and only the callee is missing.

### The list property, attempted and reverted — with the one open question (2026-08-03)

Built both halves and put it back, because the second half did not converge and half of a mechanism
in the moc is worse than none.

**The runtime half worked and is the part worth keeping in mind.** A side table of
`{owner, property, items}` with `append`/`count`/`at`/`clear` callbacks, handed out as a
`QQmlListProperty<QObject>` from `callProp`'s READ path, with the entry dropped through the same
`destroyed()` hook the other side-tables use. It compiled clean on Qt5 and Qt6 — the index type
differs between them (`int` against `qsizetype`) and the class NAMES it, so
`decltype(QQmlListProperty<QObject>().count(nullptr))` takes it from Qt instead of guessing per
version.

**The emitter half stopped on one thing.** A declared `property list<QtObject>` becomes
`@Property QmlObjectList kids;` correctly — that much is in the generated D — but the label dump
still emits `writefln("kids\t%s", propStr(o, "kids"))` where it should emit the empty form, and the
branch that decides that is keyed on the DumpLine's dtype, which is set from the very same
`p.dtype` that produced the field one line earlier. Why the two disagree is the open question, and
it is the whole of what is left: the runtime, the property, and the append are all in place.

Reverted whole; the build is green and both corpora and all 111 fixtures are unchanged. The next
attempt starts by printing that dtype at the emission point rather than by rebuilding the design.

### The list property, second attempt — three findings and one wall (2026-08-03)

Went further this time. The open question from the last attempt turned out to be a one-line thing
and the real wall is somewhere else, so the record is worth more than the code was.

**Finding 1 — why the label dump ignored the dtype.** `collectDump` routes any dtype that starts
with an uppercase `Q` through `propStr(...)` and pushes the line with an EMPTY dtype (that is how a
QColor is read as text). `QmlObjectList` starts with Q, so it took that branch and lost its dtype
before the empty-print decision ever saw it. Naming it in that condition fixes it — the previous
entry's "open question", answered.

**Finding 2 — a property with no metatype crashes the dump.** With the property added but the
metatype unregistered, `--dumpall` segfaulted, and gdb named it: `qtd_dump_object_as` ->
`QMetaType::canConvert`, walking a null interface. The guard for that is kept — a dump that crashes
is not one of the options, whatever put the property there. That is the only part of this attempt
that stays.

**Finding 3 — `--gc-sections` eats a registration.** `static const int x = qRegisterMetaType<…>()`
at file scope is exactly what the linker removes when nothing reads `x`, so the registration
silently never ran. Registering from inside `buildMo`, before the property is added, is the shape
that works.

**The wall.** With the metatype registered and carrying `IsQmlList` (probed directly: flags `0x1005`,
`isQmlList=1`), `listAppend(this, "kids", …)` still returns false — `QQmlListReference` refuses a
property whose read is served by our runtime meta-object. That is the next thing to isolate, and it
wants a standalone probe against a `QMetaObjectBuilder`-built object rather than another pass over
the whole pipeline.

Reverted except the crash guard; build green, both corpora and all 111 fixtures unchanged.

### DONE: the list property — and the two registrations it needed (2026-08-03)

Third attempt, and this time the wall was isolated before any of it was rebuilt. A standalone probe
against a `QMetaObjectBuilder`-built object, with a `QQmlListProperty<QObject>` served from
`qt_metacall`, said it in four lines:

    ref valid=1 canAppend=1 canAt=1
    listValueType=<null>
    append(null)=1 count=1
    append(obj)=0 count=1

A null element appends and a real one does not — which is `QQmlListReference::append` checking the
object against the list's ELEMENT type, and finding none. Registering the metatype is not enough:
`qmlRegisterAnonymousType<QObject>(…)` is what puts the element type in QQmlMetaType, and with it
`listValueType=QObject` and `append(obj)=1`.

So the recipe, all of it verified before it was written:

1. the METATYPE, or `QMetaProperty::read` hands back an invalid QVariant and the dump dies in
   `QMetaType::canConvert` (gdb named that one);
2. the ELEMENT type in QQmlMetaType, or every non-null append is refused;
3. both from a FUNCTION, called from `buildMo` before the property is added — `--gc-sections`
   removes a file-scope `static` whose value nothing reads, and the registration then silently
   never runs;
4. the read served from `callProp`, handing out a `QQmlListProperty` over a side table the runtime
   owns, one per (object, property), dropped through the same `destroyed()` hook as the other
   side-tables;
5. the emitter marks the property, and exempts it from the "read a Qt value type as text" branch,
   which was swallowing its dtype because the name starts with Q.

The generated code needed no change at all: `listAppend(this, "kids", _al_kids_0)` was already being
emitted for every element of an array binding, and now it lands.

**Corpus 42 of 46 to 44** — ArrayBinding and UsesList pass. Both corpora unchanged (Basic 56 of 57,
Fusion 48 of 49, 2 value differences each, render 49 and 44 with none differing, click 34 and 34
with one, diagnostics 64 and 48).

**The strong protocol now covers 113 of the 115 fixtures**, and the two it does not are the
`Connections` pair, which is a deliberate structural difference both fixtures document in their own
headers. There is no remaining GAP in that gate — only a decision.

### The attached-child gate, measured a NINTH time — and the picture has changed (2026-08-03)

Worth re-measuring after the property machinery landed, and it moved the gate from "obviously not"
to "one ordering fact away".

| Basic, gate open + compile-whole | shut | open |
|---|---|---|
| documents identical in every property | 56 of 57 | 51 |
| value differences | 2 | 21 |
| paths we have and the engine does not | 0 | 36 |
| paths the engine has and we do not | 0 | 21 |
| **render at rest** | 49, none differing | **49, none differing** |
| **frame after a click** | 34, none differing | **34, none differing** |
| diagnostics | 64 | 75 |

The frame axes are IDENTICAL open and shut — the compiled ContextMenu subtree draws exactly what the
engine draws, at rest and after a press. That has never been true before; the first measurement of
this gate cost four documents that threw at construction, and the seventh still cost 2034 paths.

What it costs now is five documents on the value axis, and the residue is one thing:
`popup.contentItem.data[1]` is our ScrollIndicator where the engine has a Rectangle — an ORDER
difference in the ListView's `data` — plus the transition under that indicator. 36 of the 36
only-ours and 21 of the 21 only-engine are those two paths.

The gate stays shut for now, because five documents is five documents. But the reason has been one
ordering fact for the first time, and it is the same shape as every ordering fact this file has
already recorded and fixed.

### Correction: it is not an ordering fact, it is two invisible internals (2026-08-03)

The entry above called the gate's residue "an ORDER difference in the ListView's `data`". Looked at,
it is not. Basic's ComboBox popup contentItem, dumped index by index:

| | engine | ours |
|---|---|---|
| `data[0]` | QQuickItem (w 140) | QQuickItem |
| `data[1]` | QQuickRectangle — z 10, `#00000000`, `visible false` | QQuickScrollIndicator |
| `data[2]` | QQuickRectangle — z 11, `#00000000`, `visible false` | — |
| `data[3]` | QQuickScrollIndicator (w 6) | — |

Our indicator is not in the wrong place: the engine's ListView carries TWO extra children we never
build, and they push its indicator from index 1 to index 3. Both are fully transparent, invisible,
and above everything at z 10 and 11 — Qt internals for that view, not anything the document writes.

Which explains the shape of the whole measurement. They cannot affect a frame — they are invisible
and transparent — and that is exactly what the render and click axes said when they came out
identical open and shut. Only a property census can see them, and what it sees is the engine having
objects we do not, not us building the tree wrong.

So the gate's cost is smaller than "five documents" makes it sound, and it is not a defect with a
fix in the compiler. Re-open it when the census learns to say "the engine has an internal object
here" the way it already says "this path is unmeasurable" — the marker exists, the classification
does not.

### The delegate had never had its context (2026-08-03)

The task on the list was "a delegate's CHILDREN get the document's context, so `index`/`modelData`/
roles do not resolve there". Measuring it found something one level below: **the delegate ROOT had
never had the per-item context either.** Every `index`, every `modelData`, every model role inside
any delegate had been reading nothing since the feature was written.

It was invisible because of what the acceptance test compares. `CDelegate` binds
`text: root.tag + "-" + index` and matches the engine's `outer-0`. But `index` there is read as an
**int**, at **item 0** — and zero is also what a lookup that found nothing returns. The one value
that could not distinguish the two answers was the only one being compared.

The cause, from a probe printing the context chain at read time:

```
[ctx] obj=..._delegate name=index ctx=0x...d590 ctxobj=<none> baseUrl=file://...QDelegateKidCtx.qml val=
        up 0x...d590 obj=<none>
        up 0x...b5e0 obj=<none>
```

Two levels, no context object, base URL our document — and the SAME context pointer for both items.
That is our own per-document cached context, attached by `attachContext(this, docUrl)` at the top of
the delegate's constructor. The view installs the per-item context right after construction, found
the slot taken, and never installed anything. There was no per-item level in the chain at all.

Four parts, and they only work together:

- **The delegate root attaches nothing.** `holdContext(this)` marks the object (a dynamic property,
  so it dies with the object and the dump — which walks the meta-object — cannot see it) and both
  `attachContext` paths honour the mark. `classBegin()` attaches a context too, which is why the
  mark has to live on the object rather than be a decision at the call site.
- **A child nests inside its enclosing object's context**: `attachContextIn(this, __qmltcOuter, url)`
  creates a QQmlContext whose PARENT is the outer object's, which is how the engine nests them, so
  `contextProperty` walks up into the per-item names. `__qmltcOuter` carries the D object, not its
  QObject — passing it straight to C++ is a segfault (gdb, first run) — so it resolves through the
  same registry every other D-object-to-QObject step uses.
- **`contextObject()` walks up** the context parents. A nested context has no object of its own, and
  the notify connection needs the one the view published.
- **The body waits.** A subtree that reads a context name defers to the existing `__qtdReady()`
  hook — the same parentChanged mechanism a delegate already used to find its enclosing object —
  because the engine installs the context AFTER the constructor returns. The early call that hook
  makes ("already parented? then nothing to wait for") is guarded by the resolution failing; with
  nothing to resolve there was no guard and the body ran in the constructor exactly as before, so
  the context case brings its own: `if (!hasContext(this)) return;`.

`tests/qmltc/quick/QDelegateKidCtx.qml` is the fixture, and it is written so it CAN fail: three
discriminators, one per path — a base property on the delegate root, a declared property on the
root, and a declared property reading back out of a CHILD one level below it. All three are
**strings** (`"r" + index`, `"kid" + index`), because that is the trap the old test fell into: as an
int, item 0's index and a failed lookup are both 0. Before the change all three read `r`/`o`/`kid`
against the engine's `r0`/`o0`/`kid0`; after, all three agree.

One more thing had to move for the fixture to be comparable at all. The dump answers `__class` by
walking to the first Qt class, and "is a Qt class" was decided by a leading `Q` — so
`QDelegateKidCtx_dc0_delegate`, generated from a document whose name starts with Q, passed that
test and reported itself. The meta-object channel already carries this kind of fact: every runtime
meta-object we build now declares `Q_CLASSINFO("qtdGenerated", "1")` and the walk skips it.

Measured before and after on the same harness, both corpora, all five axes:

| | Basic before | Basic after | Fusion before | Fusion after |
|---|---|---|---|---|
| documents constructed | 61 | 61 | 52 | 52 |
| value differential | 51 identical | 51 | 44 identical | 44 |
| render identical | 49 | 49 | 44 | 44 |
| click identical | 34 | 34 | 34 | 34 |
| diagnostics | 26 | 26 | 17 | 17 |

Identical, line for line, on every axis — which is the honest result: Qt's own Controls do not read
a delegate context in any expression this compiler currently accepts, so nothing that was already
compiling could move. What moved is that the reads which DO compile are now correct, and that a
whole class of silent wrong answers has a test that would catch it coming back.

### A model role by name, and the boundary the engine draws around it (2026-08-03)

With the delegate context working, the read Qt's Controls actually write becomes reachable:
`text: model[control.textRole]`. The roles are properties of the per-item model, so this is the
meta-object channel once more — a property read by name — and it comes out of `contextProperty`,
which asks the context and its context object and then walks up. Both spellings go through the same
helper: the computed key (`model[k]`) and the literal one (`model.day`, Qt's MonthGrid).

The first attempt read it off `contextObject()` and answered EMPTY on every path. A Repeater over an
int model publishes `index` on the context itself and carries **no context object at all** — the
same probe that found the missing per-item context said so, and it was ignored the first time.

**The engine draws a boundary here, and it had to be measured to be seen.** A delegate that declares
required properties gets the context injection turned OFF:

| delegate declares | engine's `model["index"]` |
|---|---|
| nothing | `0` |
| `required property int index` | *(empty)* |

So Qt's ComboBox and SearchField — which spell it `required property var model` — are reading the
INJECTED property, not the context. Relaxing the guard to accept a declared `model` closed their
`text` refusals (Basic diagnostics 26 → 24, measured), and it was **reverted**: it would have put a
plausible value where the engine has none. The refusal stays until required-property injection is
implemented, which is now the named next step.

`QDelegateRole.qml` covers the literal key, `QDelegateRoleReq.qml` the computed one, both with
string discriminators for the same reason as before.

#### The `__class` rule this exposed, and the regression it repaired

Naming our generated classes in the meta-object (`qtdGenerated`, the previous entry) made the dump
skip them — right for a delegate item, wrong for the document ROOT, where the engine reports the
document's own type when the document declares members. That was a regression shipped in the same
commit and caught here by a fixture whose root declares a property.

The rule that covers every case is one hint: **the root is named after the DOCUMENT**, not after our
generated class.

| | our class | hint matches? | reported | engine |
|---|---|---|---|---|
| fixture root, declares members | `QDelegateRoleReq` | yes | `QDelegateRoleReq` | `QDelegateRoleReq` |
| fixture root, declares none | `QDelegateRole` | yes, then skipped for declaring no properties | `QQuickItem` | `QQuickItem` |
| corpus root (`Rt` prefix) | `RtRangeSlider` | no — nothing in our chain is named `RangeSlider` | `QQuickRangeSlider` | `QQuickRangeSlider` |
| delegate item, no hint | generated | — | Qt base | Qt base |

Naming the root after our own CLASS instead cost two corpus documents (RangeSlider, Tumbler), which
is how the distinction was found: the harness prefixes its class names and the engine has never
heard of them.

Measured on both corpora after all of it: values, render and click identical to the pre-change
baseline, diagnostics 26 and 17 unchanged — the role read closes a shape Qt's own Controls never
write without required properties.

### The engine's own rule for when `model` exists (2026-08-03)

The previous entry refused a delegate that declares `model`, on the strength of one measurement:
a delegate with `required property int index` answers EMPTY for `model["index"]`. That reading was
too broad. The measurement says something narrower and the engine's rule is a three-way one:

| the delegate declares | the engine's `model` | ours |
|---|---|---|
| nothing required | the context's | the context's — same |
| `required property var model` (ComboBox, SearchField) | the INJECTED property | the context's — same object, different route |
| required properties, but not `model` | **nothing** — indexing `undefined` throws | must refuse |

Only the third is a refusal, and it is a refusal because a context read there would invent a value
the engine does not have. The second is readable precisely because we never mark our own properties
required, so our side keeps the context the engine gave up.

`modelIsReadable()` is those three lines. With it, Qt's ComboBox and SearchField compile their
`text` again: **Basic diagnostics 26 → 24, Fusion 17 → 15**, values, render and click identical to
the baseline on both corpora.

`QDelegateReqNoModel.qml` is the third row, in its own file — and the reason it is its own file is
itself a finding: two Repeaters in one document does not work, because only the FIRST one's items
land on a path both sides dump, so a second one could never fail. Negative control run: with the
guard disabled the fixture reads `n0` against the engine's empty, which is exactly the invented
value the guard exists to prevent.

What is still missing, and is now the named next step: **we do not fill a required property**. A
`required property int index` is declared by us and never written, so it reads 0 forever — invisible
at item 0, which is the same trap as before. Marking it required in the meta-object so the view
injects it is Qt6-only (`QMetaPropertyBuilder::setRequired` does not exist in 5.15), so the portable
route is to fill it ourselves from the context, which we still hold.

#### Correction: that `__class` rule was reading the harness, not the engine

The table above says the engine "reports the document's own type when the document declares
members". It does not. Both sides run the SAME walk — first class whose name begins with `Q` and
declares properties of its own — and the engine's document type is named `<Document>_QML_n`. So
`QDelegateRoleReq_QML_0` survives that test and `Locals_QML_0` does not, and the answer differs by
whether the DOCUMENT's name happens to start with a Q.

`tests/qmltc/corpus/Locals.qml` is what said so: it declares three properties, and the oracle still
answers `QObject`. Exempting our named root class from the leading-Q test made our side answer
`Locals` — a difference invented entirely by the harness, and the full build caught it.

So the exemption applies to one test only: a class the caller NAMED is not skipped for being ours.
It is still skipped for not beginning with Q, and still skipped for declaring no properties. That
lands every case on the engine's answer:

| | our class | reported |
|---|---|---|
| `QDelegateRoleReq`, root declares members | `QDelegateRoleReq` | itself — engine: `QDelegateRoleReq_QML_0` → same |
| `QDelegateRole`, root declares none | `QDelegateRole` | skipped, no own properties → `QQuickItem` |
| `Locals`, root declares members | `Locals` | skipped, no leading Q → `QObject` |
| corpus root | `RtRangeSlider` | hint `RangeSlider` matches nothing → `QQuickRangeSlider` |
| delegate item, no hint | generated | skipped for being ours → `QQuickItem` |

The lesson is the one this file keeps recording in different clothes: **an agreement between the two
sides can come from a shared artefact rather than from a shared fact**, and the way to tell is a
document that breaks the artefact. Here it was a name that does not start with Q.

#### Three things only the FULL build could say

Running the targets I had just touched said green three times over while the suite was red. Each
failure was mine, and each was invisible to a directed measurement:

1. **`Locals.qml`** — the `__class` correction above. A directed run never compiles a document whose
   name does not begin with Q, and that is the only kind that breaks the artefact.
2. **The labels axis on all four delegate fixtures.** `--verify-props` is the independent half of
   the weak protocol: it fails when the engine built a QML-declared member no label mentions. An
   item a VIEW creates has no static path, so `--labels` drops it by design, and a delegate that
   declares properties trips a guard that was never able to name them. `labelsGap` in the build file
   exempts exactly those four, beside the `dumpallGap` that already existed — the strong `-all-`
   target does compare those items, and is green for all four.
3. **A root that is a LOCAL TYPE.** `QLocalRoot.qml` is a `LocalBase`, so by the time the root's
   dump call is emitted `g_docUrl` is *LocalBase.qml* and the hint named the wrong type. The
   document's own file (`g_rootDocUrl`) is the right one.

And one rule of the suite I did not know and had to be taught by it: the node that generates a
fixture's D **treats exit 3 (partial) as failure**, on purpose, so no fixture can quietly go
partial. My directed runs looked green because the `.d` was already cached and the tool never ran.
`QDelegateKidCtx` lost its one diagnostic (a declared property reading the context, which
`QDelegateRole` covers without one); `QDelegateReqNoModel` cannot lose its — its refusal IS the
test — so it is named in `partialOk`, which accepts 0 or 3 and nothing else.

### Filling a required property from the context: measured, and it cannot work (2026-08-03)

The named next step was to fill the required properties a delegate declares — the view writes them
in the engine, and marking a property required in our meta-object is Qt6-only
(`QMetaPropertyBuilder::setRequired` does not exist in 5.15), so the portable route looked like
reading them from the context we still hold.

It does not work, and one fixture with a control in it says exactly why:

| | `index` — DECLARED by the delegate | `modelData` — not declared |
|---|---|---|
| ours | **not** in our context | in our context (we read `m0`) |
| engine | injected onto the item (`0`) | nothing — it withheld the context, indexing `undefined` throws |

Mirror images. **Declaring the property is precisely what removes it from our context**, so the
context can never be the source for it. The fill was written, measured, and reverted; the only route
left is marking it required in the meta-object, which cannot be done on Qt 5.

What the measurement DID hand over is a live defect in the other direction. In a delegate that
declares required properties, a bare context name (`modelData`, `index`) gave us a value where the
engine has none — the same shape as `model[...]`, which already had the three-way guard. Bare names
now follow the same rule, and `QDelegateReqFill.qml` is the guard: without the refusal it reads
`m0` against the engine's empty.

Its `index` is an int **on purpose and is not coverage**: the engine injects 0, our unwritten field
reads 0, and they agree by accident. It is declared only to put the delegate on the required side of
the boundary. Declared as a string it exposes the unfillable half — engine `"0"`, ours `""` — which
is the gap above, still open.

Corpora after: Basic 24 diagnostics, Fusion 15, values, render and click identical to the baseline.

### The census was reading blind: 12 refusals that did not say what they refused (2026-08-04)

Of the ~39 diagnostics left across both corpora, twelve came out as `expression for 'string' []` —
an empty snippet in a message whose whole job is to be read. The census picks the next piece of work
from these, so it was choosing among things it could not see.

The snippet is cut from the source by offset, and `g_srcText` holds ONE document. A spliced local
type puts its own file there, and the members it splices come from TWO files: the type's and the use
site's. `text: control.model.display` is written at the use site, so its offsets index the document
while the text in hand was `Label.qml` — 371 bytes against an offset of 1325 — and the range fell
outside, which the guard correctly turned into "".

A single fallback to the document is not enough either: a local type can splice a local type (Qt's
`HorizontalHeaderView` → `HorizontalHeaderViewDelegate` → `Label`), and the expression belongs to
the middle one. What works is the chain of documents actually ENTERED, innermost first — pushed and
popped at the same five sites that already save and restore `g_srcText`. That is the distinction the
earlier "try every parsed file" attempt lacked: offsets are valid in many files at once, so it
quoted plausible nonsense; the enclosing chain is not a guess.

Empty snippets: **12 → 1** (the last is a node with no source location of its own). Counts unchanged
— nothing about the compiler moved, only what can be read about it. What the census can now see:

```
control.model[control.headerView.textRole]     control.model.display ?? ""
highlightedItem ? highlightedItem.y : 0        model.month === control.month ? 1 : 0
index === control.currentIndex ? 0.95 : pressed ? 0.7 : 0.45
```

### A refusal that had already been emitted (2026-08-04)

Chasing the census's biggest group — reading through a declared object property — the isolation was
seven lines:

```qml
Item { id: kid; width: 33 }
property Item probe: kid
property real w: probe.width
```

`qmltc-d` reported *the initial binding of property 'probe' (Item) is not supported*. The generated
D says otherwise: `setPropObj(this, "probe", _dc0)`, the read `propDouble(probe, "width")`, and both
notify connections are all there. The chain that compiles an initial value only knows SCALARS, so an
object property whose value WAS accepted fell out of the end of it and was reported as a refusal of
something already emitted.

The message now fires only when the object value was not accepted. Corpus counts unchanged (Basic
24, Fusion 15) — no Qt document has this shape, so it never showed there. It matters anyway: the
census is what picks the next piece of work, and this one was pointing at finished work.

Written and thrown away in the same pass: a branch to accept a BARE name as an object property's
initial value (`property Item probe: kid`). Measured against the pre-change compiler first —
`setPropObj` was already emitted, `objPathExpr` resolves a bare name fine — so it was dead code, and
it went out before the commit rather than in it.

### An object-literal property was not a path head (2026-08-04)

```qml
property Item probe: Item { width: 33 }
property real w: probe.width      // refused
```

The child was built, parented and held in the field; the property existed and read back as
`<object>`. Everything worked except reading THROUGH it — the object-literal path recorded no type
for the property, so it was not a path head and `probe.width` had nothing to resolve against.

Qt's Fusion TreeViewDelegate is the case that names it: `property ColorImage arrow: ColorImage {}`
and then `implicitWidth: Math.max(arrow.implicitWidth, 20)` on the indicator.

One registration at each of the two literal sites (`UiObjectBinding` and `UiObjectDefinition`), and
`QObjLiteralProp.qml` as the guard, with the negative control run: without the fix it reads `w 0`
and `h 0` against the engine's 33 and 20; with it both sides agree on everything, including the
child's thirty properties.

Fusion diagnostics **15 → 14**, Basic 24 unchanged; values, render and click identical to the
baseline on both corpora.

### An enum constant where a NUMBER is wanted (2026-08-04)

`loops: Animation.Infinite`. `loops` is a plain `int` on QQuickAbstractAnimation and `Infinite`
names a constant of a different enum entirely, so the string-key channel a genuinely enum-typed
property uses cannot carry it — QMetaEnum would have nothing to convert against. The value is what
the property takes.

Two things were learned by measuring rather than assuming:

**The helper already existed.** A newly written `qtd_enum_value` collided at the C++ level with the
one the runtime has shipped since `StandardKey.Undo` needed it. Deleted; the existing one is used.

**And it had no answer here.** `QMetaType::fromName("QQuickAbstractAnimation")` finds nothing —
nothing in the process ever instantiates a `QQuickAbstractAnimation*`, so the class has no metatype,
and appending the `*` does not help either. The question that always has an answer is asked of the
OBJECT: it carries the whole chain in its own meta-object, and `Animation.Infinite` is by
construction an enum of a class in that chain. `enumValueOn(obj, class, key)` asks the object first
and falls back to the named class for an unrelated enum.

`QEnumAsInt.qml` guards it, negative control run: without the fix `loops` stays at the default 1
against the engine's -1.

Fusion diagnostics **14 → 12**, Basic 24; values, render and click identical to the baseline on both
corpora.

### The same read, live on one property and dead on another (2026-08-04)

Isolated inside a delegate, three spellings of one thing:

| | |
|---|---|
| `opacity: model.index` — a BASE property | compiles |
| `property int mi: model.index` — a DECLARED one | *"depends on 'model', which has no known notify"* |
| `opacity: model.index === 1 ? 1 : 0` | refused |

Two separate defects and one still open.

**The dependency was the wrong name.** A role read recorded `model` as what it depends on. `model`
has no notify — it is not a property of anything — so the binding was reported dead. What it depends
on is the ROLE, and recorded that way it lands on the branch that already existed for a bare context
name: `connectNotify(contextObject(this), role, …)`.

**And the rule reached only some of the consumers.** There are THREE places that turn a dependency
into a connection, and the declared-property one had no context branch at all. So the identical read
was LIVE on a base property and DEAD on a declared one, silently. This file has recorded that shape
before ("a new rule almost always has to land in more than one of them"); this is another instance.

`QDelegateRole.qml` gained `property string dotName: "d" + model.index` for that path, and its
comment says what the fixture does NOT cover: the liveness itself, because nothing in that document
can change a role.

Still open, and now precisely stated: a comparison whose operand is a role read
(`model.index === 1 ? …`). The role read is compiled against a declared type, and in a comparison
there is none to hand — the type has to come from the other operand.

Corpus counts unchanged (Basic 24, Fusion 12); values, render and click identical on both.

### A comparison gives its operands no type (2026-08-04)

`model.index === 1 ? 0.25 : 0.75` was refused, and the reason is one line of the compiler: a
comparison compiles both sides with an EMPTY declared type — what two values are compared as is
their own business. That is exactly what a read which needs a type cannot survive. A model role
crosses the meta-object, so the D type has to be named at the call site, and the comparison named
nothing.

The other operand knows: a literal `1` is an int. The typed attempt runs only AFTER the untyped one
fails, so every comparison that compiles today compiles to the same thing.

`QRoleCompare.qml` guards it, with 0.25 and 0.75 rather than 0 and 1 on purpose: `opacity` defaults
to 1, so a binding that never compiled leaves it there and the refusal is visible. Negative control
run — without the fix it reads 1 against the engine's 0.75.

Qt's two cases stay refused, and **for reasons that are not this one**: MonthGrid's root is
`AbstractMonthGrid`, which is not a bound type (a recorded ceiling), so neither operand of
`model.month === control.month` can be typed at all; and PageIndicator's `index === control.currentIndex`
reads a required property we cannot fill, which is the honest refusal from the earlier entry. Corpus
counts unchanged (Basic 24, Fusion 12), all six axes identical.

### One type missing from a registry of 10874 rows (2026-08-04)

`opacity: Tumbler.displacement` was refused as *declared type '?'* — but `opacity` on a `Text` is a
double everybody knows. Comparing the two registries: of every QtQuick type, **exactly one** was
absent from the Controls binding's — `Text`. Its 78 property rows were filed under `QQuickText`, the
C++ class name.

The cause is one line of the generator. A `Component` with no exports is recorded under its C++
class name on purpose — grouped-property helpers like `QQuickRangeSliderNode` are reachable and
never exported — but that entry OVERWROTE a real QML name the same class already had, read from a
different `.qmltypes`. Last one wins, and in the Controls binding the unexported re-declaration of
`QQuickText` came last. The fix is that the fallback only applies when the class has no name yet.

Cost while it lasted: not one `Text` binding in either corpus could be typed, and nobody noticed
because the refusals came out wearing another shape.

**And fixing it turned the runtime gate red**, which is the second half of this entry:
`Tumbler DOES NOT BUILD: undefined identifier 'modelData'`. A declared property we do NOT emit
(`required property var modelData`) stayed in scope anyway, so every read of the name compiled to an
identifier the D compiler had never heard of. Not a refusal — a link error. It only surfaced now
because `Text.text` became typeable at all; before that the binding was refused earlier and the
undefined name never got out. The name now leaves scope with the property, and the read is refused.

Both Tumblers moved from *declared type '?'* to a typed expression refusal, which is the more
actionable message. Counts unchanged (Basic 24, Fusion 12), 61 and 52 documents construct, all six
axes identical.

### The registry check became a gate (2026-08-04)

The `Text` bug was found by comparing two tables that had never been compared. Swept for the same
signature everywhere — a QML name in `qmlmap.tsv` with no rows in `qmlprops.tsv` — across every
registry: `Text` was the only one. The inverse shape (a class filed under BOTH its QML and its C++
name) is also empty, and `qmlattached`/`qmlmethods` legitimately cover a subset, so there is no
signature there.

The check is three lines of shell, and not having it cost every `Text` binding in both corpora. It
is now `registry-gate-controls` and `registry-gate-quick`, inside `./build`, with its negative
control run: with `Text`'s rows removed from a copy of the registry it fails and names the type.

Adding it turned the build red once more, and again for a reason only the full build could give:
`self-test FAIL unclassified target: registry-gate-quick`. Every target must be classified by family
and Qt axis in `tools/test-report.sh` — a new target that is not is a failure, deliberately. Both
are `gate`, with no version axis: they check DATA, not something linked against a Qt.

### An attached property read for its VALUE (2026-08-04)

`opacity: Tumbler.displacement` — how both style corpora fade a Tumbler's delegate with distance.
The OBJECT-valued half of this (`Window.window ? … : …`, a truth test) already had a branch; the
scalar half had none at all, so every such read was refused.

It is the same channel as any other property read, on an object fetched by
`qmlAttachedPropertiesObject` instead of from a field, and the member's type is already published by
`qmlattached.tsv`. The DEPENDENCY side needed nothing — it already emits
`tryConnectMeta(attachedObj(…), "displacementChanged()", …)`, so the binding is live the moment the
read compiles.

**Basic 24 → 21, Fusion 12 → 11**, all six axes identical.

A fixture was written and thrown away. `--objpaths` on a Tumbler comes back EMPTY — its items are
created by the view and have no static path — so the file compared only the root's `opacity` and
would have passed with the defect present. A fixture that cannot fail is worse than none, because it
claims coverage it does not have; the guard here is the corpus measurement, as it is for the other
changes whose observable lives inside a view.

### `objectName` was in no type of one registry (2026-08-04)

Isolating the `highlightedItem` group turned up an asymmetry that has nothing to do with it:

```qml
property string s: t.text          // compiles
property string s: t.objectName    // refused
property double d: t.width         // compiles
```

`objectName` is the one property EVERY QObject has. Counted: the Controls registry publishes it for
310 of its 331 types; the QtQuick one for **0 of 186**. The Controls spec reads the QML module's
`plugins.qmltypes` — where `QtObject` declares `objectName`, from which it descends the whole
prototype chain — and the QtQuick spec read only QtQuick's. One line in the spec: 194 rows across
214 types, and the read compiles.

Same family as the `Text` bug: a DATA gap wearing a compiler gap's clothes. And a shape the gate as
first written could not see — it checked that a type has SOME rows, not that it has the right ones.
It now also fails when no type in a registry publishes `objectName`, with the diagnosis in the
message (which `plugins.qmltypes` is missing from the spec) and its negative control run.

The spec change is a vocabulary change, so the manifest gate is what judges it: full build green,
and all six axes on both corpora identical.

### A null object property, and a partial with nothing reported (2026-08-04)

`property Item hi: null` was refused, and the refusal took the DECLARATION with it — so the property
did not exist at all, which is a structural difference from the engine rather than a value one. It
is the first half of Qt's Basic ComboBox
`property Item highlightedItem: parent ? parent.itemAtIndex(control.highlightedIndex) : null`.

`QNullObjProp.qml` guards it. Its negative control shows the shape twice over: without the fix the
engine has a `hi` line we do not, AND the root's `__class` changes — our class stopped declaring
properties, so the walk skipped past it, which is the rule from an earlier entry confirming itself
from the other side.

**And the fixture immediately failed for a different reason, which was mine.** It exited 3 with an
EMPTY stderr: a "members were skipped and reported" verdict with nothing reported. Two commits ago,
silencing a false-alarm refusal removed the MESSAGE and left the COUNTER. The corpora tolerate exit
3 and said nothing for two days; the fixture gate treats 3 as failure, and caught it the first time
a fixture went through that branch.

Worth naming as a property of the instruments: **the corpus measures quantity, the fixture gate
measures verdict**, and each sees things the other tolerates by construction.

Corpora unchanged (Basic 21, Fusion 11), all six axes identical.

### A method call whose result is an OBJECT (2026-08-04)

The invoke channel always returned TEXT — QMetaType converts it, which is how a colour travels
everywhere here — and no string stands for an item. So a call like `parent.itemAtIndex(i)` could not
be a value at all, and the property reading it was refused, declaration included. The call body is
now split from its result formatting: one implementation produces a `QVariant`, and the two entry
points disagree only about how to hand it back.

Two corrections came out of measuring rather than designing:

**The first fixture could not fail.** It read `lv.itemAtIndex(0)`, which is `<null>` on BOTH sides —
a view has not created its items when the dump runs. `childAt(10, 10)` answers from the object tree
alone and needs no layout.

**And the call still answered null.** The assignment was emitted before the children existed and
before the root had a size, so `childAt` had nothing to find. The engine evaluates the binding once
the tree is there; the call-based init now goes to the LATE phase, which is where every other
read-through-the-tree in this compiler already lives.

Negative control run: without the fix the engine has an `hi` line we do not, and the root's
`__class` changes with it. Corpora unchanged (Basic 21, Fusion 11), all six axes identical.

What is left of Qt's `property Item highlightedItem: parent ? parent.itemAtIndex(…) : null` is the
ternary itself: object-or-null, which the BASE-property path has had since the Fusion gradients
needed it and the declared-property path does not.

### The highlightedItem group, closed (2026-08-04)

```qml
property Item highlightedItem: parent ? parent.itemAtIndex(control.highlightedIndex) : null
```

Two things were still missing after the object-returning call landed.

**The object-or-null ternary on a DECLARED property.** The base-property path has had it since the
Fusion gradients needed it (`gradient: control.down ? null : buttonGradient`); the declared one did
not, so the property was refused and its declaration went with it.

**And a question written two ways.** `control.background ? … : …` compiled; `parent ? … : …` did
not. It is the same question — *do I have one yet?* — and refusing one spelling makes the support
look arbitrary. A bare name that IS an object here (a child's id, a declared object property,
`parent`) now answers it.

`QObjTernary.qml` compares BOTH branches on purpose: `present` takes the call branch, `absent` takes
the null branch, and it is `absent` that proves the condition is evaluated rather than assumed true.
Negative control run — without the fix both lines are missing from our side.

**Basic diagnostics 21 → 16**, Fusion 11, and the ComboBox no longer mentions `highlightedItem`.
All six axes identical on both corpora.

### Two more value forms of things whose truth-test form compiled (2026-08-04)

`parent: T.Overlay.overlay` — how Qt's Drawer puts itself in the window's overlay. Two pieces:

**Reading an attached property that IS an object, as a value.** `indicator.Window ? … : …` compiled;
`T.Overlay.overlay` did not. Now resolved in the object walker, import-alias spelling included, and
retyped by the QML name of the C++ class when the registry knows one so the walk can continue
through it.

**Assigning to a BASE property that holds an object.** The only object-assignment branch required
the target to be a DECLARED property; a base one typed `QQuickItem*` had no branch at all, which
left the object-or-null ternary as the only base-object assignment the compiler could do.

**Basic 16 → 15, Fusion 11 → 10**, all six axes identical.

No fixture, and the reason is the one from the Tumbler entry: `Overlay.overlay` exists only with a
window, and corpus documents are constructed without one — both sides would read `<null>` and the
file could not fail. The guard is the measurement.

### The fourth consumer, and the `@` it had never seen (2026-08-04)

Applying the pattern from the previous entry as a method — for every truth-test branch, look for its
value form — turned up the same shape one level along:

`property int g: Window.width` compiled the VALUE and then reported *depends on '@Window.width',
which has no known notify*. The `@` is the internal encoding of an ATTACHED dependency. The
base-property consumer has resolved it since Qt's Menu read `Window.window`; the declared-property
one had never seen the encoding at all and printed the marker as if it were a property name.

That is the fourth time a rule reached some of the dependency consumers and not this one. The three
are now named with their line numbers in the resume note, and this is the first place to look when a
newly-compiling read complains about notify.

Corpora unchanged (Basic 15, Fusion 10) — Qt does not write this form on a declared property, so no
count moves; what moves is that the message stops being false.

Still open and isolated: `kid.Window.width`, the OBJECT form of the attached read (as opposed to the
type-name form). The branch is written and does not fire, so something above it claims the
expression first — measured rather than guessed at next.
