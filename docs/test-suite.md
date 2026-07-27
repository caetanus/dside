# Test suite

The binding is validated by a target matrix run through reggae (`./build --list`,
`./build <target>`). MOST targets compile and run on **ldc2 AND dmd** and, where
Qt-version-specific, on **Qt5 AND Qt6** — but some are deliberately single-config
(the `manifest-gate-*` gates and `lupdate-check` are singletons; `qmlaot`/`qmltypes`
are Qt6-only). This document is the contract: what is tested, on what config, and what
is a known gap. There is a **CI scaffold** (`.github/workflows/ci.yml`, master +
codegen-tools) that provisions Qt5/Qt6 + the pyside-setup libsample corpus and runs
the matrix; the version-independent gates are mandatory, the manifest gates advisory
(baselines are Qt 6.11, distro-CI Qt differs). The manifest gates are **optional** reggae
top-level targets — reachable by name but excluded from the default `./build`, so the full
matrix never fails on baseline drift; CI runs them in a separate continue-on-error step.
**HONEST: it is not yet proven green on
a real runner** — treat the local machine (Qt 5.15 + 6.11) as the current source of
truth until CI goes green.

## Categories

| Category | Targets | What it proves |
|----------|---------|----------------|
| **libsample (shiboken corner cases)** | `sample_*` (28 cases) + `sample_cornercases` | The hard binding cases shiboken's own test lib is built to expose: value types, object types, MI, enums/flags, overloads, references, function pointers, inject-code, modified ctors, comparison/operators, exceptions, `MoveOnly`. `cornercases` asserts `ALL PASS`. |
| **GC / lifetime (wrapper mode)** | `wraptest`, `widget_test` (qt5+qt6), `moc_test` (qt5+qt6), `moclife_widget` (qt5+qt6) | Holder identity, parenting-pins, orphan reclamation on GC, reparent detection; a real QApplication+widgets app; a moc subclass (`CannonField : QWidget`, `paintEvent` override) — construction via `new QWidget(parent)`; `moclife_widget` destroys an attached QtdWidget subclass and requires `g_moAttach`+`_reg` back to baseline. |
| **moc / signals / properties** | `cannon_t1..t11`, `cannon_widget` | CTFE `@QObject`/`Signal`/`@Slot`/`@Property` via `QMetaObjectBuilder`: custom signals (incl. `QString` args), NOTIFY properties → QML/binding updates, value-type ctors, parenting; `t10` a `@Property string` read/write, `t11` the nothrow-slot error policy. |
| **uic (CTFE)** | `uic`, `dialog`, `tabs`, `mainwin`, `hello`, `egroup`, `combo`, `spacer`, `icon`, `uicheck`, `corpus-check` | `mixin(uiForm(import(".ui")))` → typed struct. `uicheck` + `corpus-check` are **differential**: our tree must serialize identically to `QUiLoader`'s over the whole Qt baseline corpus (**60/60**). |
| **QML (D backend)** | `qml`, `qmlreg`, `qmltwo`, `homonym`, `qmlaot`, `qmltypes`, `moclife` | D `@QObject` driving QML: exposed via `setContextProperty` (`qml`); registered as an instantiable element via `qmlRegisterType` (`qmlreg`); the `.qml` precompiled to bytecode by `qmlcachegen` and linked with **no source shipped** (`qmlaot`); a `.qmltypes` emitted by CTFE and validated by Qt's own `QQmlJSTypeDescriptionReader` (`qmltypes`); the moc side-table lifetime (`moclife`). Targets that need `qmlcachegen`/`Qt6QmlCompiler` skip if absent. |
| **i18n (tr / lupdate)** | `tr`, `lupdate-check` | Runtime `"str".tr` (free UFCS, module context) + `QTranslator.install` translating a real `lrelease` `.qm`; and `lupdate-d` (libdparse) extracting `tr`/UFCS/`translate`, diffed against a golden `.ts`. Together they span D source → `lupdate-d` → `.ts` → `.qm` → `tr()`. |
| **governance gates** | `manifest-gate-qtwidgets`, `manifest-gate-qml` | Regenerate a binding and diff its per-symbol `coverage-manifest.tsv` against a checked-in baseline (`tests/coverage/`); **fail** on a disappeared symbol, a worsened fate, or a new unmapped/inline-failed drop. |
| **qrc / containers / misc** | `qrc`, `container_qvector`, `qlist_roundtrip`, `holder_test`, `webengine` | CTFE `.rcc`; `QList`/`QVector` round-trips; holder unit; a WebEngine private-type smoke. |

## Matrix

- **Compilers:** ldc2 **and** dmd for MOST targets — but not universally: the gates
  (`manifest-gate-*`, `expected-fails-lint`) and `lupdate-check` are deliberately single-config
  singletons, and a few targets are Qt6-only (`qmlaot`, `qmltypes`). (D's own `extern(C++)`
  mangling diverges between ldc2 and dmd on Itanium substitutions; `pragma(mangle)` with clang's
  exact symbol keeps them identical — this axis guards that, which is why nearly everything else
  builds on both.)
- **Qt:** Qt6 (6.11) is primary; Qt5 (5.15) is exercised via the `*-qt5` wrapper targets
  (`widget_test`, `moc_test`) and the Qt5 wrap specs. Value-type ABI differs Qt5↔Qt6, so
  this axis is load-bearing, not cosmetic.
- **Platform:** Linux / POSIX (Tier 1 — see the repo README). Windows/MSVC-x64 is a
  roadmap, not tested.

## Known expected-fails / exclusions (honest gaps)

Inventoried as **structured state** in `tests/expected-fails.json` (id / area / reason /
since / remove-when): `uic-private-widgets`, `virtual-container-return`,
`moveonly-byvalue-params`, `windows-msvc`, plus the QML/moc private-API risks.
**Honest scope:** `expected-fails-lint` reads the file and STRICTLY validates it (fixed
schema value + kind enum, unique IDs, field-by-kind rules, and every `risk` probe naming
a real target) — a typo can't invent an accepted category. It is a schema LINTER, not an
expected-fail RUNNER: it does not execute probes, evaluate `remove_when`, or detect
unexpected pass/fail (that runner is the tracked follow-up). `@Property string` read/write has a focused test
(`cannon_t10`); ownership destruction invariants have one too (`ownership`).

## Coverage manifest (gated)

Each binding emits a per-symbol `coverage-manifest.tsv` (`cppClass · symbol · usr · fate`, fates:
`bound` / `shimmed` / `signal` / `inherited` / `pure-virtual` / `unmapped-type` / `inline-failed`)
plus a `coverage.txt` summary. The key is class + the clang **USR**, so overloads are distinct rows
(a class+name key collapsed them). Every Unmappable drop is `recordSym`'d, so the object-method AND
value-type/wrapper/ctor paths are per-symbol — the `coverage.txt` "not per-symbol" residual is 0.
The `manifest-gate-*` targets diff the fresh manifest against `tests/coverage/*.manifest.tsv` and
fail on a disappeared/regressed/new-drop symbol or a duplicate-USR collision; each is built
`-unittest` and run `--DRT-testmode=run-main`, so it runs its own regression-detection tests before
vouching. **Gate coverage is still partial: only Qt6 raw-QtWidgets + Qt6-QML have baselines** (Qt5,
wrapper, webengine don't) — that's the open follow-up.

## Tracked follow-ups (to make this a real contract)

- Per-category **counters + regression history** in CI (pass/expected-fail per category),
  not just a green/red matrix, and a structured test report (JSON/TSV) over the ~162 targets.
- An expected-fail RUNNER on top of the existing strict linter (execute probes, evaluate
  `remove_when`/expiration, detect unexpected pass/fail) — the linter validates structure only.
- Extend the manifest gates to Qt5, wrapper mode and webengine (only Qt6 raw-QtWidgets + Qt6-QML
  have baselines today).
- Ownership-invariant tests for `holder` beyond `wraptest` (C++ destroy before the D
  wrapper, `deleteLater` at shutdown, app singleton, varied reparenting, non-QObject).
- Treat the QML/tooling private APIs (`QQmlPrivate`, `QQmlJSTypeDescriptionReader`,
  `QMetaObjectBuilder`) as versioned risk: per-Qt-version probes + expected-fails, not comments.
