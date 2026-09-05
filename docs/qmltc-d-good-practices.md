<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# Writing QML that `qmltc-d` compiles well

This is for someone with a working application who wants more of it compiled to D and fewer
expressions handed back to the engine. It is not a style guide: every rule here was found by
compiling a real reader and Qt's own Controls, and each one names what it cost.

Nothing here is required. **A document that follows none of it still runs** — see *The ladder*
below. The difference is how much of it is D and how much is the engine.

## The ladder, first, because it decides how much any of this matters

Every expression takes the highest tier that can hold it:

1. **compiled** — a D expression, with a real notify connection behind it;
2. **AOT shadow** — a generated QML document compiled to bytecode at build time, carrying the
   original document's imports (only when the build passes `--shadow-dir`);
3. **the engine** — `QQmlExpression`, evaluated live, exactly what would have run if this compiler
   did not exist.

A failure at one tier falls to the next; the bottom one always answers. So a refusal is a
*performance* result, not a correctness one — with one exception worth knowing: an expression the
engine also cannot resolve throws, and a throwing binding leaves its property at the default. Those
are printed. Read them.

## Measure before you change anything

```sh
qmltc-d Main.qml Main --qmlmap <gen>/qmlmap.tsv --no-main > Main.d 2> Main.diag
grep -c 'delegated to the engine' Main.diag     # tier 3
grep -c 'skipped (later phase)'   Main.diag     # not compiled at all
grep -oE "delegated to the engine: '.*'" Main.diag | sort | uniq -c | sort -rn | head
```

The last line is the one that pays: refusals cluster. In the reader this was measured on, four
spellings of one name (`theme.ink`, `theme.paper`, `theme.muted`, `theme.accent`) were 293 of 915
delegations. Fixing a *shape* moves hundreds of expressions; fixing an expression moves one.

At run time:

| variable | shows |
|---|---|
| `QTD_JS_TRACE=1` | every delegated binding's value on every re-evaluation |
| `QTD_PROMISE_DEBUG=1` | which cross-document names resolved, and which never did |
| — | `qtd_bind_js: … threw:` and `qtd_run_js: … threw:` are always printed, once per binding |

## Rules that move whole clusters

### 1. A name from another document is answered late, or not at all

`theme.ink`, where `theme` is a context property or a property of whoever instantiated this
document, cannot be resolved by a compiler that sees one document at a time. It is handed a
**promise**: an object that is filled when the name becomes reachable, after which the binding
re-evaluates by itself.

It resolves for a **context property** (`setContextProperty`) and for a name on an object in the
tree above. It does **not** resolve for a name that only exists in a delegate's scope, and it cannot
for an object that is never parented.

If a cluster of refusals all name one thing, publish that thing from D as a `@QObject` with
`@Property`s and set it as a context property. In the reader, moving a `readonly property var theme`
table from QML into a D `Theme` object made every `theme.*` binding resolve.

### 2. Declare delegate data as `required property`

`modelData` and `index` are the one shape the promise cannot reach: a delegate body is created
before it is parented, so there is nothing above it to ask. Written as

```qml
Repeater {
    model: pages
    delegate: Text { required property string label; text: label }
}
```

the name is a property of the object itself and compiles. Written as `modelData.label` it is
delegated, and if the delegate is built eagerly it throws.

### 3. Handlers take no parameters if you want them compiled

A handler with parameters is neither compiled nor delegated — its parameters live in the slot
signature and there is nowhere to publish them. `onClicked: (mouse) => { … }` refuses;
`onClicked: { … }` reading `mouse` from the enclosing scope does not.

### 4. Prefer a typed function signature

`function pick(i) { … }` crosses as `QVariant` in and out — it works, and every call goes through
the engine. `function pick(i: int) : string { … }` compiles.

### 5. `Component { … }` is never compiled

A `Component` is a template; building it eagerly would instantiate its contents once, which is
wrong. It is skipped by design. This is not a gap to work around — it is what `Component` means.

### 6. A property you add to a `Timer` or a `ListModel` is read through the meta-object

`Timer`, `ListModel`, `RowLayout` and friends are not in the binding, so the **engine** builds them
and the generated D holds a shell around the instance. Properties the document declares on such an
element are declared into the engine's object too, so one name answers both halves —
`shotTimer.target = x; shotTimer.restart()` works. They are not D fields, so reads and writes cost a
meta-object round trip rather than a field access. That is a price, not a limitation; if a property
is written every frame, put it on the enclosing object instead.

### 7. Ids are visible everywhere; declaration order does not matter

An id declared at the bottom of the document is nameable from the top. This was not always true and
it is worth knowing it is now, because the workaround (moving elements around) is no longer needed.

### 8. Spelling changes the answer more often than it should

Two that were measured, both now fixed, both worth remembering as a debugging instinct: `color:
paper` and `color: root.paper` took different paths, and `Connections` cost every unbound sibling
below it. When two spellings of the same thing behave differently, that is a compiler defect —
reduce it to the smallest document that shows it and report it. Every rule in this file arrived that
way.

## What to do with a refusal you cannot avoid

Leave it. It runs. Spend the effort on the cluster at the top of the `uniq -c` list instead — and if
a delegated binding *throws*, that is a real defect in the document or the compiler, not a
performance note. Those are the lines to chase.
