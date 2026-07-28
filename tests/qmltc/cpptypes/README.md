# Corpus C++ types (vendored)

Verbatim copies of app-defined QML types from Qt's own `qmltc` test corpus
(`qtdeclarative/tests/auto/qml/qmltc/QmltcTests/cpptypes/`), kept here for the same reason
`tests/uic/corpus/` vendors Qt's `.ui` files: the build stays hermetic and the differential runs
against types we did not write.

They are ordinary `Q_OBJECT` + `QML_ELEMENT` + `Q_PROPERTY` classes — nothing qmltc-specific.
The pipeline over them is Qt's own: `moc --output-json` -> `qmltyperegistrar`, which yields both
the registration `.cpp` the ORACLE links (so the engine can instantiate them) and the
`.qmltypes` registry qmltc-d compiles against.

Copyright (C) The Qt Company Ltd. SPDX-License-Identifier: LicenseRef-Qt-Commercial OR GPL-3.0-only
