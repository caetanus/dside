<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# Bugs found from the outside

Found while writing an application *against* the binding — a QtQuick Bible reader
(`~/p/bible/demo-dside/`) with six QML documents and a D backend. That vantage point is
what these have in common: none of them shows up in the test suite, because the suite
exercises the pieces and an application exercises the joins.

Every entry below was reproduced by the reporter on this machine. Where a claim is a
measurement, the numbers are the ones observed, not extrapolations; where it is a
compiler diagnostic, the text is copied verbatim.

Environment: ldc2 1.42.0 (DMD 2.112.1), Qt 6.11.1, Linux x86-64, 30 GiB RAM,
generator at `6e8a733-dirty`, binding `generated/qt-6.11/cxx-quick`.

---

## 1. `qmltc-d` segfaults on `focus` + `Keys.*` on the same object

**Severity: crash.** Deterministic, 100% of runs.

```qml
// crash.qml
import QtQuick 2.15
Item { focus: true
       Keys.onPressed: console.log("x") }
```

```sh
qmltc-d crash.qml G --qmlmap generated/qt-6.11/cxx-quick/qmlmap.tsv
# rc=139 (SIGSEGV)
```

**The trigger is the combination, not either part.** Each alone exits 0:

| document | rc |
|---|---|
| `Item { Keys.onLeftPressed: … }` | 0 |
| `Item { Keys.onPressed: … }` | 0 |
| `Item { focus: true }` | 0 |
| **`Item { focus: true; Keys.onPressed: … }`** | **139** |
| **`Item { focus: true; Keys.onLeftPressed: … }`** | **139** |
| **`Rectangle { focus: true; Keys.onLeftPressed: … }`** | **139** |

Holds for `Item` and `Rectangle`, for the generic handler and the specific one.

```
Program received signal SIGSEGV, Segmentation fault.
#0  compileObject(QQmlJS::AST::UiObjectInitializer*, std::string const&,
                  std::string&, int&, char const*, std::string const&,
                  DType const*, std::string const&) ()
#1  main ()
```

The last diagnostic emitted before the crash is always

```
qmltc-d: <file>: signal handler in <root> not yet supported — skipped (later phase)
```

so the path that *refuses* the handler is the one that then dereferences something
invalid. The refusal itself is correct — what is missing is returning from it without
touching the pointer.

**Impact measured on the demo's own documents:**

| document | result |
|---|---|
| `Pagina.qml` (no `focus`) | 355 lines of D, `ldc2 -c` clean, 8 bindings delegated |
| `Main.qml` | crash, zero output |
| `Config.qml` | crash, zero output |

Two of three application documents produce nothing at all — and since the tool writes
to stdout, a build wiring it up gets an empty file rather than an error.

---

## 2. `qrcRegister` (CTFE) does not scale, and fails silently when it runs out

**Severity: blocks a real application.**

`qrcRegister` builds the resource tree at compile time. Measured on this demo, adding
one small `.qml` at a time (`ldc2`, peak RSS of the compiler process):

| documents | embedded QML | peak RSS |
|---|---|---|
| 2 | 20.7 KB | 3 227 MB |
| 3 | 28.5 KB | 5 027 MB |
| 4 | 33.9 KB | 6 474 MB |
| 5 | 38.6 KB | 7 952 MB |
| 6 | 46.4 KB | **OOM-killed** |

That is roughly **190 MB of compiler RSS per KB of QML**, growing linearly. The sixth
document (7.8 KB) was enough to end it:

```
kernel: oom-kill: … task=ldc2,pid=1662460
kernel: Out of memory: Killed process 1662460 (ldc2)
        total-vm:16130508kB, anon-rss:11070360kB
```

**The silent-failure part is what costs the time.** `ldc2` takes SIGKILL, the shell sees
`rc=137`, *nothing* is printed on stdout or stderr, and the previous binary stays in
place. The symptom presented to the developer is a QML type that "does not exist" at
runtime while the `.qrc` plainly lists it — with no reason to suspect the build. Two
things would have made this a two-minute problem instead of an hour:

- `build.sh`-style consumers should check the exit status (`set -e` does not help when
  the failure is the *linker step being killed* and the caller pipes the output);
- a note in the manual that the CTFE resource path has a practical ceiling.

**Workaround, which keeps the single-binary property and costs nothing:** generate the
blob with Qt's own `rcc` and embed the finished file with one `import()`.

```sh
/usr/lib/qt6/rcc --binary ui.qrc -o ui.rcc
```

```d
static immutable ubyte[] _rcc = cast(immutable(ubyte)[]) import("ui.rcc");
shared static this() { QResource.registerResource(cast(ubyte*) _rcc.ptr, ""); }
```

Same six documents: **363 MB** peak, versus the OOM. A 20× reduction, and it stops
scaling with document count at all.

This does not argue for deleting `qrcRegister` — the CTFE story is worth keeping for
small resource sets, and it is what makes the test suite self-contained. It argues for
documenting the ceiling and offering the `rcc` route beside it.

---

## 3. `QQuickWindow::grabWindow` is not bound

`coverage-manifest.tsv` explains why:

```
QQuickWindow	grabWindow	c:@S@QQuickWindow@F@grabWindow#	object-type by value: QImage …
```

Consequence for an application: **there is no way to screenshot your own window from
D.** That matters more than it sounds — on a Wayland compositor that refuses external
capture (`grim` simply hangs here), and under `QT_QPA_PLATFORM=offscreen`, the app
photographing itself is the only way to see what it rendered. The workaround is to go
through QML (`item.grabToImage(cb)` → `cb.saveToFile(path)`), which works but means the
capability is unreachable from the D side of an app that has no QML.

`QScreen::grabWindow` is unbound for the same reason (`QPixmap` by value).

---

## 4. API papercuts that stop the first program from compiling

All three reproduced here as three-line programs. None is *wrong* — each is a
consequence of a deliberate design choice — but together they are what a newcomer hits
in the first ten minutes, and none is in `docs/manual/dside/`.

### 4a. `new QQuickView()` is ambiguous

```d
import qt.quick.qquickview;
void main() { auto v = new QQuickView(); }
```

```
Error: `qt.quick.qquickview.QQuickView.__ctor` called with argument types `()`
       matches multiple overloads exactly:
```

`this(QWindow = null)` versus `this(QQmlEngine = null, QWindow = null)`. The fix is
`new QQuickView(cast(QWindow) null)`, which nobody guesses.

### 4b. `QUrl(QString)` is not callable

```d
import qt.quick.qurl, qt.quick.qstring;
void main() { auto u = QUrl(qstr("qrc:/a.qml")); }
```

```
Error: none of the overloads of `this` are callable using argument types `(QString)`
```

Since `qstr` is *the* documented way to make a `QString`, this reads as a contradiction.
The working form is `QUrl("qrc:/a.qml", QUrl.ParsingMode.TolerantMode)` — the string
overload exists but requires the mode explicitly.

### 4c. `ref const(T)` rejects rvalues — across the whole value-type surface

```d
v.setSource(QUrl("qrc:/a.qml", QUrl.ParsingMode.TolerantMode));
```

```
Error: function `QQuickView.setSource(ref const(QUrl) a0)` is not callable
       using argument types `(QUrl)`
```

A local variable fixes it. This is D's rule, not a binding bug, but it applies to
*every* `const T&` parameter in Qt (`QModelIndex`, `QVariant`, `QSize`, `QRect`, `QUrl`,
`QString`…), so in practice it is the single most frequent compile error when writing
against this binding. It deserves a line in the manual next to the `asQPaintDevice()`
note, which is the same kind of "surfaced rather than hidden" decision.

---

## 5. The application constructor should be a mixin, not 40 copies

**Not a defect — a missing abstraction, and one the project already has the idiom for.**

Constructing the application object takes four lines that every program must repeat:

```d
import appctor : QAPP_CTOR;
pragma(mangle, QAPP_CTOR) extern(C++) void __qapp_ctor(void*, ref int, char**, int);
__gshared int argc = 1; __gshared char*[2] argv = [cast(char*) "app\0".ptr, null];
auto raw = __cpp_new(__QApplication_size); __qapp_ctor(raw, argc, argv.ptr, 0);
```

`tests/support/appctor.d` centralises the mangled **string** — its own header says why:
*"Forty test files carried the Itanium symbol as a string literal… One place, so a
third ABI is one edit rather than forty."* But the **declaration** is still copied: 40
files under `tests/` repeat the `pragma(mangle)` line, and `docs/manual/dside/using-the-binding.rst:74`
teaches it as the thing every program writes.

Three costs, in order of how much they bite:

1. **`appctor.d` has no `QGUIAPP_CTOR`.** Writing a QtQuick app — the direction the
   project targets — means inventing a symbol that the one file created to prevent
   exactly that does not contain. The reporter derived
   `_ZN15QGuiApplicationC1ERiPPci` by analogy and only afterwards confirmed it against
   `nm -D libQt6Gui.so.6`. It was right; it was still a guess.
2. **`argc` must outlive `main`.** Qt keeps a *reference* to it and reads `argv` for the
   process lifetime. The tests get this right with `__gshared`; nothing states the rule,
   and a local `int argc` compiles, runs, and only misbehaves the day something calls
   `QCoreApplication::arguments()`.
3. Forty copies of a `pragma(mangle)` is forty places for a future ABI to be wrong in.

**The symbol is derivable from the class name**, so none of this needs a table:

```
Itanium:  _ZN <len(name)> <name> C1ERiPPci
MSVC:     ??0 <name> @@QEAA@AEAHPEAPEADH@Z
```

A CTFE string mixin in the project's existing idiom (`qrcRegister`, `uiForm`) covers all
three classes with no per-class knowledge:

```d
mixin(qtdApplication!"QGuiApplication");
void main() { auto app = criarApp("meuapp"); … }
```

Verified by the reporter for all three, symbol compared against the shipped libraries:

| class | symbol the mixin emits | present in |
|---|---|---|
| `QApplication` | `_ZN12QApplicationC1ERiPPci` | `libQt6Widgets.so` |
| `QCoreApplication` | `_ZN16QCoreApplicationC1ERiPPci` | `libQt6Core.so` |
| `QGuiApplication` | `_ZN15QGuiApplicationC1ERiPPci` | `libQt6Gui.so.6` |

A working implementation is in `~/p/bible/demo-dside/qtdapp.d` (56 lines, no
dependencies beyond `cxxrt`), written so it can be lifted into `runtime/` as-is. It also
folds in the `__gshared argc` rule, which is the part a user cannot be expected to know.

---

## 6. Documentation contradicts itself on Windows

- `docs/windows-roadmap.md:7` — "Status: **built and measured.** … the full matrix now
  runs on a Windows VM against Qt 6.10.3 (MSVC) and Qt 5.15.2, with ldc2 and dmd."
- `README.md:26` — "Windows/MSVC-x64 is a documented, not-yet-working roadmap".
- `docs/FEATURES.md:77` — "Windows/MSVC-x64: deferred".

One of these is stale. The roadmap is the more recent and the more specific, which
suggests the summary lines are the ones to update — but a reader has no way to tell,
and this is exactly the kind of claim a prospective user checks first.
