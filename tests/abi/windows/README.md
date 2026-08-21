<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# MS x64 ABI probe

The experiment behind the note in `docs/windows-roadmap.md`. It settles deep risk
№1 — whether the explicit-`self` pattern xiboca emits survives the Microsoft x64
calling convention — and it is kept because a measurement nobody can repeat is an
anecdote.

Run it on a Windows machine with `ldc2`, `dmd` and a `clang++` targeting
`x86_64-pc-windows-msvc`:

```sh
clang++ -std=c++17 -c probe_impl.cpp -o probe_impl.obj

ldc2                     -of=p.exe probe.d probe_impl.obj && ./p.exe   # -> PASS
ldc2 -d-version=SretFirst -of=p.exe probe.d probe_impl.obj && ./p.exe  # -> FAIL, prints 0x0
ldc2 -d-version=SysV      -of=p.exe probe.d probe_impl.obj && ./p.exe  # -> segfault
dmd                      -of=pd.exe probe.d probe_impl.obj && ./pd.exe # -> PASS
```

One shape per compilation, deliberately: LDC refuses two declarations of the same
mangled name with different types, which is the check doing its job.

Measured 2026-08-21, Windows 10 x64, LLVM 19.1.7, ldc2 1.42.0, dmd — **both D
compilers agree**:

| Case | SysV (Linux) | MS x64 |
|---|---|---|
| plain `const` member, scalar return | `f(this, …)` | same |
| non-`const` member with an argument | `f(this, …)` | same |
| **member returning by value** | `f(sret, this, …)` | **`f(this, sret, …)`** |

Three failure modes were observed, and the middle one is why this had to be run
rather than reasoned about:

* declared `Ret f(void* self)` — the SysV shape — **segfaults**;
* declared `void f(Ret* sret, void* self)` — sret first — **does not crash and
  returns `0x0`**, which is the silent-wrong-answer case;
* declared `void f(void* self, Ret* sret)` — **correct on ldc2 and dmd**.

No Visual Studio is installed on the machine this ran on. `ldc2` and `dmd` both
link and run without it.

## And then against real Qt

`qtglue.cpp` + `qtd.d` are the second half of the same question: the probe above
uses a class we wrote, so it proves the convention; this one calls **Qt itself**.

```sh
Q=/c/Qt/6.10.3/msvc2022_64
clang++ -std=c++17 -c qtglue.cpp -o qtglue.obj -I$Q/include -I$Q/include/QtCore
ldc2 -of=qtd.exe qtd.d qtglue.obj -L=$Q/lib/Qt6Core.lib
PATH=$Q/bin:$PATH ./qtd.exe        # -> QByteArray::length() -> 12 ... QT-CALL: PASS
```

D reaches `?length@QByteArray@@QEBA_JXZ` through the explicit-`self` pattern, on a
`QByteArray` built by C++, and gets 12 for a 12-byte array. Measured 2026-08-21 on
Windows 10 with Qt 6.10.3 (msvc2022_64), LLVM 19.1.7, ldc2 1.42.0 — **and no
Visual Studio installed**.

Note the Qt 5 on that machine is `msvc2017`, 32-bit: Qt5 parity cannot be built
there against an x64 toolchain, and needs an x64 Qt5 build before it means
anything.
