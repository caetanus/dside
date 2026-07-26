# Test suite

The binding is validated by a target matrix run through reggae (`./build --list`,
`./build <target>`). Every target **compiles and runs** on **ldc2 AND dmd**; the
Qt-version axis (**Qt5 AND Qt6**) is exercised where a target is Qt-version-specific.
This document is the contract: what is tested, on what matrix, and what is a known
expected-fail. The per-symbol coverage manifest is now gated (see **governance gates**);
a per-category CI counter with regression history is still a tracked follow-up (see below).

## Categories

| Category | Targets | What it proves |
|----------|---------|----------------|
| **libsample (shiboken corner cases)** | `sample_*` (28 cases) + `sample_cornercases` | The hard binding cases shiboken's own test lib is built to expose: value types, object types, MI, enums/flags, overloads, references, function pointers, inject-code, modified ctors, comparison/operators, exceptions, `MoveOnly`. `cornercases` asserts `ALL PASS`. |
| **GC / lifetime (wrapper mode)** | `wraptest`, `widget_test` (qt5+qt6), `moc_test` (qt5+qt6) | Holder identity, parenting-pins, orphan reclamation on GC, reparent detection; a real QApplication+widgets app; a moc subclass (`CannonField : QWidget`, `paintEvent` override) — construction via `new QWidget(parent)`. |
| **moc / signals / properties** | `cannon_t1..t9`, `cannon_widget` | CTFE `@QObject`/`Signal`/`@Slot`/`@Property` via `QMetaObjectBuilder`: custom signals (incl. `QString` args), NOTIFY properties → QML/binding updates, value-type ctors, parenting. |
| **uic (CTFE)** | `uic`, `dialog`, `tabs`, `mainwin`, `hello`, `egroup`, `combo`, `spacer`, `icon`, `uicheck`, `corpus-check` | `mixin(uiForm(import(".ui")))` → typed struct. `uicheck` + `corpus-check` are **differential**: our tree must serialize identically to `QUiLoader`'s over the whole Qt baseline corpus (**60/60**). |
| **QML (D backend)** | `qml`, `qmlreg`, `qmlaot`, `qmltypes`, `moclife` | D `@QObject` driving QML: exposed via `setContextProperty` (`qml`); registered as an instantiable element via `qmlRegisterType` (`qmlreg`); the `.qml` precompiled to bytecode by `qmlcachegen` and linked with **no source shipped** (`qmlaot`); a `.qmltypes` emitted by CTFE and validated by Qt's own `QQmlJSTypeDescriptionReader` (`qmltypes`); the moc side-table lifetime (`moclife`). Targets that need `qmlcachegen`/`Qt6QmlCompiler` skip if absent. |
| **i18n (tr / lupdate)** | `tr`, `lupdate-check` | Runtime `"str".tr` (free UFCS, module context) + `QTranslator.install` translating a real `lrelease` `.qm`; and `lupdate-d` (libdparse) extracting `tr`/UFCS/`translate`, diffed against a golden `.ts`. Together they span D source → `lupdate-d` → `.ts` → `.qm` → `tr()`. |
| **governance gates** | `manifest-gate-qtwidgets`, `manifest-gate-qml` | Regenerate a binding and diff its per-symbol `coverage-manifest.tsv` against a checked-in baseline (`tests/coverage/`); **fail** on a disappeared symbol, a worsened fate, or a new unmapped/inline-failed drop. |
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

## Coverage manifest (gated)

Each binding emits a per-symbol `coverage-manifest.tsv` (`cppClass · symbol · fate`, fates:
`bound` / `shimmed` / `signal` / `inherited` / `pure-virtual` / `unmapped-type` /
`inline-failed`) plus a `coverage.txt` summary. The **object-method path is per-symbol**; the
`manifest-gate-*` targets diff it against `tests/coverage/*.manifest.tsv` and fail on regression.
**Still partial:** value-type / wrapper / ctor / stub drops are counted in the `coverage.txt`
aggregate but not yet emitted per-symbol (widgets: 493, qml: 425 aggregate-only). Completing that
is the open manifest follow-up.

## Tracked follow-ups (to make this a real contract)

- Per-category **counters + regression history** in CI (pass/expected-fail per category),
  not just a green/red matrix, and a structured test report (JSON/TSV) over the ~140 targets.
- Emit the value-type/wrapper/ctor/stub drops **per-symbol** so the manifest covers the whole
  API surface, not only the object-method path.
- Ownership-invariant tests for `holder` beyond `wraptest` (C++ destroy before the D
  wrapper, `deleteLater` at shutdown, app singleton, varied reparenting, non-QObject).
- Treat the QML/tooling private APIs (`QQmlPrivate`, `QQmlJSTypeDescriptionReader`,
  `QMetaObjectBuilder`) as versioned risk: per-Qt-version probes + expected-fails, not comments.
