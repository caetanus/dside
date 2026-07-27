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
  reactive bindings, default children, and **cross-file local `.qml` types** (a `Foo {}` that
  resolves to a sibling `Foo.qml`, as both root and child, with use-site member merging + override
  dedup). **7 / 66 are diff-GREEN vs the engine on ldc2+dmd**, and the tool's own compile-clean count
  EQUALS this build+diff green count — every file qmltc-d reports FULL genuinely diffs green, no
  silent-wrong emissions. Cross-file local types are essential to several (`ComponentWithAlias3`,
  `myMatryoshkaItems`, `myCheckBox`, `MyBaseItem`, `LocallyImported`). The remaining ceiling is
  structural: the corpus is fundamentally about compiling QML against **app-defined C++ types**,
  which a generic backend can't bind. Each further delta (`QtObject`-typed object props, custom
  `default property list<>` semantics, animations/value-sources, more type maps) unlocks ~1 file.
- **42 / 108 are pure QtQml.** Of these, qmltc-d compiles **17 fully** (10 → 17 as functions, enums,
  signals, `++`/`--`, `+=`, `if`/`else`, `console.log` and function-expression handlers landed). But
  **~17 of the 42 are rooted in a custom C++ type** (`QmlGroupPropertyTestType`, …) — Qt's qmltc
  corpus is fundamentally about compiling QML against app-defined C++ types, which a fresh-`@QObject`
  backend can't do. The QtObject-rooted files left each need a distinct niche (`Qt.binding`,
  cross-object member access, `= undefined`, external JS imports, `QtObject`-typed signal params).

Nothing here is silently dropped: any member or binding qmltc-d can't compile is reported on stderr
and the file exits `3` (PARTIAL), never a wrong emission.

## Tracked gaps (honest TODO)

- **Declared signals** (`signal foo(int)`), **`enum`s**, **`Component {}`**, **`Connections`**,
  **`Timer`**, grouped properties — the remaining pure-QtQml blockers (a long tail of distinct
  members).
- **Control flow inside functions** (`if`/`for`/local `var`s) and multi-statement return bodies —
  compileStmt currently handles assignments and calls.
- **Reactivity of a binding to what a no-arg function reads internally** (a binding calling a
  param-less `f()` that reads a property doesn't yet re-evaluate on that property's change;
  param'd calls are reactive through their arguments).
- **AOT fallback (end of flow)**: route whatever qmltc-d can't compile to the existing `qmlcachegen`
  bytecode + engine path (Qt's own hybrid model), so a PARTIAL file becomes a working hybrid rather
  than incomplete. Deferred until the static subset is wide enough.
- Brace-block (multi-statement) handler bodies; **child-target alias reactivity**; **dynamic
  mutation of child properties** (the dump/oracle mutate only root scalars today).
- More expression coverage: general member access, string methods, more `Math.*`, `Math.floor/ceil`.
- Non-scalar property types: `color`, `vector2d/3d/4d`, `url`, `size`, `rect`, `quaternion`.
- **Cross-file / local-type compilation** — DONE (roots + children + use-site member merge,
  cycle-guarded against self-referential files). Remaining cross-file work: nested `Component {}`,
  `QtObject`-typed object properties (`property QtObject o: QtObject {}`), `list<QtObject>`.
- **More QtQuick type maps** (`TextEdit`, `TextInput`, `MouseArea`, `Repeater`, `ListView`) and
  **bool/url base props** — each a mechanical delta unlocking ~1 corpus file.
- **Animations** (`justAnimation`): the engine runs the animation and the final value differs from
  the static binding — either read the animation's `to`/`from` or accept these as out of static scope.
