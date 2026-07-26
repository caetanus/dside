# Test suite

The binding is validated by a target matrix run through reggae (`./build --list`,
`./build <target>`). Every target **compiles and runs** on **ldc2 AND dmd**; the
Qt-version axis (**Qt5 AND Qt6**) is exercised where a target is Qt-version-specific.
This document is the contract: what is tested, on what matrix, and what is a known
expected-fail. It is not yet a per-category CI counter with regression history — that
is a tracked follow-up (see below).

## Categories

| Category | Targets | What it proves |
|----------|---------|----------------|
| **libsample (shiboken corner cases)** | `sample_*` (28 cases) + `sample_cornercases` | The hard binding cases shiboken's own test lib is built to expose: value types, object types, MI, enums/flags, overloads, references, function pointers, inject-code, modified ctors, comparison/operators, exceptions, `MoveOnly`. `cornercases` asserts `ALL PASS`. |
| **GC / lifetime (wrapper mode)** | `wraptest`, `widget_test` (qt5+qt6), `moc_test` (qt5+qt6) | Holder identity, parenting-pins, orphan reclamation on GC, reparent detection; a real QApplication+widgets app; a moc subclass (`CannonField : QWidget`, `paintEvent` override) — construction via `new QWidget(parent)`. |
| **moc / signals / properties** | `cannon_t1..t9`, `cannon_widget` | CTFE `@QObject`/`Signal`/`@Slot`/`@Property` via `QMetaObjectBuilder`: custom signals (incl. `QString` args), NOTIFY properties → QML/binding updates, value-type ctors, parenting. |
| **uic (CTFE)** | `uic`, `dialog`, `tabs`, `mainwin`, `hello`, `egroup`, `combo`, `spacer`, `icon`, `uicheck`, `corpus-check` | `mixin(uiForm(import(".ui")))` → typed struct. `uicheck` + `corpus-check` are **differential**: our tree must serialize identically to `QUiLoader`'s over the whole Qt baseline corpus (**53/53**). |
| **qrc / containers / misc** | `qrc`, `container_qvector`, `qlist_roundtrip`, `holder_test`, `webengine` | CTFE `.rcc`; `QList`/`QVector` round-trips; holder unit; a WebEngine private-type smoke. |

## Matrix

- **Compilers:** ldc2 **and** dmd — every target, both. (D's own `extern(C++)` mangling
  diverges between them on Itanium substitutions; `pragma(mangle)` with clang's exact
  symbol keeps them identical — this axis guards that.)
- **Qt:** Qt6 (6.11) is primary; Qt5 (5.15) is exercised via the `*-qt5` wrapper targets
  (`widget_test`, `moc_test`) and the Qt5 wrap specs. Value-type ABI differs Qt5↔Qt6, so
  this axis is load-bearing, not cosmetic.
- **Platform:** Linux / POSIX (Tier 1 — see the repo README). Windows/MSVC-x64 is a
  roadmap, not tested.

## Known expected-fails / exclusions (honest gaps)

Tracked as **structured state** in `tests/expected-fails.json` (id / area / reason /
since / remove-when), not prose — so they block regression and measure progress:
`uic-private-widgets`, `virtual-container-return`, `moveonly-byvalue-params`,
`windows-msvc`. `@Property string` read/write now has a focused test (`cannon_t10`);
ownership destruction invariants have one too (`ownership`).

## Tracked follow-ups (to make this a real contract)

- Per-category **counters + regression history** in CI (pass/expected-fail per category),
  not just a green/red matrix.
- Fold the coverage manifest (`generated/<dir>/coverage.txt`) into a per-method status
  report and gate on it.
- Ownership-invariant tests for `holder` beyond `wraptest` (C++ destroy before the D
  wrapper, `deleteLater` at shutdown, app singleton, varied reparenting, non-QObject).
