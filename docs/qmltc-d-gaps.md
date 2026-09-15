<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# Where qmltc-d's remaining work is, ranked by what it costs

`docs/qmltc-d.md` says what the compiler covers. This says what it does **not**, ordered by how
much of a real application each gap accounts for, so that the next piece of work is chosen by
measurement rather than by which diagnostic is easiest to read.

It is deliberately not a wish list. Every row below is a count taken from one corpus, with the
command that produced it, and a three-line reproduction that a fixture can be built from.

## The one-sentence version

**88% of everything the compiler refuses is a single shape: a name that belongs to another
document.** Not eighty-seven separate gaps — one, seen from many angles.

## What has since been built, and what it moved (2026-09-15, 59559c0)

The largest sub-shape of rows 1 and 2 — a **member read through a name the application published**
(`theme.ink`, `bible.<x>`: a context property, so no registry can type it) — is now COMPILED rather
than delegated. The read goes through the meta-object off the object the context answers with, and
its notify is connected when that name becomes reachable rather than when the code is emitted; the
mechanism and its three measurements are in that commit, and the fixture is
`tests/qmltc/dtypes/DCtxTheme.qml` with `qmltc-pedantic-DCtxTheme` asserting that the document
compiles with no delegation at all.

Re-measured on the same application by the session that owns it, with the tool rebuilt and the
diagnostics recounted from scratch rather than subtracted on paper:

| | before | after |
|---|---|---|
| expressions delegated to the engine | 339 | **214** |
| of those, `theme.<member>` | 88 | **4** |
| shadow documents (`bindShadow`) | 206 | **89** |
| startup, restored→ready, engine tier | 183–191 ms | **~80 ms** |
| startup, restored→ready, bytecode tier | 226 ms | **~86 ms** |
| the same application, not compiled at all | 110–118 ms | 110–118 ms |

The last row is the one that matters, and it is why this gap was ranked first: **compiling that
document used to COST startup time** — the compiler was adding machinery (an engine expression or a
bytecode unit per refusal) to a document that stayed interpreted, and the arithmetic of 68% refusals
came out exactly as it had to. Both tiers are now under the interpreted time.

Two readings worth keeping, because neither was obvious before the measurement. The tiers have
converged and *crossed*: with 89 shadows the per-expression component loads cost marginally more
than the same number of engine expressions, so the bytecode tier is no longer the faster one — it is
the one that reads no `.qml` at run time, which is a different property and the one a strict build
would want. And what is left is no longer one shape: the 214 spread across handlers, `Connections`
with no id, functions with an untyped parameter, `var` initialisers, and calls on a published name
(`theme.nameAt(i)` — a call, not a read, and still refused). Rows 1 and 2 below remain as measured
at `7301574`; they are the baseline this table moved, not a current count.

## What was measured, and on what

A real Portuguese Bible reader (`lectio`), whose interface is 12 QML documents, compiled against
the tool at `7301574` and Qt 6.11.1 on Linux.

| | |
|---|---|
| documents | 12 |
| QML | 5 403 lines |
| D emitted | 49 792 lines |
| documents producing an object file | 12 of 12 |
| diagnostics | 1 153 |

The corpus is not in this repository — it is someone's application, and it moves. Everything below
is a snapshot; the commands to retake it are at the end. Numbers here are **not** gated by
`docs-numbers`, which owns the figures in `README.md` and `docs/qmltc-d.md` and nothing else.

**Speed is not the problem, and this document is not about it.** The largest document — 1 258 lines
of QML into 30 694 lines of D — compiles in 170 ms; the second largest in 50 ms. Optimising
qmltc-d means widening what it accepts, not making it faster.

## The ranking

Counts are diagnostics over the 12 documents. The first two rows are the same gap.

| # | cluster | count | what it is |
|---|---|---|---|
| 1 | a name from an **enclosing document** | **292** | `theme.ink`, `root.bookFace` — the head is declared in the document that instantiated this one |
| 2 | a name from the **delegate context** | **121** | `modelData.label`, `index` — supplied by the view at run time |
| 3 | a declared property whose **initial binding** is refused | 107 | the property exists and holds its type's default |
| 4 | a **function with an untyped parameter** | 64 | skipped entirely — callable from neither D nor the engine |
| 5 | a group member whose dependency has **no known notify** | 72 | assigned once, never updated |
| 6 | `Connections` without `target:` + `function on<Signal>` | 35 | one supported spelling out of several |
| 7 | everything else | 57 | genuinely local expressions the type router does not carry |

Rows 1 and 2 are 413 of the 470 refusals that quote an expression — **88%** — and they are also
the direct cause of 19 of the 24 delegated bindings that throw at run time.

## 1 and 2 — a name that belongs to another document

### The reproduction

Three lines each, and both refuse today:

```qml
// theme is declared in the document that instantiates this one
import QtQuick
Item { Text { color: theme.ink } }
```
```
base property 'color' in x_outer_dc0 (Text) not yet supported: declared type 'QColor'
    [theme.ink] — skipped (later phase)
```

```qml
// modelData comes from the view, not from the document
import QtQuick
Item { Repeater { model: [{ label: "a" }]; Text { text: modelData.label } } }
```
```
base property 'text' in x_model_dc0_dc0 (Text) not yet supported: expression for 'string'
    [modelData.label] — skipped (later phase)
```

### Why it is refused

QML resolves a bare name up the **context chain**, so a component may name ids and properties of
the document that instantiated it. The compiler sees one document at a time and cannot know what
that will be — which is a real limit, not an oversight.

What makes this the top of the list is that the refusal happens **twice**. The expression does not
compile, which is expected; and then `jsDelegate` also refuses it, which is not obviously
necessary, because the engine is exactly the thing that can resolve a name we cannot. It refuses
because it hands objects over by name and there is no object to hand over: `theme` is neither a
declared property, nor a base property, nor an object path.

### The distribution

| head | count | where it comes from |
|---|---|---|
| `theme` | 164 | a `property var` on the reader's root |
| `modelData` | 121 | the delegate's model row |
| `root` | 95 | the enclosing document's root id |
| `mapView`, `verse`, `bible`, … | 32 | other enclosing ids |
| head declared in THIS document | 57 | the genuinely local remainder |

`root.bookFace` is refused in 11 of the 12 documents while `bookFace` is declared in 2 of them —
which is the measurement that shows this is a boundary problem and not a typing one.

### The candidate route, stated as a candidate

The compiled path **already** looks a name up in the enclosing scope: `readName` and `objPathHead`
resolve an outer-scope bare name and the emitter reaches it through `__outer`. The delegation path
does not use that. Handing `__outer` over under a generated name and rewriting `theme` to
`__o.theme` would give the engine something it can resolve, and it is the same rewriting
`jsDelegate` already performs for attached types and `as` casts.

This has not been implemented or measured. What is measured is only that 413 refusals share this
head shape, and that the delegation machinery it would reuse exists.

## 3 — a declared property whose initial binding is refused

107 of them. The property is declared and reads as its type's default; every expression that reads
through it then answers `undefined`, which is where most of the 24 run-time throws come from.

`var` properties are already handled — their initial value is delegated to the engine (44 of them
in this corpus). The same treatment is not applied to a declared property of any other type: the
emitter declares the property and prints the refusal without trying `jsDelegate`. Whether that is
correct for every type is an open question a fixture would answer.

### Closed, 2026-09-06

It was correct for every type, and there were four emitters, not one — the scalar path, the colour
path, the value-type path and the `var` path each printed their own refusal. All four now offer the
binding to the engine first. **107 → 4**, and the four that remain are not this gap: they are
`modelData` read inside a delegate that declares required properties, where the engine has no
`modelData` either, so refusing is the honest answer (see `ctxNameIsReadable`).

Two things had to be fixed for it to hold:

- **A binding whose body is a BLOCK.** `readonly property int wantedZoom: { … return z }` is
  ordinary QML and is not an expression, so the delegation — which is handed one — was never offered
  it. A block is JavaScript and the engine runs JavaScript: `(function(){ … })()` is an expression
  again, and the reads inside it are captured as the binding's dependencies exactly as they would be
  in one.
- **The promise rewrite must not touch a name DECLARED in that block.** It is a whole-token
  substitution over the source, safe in an expression and not in a block: `var worldPx` became
  `var __sp_worldPx.worldPx` and the engine refused the whole body — losing every read in it, not
  just that name. The test is whether the source is a block, not whether it is a handler.

Fixture: `tests/qmltc/quick/QBlockBinding.qml`, which reads a block-declared local back through the
binding's result, so a broken rewrite is a wrong VALUE rather than a silence.

## 4 — a function whose parameter type cannot be inferred

64 of them, and the refusal is deliberate: guessing `double` compiles `f(x, y) { return x + y }`
into numeric addition, which is wrong the moment it is called with strings. Qt declines the same
shape.

But the function is then emitted **nowhere**, so it is callable from neither side. Measured in the
reader: `nav.visibleIndex(nav.browsedBook)` is a delegated binding, and it fails at run time with

```
TypeError: Property 'visibleIndex' of object Main_dc9 is not a function
```

A QML function with untyped parameters is JavaScript, and the engine runs JavaScript. Emitting a
method that hands the call to the engine — the channel `runJs` already opens — would make it
callable by both halves without guessing a type. Not implemented.

## What it costs at run time

The reader starts, stays up, and renders; what remains is 24 delegated bindings that throw on first
evaluation. Measured on the built binary, `QT_QPA_PLATFORM=offscreen`:

| | count | traces back to |
|---|---|---|
| `Cannot read property 'X' of undefined` | 16 | gaps 1 and 3 |
| `Cannot read property 'X' of null` | 3 | an object assigned later than the binding |
| `Property 'X' … is not a function` | 3 | gap 4 |
| `ReferenceError: bible is not defined` | 2 | a context property of the application's own root, not in the hand-built context chain |

The last row is not in the list above because it is not the compiler's: the application registers
`bible` on the engine's root context, and an expression delegated from a hand-built context does
not see it. It is listed because it is a real failure and belongs somewhere.

## Retaking the measurement

```sh
DSIDE=~/lab/qt-dlang-gen
TOOL=$DSIDE/.build/qt-6.11-cxx-quick/qmltc-d
MAP=$DSIDE/generated/qt-6.11/cxx-quick/qmlmap.tsv
for f in *.qml; do n=${f%.qml}; "$TOOL" "$f" "$n" --qmlmap "$MAP" --no-main >"$n.d" 2>"$n.diag"; done

# the ranking
cat *.diag | sed -E 's|^qmltc-d: [^ ]*/([A-Za-z]+)\.qml(:[0-9:]*)?: |  |' \
  | sed -E "s/'[^']*'/'X'/g; s/\[[^]]*\]/[…]/g; s/ in [A-Za-z0-9_]+ / in C /g" \
  | sort | uniq -c | sort -rn
```

The cross-document share is computed by taking the head identifier of each quoted expression and
asking whether the same document declares it (`id:`, `property`, `function`). That extraction is a
regular expression over the QML, so it is approximate at the edges — a property named `x` whose
value is a block was excluded by hand. The three headline counts (292 / 121 / 57) come from the
dotted-head form only, which is why they do not sum to the 542 refusals that quote anything.

## Re-measurement, 2026-09-06 (the reader now starts)

After the delegate-late-phase, engine-owned-property and id-pre-pass fixes, the reader — built
`USE_QMLTC=1` — **boots, exits 0 and paints its chrome**, where an earlier build built the tree and
then aborted with nothing on screen. The run-time throws that remain fell from ~100 to **35
`qtd_bind_js` + 3 `qtd_run_js`**, all on `Main_*`. Numbers are not directly comparable to the table
above: the reader has since grown a measures overlay (`Measure.qml`), and because it is kept out of
the qmltc list it is **inlined into `Main`**, so ~12 of the 35 are its `entry.modern/ratio/fig/…`
reading through an `entry` that is `undefined` at bind time — gap 3, wearing the overlay's names.

The classes still trace where the table says:

- `Cannot read property 'X' of undefined/null` — gaps 1 and 3. The body stays blank because the
  verse list's own bindings (`theme` sub-reads, model `.length`) are in this set.
- `Property 'adopt' … is not a function` — **gap 4, confirmed on a fresh case.** `function
  adopt(newContent)` (untyped parameter) is emitted nowhere, so `Component.onCompleted:
  stage.adopt(...)` — the FIRST page load — throws, which is part of why the body is blank. The
  application-side half of this was a bare `adopt(...)` self-call; qualifying it to `stage.adopt`
  moved the error from `ReferenceError: adopt is not defined` to gap 4's `is not a function`, which
  is the honest failure.

### The move that dissolves the largest throwing cluster, at the source

The `modelData.*` / cross-document class (gaps 1–2) is, in this reader, an **application shape, not a
compiler limit**, and the fix needs nothing new on either side. The data already crosses as a
`@Property string` of JSON that QML `JSON.parse`s into a list of maps — which is what a
`QVariantList` of `QVariantMap` **already is**, and a `QVariantList` already serves directly as a QML
model, no `QAbstractListModel` and no moc addition. So there are two independent moves:

1. **Compile the delegates now.** The model is already a list of maps; a delegate written
   `required property string text; text: text` (good-practices §5.2) compiles where `modelData.text`
   was delegated — no data-side change at all. This alone removes the cluster.
2. **Drop the JSON round-trip.** Have D build and expose the `QVariantList` directly instead of
   serialising a string the QML re-parses each chapter. An improvement, orthogonal to (1).

Teaching the compiler to resolve `modelData.var` is the wrong end; the model already carries the
names, the delegate just has to claim them.
