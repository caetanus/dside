<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# Using DSide

Qt from D, in the order you will actually hit the questions. Every program shown
here is a real file in `tests/`, compiled and run by the build — nothing on this
page is illustrative pseudocode.

1. [Getting a build](#getting-a-build)
2. [Your first window](#your-first-window)
3. [Who owns what](#who-owns-what) — read this one
4. [Signals and slots](#signals-and-slots)
5. [Your own QObject, with its own signals](#your-own-qobject-with-its-own-signals)
6. [Strings and containers](#strings-and-containers)
7. [When something is missing](#when-something-is-missing)

## Getting a build

The bindings are generated, not vendored: `xiboca` emits them and the build
compiles them into two archives. From a consumer's side, three things go into
your project — the generated import path and the two archives. That path is
exercised on every build by `tests/consumer/hello.d`, which is copied out of the
checkout and built somewhere else precisely so "it compiles in-tree" cannot be
mistaken for "somebody else can use it".

## Your first window

```d
import qt.widgets.qapplication, qt.widgets.qwidget, qt.widgets.qlabel;
import cxxrt;

pragma(mangle, "_ZN12QApplicationC1ERiPPci")
extern(C++) void __qapp_ctor(void* self, ref int, char**, int);

void main() {
    __gshared int argc = 1;
    __gshared char*[2] argv = [cast(char*) "hello\0".ptr, null];
    auto raw = __cpp_new(__QApplication_size);
    __qapp_ctor(raw, argc, argv.ptr, 0);
    cast(void) QApplication.wrap(raw);

    auto w = new QWidget(null);
    auto l = new QLabel(w);        // parented: Qt owns it, the wrapper is pinned
    l.setText("hello from D");
    w.resize(200, 60);
}
```

Three things in that snippet surprise everyone, and all three were found by the
first person to try, not predicted:

- **`QApplication` is constructed by hand.** Its `(int&, char**, int)`
  constructor is not auto-bound, so every program declares that one
  `pragma(mangle)` line. It is the only place you will meet a mangled name.
- **`new QWidget()` and `new QWidget(null)`** are both valid, and a bare literal
  `null` used to be ambiguous between the adopt constructor `this(void*)` and
  `this(QWidget parent = null)`. If a constructor call will not resolve, this is
  usually why.
- **`w.width()` does not exist.** `QWidget` inherits it from `QPaintDevice`, its
  *second* base, so it is reached as `w.asQPaintDevice().width()`. Multiple
  inheritance is surfaced as an explicit cast rather than flattened, because
  flattening it would hide which base a method really comes from.

## Who owns what

**The default is borrowed.** A pointer Qt returns to you is Qt's; the binding
wraps it without claiming it. Only the paths that *allocated* an object own it.
That default is deliberate: assuming ownership of something you did not allocate
is a double free, and assuming the opposite is merely a leak.

The model is called **parenting-pins** and it is four rules:

| | |
|---|---|
| **Identity** | `wrap(ptr)` returns the *same* D wrapper for the same C++ pointer, always |
| **Pinning** | a parented child is held by a GC root, so it lives as long as its parent even with no D reference to it |
| **Collection** | a dropped, *unparented* wrapper is collected, and its finalizer calls `deleteLater` — you owned it |
| **Destruction** | when C++ destroys the object, `destroyed()` nulls the pointer and unpins |

The consequence that matters in practice: **a parented widget cannot be
collected out from under Qt**, and an unparented one you dropped will be
destroyed for you. You do not manage lifetimes by hand, and you do not need
`scope` or manual `destroy`.

**A destroyed object throws instead of crashing.** Every wrapper checks its
pointer on every call, so using an object Qt has already deleted raises an
exception naming the problem rather than segfaulting. That check is why the rule
above is safe to rely on.

Ownership that *moves* at a call — `QTreeWidget.addTopLevelItem` taking its
argument, for instance — is not inferred. It is declared in the spec and audited
against Qt's documentation, and `ownership-gate` fails the build if any method
taking such a type is unclassified. Anything not classified is a gap the build
knows about, not a silent guess.

This layer is single-threaded by design: Qt's main thread, D's stop-the-world GC.

## Signals and slots

A Qt signal becomes a method that takes a D delegate:

```d
auto timer = new QTimer();
timer.connectTimeout(() { writeln("tick"); QApplication.quit(); });
timer.start(50);
```

`connect<SignalName>` is generated per signal, so the compiler checks the
delegate's signature — a mismatched slot is a compile error rather than a
runtime warning on stderr, which is what `QObject::connect` with strings gives
you in C++.

## Your own QObject, with its own signals

Subclassing Qt from D, overriding virtuals, and declaring your own
signals/slots/properties is one mixin:

```d
@QObject class CannonField {
    mixin QtdWidget!QWidget;              // subclass QWidget + attach a meta-object
    Signal!int angleChanged;              // your own signal
    private int _angle;
    @Slot void setAngle(int a) { if (a != _angle) { _angle = a; angleChanged.emit(a); } }
    @Slot void onAngle(int a)  { lastAngle = a; }
    void paintEvent(QPaintEvent e) { paints++; }   // override of a QWidget virtual
    int paints = 0, lastAngle = -1;
}

auto cf = new CannonField();
connectMeta(cf, "angleChanged(int)", cf, "onAngle(int)");
cf.setAngle(30);                          // -> angleChanged(30) -> onAngle
```

There is no `moc` step and no generated C++ for your class. The meta-object is
built at compile time from the `@Slot`, `Signal!T` and property declarations, and
attached at construction — so Qt's introspection, `connect` by name, and QML all
see your type as an ordinary `QObject`. Virtual overrides reach D through a
trampoline that the same mixin installs, which is why `paintEvent` above is just
a method.

## Strings and containers

`QString` converts both ways: `qstr("text")` builds one, `.toString` reads one
back. Qt containers are surfaced as D's own where the mapping is exact —
`QHash<QString,int>` arrives as `int[string]`, `QMap<QString,QString>` as
`string[string]` — with the C++ call hidden behind a wrapper, so you index them
like any D associative array.

## When something is missing

Two different situations, and telling them apart is the first move:

**Not bound yet.** The binding ships a `coverage-manifest.tsv` with one row per
symbol and its fate. `unmapped-type` means the method exists in Qt and its
signature uses a type the generator does not map yet — the row names that type.
Everything else (`bound`, `inherited`, `shimmed`, `signal`, `pure-virtual`) means
it is there, possibly under a different reach than you expect: `inherited` is the
`asQPaintDevice()` case above.

**Bound and wrong.** That is a bug, and the useful report is the smallest D
program that shows it, because that is the shape the test suite already speaks —
see `docs/test-suite.md`.

To add what is missing yourself, the generator's side is
`docs/xiboca/generating-a-wrapper.md`; the ownership keys there are the ones that
cannot be inferred.

## See also

- `docs/qmltc-d.md` — QML compiled to D, and what it does and does not cover
- `docs/FEATURES.md` — the capability list
- `docs/test-suite.md` — how all of the above is verified
