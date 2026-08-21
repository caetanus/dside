<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# Archive member selection on Windows

Deep risk №2 of `docs/windows-roadmap.md`: `link.exe` and `lld-link` have no
`--start-group`, and this project relies on archive member selection — it is what
replaced the manual import-closure BFS, and what lets `libbinding ↔ libshims ↔ Qt`
resolve at all.

Two questions, three experiments:

```sh
for f in a a2 poison b used inlonly; do clang++ -std=c++17 -c $f.cpp -o $f.obj; done
llvm-lib /OUT:libA.lib a.obj a2.obj poison.obj
llvm-lib /OUT:libB.lib b.obj
llvm-lib /OUT:libJ.lib used.obj inlonly.obj
```

**1 — Does a cycle resolve with no group?** `main -> a_fn (A) -> b_fn (B) ->
a_helper (A)`, so A must be searched again after B:

```sh
ldc2 -of=g1.exe m.d -L=libA.lib -L=libB.lib && ./g1.exe   # -> 21, PASS
ldc2 -of=g2.exe m.d -L=libB.lib -L=libA.lib && ./g2.exe   # -> 21, PASS
dmd  -of=gd.exe m.d libA.lib libB.lib      && ./gd.exe    # -> 21, PASS
```

Both orders, both compilers.

**2 — Is an unreferenced member really left out?** `poison.obj` is inside
`libA.lib` and calls a symbol that exists nowhere. The link above succeeds, so it
was not pulled in — and referencing it proves it was there to pull:

```
lld-link: error: undefined symbol: never_defined_anywhere
```

**3 — The webengine shape.** An unreferenced object whose out-of-line inline copy
needs an absent symbol:

```sh
ldc2 -of=j1.exe m3.d -L=libJ.lib          && ./j1.exe   # -> 7, PASS
ldc2 -of=j2.exe m3.d used.obj inlonly.obj               # -> undefined symbol
```

Through the archive it links; the same objects passed **directly** fail. Same
contrast as on Linux, which is the property the project depends on.

**One correction worth keeping**, because it is the easy mistake and it looked
like the linker failing: selection is per **object file**, not per symbol. A first
version of experiment 3 put `uses_nothing()` and the offending inline in the same
`.cpp`; the member was then pulled in — correctly — and the archive appeared not
to help.

Measured 2026-08-21, Windows 10 x64, LLVM 19.1.7, ldc2 1.42.0, dmd, no Visual
Studio installed.
