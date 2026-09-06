<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# Writing QML that `qmltc-d` compiles well

For someone with a working application who wants more of it compiled to D and less of it handed back
to the engine.

It has two halves, and they turn out to be the same half. **§3–4 are about design** — how to
compose, where a document's boundary belongs, what SOLID means in QML. **§5–9 are about the
compiler** — which shapes it takes, how to measure what it did, how to diagnose a difference. They
agree almost everywhere, because *the compiler can only compile what a document names for itself*,
and naming what you need is also what makes a document reusable. Where they disagree, §4 says so.

Nothing here is invented. Every rule arrived as a defect in a real reader or in Qt's own Controls,
and each one says what it cost when it was found. The numbers are measurements, not estimates.

**Nothing here is required, either.** A document that follows none of it still runs — see *The
ladder*. The difference is how much of it is D.

---

## 1. The ladder, first, because it decides how much any of this matters

Every expression, handler and element takes the highest tier that can hold it:

| tier | what it is | when |
|---|---|---|
| 1 | **compiled** — a D expression with a real notify connection behind it | the compiler can name everything it reads |
| 2 | **AOT shadow** — a generated QML document compiled to bytecode at build time, carrying the original document's imports | only when the build passes `--shadow-dir` |
| 3 | **the engine** — `QQmlExpression`, evaluated live and kept live | everything else |

**A failure at one tier falls to the next; the bottom one always answers**, because the engine is
what would have run had this compiler not existed. So a refusal is a *performance* result, not a
correctness one.

The exception worth knowing: an expression the **engine** also cannot resolve throws, and a throwing
binding leaves its property at its default. Those are printed, one line per binding, and they are
the lines to chase. Everything else in a `.diag` is accounting.

> This ladder is enforced, not assumed. `shadowaot-*` runs the same program twice — once as built,
> once with `QTD_SHADOW_FORCE_FAIL=1` — and demands the **engine's values** from both. A gate that
> only checked "it did not crash" would pass with every property sitting at its default.

---

## 2. Measure before you change anything

### The census

```sh
qmltc-d Main.qml Main --qmlmap <gen>/qmlmap.tsv --no-main > Main.d 2> Main.diag

grep -c 'delegated to the engine' Main.diag     # tier 3
grep -c 'skipped (later phase)'   Main.diag     # not built at all
grep -oE "delegated to the engine: '.*'" Main.diag | sort | uniq -c | sort -rn | head
```

**The last line is the one that pays.** Refusals cluster: in the reader this was measured on, four
spellings of one name — `theme.ink`, `theme.paper`, `theme.muted`, `theme.accent` — were 293 of
1084 delegations. Fixing a *shape* moves hundreds of expressions; fixing an expression moves one.

For scale, that same application today: 58 105 lines of D, **1084 delegated**, **275 refused**,
499 cross-document promises.

### At run time

| switch | shows |
|---|---|
| — | `qtd_bind_js: … threw:` and `qtd_run_js: … threw:` are always printed, once per binding |
| `QTD_JS_TRACE=1` | every delegated binding's value, on every re-evaluation |
| `QTD_PROMISE_DEBUG=1` | which cross-document names resolved, and which never did |
| `QTD_DUMP_TREE=<ms>` | the object tree with geometry, read through the meta-object |
| `QTD_CTX_DEBUG=1` | whether a throwing binding's context carries the per-item names |
| `QTD_SHADOW_FORCE_FAIL=1` | forces tier 2 to fail, so the fallback is exercised |

`QTD_DUMP_TREE` is the one to reach for first when something *looks* wrong. A screenshot says a
document collapsed; it does not say which item. The dump says `Main_dc2 0x64 @0,0` — a header 0
wide against a window of 620 — and the search is over.

### Comparing frames

If the application can photograph itself, build it both ways and diff the pixels rather than the
impression. The last defect in the reader was 46 columns of white where the engine draws a shadow;
by eye it read as "a page inset", which is not what it was. Sampling one row across both frames named
it in one step (`#ffffff` against a gradient), and after the fix every sampled pixel matched.

---

## 3. Composition: what a document is, and when to make another

**The unit of composition in QML is the document.** A `.qml` file is a type; instantiating it is the
only way to reuse it; and it is also the unit this compiler generates a class for. So the question
"should this be its own file?" has the same answer for design and for compilation, which is
convenient and not a coincidence — both are asking whether the thing has an interface.

### When to split

Split when **any** of these is true. Two of them being true is not twice the reason; one is enough.

1. **It is instantiated more than once.** Two copies of twenty lines is the moment, not the third.
2. **It has a name you would use in a sentence about the application.** "the reference button", "the
   page turn", "the theme picker". If you can name it without saying "the Item that…", it is a type.
3. **Its state is its own.** A block that declares three properties nothing outside it reads is
   already a document that has not been written yet.

### When NOT to split

- **A block that reads five things from its parent and writes two.** Extracting it does not create a
  component, it creates a coupling with a longer name — and here it also costs you tier 1, because
  those five names become cross-document and go to the promise (§5.1).
- **Anything that exists to avoid indentation.** Depth is not complexity.
- **A delegate under 15 lines.** Write it inline; the compiler treats an inline delegate and a
  delegate in its own file identically, so this is purely a readability call.

### The middle option, which is usually the right one

`component Foo: Rectangle { … }` — an **inline component** — is a type in the same file. It is
reusable, it takes properties, and it does *not* pay the cross-document cost, because the compiler
still sees one document. Reach for it when the thing is a type but only this file's business.

```qml
// one file, two types, no cross-document names
Item {
    component Swatch: Rectangle {
        required property color tint
        width: 20; height: 20; radius: 10; color: tint
    }
    Row { Repeater { model: palette; delegate: Swatch { tint: modelData } } }
}
```

### A document's interface is its declared properties and its signals

```qml
// Leaf.qml — everything it needs, named at the top, and nothing else
Item {
    required property string body          // in
    property int size: 16                  // in, with a default
    signal verseChosen(int number)         // out
}
```

- **In: declared properties.** `required` where there is no sensible default — the engine then
  refuses to instantiate it wrong, which is a better error than a blank screen.
- **Out: signals.** A child that reaches up and writes `root.selection` has made the parent part of
  its own definition; a child that emits `verseChosen(n)` can be dropped into any parent.
- **Never reach up.** `root.something` inside a child document is the single most expensive habit in
  this codebase: it cannot compile (the compiler sees one document at a time), it goes to the
  promise, and if the name is not reachable at run time it throws and the property keeps its
  default. Every one of those is a line in your census.

---

## 4. SOLID, in QML, with the price tag attached

The principles are not decoration here. Four of the five have a direct, measurable cost in the
census, because **the compiler can only compile what a document names for itself**.

### S — one document, one job

A document that paints, animates, persists and parses is four documents. The test is the one from
§3: can you name it in a sentence? `Main.qml` at 1300 lines is where a reader's every gap
concentrated, and it is 1300 lines because four jobs never left it.

### O — extend by composing, not by editing

Adding a case to a document means editing it and re-testing everything it already did. Adding a
*type* means the old ones are untouched. In QML the mechanism is a `Loader`, a delegate chosen by
role, or simply another file:

```qml
// closed for modification: adding a kind adds a file, and touches nothing here
Loader { source: "cards/" + model.kind + "Card.qml" }
```

### L — a substitute must honour the contract

If `SepiaTheme` can stand where `Theme` stands, every property `Theme` declares must exist on it
with the same meaning. In QML nothing checks this for you, which is exactly why the contract should
be **declared properties** rather than "whatever the object happens to have": a `var` that is
sometimes an object and sometimes a string is a Liskov violation you will meet at run time, and here
it is also the shape that cannot compile.

### I — declare the properties you need, not a bag of `var`

```qml
// costs: a meta-object hop per read, no compiled binding, and a throw when it is undefined
property var config

// costs: nothing. Compiles.
required property string face
required property int size
```

`property var` is the interface-segregation violation that this compiler charges for by name:
a `var` is opaque, so every read through it is delegated. Splitting one `var` into the three
properties actually read is usually the largest single win available in a document.

### D — depend on what is passed in, not on who instantiated you

This is the one that matters most, and it is §3's "never reach up" restated:

```qml
// Leaf.qml, depending on the concrete parent: refuses to compile, may throw
color: root.theme.ink

// Leaf.qml, depending on its own interface: compiles
required property color ink
color: ink
```

The parent passes `ink: theme.ink` at the instantiation site — one delegated expression there
instead of every read inside the child. In the reader, the `theme.*` cluster is 293 delegated
expressions, and all of them are this.

**The counter-case, and it is a real one:** a palette read by forty documents is a genuine
cross-cutting concern, and threading it through forty constructors is worse than the coupling.
Publish it as a **context property from D** instead — the promise resolves it, once, and the
documents stay independent of each other. Dependency inversion means depending on an abstraction,
not on threading everything by hand.

---

## 5. Rules that move whole clusters

### 5.1 A name from another document is answered late, or not at all

`theme.ink`, where `theme` is a context property or a property of whoever instantiated this
document, cannot be resolved by a compiler that sees one document at a time. It is handed a
**promise**: an object that exists now and is filled when the name becomes reachable, after which
the binding re-evaluates by itself.

It resolves for a **context property** and for a name on an object above it in the tree. It does
**not** resolve for a name that lives only in a delegate's scope, nor for an object that is never
parented.

**If a cluster of refusals all name one thing, publish that thing from D** as a `@QObject` with
`@Property`s and set it as a context property. In the reader, moving a `readonly property var theme`
table out of QML into a D `Theme` object made every `theme.*` binding resolve.

### 5.2 Declare delegate data as `required property`

`modelData` and `index` are the one shape the promise cannot reach: a delegate body is created
before it is parented, so there is nothing above it to ask. Written as

```qml
Repeater {
    model: pages
    delegate: Text { required property string label; text: label }
}
```

the name is a property of the object itself and compiles. Written `modelData.label` it is delegated,
and where the delegate is built outside a view it throws.

This is the largest single cluster left.

> **`required property` in a delegate is Qt 6.** Measured on one document across both: every value
> reads back on Qt 6.11 and all of them are undefined on Qt 5.15, because filling a delegate's
> required properties from the model arrived with Qt 6. An application that ships both majors has
> three options, and the middle one is usually right:
>
> | spelling | Qt 5 | Qt 6 | compiles |
> |---|---|---|---|
> | `modelData.label` | yes | yes | no — one delegated read per use |
> | `property string label: modelData.label`, then read `label` | yes | yes | the reads do; one delegated expression per row-property |
> | `required property string label` | **no** | yes | yes |

### Hand the rows over as a model, not as JSON

A `QVariantList` of `QVariantMap` **is** a QML model — a view iterates it and a delegate reads the
keys by name, with no `QAbstractListModel` and no roles to register. Build it from D with `setModel`,
which takes an array of structs and uses the field names as the keys:

```d
struct Verse { int number; string text; bool marked; }
setModel(this, "page", verses);          // `page` is a `QmlVar` @Property
pageChanged.emit();
```

The struct is the row's schema, declared once, and it is the same list of names the delegate claims.
The alternative applications reach for — a JSON string the QML re-parses on every change — pays a
serialise, a parse, and a delegate reading through `modelData` on every key.

### 5.3 Handlers take no parameters if you want them compiled

A handler with parameters is neither compiled nor delegated — its parameters live in the slot
signature and there is nowhere to publish them. `onClicked: (mouse) => { … }` refuses;
`onClicked: { … }` reading `mouse` from the enclosing scope does not.

### 5.4 Prefer a typed function signature

`function pick(i) { … }` crosses as `QVariant` in and out — it works, and every call goes through
the engine. `function pick(i: int) : string { … }` compiles.

### 5.5 A property you add to a `Timer`, `ListModel` or `RowLayout` costs a meta-object hop

Those types are not in the binding, so the **engine** builds them and the generated D holds a shell
around the instance. Properties the document declares on such an element are declared into the
engine's object too, so one name answers both halves — `shotTimer.target = x; shotTimer.restart()`
works — but reads and writes are meta-object round trips rather than field accesses. That is a
price, not a limitation. If a property is written every frame, put it on the enclosing object.

### 5.6 Ids are visible everywhere, and declaration order does not matter

An id declared at the bottom of the document is nameable from the top. Worth knowing because the
workaround — moving elements around — is no longer needed.

---

## 6. What is never compiled, and why that is correct

- **`Component { … }`** is a template. Building it eagerly would instantiate its contents once,
  which is wrong. This is what `Component` *means*, not a gap.
- **A type with no default property** (`Action`, `FontLoader`, `Translate` and eleven others) cannot
  hold bare children. Assuming one would invent a path neither side has.
- **A delegate's per-item names outside a view.** If nothing instantiates the delegate per item,
  there is no per-item context and no value to find.

---

## 7. Diagnosing a difference: the method

Every defect fixed in this compiler was found the same way, and the order matters.

1. **Describe the phenomenon, not the code.** "The footer labels are piled at the same x" is a
   phenomenon. "The width binding is wrong" is a guess.
2. **Get the geometry** (`QTD_DUMP_TREE`) or **the pixels** before touching anything. A crash gets
   a backtrace — `gdb -batch -ex run -ex bt` — never a hypothesis.
3. **Reduce to the smallest document that shows it.** Every rule in this file arrived as a ten-line
   `.qml`. Reducing is also what tells you whether it is one defect or three: the delegate late
   phase turned out to be hiding three separate null dereferences, each of which surfaced as its own
   SIGSEGV the moment the dead code ran.
4. **Turn the reduction into a fixture** under `tests/qmltc/quick/`, and check that it asserts the
   thing it is about. The differential compares the ROOT's properties, so a fixture about a nested
   item must publish the value on the root:

   ```qml
   readonly property real rowW: row.width      // this is what the fixture asserts
   ```

   The first version of `QDelegateSibWidth` asserted only `width` and `height` and passed in both
   directions. A fixture that would pass before the fix is not a fixture.
5. **Two spellings of the same thing behaving differently is a compiler defect**, always. `color:
   paper` and `color: root.paper` took different paths; a `Connections` cost every unbound sibling
   below it; `anchors.left` was copied as text while `anchors.fill` was not. When you see this,
   reduce it and report it.

---

## 8. What to do with a refusal you cannot avoid

Leave it. It runs. Spend the effort on the cluster at the top of the `uniq -c` list instead.

**A delegated binding that *throws* is different.** That is a real defect in the document or in the
compiler, not a performance note — the property is sitting at its default and the document says it
is bound. Those lines are always worth chasing.

---

## 9. Reading a `.diag`

| line | meaning |
|---|---|
| `delegated to the engine: '<expr>'` | tier 3. Works, costs an evaluation. |
| `skipped (later phase)` | not built. The property exists; its value does not. |
| `not yet supported — the body does not compile and could not be delegated` | both halves failed. Rare now. |
| `Component in X is a template … skipped` | correct behaviour, see §6. |
| `'X' declares no default property` | correct behaviour, see §6. |
| `Connections in X is not on an id of this document — delegated` | the engine owns the whole element, handlers included. |

Exit code 3 means **partial**: members were skipped and every one was named on stderr. It is normal
and it is not a failure. Exit 1 or 2 mean the document could not be read at all.
