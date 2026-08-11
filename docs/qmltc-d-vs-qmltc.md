# qmltc-d vs Qt's `qmltc`

Both compile QML documents ahead of time: Qt's `qmltc` to C++, ours to D. This page is the
comparison, and it tries hard to be a fair one — every number below was **measured on this machine
today**, over the same corpus, and every claim about Qt's tool is either a measurement or a quote
from Qt's own documentation with the file named.

Reproduce with `tests/qmltc/o3.sh` for our side; the qmltc sweep is at the bottom.

> **What is not compared.** I did not compile qmltc's C++ output, and I did not run it. So nothing
> here says its output is wrong — only what it does and does not produce, and what it needs at run
> time. Where our side makes a correctness claim, it is because the gate renders the result and
> compares it with the engine; Qt ships no equivalent gate, which is itself one of the differences.

## The short version

The tools are not competing implementations of the same idea. `qmltc` replaces `QQmlComponent`
object creation with C++ and **keeps the engine for the dynamic parts on purpose**; qmltc-d tries to
remove the engine from the compiled parts and has a **ladder** for everything it cannot. Qt's design
is the more conservative one, and it is honest about it. Ours takes the risk and pays for it with a
gate.

| | Qt `qmltc` | qmltc-d |
|---|---|---|
| Output | C++ | D |
| Maturity | **"Tech Preview"** — Qt's own word | one corpus proven, one dialect measured, one open |
| Bindings | stay in the document's compilation unit; installed at run time by `QQmlCppBinding` | D methods + signal connections |
| Needs the `.qml` at run time | **yes** — `compilationUnitFromUrl(q_qmltc_docUrl_X())` | **no** for a compiled document (measured) |
| When it cannot compile a document | **nothing is generated; the build fails** | the ladder: `-O0`, and Qt runs the document |
| Correctness gate shipped | none | frame **and** every property vs the engine, per document, in `./build` |
| Qt Quick Controls | Qt's doc: "might not get compiled correctly" | that IS the primary corpus |
| Output re-exposable to QML | **no** — Qt's doc | **yes** — verified |
| Build system | CMake + `qt_add_qml_module` required | any; reggae here |
| Needs private Qt API | yes (Qt's doc) | yes (`QMetaObjectBuilder`, Qt6 interceptor) |
| Generated API stability | "does not guarantee … API-, source- or binary-compatible … even patch versions" | same posture |

## Measured: the same 329 documents

Qt's five Quick Controls styles, walked recursively, `impl/` included. Qt's rule for its own tool is
in its docs: *"when qmltc rejects a QML document (whether due to errors or warnings, or because of
constructs qmltc doesn't yet support), the build process will fail … When qmltc fails, nothing is
generated"*. So the measurement is: did it produce a header?

| style | documents | qmltc generated | qmltc generated **nothing** |
|---|---:|---:|---:|
| Basic | 70 | 59 | 11 |
| Fusion | 70 | 56 | 14 |
| Universal | 66 | 54 | 12 |
| Imagine | 56 | 51 | 5 |
| Material | 67 | 60 | 7 |
| **total** | **329** | **280** | **49** |

Ours, on the same 329, judged on both axes: **235 compiled · 49 at `-O0` · 45 unjudgeable ·
0 unplaced.**

**These two numbers do not mean the same thing and must not be put side by side.** 280 is "the
compiler produced output". 235 is "compiled, rendered, and every property of every named object
agrees with the engine". The comparable statement is the one below.

### Where the two disagree, document by document

Of the **49** documents qmltc generates nothing for:

| our verdict | count |
|---|---:|
| **COMPILED** — and gate-verified identical to the engine | **21** |
| **DEMOTED** to `-O0` — Qt builds it, still identical | 4 |
| UNJUDGEABLE — no frame for either of us to compare | 24 |

So: **21 documents that Qt's own compiler refuses outright, we compile and prove behave identically
to the engine.** 4 more we place safely. The remaining 24 neither tool can claim, and they are not
counted.

Of the **280** qmltc does generate for, we compile 205, place 54 at `-O0`, and cannot judge 21. The
54 are the interesting column: those are documents where *something* about our compiled form
differed from the engine and the gate demoted it. qmltc generated C++ for all 54 and nothing checked
whether it matches. That is not an accusation — it is the missing measurement on that side.

### Why qmltc refuses those 49

Its own diagnostics, bucketed:

| reason | documents |
|---|---:|
| `Can't compile the QML base type "X" to C++ because it lives in "<module>" instead of the current file's "<module>" QML module` | 28 |
| `Property '__delegateHeight' is a reserved C++ word, consider renaming` (and `__contentIndent`, `__isDiscrete`, `__clearIndicatorWidth`) | 12 |
| `Type ContextMenu is used but it is not resolved` / `unknown attached property scope ContextMenu` | 7 |
| `Cannot defer property assignment to "X" …` | 2 |

The first is the cross-module limitation Qt documents: *"Imported QML modules that consist of
QML-defined types (such as QtQuick.Controls) might not get compiled correctly … At present, you can
reliably use QtQml and QtQuick modules as well as any other QML module that **only** contains C++
classes exposed to QML."* Qt's Controls styles inherit each other's QML-defined types constantly
(`Dialog.qml` uses `Label`), so this is the corpus falling outside the tool's stated scope rather
than a bug.

The second is the one worth pausing on. **C++ reserves identifiers containing a double
underscore**, so a QML property named `__delegateHeight` cannot become a C++ member — and Qt's own
`Slider`, `RangeSlider`, `Tumbler`, `SearchField` and `TreeViewDelegate` use exactly such names. D
does not reserve them. Of those five, we compile four and prove them identical; the fifth
(`TreeViewDelegate`) has no standalone frame for either tool. This is a property of the **target
language**, not of either compiler's cleverness — and it is the clearest illustration of why a
QML→C++ compiler and a QML→D compiler are not the same problem.

## The architectural difference: where does a binding live?

This is the part that matters most, and it is visible in the generated code rather than in any
claim. For Qt's Basic `Button.qml`:

**qmltc** emits the object tree as C++ and leaves the bindings in the document's compilation unit:

```cpp
static const QUrl& q_qmltc_docUrl_Button() noexcept {
    static QUrl url {QStringLiteral("qrc:/qt-project.org/imports/QtQuick/Controls/Basic/Button.qml")};
    return url;
}
…
QQmlCppBinding::createBindingForNonBindable(
    QQmlEnginePrivate::get(engine)->compilationUnitFromUrl(q_qmltc_docUrl_Button()),
    this, 0, this, 40, -1, QStringLiteral("implicitWidth"));
```

`implicitWidth` is function **#0** of that document's compilation unit, evaluated by the engine —
as bytecode, JIT, or an AOT C++ function if `qmlsc` produced one. This is deliberate, and Qt says
so: *"It does not have to understand the JavaScript code in bindings and functions, though"*, and
*"The generated code uses QQmlEngine to interact with dynamic parts of a QML document — mainly the
JavaScript code."*

**qmltc-d** compiles the binding itself:

```d
@Slot void __rcb_implicitWidth() {
    setProp(this, "implicitWidth", __qmltcMax(
        propDouble(this, "implicitBackgroundWidth") + propDouble(this, "leftInset") + …,
        propDouble(this, "implicitContentWidth")   + propDouble(this, "leftPadding") + …));
}
…
connectMeta(this, "implicitBackgroundWidthChanged()", this, "__rcb_implicitWidth()");
```

The consequence is the run-time dependency. qmltc's output loads the document at run time; ours
does not, and that was checked rather than assumed:

```
engine rendering the document       = 191-byte PNG
compile it, DELETE the document, run = 191-byte PNG
BYTE-IDENTICAL
```

(Our generated code does call `attachContext(this, "file://…/Button.qml")`, but that only sets a
`QQmlContext` **base URL** — a string for resolving relative paths. Nothing opens the file.)

The honest other half: a document our ladder hands over at `-O0` **is** built by the engine from the
document, so there the `.qml` must ship — exactly like qmltc, and the compiler says which happened.

## Re-exposing the result to QML

Qt: *"Despite qmltc working closely with QQmlEngine and creating C++ code, the generated classes
cannot be further exposed to QML and used through QQmlComponent."*

Ours can, because the generated class is an ordinary `@QObject` whose `QMetaObject` the moc runtime
builds at CTFE. Verified end to end:

```d
qmlRegisterType!IHelloWorld("Gen", 1, 0, "IHelloWorld");
```

```qml
import Gen 1.0
QtObject {
    property IHelloWorld inner: IHelloWorld { hello: "from QML" }
    property string seen: inner.greeting     // the COMPILED binding, re-evaluated
}
```

```
seen = from QML!
```

## What Qt's tool does better

Not a courtesy section — these are real and they matter if you are choosing.

- **It targets the language Qt is written in.** No binding generator underneath, no ABI surface, no
  second mangling scheme. Ours only exists because there is a whole `extern(C++)` generator below it.
- **Its scope statement is narrower and therefore safer.** "QtQml and QtQuick, and modules that only
  contain C++ classes" is a boundary a user can check before adopting. Ours is "measured on these two
  corpora", which is a weaker kind of promise even when the numbers are better.
- **Refusing the build is a defensible design.** A ladder that silently hands work to the engine can
  hide a regression as a performance loss instead of a failure. That is precisely why `-O3` is a
  pipeline with a gate rather than a flag, and why the compiler reports every hand-over — but Qt's
  choice needs no such machinery to stay honest.
- **It is part of Qt.** It moves with the engine, and its authors can change the engine when the
  compiler needs it. We follow.

## How to reproduce the qmltc sweep

```sh
st=Basic; B=/usr/lib/qt6/qml/QtQuick/Controls/$st
{ printf '<RCC><qresource prefix="/qt-project.org/imports/QtQuick/Controls/%s">\n' "$st"
  find $B -name '*.qml' | while read f; do
      printf '  <file alias="%s">%s</file>\n' "${f#$B/}" "$f"; done
  printf '</qresource></RCC>\n'; } > $st.qrc

for f in $(find $B -name '*.qml' | sort); do
  rm -f o.h o.cpp
  /usr/lib/qt6/bin/qmltc --resource $st.qrc --header o.h --impl o.cpp \
      --module QtQuick.Controls.$st -I /usr/lib/qt6/qml "$f" > o.out 2>&1
  [ -s o.h ] || echo "REFUSED $(basename $f .qml): $(grep -m1 Error: o.out)"
done
```

The `.qrc` is needed because qmltc resolves a document by its **resource** path; the styles' own
`qmldir` gives the prefix (`prefer :/qt-project.org/imports/QtQuick/Controls/<Style>/`).

Measured against Qt 6.11.1 (`/usr/lib/qt6/bin/qmltc`), qtdeclarative sources at
`~/src/qtdeclarative`. Qt quotations are from
`src/qml/doc/src/tools/qtquickcompiler/qtqml-qml-type-compiler.qdoc` and
`src/qml/doc/src/qtqml-qtquick-compiler-tech.qdoc`.
