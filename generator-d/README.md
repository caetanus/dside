# generator-d — the generator, in D

The Qt binding generator: native D on the **libclang C API** (`clang_c.d`, no
`clang.cindex`). It discovers classes, extracts public ctors/methods, maps types,
and emits a **pure `extern(C++)`** D binding (`emit_cxx.d`) — modules mangle
straight to the Qt symbols; there is no per-class C shim to compile.

> **The generator emits `extern(C++)` only** (spec `"abi": "cxx"`). The earlier C-ABI
> shim emitter was **removed** from `emit.d` (a few dead helper functions still linger
> in `gen.d`, referenced by nothing, pending a cleanup). A non-`cxx` spec now errors.

## Build & run

```sh
dub build                                   # -> ./gend  (ldc2 or dmd)
./gend ../generator/spec_cxx_qtwidgets.json # emits generated/<...>/qt/widgets/*.d
```

`gend <spec.json>` writes the binding into a gitignored `generated/` dir and a
`coverage.txt` (D bindings emitted + methods dropped as unmapped-type) beside it.

## Speed

Native libclang (C API) vs the retired Python `clang.cindex` port: whole QtCore
generated in seconds where Python took minutes. The generator is a dev-time tool,
so its language is invisible to users — but at whole-Qt scale the speed matters.

## Bind your own Qt C++

Point `headers` + `source_filter` at your project and it binds your own `QObject`
subclasses and value types the same way — no `Q` prefix required.

```json
"headers": [".../shape.h"], "source_filter": "examples/userlib"
```

## Rules from shiboken — a small regex subset

The generator pulls PySide's typesystem XML as data (no shiboken fork), but only a
**small regex-extracted subset**: `<rejection>` (skip a class/method) and
`<object-type>` vs `<value-type>` (never heap-copy an object by value). It does
**not** parse ownership/rename semantics — it is not a general typesystem parser.

```json
"typesystem_dir": "/usr/share/PySide6/typesystems",
"typesystem_glob": "typesystem_core*.xml"
```

## Files

| File | Role |
|------|------|
| `gen.d` | entry point: spec parsing, discovery, `loadRules` (typesystem regex) |
| `emit_cxx.d` | the **canonical** `extern(C++)` emitter (methods, ctors, wrapper/GC mode, exceptions, uic/moc glue) |
| `emit.d` | driver: discovery, drives the `extern(C++)` emitter, writes files, reports coverage |
| `clang_c.d` | libclang C API bindings |

See the repo `README.md` for the overall architecture and status matrix, and
`docs/FEATURES.md` for the capability list.
