<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# Windows support — roadmap

Status: **not started** (Linux is the only verified platform). This is a design
roadmap, not a record of work done.

**Scope: x64 ONLY.** win32 is explicitly out (owner's decision). This matters: win32's
`__thiscall`/`__stdcall`/`__cdecl` zoo was the scary part of every "call a member via a
raw pointer" trick here. x64 Windows has **exactly one** calling convention (`this` in
RCX = the first integer arg; sret is a hidden pointer ordered `[RCX=retptr, RDX=this,
R8…]`), so the member-as-free-function tricks below become well-trodden instead of
convention-dependent guesswork.

## The one thing that makes this tractable

The generator does **not** hand-roll Itanium mangling — it asks libclang for every
symbol via `clang_Cursor_getMangling()` (`xiboca/emit_cxx.d:94, 1111, 1186, 1327,
1536, 1577, …`). So the mangled names are whatever the **target ABI of the parsed
translation unit** produces: Itanium on Linux/MinGW, MSVC (`?foo@Bar@@…`) if the Qt
headers are parsed with an MSVC target triple. That turns "port the C++ ABI" from
"write a second mangler" into "point libclang at the right target + fix the mechanics".

The mechanics (the reggae build in `reggae/qtd_build.d`) are where the real Windows work
is — the commands are POSIX shell throughout.

---

## Tier 1 — MinGW-w64 + MSYS2 (small; do this first)

Qt built with MinGW uses the **Itanium C++ ABI** — the same one Linux uses. Consequences:

- `getMangling` already returns matching names → **the generator is unchanged**.
- The entire POSIX toolchain that `qtd_build.d` shells out to exists in MSYS2: `sh`,
  `ar`, `ld` (with `--start-group`), `find`, `sed`, `flock`, `pkg-config`, `clang++`.
  `.o` / `.a` extensions stay.
- LDC/DMD target `-mtriple=x86_64-windows-gnu`.

In practice this should **nearly run as-is** inside an MSYS2 shell. Expected work:

- [ ] Ensure reggae invokes `sh` (not `cmd.exe`) for target commands (run from MSYS2, or
      force the shell).
- [ ] Confirm `QT_QPA_PLATFORM=offscreen <app>` works (it does under `sh`).
- [ ] Confirm LDC **and** DMD link against MinGW Qt (parity, as on Linux).
- [ ] Run the full `./build` and the libsample survey; expect green with no code changes,
      or only path/extension tweaks.

**Value:** proves the `extern(C++)` + reggae architecture is genuinely portable, in days
not weeks. This is the cheap win and the recommended first step.

---

## Tier 2 — native MSVC Qt (the common distribution; larger)

Mangling still comes from libclang (parse with an MSVC triple → `?…@@…` names), but the
build mechanics in `qtd_build.d` are POSIX-hardcoded and must be parametrized:

| Today (POSIX) | MSVC |
|---|---|
| `ar rcs lib.a` | `llvm-lib` / `lib.exe` → `.lib` |
| `.o`, `od/*.o` | `.obj` |
| `-fPIC` | remove |
| `clang++` (shims) | `clang-cl` (MSVC ABI) |
| `-L--start-group … --end-group` | **link.exe / lld-link have no group** — list the archive twice, or merge into one `.lib` |
| `pkg-config --cflags/--libs` | qmake / `QTDIR` (MSVC Qt ships no pkg-config) |
| `flock` | no native equivalent → `mkdir`-based atomic lock, or `--single` |
| hardcoded Itanium literals: `_ZN10QArrayData…`/`_ZN9QListData…` (`emit_cxx.d`) **and `_Znwm`/`_ZdlPv`** (operator new/delete in the generated `cxxrt.d` — `cxxRuntime()`) | fetch via libclang, or emit per-ABI (`??2@YAPEAX_K@Z` / `??3@YAXPEAX@Z` on MSVC) |
| link: `-L--gc-sections -L--as-needed` + shim compile `-ffunction-sections -fdata-sections` | `/OPT:REF` (drops unreferenced fns/data — **on by default in release**, and each fn is already a COMDAT so no `-ffunction-sections` needed); `--as-needed` has no analogue (Windows import libs only import referenced symbols). The à-la-carte binary is basically free on MSVC. |

### Two deep risks — de-risk these BEFORE touching the mechanics

Each deserves an isolated proof, exactly like the Linux "step 0" (which empirically proved
the explicit-`self` `pragma(mangle)` member call incl. sret + const on ldc + dmd).

> **MEASURED 2026-08-21 on the Windows 10 VM — risk 1 is REAL, and it is one line of emission.**
> A C++ class was compiled with `clang++` targeting `x86_64-pc-windows-msvc` and called from D
> through `pragma(mangle)` with an explicit `self`, on **ldc2 1.42 and dmd**, both agreeing:
>
> | case | SysV (Linux) | MS x64 |
> |---|---|---|
> | plain `const` member, scalar return | `f(this, …)` | **same** |
> | non-`const` member with an argument | `f(this, …)` | **same** |
> | **member returning by value** | `f(sret, this, …)` | **`f(this, sret, …)`** |
>
> Declared the SysV way (`Ret f(void* self)`) the call **segfaults**; declared as
> `void f(void* self, Ret* sret)` it returns the right value on both compilers. Written the other
> way round, `void f(Ret* sret, void* self)`, it does not crash — it silently yields `0x0`, which is
> the worse failure mode and the reason this had to be measured rather than reasoned about.
>
> So the emission strategy SURVIVES: it needs an MS-ABI variant for exactly one case, the
> value-returning member, and nothing else about the explicit-`self` pattern changes.
>
> **AND THE MECHANISM ITSELF WAS THEN RUN AGAINST REAL QT**, on the same machine, same day.
> Qt 6.10.3 (msvc2022_64) was already installed there. With `clang++` from LLVM's extractable
> package and no Visual Studio at all:
>
> * `#include <QObject>` compiles;
> * a program using `QString`/`QByteArray` links against `Qt6Core.lib` and prints the right answer;
> * and **D calls a real Qt member by its MSVC mangled name** — `?length@QByteArray@@QEBA_JXZ`,
>   reached with the explicit-`self` pattern on an object built by C++ — returning 12 for a
>   12-byte array.
>
> That is the whole xiboca call mechanism, working on Windows. What remains for Tier 2 is the
> build mechanics table below (archives, extensions, group linking, pkg-config), not the question
> of whether the approach can work there.
>
> One thing the machine also settles: its Qt 5.14.1 is `msvc2017` **without a `_64` suffix — it is
> 32-bit**, so Qt5 parity cannot be built there against an x64 toolchain. Qt5-on-Windows needs an
> x64 Qt5 build before it means anything.
>
> Also measured on that machine: **ldc2 and dmd link and run without Visual Studio installed** —
> both ship what they need — so the Tier 2 assumption that `link.exe`/`lib.exe` are prerequisites is
> wrong for the D half. `clang++` from the extractable LLVM package is enough for the C++ half.

1. **MS x64 calling convention on the explicit-`self` shims.**
   The pattern `pragma(mangle,"…") extern(C++) Ret __Class_m(void* self, …)` assumes the
   SysV/Itanium convention (`this` = first pointer arg, and its sret handling). On **MS
   x64 the ordering of `this` and the by-value-return (`sret`) slot differs.** Re-prove
   `sret` + `const` + by-value member calls on ldc **and** dmd targeting
   `-windows-msvc` before relying on the shim pattern. If this doesn't hold, the emission
   strategy for member calls needs an MS-ABI variant — this is the highest risk.

> **MEASURED 2026-08-21 — risk 2 is NOT a risk.** Built on the same VM with `llvm-lib` and
> linked by `lld-link` (through ldc2) and by dmd, with no group flag anywhere:
>
> * a **circular** dependency across two archives — `main -> a_fn (A) -> b_fn (B) -> a_helper (A)`,
>   so A must be searched again after B — resolves in **either link order**, `A B` and `B A`;
> * an archive member that **nothing references** is not pulled in, proven both ways: with no
>   reference the link succeeds, and adding one reference to it fails with
>   `undefined symbol: never_defined_anywhere`, so the member was there and selection is what kept
>   it out;
> * the **webengine shape** behaves as on Linux: an unreferenced object whose inline copy needs an
>   absent symbol links clean **through an archive** and fails when the same objects are passed
>   **directly** — which is the property the manual import-closure BFS was replaced by.
>
> One correction to my own first attempt, kept because it is the easy mistake: selection is per
> OBJECT FILE, not per symbol. Putting the referenced function and the offending one in the same
> `.cpp` makes the member get pulled in — correctly — and looks like the linker failing.
>
> So neither deep risk survives contact. Tier 2 is now mechanics only.

2. **Archive-DCE without `--start-group`.**
   The linker's archive-member selection (which replaces the manual import-closure BFS —
   see the Linux proof: dmd linking the full webengine binding directly fails on an
   unreferenced inline symbol, but the same objects in an archive link clean) exists in
   link.exe / lld-link too, but circular refs (libbinding ↔ libshims ↔ Qt) are handled
   without a group: list the archive twice, or merge. Confirm the webengine-style
   unreferenced-inline case is still dropped. Likely yes (MSVC linkers do member
   selection), but this is the exact thing to validate.

### THE REGGAE BUILD ITSELF RUNS ON WINDOWS — 2026-08-21

Not just the hand-driven pipeline below: `reggae -b binary` builds the reggaefile there, and the
resulting `build.exe` constructs the whole graph and runs targets.

```
reggae -b binary .          reggaefile compiled and linked -> build.exe
./build.exe --list          881 targets
./build.exe license-coverage
                            license-coverage OK: 616 tracked file(s) ...
```

**881 and not 1205, for a stated reason**: that machine's Qt5 is `msvc2017`, 32-bit, so
`qtHasModule` does not find it under `$QTDIR/lib` and every Qt5 target is absent — measured, `grep
-c qt5` over the listing returns 0. The gap is the Qt5 half, not a silent truncation.

What the environment needs: `QTDIR` pointing at the Qt prefix, LLVM's `bin` on PATH for
`clang++`/`llvm-lib`, and Git Bash's `/usr/bin` on PATH — which a non-interactive ssh session does
not have by default.

Four more items, each found by getting one step further:

| | |
|---|---|
| pkg-config | 35 call sites were six questions; they now go through a probe backed by `QTDIR` where pkg-config is absent |
| `writeIfChanged` | graph construction writes into `.build/<binding>/` before any target runs; on a first build that directory does not exist |
| `findTool` | asked for `moc`, and Qt ships `moc.exe` — a present tool read as MISSING |
| `QT_INSTALL_LIBEXECS` | probed via qtpaths/qmake **on PATH**, and Qt's installer does not put its bin there; the probe is now the last resort |

### THE HAND-DRIVEN PIPELINE WORKS TOO — 2026-08-21

End to end, on the Windows 10 VM, with `clang++` from LLVM's extractable package, `ldc2` 1.42.0 and
Qt 6.10.3 (msvc2022_64), and **no Visual Studio installed**:

```
xiboca.exe spec-win.json    271 classes emitted, 1252 D bindings, 0 Itanium manglings
clang++                     7 of 7 C++ shims compiled
ldc2                        335 of 335 D modules compiled
llvm-lib                    libbinding.lib + libshims.lib
ldc2 app.d + both archives + Qt6Core.lib
./app.exe                   QByteArray -> "hello windows" (13 bytes)
                            WIN-BINDING: PASS
```

A `QByteArray` built from a D `string`, crossing the generated binding into `Qt6Core.dll` and back.

Four changes got it there, and every one was small:

| | |
|---|---|
| `dub.json` | `libs-posix: [clang]` / `libs-windows: [libclang]` — the name differs, and `libs-<platform>` ADDS rather than replaces |
| pkg-config | made optional; Qt's MSVC builds ship no `.pc` at all, and a spec that gives `cflags`/`libs` needs no such tool |
| ABI symbols | the five names the emitter spells itself now come from a table indexed by the ABI **libclang is using**, decided once after discovery |
| destructors | the runtime value types emit `extern(D) ~this()`; a C++-mangled one collides with the copy `Qt6Core.lib` exports |

### Where the mechanics stand

The generator itself now **builds and runs on Windows**, and produced a QtCore binding there:

```
discovered 286 classes in <QtCore>
done: 271 classes emitted, 1252 D bindings  (6.2 s)
```

Everything it emitted then compiled: **7 of 7 C++ shims** (`qtdmoc.cpp` needs Qt's private headers,
same as on Linux) and **all 335 D modules**, with `clang++` and `ldc2`, no Visual Studio.

Two porting items were found by getting that far, both bounded:

**1. Hardcoded Itanium literals — 5 of them, exactly as this table predicted.** libclang does the
right thing on Windows: of the manglings in the emitted tree, **2537 are MSVC and 8 are Itanium**,
and all 8 come from string literals in the generator rather than from the AST. Their MSVC
counterparts, read from `Qt6Core.lib`:

| literal | MSVC name |
|---|---|
| `_ZN10QArrayData10deallocateEPS_xx` | `?deallocate@QArrayData@@SAXPEAU1@_J1@Z` |
| `_ZN7QStringC1EPK5QCharx` | `??0QString@@QEAA@PEBVQChar@@_J@Z` |
| `_ZN10QByteArrayC1EPKcx` | `??0QByteArray@@QEAA@PEBD_J@Z` |
| `_Znwm` / `_ZdlPv` | operator new/delete, MSVC-mangled |

**2. Duplicate symbols at link, which is new and NOT in this table.** The emitted
`extern (C++) struct QByteArray` declares `~this()`, so LDC emits an out-of-line destructor under
the C++ mangled name — and `Qt6Core.lib` exports one too:

```
lld-link: error: duplicate symbol: public: __cdecl QByteArray::~QByteArray(void)
>>> defined at libbinding.lib(qbytearray.obj)
>>> defined at Qt6Core.lib(Qt6Core.dll)
```

On Linux this merges; COFF has no equivalent, so the value-type runtime modules need their
destructors declared rather than defined on Windows. This is the one genuinely new item the port
turned up.

### Mechanics work (after the de-risks pass)

- [ ] Introduce a `struct Toolchain` in `qtd_build.d`: `objExt`, `libExt`, `archiver`,
      `linkerGroup` (start/end or double-list), `picFlag`, `qtCflags()`, `qtLibs()`,
      selected by `version(Windows)` / a target flag.
- [ ] Replace `flock` with a **`mkdir`-based atomic lock** (portable to both OSes; also
      removes the util-linux dependency on Linux) — keeps the concurrency guards that stop
      reggae's diamond-node double-scheduling from truncating shared archives.
- [ ] Qt flags from qmake / `QTDIR` instead of `pkg-config`; re-derive the private-header
      discovery (`mocPrivateFlags`) for the MSVC include layout.
- [ ] Fix the ~3 hardcoded Itanium literals to be ABI-aware.
- [ ] `set QT_QPA_PLATFORM=offscreen&& app` for cmd (or keep requiring `sh`).

---

## Tier 2.5 — the exception + guard layer (added 2026-07; the newest x64-critical bits)

Since this roadmap was first written, the binding gained C++/Qt→D **exception translation**,
gated by the spec's `"exceptions": true` flag (on for `spec_cxx_qtwidgets.json`). It leans on
two mechanisms that need Windows validation — see [[cpp-exception-translation]] for the full
design. Both were proven on Linux with a ~10-line experiment; **each needs the SAME experiment
re-run on a Windows box** before trusting exceptions there.

### (A) The per-signature guard = deep risk #1, amplified
Every out-of-line method AND heap object ctor now routes through a shared C++ guard that does
`reinterpret_cast<Ret(*)(void*, Args…)>(fn)(self, args)` — i.e. it calls the Qt member through
its symbol address as if it were a free function with `this` as arg 0 (`emit_cxx.d`, `struct
Guard`). This is exactly deep-risk #1 (MS x64 `this`/sret ordering) but now on the hot path for
~every call, not just ctors. GOOD NEWS with x64-only: one convention, and `this`-as-arg-0 +
sret ordering `[retptr, this, args]` is consistent between a member and a free-function-with-
explicit-self on MS x64 — so the guard's typed `reinterpret_cast` *should* generate the right
ABI (the guard is TYPED, not `void*`/varargs, so the compiler does the per-ABI passing). Still:
**re-prove sret + const + value-param member calls via a guard on ldc AND dmd `-windows-msvc`**
(the Linux proof: `/tmp` guardproto — a throwing member called through a fn-ptr guard, caught).

### (B) Cross-language exception unwinding under SEH = the ONE genuinely new risk
The guard's `catch(...)` calls a `[[noreturn]] qtd_lippincott()` which calls back into D
(`qtd_throw_d`, in `cxxrt.d`) to `throw new QtCppException`. **On Linux this D exception unwinds
cleanly back through the C++ guard frame to the D caller — verified on ldc AND dmd (shared
DWARF/libunwind).** Windows x64 uses **table-based SEH** (`.pdata`/`.xdata` + `RtlUnwindEx`), not
DWARF. LDC/DMD targeting MSVC-x64 use SEH too, so the D throw and the C++ `catch(...)` go through
the same machinery and it *may* just work — but a D `Throwable` crossing an MSVC C++ catch funclet
back to a D handler is NOT guaranteed. **Decisive experiment (run on Windows):** C++ shim
`try { throw std::runtime_error("x"); } catch(...) { qtd_throw_d(...); }`, D `qtd_throw_d` does
`throw new QtCppException`, D caller `try { shim(); } catch (QtCppException e) {…}` — assert
caught, on ldc AND dmd. If it FAILS: fall back to the mechanism rejected on Linux — C++ catches
into a thread-local, D checks it after each guarded call and throws there (SEH-independent, but
adds a per-call check). The guard forwarders already funnel through one place, so swapping the
translation mechanism is localized.

### Note: the Q_GADGET skip is portable
`qt_check_for_QGADGET_macro` is DECLARED-but-never-DEFINED by Qt; we skip it because `&__raw`
forces a symbol reference to a nonexistent symbol (link error). Same on any platform — keep it.

## Cross-cutting decision: shell dialect

Every target command in `qtd_build.d` is a POSIX `sh -c` snippet (`rm -rf`, `mkdir -p`,
`cp`, `sed -i`, `find`, `for c in *.cpp`, `$(…)`, `${c%.cpp}`, `[ … -nt … ]`,
`2>/dev/null`). Two options:

- **Require `sh`** (MSYS2 / Git-Bash) on Windows and keep one command dialect. *Recommended*
  — far less churn, and MinGW/MSYS2 is the Tier-1 target anyway.
- Rewrite every command to be cmd-compatible. Much more work; only worth it for a
  no-MSYS2 native experience.

---

## Recommendation

1. **Tier 1 (MinGW/MSYS2) first** — validates portability cheaply; likely just path/shell
   tweaks. Start with parametrizing the `Toolchain` + the `mkdir` lock, which is shared
   with Tier 2 anyway.
2. **Tier 2 (MSVC) only after** proving the two deep risks (MS x64 sret/`this` ABI on the
   shims, and archive-DCE without `--start-group`). If either fails, the design changes —
   don't build the mechanics on an unproven ABI.
