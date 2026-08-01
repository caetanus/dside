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
