# legacy — the pre-`extern(C++)` C-ABI path

This directory holds the **old C-ABI binding stack**, kept only because the QML demo has
no `extern(C++)` (cxx) equivalent yet. Everything here is frozen; the mainline is the cxx
generator + reggae build described in the top-level `README.md`.

- **`convert/`** — `qtd_convert.{cpp,d}`: value-type conversion helpers (QString/QByteArray/…)
  for the C-ABI shim path.
- **`metaobject/`** — `bindingmanager.d` (the GC/identity layer for the C-ABI path),
  `qtd_meta.cpp` / `qtmeta.d` / `metaobj.d` (runtime `QMetaObject` via `QMetaObjectBuilder`),
  and a small standalone demo.
- **`qt6-qml/`** — a QtQuick/QML dashboard app driven from D, built on the C-ABI stack above.

The generator still emits C-ABI output (`emit.d`'s `emitClass`, gated on `abi != "cxx"`),
whose generated modules `import qtd_convert;` / `import bindingmanager;` from here. The
QML binding is produced from `generator/spec_qml.json`.

**Follow-up:** port the QML demo to the cxx path (`qmlRegisterType` via the CTFE moc in
`runtime/qtmoc`). Once QML runs on cxx, this whole directory — and the C-ABI code in the
generator — can be deleted.
