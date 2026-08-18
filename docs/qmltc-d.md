<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# qmltc-d — a QML → D compiler

`qmltc-d` turns a `.qml` document into a D class. A binding stops being a JavaScript expression the
engine re-evaluates and becomes a D method plus a signal connection. Qt's own Basic `Button.qml`,

```qml
implicitWidth: Math.max(implicitBackgroundWidth + leftInset + rightInset,
                        implicitContentWidth + leftPadding + rightPadding)
```

comes out as a slot the meta-object calls when any operand changes:

```d
@Slot void __rcb_implicitWidth() {
    setProp(this, "implicitWidth", __qmltcMax(
        propDouble(this, "implicitBackgroundWidth") + propDouble(this, "leftInset") + …,
        propDouble(this, "implicitContentWidth")   + propDouble(this, "leftPadding") + …));
}
```

```
connectMeta(this, "implicitBackgroundWidthChanged()", this, "__rcb_implicitWidth()");
connectMeta(this, "leftInsetChanged()",               this, "__rcb_implicitWidth()");
…
```

No JS engine is involved in that binding again, and the document is not read at run time. That last
part is measured rather than asserted — see [Does the .qml ship?](#does-the-qml-ship).

- **What it is compared with Qt's `qmltc`:** `qmltc-d-vs-qmltc.md`.
- **How every defect in it was found:** `qmltc-d-journal.md` (history; the numbers there are
  whatever was true on the day).
- **Source:** `tools/qmltc/qmltc_d.cpp` (compiler), `tests/qmltc/qtd_qmlvalues.cpp` (oracle),
  `tests/qmltc/o3.sh` (the gate).

## The criterion

One sentence, and everything below serves it:

> **Does it render and behave like the interpreted document?**

The QML engine is the specification. Not a spec document, not a test someone wrote — the engine,
running the same file, compared property by property and pixel by pixel. A construct is supported
when the differential says so and not before.

## Using it

```sh
qmltc-d --dump [-O0|-O1|-O2|-O3|-Ox] [--no-main] <file.qml> <ClassName> \
        --qmlmap <qmlmap.tsv> [-I <import dir>] > Generated.d
```

- `--dump` writes the D module to stdout. Diagnostics go to stderr.
- `--no-main` emits the **class only**. Without it the module carries a `main` for the differential
  harness, which is an error rather than an inconvenience once you link it into a program.
- `--qmlmap` is the type registry the generator writes beside a binding
  (`generated/<qt>/<binding>/qmlmap.tsv`). It is how the compiler knows that `Text` is
  `QQuickText`, what `implicitWidth` notifies, and which properties a type has.
- `-I` adds an import directory, for documents that resolve types from their own folder.

Exit codes: **0** compiled · **2** could not read the input · **3** PARTIAL — members were skipped
and every one was reported on stderr · **4** a delegation happened and `--pedantic` was given.

The generated class is an ordinary `@QObject`, so it takes part in everything the moc runtime
offers, including being handed back to QML:

```d
import qtmoc, generated;
qmlRegisterType!IHelloWorld("Gen", 1, 0, "IHelloWorld");   // works; verified
```

## The four mechanisms

Everything qmltc-d does is one of four, and they are not equally trustworthy. **That ordering is
the `-O` scale.**

### 1 — Static translation

Every name has a known D type, so the expression becomes D. Arithmetic, `a === b`, string
concatenation, ternaries, enum keys, property reads, `Math.*`, `for` loops and locals in a function
body all live here. Trivial JS is not a problem; *untypable* JS is. The limit is the type registry,
not the language.

### 2 — QVariant, for what is typed only at run time

`property var control`, `property color targetColor`: the meta-object declares the property, the
value lives in a runtime slot keyed by (object, name), and reads go through the meta channel. The
value is right; the type is late.

No D field is generated for these. A `QColor` field changed how every *read* of it compiled and
cost eight link failures before it was done this way — the value does not live on the D side at
all, exactly as a list property already worked.

### 3 — Containment, COM-style

Qt's Material style is built on `impl` types it does not export — `Ripple`, `BoxShadow`,
`ElevationEffect`. No D subclass can wrap a type with no linkable symbol, so the **engine** builds
the object and the generated class holds an opaque pointer to it; every member is asked of
whichever object owns it.

This is why Material compiles far less than Basic. It is not weak JS translation — it is unexported
types, and no amount of compiler work removes a symbol that is not in the library.

### 4 — Delegation, to the engine

`control.model[control.headerView.textRole]` reads a member by a name known only at run time: there
is no property to name and no type to hold the result. The expression is handed to the engine,
which also tracks its dependencies — the point being that **the dependencies of an expression we
cannot compile are exactly the ones we cannot enumerate.**

With `--shadow-dir` the same expression is compiled at build time instead: it becomes a generated
QML document carrying a real `Binding`, which `qmlcachegen` turns into bytecode. It has to be a
binding and not a function — what makes a delegated expression live is the engine capturing a
*binding's* dependencies, and a function call captures nothing.

### Where the fourth mechanism is not applied yet, and it is one rule

Delegation is applied to an EXPRESSION and to a whole DOCUMENT. It is not applied to a CHILD, and
three of the open items in `tests/expected-fails.json` are that single absence seen from different
sides:

- a default child whose **type** the registry does not know (`Timer`, `ListModel`, `RowLayout`) is
  dropped, though `createQmlObject("QtQuick", "Timer")` returns a live one — measured;
- a default child whose **shape** is unsupported (a `Connections` without the target form) is
  dropped for a different reason and by the same code;
- and dropping either **shifts the indices** of the children after it, so `data[i]` no longer names
  what the engine has there. Building some siblings and not others turns that from a short list into
  a wrong one, which is how it became visible at all.

Which of the two directions to take was settled by counting rather than arguing: **39 of the 240
documents that compile today skip a default child** — Basic's `ComboBox`, `Dialog`, `Drawer`, `Menu`,
`Popup` and `ScrollView` among them. Refusing a document whenever one child is refused would cost up
to all 39, so the tightening is out and the widening is the only affordable answer. (That those 39
match the engine today with a child missing says their skipped children are at the END of the list,
where nothing shifts behind them. Luck, not a property.)

**And one shape says the rule has to be about SOURCE, not about objects.** `AListView` builds its
`ListModel` through the engine and its `ListElement` children too, and the list still comes out
empty: `count` 0 where the engine has 3. `ListElement` is not an object anyone appends — QQmlListModel's
rows are built by the QML compiler out of the document's own text, so a `ListElement` instantiated on
its own is a shell with nowhere to go. Building a type and then its children separately cannot
reproduce that at any level of effort. What the engine needs is the SUBTREE'S SOURCE, which is what
`--shadow-dir` already hands it for a delegated expression.

The rule the codebase already states for a document — *"a document we cannot compile is not
abandoned, it is instantiated by the engine and reached through its interface like any other opaque
object"* — is the same rule a child wants. A child we cannot compile should be **built by the
engine**, not dropped: the indices stay right, the object behaves, and what we could not compile
costs a level rather than a member. That is one design, not three fixes, and it is why the three
entries name each other.

## `-O` is a degree of certainty

The scale is the four mechanisms in order, and it runs the other way from speed: **the higher the
level, the more compiles and the less is proven.** A document that needs a mechanism its level does
not allow is not compiled with it — it goes to the engine whole, which is not a failure but the
level choosing certainty.

| level | mechanisms | certainty |
|---|---|---|
| `-O0` | none of ours: Qt builds the document, as `qmlcachegen` bytecode where it can | by construction — it is the engine |
| `-O1` | static translation only, and no document with a SKIPPED member | nothing crosses untyped |
| `-O2` | ...and QVariant | value right, type late |
| `-O3` | ...and containment and delegation, **and only what BEHAVES THE SAME** | measured, per document — **the default** |
| `-Ox` | `-O3` with the check waived | experimental |

Two things about this table are easy to miss.

**The certainty levels also refuse a SKIPPED member**, not just a mechanism. A skip is worse than
weak typing: weak typing still produces the member, a skip produces a document that is missing
behaviour, and no caller can tell by reading the generated D. That refusal costs `-O1` sixty
documents on Qt's corpus, and it is what makes "`-O1` agrees with the engine" true without a render
step to check it.

**`-O3` and `-Ox` emit the same code.** The difference is not in the compiler — it does not render
and it does not run. `-O3` is a **pipeline**: compile, render, compare the frame *and* every
property, demote what differs to `-O0`. That pipeline is `tests/qmltc/o3.sh`
(`./build qmltc-o3-gate-*`). Compiling at `-O3` without running it gets `-Ox` behaviour under a
better name, and the tool's own `--help` says so.

Two more switches exist for working on coverage rather than shipping: `--no-fallback` turns the
whole ladder off, and `--pedantic` also makes a delegation a failure with its own exit code —
"we could not compile this" and "we handed this over" are different jobs.

## What each level compiles

Over Qt's five Controls styles, walked recursively (`impl/` included):

| style | documents | `-O1` | `-O2` | `-O3` compiled | demoted to the engine | unjudgeable |
|---|---:|---:|---:|---:|---:|---:|
| Basic | 70 | 39 | 39 | 54 | 5 | 11 |
| Fusion | 70 | 37 | 37 | 54 | 3 | 13 |
| Universal | 66 | 27 | 27 | 51 | 4 | 11 |
| Imagine | 56 | 0 | 0 | 41 | 11 | 4 |
| Material | 67 | 7 | 7 | 48 | 13 | 6 |
| **total** | **329** | **110** | **110** | **248** | **36** | **45** |

<!-- Measured 2026-08-14 from `qmltc-optlevels-controls-<style>` and `qmltc-o3-gate-<style>`. The
     `-O3` column previously read 329, which was the count of documents HANDLED rather than
     compiled, under a heading that says "compiles"; and `-O1` read 111 with Fusion at 38, one more
     than the gate now reports. Imagine has no optlevels line at all — it is excluded as vacuous,
     which is the entry `imagine-style-impl-types-are-not-in-the-registry` in expected-fails. -->

The middle rung currently buys **nothing**: everything in this corpus that needs weak typing also
needs containment, delegation, or has a member the compiler skips. Stated because it is a real
property of the corpus, not a defect to hide.

Imagine's 0-of-56 and Material's 7-of-67 are mechanism 3: Imagine resolves every image through a
`NinePatchImageSelector` and Material is built on unexported `impl` types.

## The measured claim

Two corpora, the same two axes, both gated in `./build`.

| corpus | documents | compiled | at `-O0` | unjudgeable | unplaced |
|---|---:|---:|---:|---:|---:|
| Qt's Controls (5 styles) | 329 | 248 | 36 | 45 | **0** |
| application-shaped | 18 | 7 | 11 | 0 | **0** |

Every document the engine can draw standalone behaves **identically** to it: same frame byte for
byte, and the same value for every property of every named object. What is compiled reaches that as
D; the rest reaches it because Qt built the document. **None is unplaced.**

**Two of fourteen** on application QML is the honest number, and it is the point rather than an
embarrassment: this dialect is where the compiler is weak today and the ladder is what makes it
correct anyway.

### Why both axes

The frame is offscreen software rendering at the implicit size, and a control that draws small
hides a great deal. Judging on the frame alone let 21 documents into `-O3` while a property
disagreed. The value axis found the deferred transitions, the gradients and every ordering defect
on record.

### Two filters, both because the harness was wrong before the compiler was

- A path the oracle marks `<missing>` is one it **cannot walk**, not a disagreement. Qt defers a
  `Transition`'s animations, so at rest the engine has none and we have ours; counting those called
  six Fusion documents wrong when two were. `tools/qmltc-value-census.py` buckets this.
- A path the **engine cannot reproduce** cannot be a verdict about us. Material's SpinBox background
  carries `placeholderTextHAlign`, which Qt reads out of uninitialised memory and which answered
  `1154029312`, `1895307008` and `-1856497920` on three consecutive engine runs. So every accusation
  is re-verified against a *fresh* engine run, and only a difference the engine reproduces counts.
  Sampling twice up front was the first attempt and was not enough — two samples of a random value
  can agree by chance, which made one Material document unplaced in one run and placed in the next.

### What the other 81 are — decomposed, 2026-08-14

`248 of 329` invites the reading "81 hard documents". Measured document by document from the o3
gate's own state files, it is nothing of the sort, and every number below came from something the
project already knew — the gate's output, the compiler's diagnostics, or the spec's exclusion list.
Reproduce with:

```sh
grep " DEMOTED\| UNJUDGEABLE" .build/qt-*-cxx-controls/o3gate/o3_{Basic,Fusion,Universal,Imagine,Material}.txt
```

| group | docs | what it is |
|---|---:|---|
| unjudgeable | 45 | the engine draws no standalone frame for them; outside the frame axis and honestly so |
| root type not bindable | 13 | `SpinBox`/`DoubleSpinBox` in all five styles and the calendar family. Qt does not export what a subclass needs — `QQuickAbstractSpinBox` is a template whose inline `handleComponentComplete` calls the unexported `QQuickIndicatorButtonPrivate::executeIndicator`, and `QQuickCalendar*` carry no export macro. Measured 2026-08-02; recorded in `generator/spec_cxx_controls.json` |
| `Component` as a property value | 3 | `SelectionRectangle` in three styles, identical signature: `topLeftHandle`/`bottomRightHandle` take an inline `Component`, which is a FACTORY — compiling it as an object would instantiate its contents eagerly. The compiler says so and skips; supporting `QQmlComponent*` properties is a feature, not a fix |
| `baselineOffset` | 2 | a question of WHEN it is measured (a `QQuickText` freezes it at its first layout), not of the formula |
| cross-file instance `baseUrl` | ≥1 | `Material/TextField`: the engine gives an object instantiated from another file the URL of the INSTANTIATING document; we give it the defining file's. The rule is already implemented and measured for local types (`g_rootDocUrl` vs `g_curClassUrl`, verified against Qt's `Dialog`/`Label`) — this path does not go through it |
| a cause the compiler DECLARED | 20 | `delegated to the engine` (Imagine's and Material's `impl` types are not in the registry), `no known notify` (a binding on `Material` with no change signal), `not yet supported`, `is a template`. Every one of these is a gap the tool announced while emitting |
| **no diagnostic at all** | **3** | see below — the only group where the compiler believes it succeeded |

The last row is the only one that is actually open, and it is the one that matters: a compiler that
knows it failed is honest — the document is demoted, the engine builds it, and the user sees the
right thing. These three compile without a single complaint and still do not behave like the engine,
which is the shape that reaches a consumer as a silent wrong result. Three documents, named, out of
an interval that reads as 81.

#### How much a frame differs, and why the number changed the priorities

`the frame differs` said the same thing for eight pixels and for half an image, so the o3 gate now
records the magnitude beside the verdict — information only; a single differing pixel still demotes,
and the comparator has no tolerance. Measured 2026-08-14:

| document | magnitude | what it turned out to be |
|---|---|---|
| `Imagine/Dial` | 69/25600 px (0.3%) | sub-pixel finish |
| `Fusion/SwitchIndicator` | 8/640 px (1.2%) | blended corners of a rounded outline; the only differing frame in the whole Fusion style |
| `Material/SliderHandle` | 157/169 px (92.9%) | both of its colours are DELEGATED — they read `Material.accentColor` and `Material.highlightedRippleColor`, attached properties with no notify the compiler knows. On a 13×13 surface that is essentially one coloured circle, a wrong colour is 93% of the pixels: the large number measures the small surface, not a large defect |
| `Imagine/GroupBox` | **geometry 40×21 against 40×59** | not paint at all — our height is wrong |
| `app/ALayouts` | 9336/19200 px (48.6%) | half the image; a whole feature |
| `app/AListView` | 1512/14000 px (10.8%) | |

Two things this number produced that no message could:

**`Imagine/GroupBox` is not a frame defect.** Its `topPadding` binding reads
`(background as NinePatchImage)?.topPadding`, `NinePatchImage` is one of the Imagine `impl` types
that are not in the registry, so the binding is DELEGATED — and `implicitHeight` on the line above
uses that padding. The wrong height is the already-recorded registry gap
(`imagine-style-impl-types-are-not-in-the-registry`) being paid in a different currency. It looked
like the most informative of the four and is the least: a known cause with a new symptom.

**Three of the four differing frames in Qt's corpus have a cause the project already recorded** —
the Imagine pair through the unregistered `impl` types, `SliderHandle` through attached-property
bindings with no notify. Only `Fusion/SwitchIndicator` is unexplained, and it is one of the three
documents in the entire corpus that compile without a single diagnostic.

**Qt's corpus and ours fail differently.** Across Qt's 329 documents four frames differ, two of them
under 1.5%; across this project's 16 application fixtures nine differ, one at 48.6%. That is not
"our corpus is harder" — it is two different problems: unimplemented features on one side, finish on
the other. The application corpus was written to stress exactly the features (`Layouts`, `ListView`,
`Loader`, `ListModel`) that a Controls style never uses.

#### The three that compile clean and still differ

Characterised 2026-08-14. Each has an oracle already: its own `-O0` build, where Qt constructs the
document and which matches the engine byte for byte.

| document | how it differs | what is known |
|---|---|---|
| `Universal/BusyIndicator` | `contentItem.size` is ABSENT from our dump, not wrong | its `contentItem` is a `BusyIndicatorImpl` (a cross-file, unregistered `impl` type) with `readonly property real size` declared ON THE INSTANCE, used one line later by `count` |
| `Material/ToolButton` | 1 value | same shape: `background: Ripple { readonly property bool square: … }`, a property added to an instance of a cross-file type |
| `Fusion/SwitchIndicator` | the FRAME differs: **8 pixels out of 640**, all on corners and edges | decoded from the PNGs on disk, no rerun needed. `0,0` is `ffffff` in the engine and `7e7e7e` here; `39,0` is `ffffff` against `b3b3b3`; the edge pixels are `000000` against `171717`. Same 40×16 geometry, same shape — the differences are the intermediate tones of a rounded outline, i.e. an ANTI-ALIASING decision, not a missing element or a wrong colour. Its own `-O0` render is byte-identical to the engine |

`Fusion/SwitchIndicator` looked like it might be the limit of the frame axis rather than a defect —
eight blended pixels on a rounded outline could be rendering noise no consumer sees. Measured
instead of assumed: across the whole Fusion style, **it is the only document whose frame differs at
all**; every other one is byte-identical to the engine, rounded outlines included. Non-determinism
would be spread across many documents on the same software backend, not concentrated in one. So the
evidence points at a real difference — a property we do not replicate (`antialiasing`, a radius, an
edge width, or the order the shape is composed) — and not at the comparator being too strict.
That matters procedurally: the tempting move on finding eight differing pixels is to add a
tolerance, and a tolerance is where "close enough" begins. The frame axis has none, deliberately.

`CNestedDecl.qml` was written to reproduce the first two and does NOT: properties declared inside an
object assigned to a property ARE emitted when the type is local and bound. That refutes "nested" and
"readonly" as the cause and leaves the cross-file, unregistered type — which is also where the
`baseUrl` divergence in `Material/TextField` lives. The fixture stays: it pins as a verified fact
what was until then an assumption.

Reproduce the split with:

```sh
for s in Basic Fusion Universal Imagine Material; do
  D=.build/qt-*-cxx-controls/o3gate/o3_$s
  for n in $(grep " DEMOTED" $D/../o3_$s.txt | grep -v "not bindable" | awk "{print \$1}"); do
      [ -s "$D/${n}_ox.diag" ] || echo "$s/$n has no diagnostic"
  done
done
```

Two things this cost to learn, both worth more than the table:

**Identical signatures mean a shared cause; identical names mean nothing.** `SelectionRectangle`
repeats the same two properties in three styles and is one defect. `TextField` appears twice and is
two unrelated stories — a baseline timing question and the `baseUrl` above.

**A number that cannot be decomposed produces the wrong conclusion.** Reading "15 do not build"
suggested cheap wins; thirteen of them are a documented limit of the exported Qt ABI, and the answer
had been written in the spec since 2 August. The o3 gate now names an unbindable root type instead
of folding it into "it does not build or run", so the next reader does not have to make that mistake
to find out.

### The 45 unjudgeable

`Action`, `ButtonGroup`, `CalendarModel`, the `*Delegate`s and the styles' `impl/` helpers have no
frame by nature — a delegate needs a view to exist and an `Action` is not drawn at all. The engine
renders nothing for them standalone, so there is nothing to compare against. They are **not**
counted as passes.

## Does the .qml ship?

For a compiled document, no — and this is the one claim worth proving rather than asserting, since
the alternative (a C++ class that still loads the document's bytecode at run time) looks identical
from the outside.

The check: render Qt's Basic `Button.qml` with the engine, compile the same file with `qmltc-d`,
**delete the document**, run the compiled binary.

```
engine on the copy                 = 0 (191 bytes)
ours with the document DELETED     = 0 (191 bytes)
BYTE-IDENTICAL
```

The generated class does call `attachContext(this, "file://…/Button.qml")`, and that is only a
`QQmlContext` **base URL** — a string used to resolve relative paths (Imagine's image selector needs
it). Nothing opens the file.

A document the ladder handed over is the other case, and it is the honest one: at `-O0` the engine
builds the document, so the document must be there. The compiler says which happened, on stderr and
in the census column.

## Verification, and where it lives in the build

| target | what it holds to what |
|---|---|
| `qmltc-o3-gate-<Style>`, `qmltc-o3-gate-app` | every judgeable document, frame **and** every property, demote what differs, fail on one that no level places |
| `qmltc-optlevels-*` | `-O1` and `-O2` produce the engine's value for every property, and the same as each other |
| `qmltc-*`, `qmltcc-*`, `qmltcq-*`, `qmltcd-*`, `qmltc5-*` | per-fixture differentials: values, values after a mutation (`<Name>.set`), object identity, deep paths, attached properties, singletons, `baseUrl` |
| `qmltc-controls-runtime-*` | 61 of Qt's Basic controls actually construct an object |
| `shadowaot-*` | a refused expression as **bytecode**, with the `.qml` moved away so nothing can read it |
| `leaf-lifetime-*` | the reactive side-table's identity and cleanup, which no document can observe |
| `qmltc-corpus` | all of the above in one name |

`-O3` is judged by the gate, deliberately not by `qmltc-optlevels-*`: `-O3` compiles greedily and
the gate demotes, so "disagrees before demotion" is its normal intermediate state rather than a
defect.

### What judging `-O1` over Qt's own corpus found

The claim "`-O1` agrees with the engine" was a count until it was measured: `-O1` compiled 111 of
Qt's 329 Controls documents, and nobody had checked what those 111 produced. Running every style
through the per-document comparison found **seven** that compiled at a certainty level and did not
match — and six of them were three missing rules rather than six quirks:

| rule | what the engine does | what we did |
|---|---|---|
| a binding that dereferences `null` writes **nothing** | JS throws, the whole binding aborts, the property keeps its default | our reads were null-tolerant and produced a value |
| QML's default for `property color` is **opaque black** | `#000000` | a default-constructed `QColor` is *invalid*, which prints `#00000000` |
| a document's **imports** are loaded, not just its own module | the module brings its resources | one `ensureModule` for the document's module only |

The third is the least obvious: Universal's `CheckIndicator` lives in
`QtQuick.Controls.Universal.impl` and draws a checkmark out of `QtQuick.Controls.Universal`, so
without the import the URL does not resolve, the image reports `status: Error`, and every geometry
downstream of its size is wrong — ten differences on one document, all from one failed load. Fusion
never showed it because there the images and the document share a module.

What is left is one defect in two styles: `DelayButton`'s two content children agree with the
engine on every property either side *assigns* — `visible`, `clipX`, `clipWidth`, `height`,
`implicitHeight`, `y`, `text` — and exchange `baselineOffset`, which **neither side assigns**:
QQuickText sets it when the text lays out. The two values are the same text laid out at height 28
and at its implicit height 19, so each side has one child in each state and they disagree about
which. (The first reading of this called it child order; measurement disproved that.) It is named
in
`tests/qmltc/optlevels-known.txt` with its measurement, and the `-O3` gate already demotes the
document, so the *behaviour* is the engine's — the broken promise is `-O1`'s, not the default's.
Four of the five styles are under continuous judgement
(`qmltc-optlevels-controls-{Basic,Fusion,Universal,Material}`): **110 documents** compiled at a
certainty level and compared property by property — 39, 37, 27 and 7 — with the rest of each style
handed to the engine and skipped. Imagine is absent for the opposite reason: `-O1` compiles nothing
there, which makes the run vacuous, and the script refuses to report a green it did not earn.

The count itself is a result of the three rules. Before them the same run reported 6 failures on
Fusion and 1 on Universal and never got far enough to report a check count; now it judges 36 and 27
of them and they agree.

Fixing the three rules also moved five of Qt's documents from `-O0` to compiled at the **default**
level — the measured claim below went from 226 to 231, a crash fix took it to 235, completing in the engine's order took it to 239, and how Qt's own styles read a colour took it to 245 — which is the useful way to read this: a
certainty level nobody had judged was hiding defects that cost the default level too.

## Scope, and what is not characterised

Qt's Controls are a narrow, disciplined dialect — `T.Something` roots, declared properties, almost
no loose JS, every type from a module. The application corpus (`tests/qmltc/app/`) exists because
that is not what people write: it has list models and delegates, `ListView`, `Loader`, real JS with
loops and arrays and objects, states and transitions, inline components, `Connections`, signals
crossing documents, one document instantiating another from its own directory, anchors, a `Timer`,
and an application *consuming* Controls rather than defining them.

What neither corpus covers is an application's **context**: a document that needs the app's C++
context properties, its models and its data. Pointed at a real one (a 78-document status bar) the
gate reports 3 compiled, 10 demoted, 4 unplaced and **61 unjudgeable** — and that last number is the
finding. `Bitcoin.qml` exists inside the bar, and the engine draws nothing for it standalone either,
so there is no oracle. The documents in the corpora are self-contained on purpose, which is what
makes them judgeable and also what they do not prove. **Judging a whole running application is a
different harness and remains open.**

## Known gaps

Named, reproduced, and demoted by the gate rather than hidden:

- **An id resolves one level down, not across the component.** QML resolves an id anywhere in its
  component; `g_childIds` holds direct children only. `tests/qmltc/app/ASignalCross.qml` compiles
  its handlers and still demotes, because its emitter names a grandchild's id.
- **`baseUrl` of children that came from a local type** is the outer document's, not the type's own
  file.
- **`layer.effect`** crashes inside `QQmlComponent::beginCreate` — reproduced in ~30 lines of C++
  with no D involved, and not worked around on purpose, since that would mean guessing someone
  else's invariant.
- **`Component` as a template** compiles today (`Repeater`/`delegate` work), but a `Component`
  bound to a property the compiler does not know is still refused.
- **Worker threads.** The moc runtime's side tables are owner-thread only, by an explicit abort
  rather than a silent race.
