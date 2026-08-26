<!--
SPDX-FileCopyrightText: 2026 Marcelo A Caetano
SPDX-License-Identifier: BSL-1.0
-->
# Windows support — roadmap

Status: **built and measured.** Both tiers below were carried out; the full matrix now runs on a
Windows VM against Qt 6.11.1 (MSVC) and Qt 5.15.2, with ldc2 and dmd — the same 1199 targets the
Linux matrix schedules, which is a newer statement than "it builds": for a while the two lists
differed, and the difference was three coverage gates that could not compare and said so. What the plan got right and
what it got wrong is recorded at the end, under *What actually happened*. Read that section first
if you are looking for the state of the port rather than the reasoning that led to it.

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

### THE MSVC ABI, ANSWERED FROM LINUX — 2026-08-21

`tools/win/cross-preflight.sh`. No Windows machine and no Visual Studio: `xwin` fetches the MSVC
CRT and Windows SDK from Microsoft's own servers, `aqt` fetches the Windows Qt, the Windows LDC
package supplies druntime and phobos, clang++ and lld-link target `x86_64-pc-windows-msvc`
natively, and wine runs the result.

```
cross-preflight probe: ABI-PROBE: PASS      <- the calling convention, against a class we wrote
cross-preflight qtd:   QT-CALL: PASS        <- ...and against Qt6Core.dll, through explicit self
```

Two things stop this halfway, and both were measured here:

* `-L=-libpath:DIR` never reaches the linker — ldc2 eats the `-l` and lld-link asks for
  `ibpath:DIR.lib`. The MSVC spelling `-L=/LIBPATH:DIR` works.
* xwin ships no `vcruntime140.lib`, which is what ldc2 asks for by default. `-mscrtlib=msvcrt` uses
  the dynamic CRT umbrella that IS there — and it must be the dynamic one, because the Qt DLLs are.

WHAT IT IS FOR, and what it is not. It answers one class of question — does our code compile, link
and RUN against the MSVC ABI — which is the class that produced the sret ordering, the exported
inline members and the mangling-table error, each of which cost a round trip to the VM. It answers
NOTHING about the build: MSYS paths, cmd.exe, PATHEXT, `guard.ps1`. Those exist only on the real
machine, and wine has no PowerShell. It is a pre-flight; **the VM stays the authority**.

### A RUNNER THAT COULD NOT RUN ANYTHING REPORTED 13 OF 13 PASSING — 2026-08-21

The one to remember. `& $exe` in PowerShell resolves a program through `PATHEXT`, and the binaries
this build produces have no extension — `wraptest-ldc2-bin`, `qmltc-d`, because that is what `-of=`
was given. The call operator does not find them, the error is **not terminating**, `$LASTEXITCODE`
is never set, and `exit $LASTEXITCODE` with `$null` exits **zero**.

So the first sweep after moving the runner to PowerShell reported thirteen targets passing with
nothing having run: the logs contained no output from any of them. The same shape gave a "captured"
one-byte file from a tool that produces four kilobytes by hand — and exited 0.

`tools/win/proc.ps1` goes through `CreateProcess`, which has no such rule, and a process that
cannot start is a failure that says so. And the rule that follows:

> **On Windows, verify a target by reading its OUTPUT, not its exit code.**

Re-measured that way: 12 of 12, none silent.

### QT5 AND QT6 SIDE BY SIDE, AND THE COMMANDS IN POWERSHELL — 2026-08-21

Qt 5.15.2 msvc2019_64 installed with `aqtinstall` (the Qt online installer wants an interactive
login; aqt pulls the same official mirrors, 45 seconds). Then four things had to exist before Qt5
did:

| | |
|---|---|
| `QTDIR` names ONE Qt | `QTDIR5`/`QTDIR6` win when set; each of the six questions asks for its own module's installation |
| the discovery marker | the spec says `/qt/`, a distribution layout; against `C:/Qt/5.15.2/…` the case differs, every header was filtered out, and xiboca said `discovered 0 classes` and exited 0 |
| the mangling table | `qbytearray_ctor_i` carried the `size_t` spelling (`_K`) where Qt5 takes an `int` (`H`), and `QListData::dispose` was the last hardcoded Itanium symbol outside `abiSym()` |
| the DLL search | there is no rpath on Windows: a Qt5 binary found Qt6's DLLs and died with 127 before `main`. Which Qt is a property of the TARGET |

**Qt5: 39 of 40 targets pass. A mixed Qt5+Qt6 sample: 13 of 13.**

The build's Windows commands are moving from `sh` to PowerShell (`tools/win/*.ps1`); the gates stay
`.sh`. `guarded()` carries both dialects at one call site, because they are one decision and halves
that live apart drift apart. Five things that had to be measured rather than reasoned about:

* `-EncodedCommand` and `-Command` both REFUSE trailing arguments, so a path reggae substitutes
  can only travel with `-File`; and it must travel as an argument, since reggae substitutes into
  the command TEXT and anything encoded is opaque to it.
* Exit codes do propagate through `executeShell → cmd.exe → powershell -File`: `exit 3` → 3, a
  failing child forwarded via `$LASTEXITCODE` → 7, a PowerShell error under
  `$ErrorActionPreference='Stop'` → 1.
* `$a[1..($a.Count-1)]` with ONE element is a descending range and returns element 0.
* PowerShell 5.1 writes a `#< CLIXML` progress banner to stderr unless `$ProgressPreference` is
  silenced — straight into gate output.
* 5.1 runs on .NET Framework: `[System.IO.Path]::GetRelativePath` is not there.

And one design rule that came out of a failure: a step's parameters cannot be handed over as
trailing arguments, because PowerShell's binder reads them before the script does
(`AmbiguousParameter,guard.ps1`), and name-versus-value cannot be guessed from a leading dash —
the value of `-Cxx` starts with `-I…`.

### 16 OF 17 SAMPLED TARGETS PASS ON WINDOWS — 2026-08-21

The mechanism, not just a link: `wraptest`, `ownership`, `moc_test`, `thread_test`,
`threadguard`, `moclife_widget`, `widget_test`, `cannon_t1/t5/widget` (a real Qt widget app,
headless), `container_qvector`, `qlist_roundtrip`, `borrowed`, `dangle`, `nonqobject`,
`noqml_helpers`.

Eight defects, and not one of them presented as what it was:

| Symptom | What it actually was |
|---|---|
| `'QString' file not found`; `undefined symbol QCoreApplication` | `QTDIR=/c/Qt/…` is an MSYS path; lld-link reads a leading `/` as an **option**, so the library is "ignored" |
| `-I…/QtWidgets` and nothing else | the probe resolved no module dependencies — they now come from Qt's own `mkspecs/modules/*.pri` |
| `duplicate symbol QPainter::translate` | MSVC exports the **inline** members of an exported class; our symbol table could not read a `.lib` and `symbolDefined()` fails OPEN, so every check built on it had silently stopped running |
| `undefined identifier __QWidget_vnames` | `clang_getCursorVisibility` answers *Invalid* for every class on MSVC; the equivalent question is `__declspec(dllimport)` |
| `OutOfMemoryError` from the GC | a member returning by value is `f(this, sret, …)` on MS x64 and `f(sret, this, …)` on SysV |
| segfault in `objectName()` | the same rule, missing from the wrapper emitter |
| `llvm-lib: Argument list too long` | a response file; Windows has a command-line length limit `ar` does not |
| `'?:*)' is not recognised as a command` | cmd.exe eats `\|` before sh sees it, single quotes and all |

### OPEN: `uicheck` — a layout margin that differs from QUiLoader, on Windows only

```
ours    pageGeneral|layout|QVBoxLayout|margins=9,9,9,9   |spacing=6|count=1|pw=pageGeneral:win=0
oracle  pageGeneral|layout|QVBoxLayout|margins=11,11,11,11|spacing=6|count=1|pw=pageGeneral:win=0
```

Both sides are measured the same way, on the same machine, under the same style — so this is a
real difference in the UI we build, not an instrument artefact. 11 is the style's margin for a
**window** and 9 for a child, and the page of a tab widget is created parentless on purpose
(see the note in `runtime/uic/uiform.d`) precisely so it gets the window default. On Linux the
two values coincide, which is why this never showed there. The open question is WHEN the margin
is resolved relative to when the page is parented.

The oracle's own `QUiLoader` warnings also land inside the dump on Windows
(`genLabel/Designer: Invalid QButtonGroup reference …`), which the harness should route away
before this can be compared cleanly.

### A BINDING TARGET BUILDS AND RUNS ON WINDOWS, THROUGH THE REGGAE GRAPH — 2026-08-21

```
./build.exe wraptest-ldc2     ->  wraptest OK      (exit 0)
```

Generated, compiled, archived, linked and executed by the same graph that runs on Linux. Nine
mechanics items, each found by getting one step further and each answered in one place rather than
at its call sites:

| | |
|---|---|
| pkg-config | 35 calls were six questions; a probe answers them from `QTDIR` where the tool is absent |
| derived spec | the build fills `cflags`/`libs` from the probe, and resolves `out_dir` and `qt_marker`, which moving the file broke |
| gen guard | watches the spec the generator is GIVEN, not the shipped one |
| `writeIfChanged` | creates its directory; graph construction writes before any target runs |
| `findTool` | `moc` is `moc.exe` — a present tool read as MISSING |
| `QT_INSTALL_LIBEXECS` | qtpaths/qmake are not on PATH; the probe is the last resort |
| path separators | both composers normalise, because `sh` eats backslashes |
| shell dialect | `posixCmd` wraps in `sh -c`; cmd.exe cannot be replaced via COMSPEC because D takes the shell from a compile-time constant |
| `-fPIC`, `ar`, `.o`, `-lstdc++` | `cxxPic`, `arCmd`, `objExt`, `cxxRuntimeLibs` — one name each |

And one finding that shaped the last of them: a path reggae substitutes is native and backslashed,
and **backslashes do not survive `executeShell → cmd.exe → sh` in any quoting** — `a\b\c` arrives
as `abc`, single-quoted, double-quoted and escaped alike. As an **argument** it arrives intact. So
`runOffscreen()` puts the binary in `$0` and keeps only the environment prefix in the command text.

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

---

# What actually happened

Written after the port was built and both matrices ran. The plan above was mostly right about the
*ABI*; almost every hour actually went somewhere else. What follows is the record, symptom first,
because in nearly every case the symptom named the wrong thing.

## The machine

    ssh <vm>                            MSYS/git-bash, no Visual Studio installed
    C:/Users/caetano/dside              the clone
    C:/Users/caetano/llvm/bin           clang++, lld-link, llvm-nm, llvm-lib
    C:/Qt/6.10.3/msvc2022_64            Qt6 x64            (aqtinstall)
    C:/Qt/5.15.2/msvc2019_64            Qt5 x64            (aqtinstall)
    C:/Python312                        the .sh gates need it

Qt's own `bin` is deliberately NOT on PATH: a dual-target build has two Qts, and only the target
knows which it needs. Everything that runs a Qt-linked program puts the right one there itself —
`run-exe.ps1`, `run-capture.ps1`, `psInline`, and `shGate` for the `sh` gates.

## The ABI, which the plan predicted correctly

| | Itanium (Linux) | MS x64 |
|---|---|---|
| member returning by value | `f(sret, this, …)` | **`f(this, sret, …)`** |
| inline member of an exported class | absent from the .so | **exported** — reimplementing it is a duplicate symbol |
| "this class is exported" | `clang_getCursorVisibility` == Default | `__declspec(dllimport)`; visibility answers **Invalid for every class** |
| `delete p` on a polymorphic type | dtor, then the CALLER's `operator delete` | vtable slot 0 (`??_G`); the free happens **inside the defining DLL** |

The sret ordering did not look like an ABI problem: the GC raised `OutOfMemoryError`, allocating an
array whose length came from uninitialised stack. The export question had to be answered in **three
separate places**, and the third one — the private-header filter in `emit.d` — silently dropped 38
`QQuick*` classes, which emptied `qmlmap.tsv`, which made `qmltc-d` skip every document, which
failed 57 targets with `root type 'Item' is not a bound Qt type`. Finding it took forcing the
*wrong* candidate to `true` and watching the count not move.

## What the plan did not predict, and what most of the work was

**`cmd.exe` is always in the middle.** reggae runs each command through `std.process.executeShell`,
which on Windows is `%COMSPEC% /C` — and modern D takes the shell from a compile-time constant, so
`COMSPEC` cannot redirect it. cmd then parses `|`, `&`, `>`, `<`, `^` and eats backslashes before
any inner shell sees the string. Concretely, over one night:

* four whole test families (`-render-`, `-time-`, `-key-`, `-click-`) handed `QT_QPA_PLATFORM=…
  prog | grep …` to cmd and got `'QT_QPA_PLATFORM' is not recognized`;
* `lupdate-check`'s `sed` pattern contains `><` and arrived mangled at any quoting;
* `expected-fails-lint` put `$in` — a native, backslashed path — in the command TEXT and cmd
  produced `C:Userscaetanodside.buildexpected-fails-lint-bin`;
* one `dirEntries` join left exactly one native separator in a path, and exactly one separator
  disappeared: `tests/qmltc/appATile.qml`.

The rule that came out of it: **paths go in arguments, never in command text**, and a step that
composes anything (a pipe, a redirect, a sequence) is written as a `.ps1` where cmd never sees it.

**A gate that cannot run says something else.** Three scripts had already decided what a silent
tool meant. `shadow-aot` reported *"the fixture must delegate"*, `optlevels` reported *"the ENGINE
dumps nothing — unjudgeable"*, and both times the diagnostics file held
`error while loading shared libraries: Qt6Core.dll`. There is no rpath on Windows. They now tell
"did not run" apart from "ran and found nothing" before concluding anything about the document.

**A gate keyed on a literal path DISAPPEARS.** `qtInstallQml()` probes `qmake6`/`qtpaths6` and falls
back to `/usr/lib/qt6/qml`. On Windows no probe is on PATH (by design, see above), so the fallback
answered with a directory that does not exist and every Controls-keyed gate emitted **no targets at
all** — the failure mode that function's own header warns about, happening in the one place nobody
had looked.

**MSYS rewrites arguments that look like paths.** `--shadow-url qrc:/qtdshadow/` reached the
compiler as `:C:/msys64/qtdshadow/`. `MSYS2_ARG_CONV_EXCL='*'` in `tests/shplatform.sh`, which also
holds the `-fPIC`-vs-MSVC answer.

## Two real defects the port found, both present on Linux

**`lupdate-d` had a use-after-free.** `unquote()` returned a slice of dparse's token text, and the
`StringCache` that owns it is a **local** of `extractD` — freed on return. Phobos's `replace`
returns its input unchanged when nothing matches, so the unescape did not launder it either. On
Linux the pages stay mapped and the `.ts` comes out correct for as long as nobody looks; on Windows
the sort that orders the messages read a pointer of `-26` and the process died with `0xC0000005`
*after* writing a correct file. With the debug heap disabled (`_NO_DEBUG_HEAP=1`, which is what made
it vanish under the debugger):

    lupdate_d!memcmp+0x30  <-  __cmp!char  <-  tsDoc.sort  <-  D main

**The compiled document's URL was string concatenation.** `"file://" + absoluteFilePath()` only
produces a valid URL where an absolute path begins with `/`. On Windows it makes `C:` the URL's
*authority*. Measured against the engine:

    engine   file:///C:/Users/…/QDeclObjType.qml
    ours     file://c/Users/…/QDeclObjType.qml

`QUrl::fromLocalFile` at all three sites. Anything resolving a relative URL inside a compiled
document (`source: "icon.png"`) was resolving it against that.

## The one thing that does not work, and why it is not a patch

`uicheck-dmd`. A D exception cannot unwind out of a clang-cl frame under **dmd on Win64**: dmd uses
`rt.deh_win64_posix` — DWARF-style exception tables, as the module name says — and a clang-cl frame
carries SEH unwind data and no DWARF LSDA. The unwinder cannot describe the frames between the
throw and the D handler, finds none, and druntime calls `terminate()` (exit `0xC0000096`, which is
`hlt`, which is what dmd emits for `assert(0)`). Measured with symbols under `cdb`:

    D2rt15deh_win64_posix9terminateFZv  <-  d_throwc  <-  qtd_throw_d  <-  qtd_test_throw
    __FrameHandler3::CxxCallCatchBlock  <-  qtd_test_throw  <-  D main

LDC is unaffected — on Windows it emits MSVC-compatible EH, so a D throw *is* an SEH exception and
composes with the C++ frames — and the ldc2 twin of every affected target proves the path. So
`uicheck` reports `EXCGAP` there and names the compiler that did prove it, rather than the matrix
going red for a limitation that is not ours.

Registered as `known_gap` **`cxx-exception-dmd-win64`**. Making it work means not unwinding through
C++ at all: the trampoline records and returns, the D side checks and throws. That is an ABI change
to every guarded call and a real piece of work, not a reshuffle of the `catch` — moving the raise
out of the catch block does not help, because the frames it must cross still have no DWARF data.

**On Windows, LDC is the supported compiler for exception translation.** Everything else works on
both.

## Coverage baselines are a pairing

The first time `manifest-gate` could run on Windows it reported 104 symbols DISAPPEARED — among
them `QNativeInterface::QX11Application` and `QAbstractItemView::keyboardSearchFlags` (Qt 6.11,
against a 6.10.3 install). Coverage is a property of *(platform, Qt)*; comparing across either axis
is a different question with no answer. A baseline now declares its pairing and a mismatch is
reported as **NOT COMPARABLE**. Generating Windows baselines is the remaining work to get the same
regression protection there.

## Verifying anything on Windows

**Read the target's OUTPUT, not its exit code.** That rule is here because a runner that could not
start any binary reported 13 of 13 targets passing: `&` cannot run an extensionless program, the
error is not terminating, and `exit $LASTEXITCODE` with `$null` exits zero. Everything goes through
`Invoke-Proc` (`tools/win/proc.ps1`) now, which uses `System.Diagnostics.Process` — CreateProcess
has no PATHEXT rule, and a process that cannot start is a failure that says so.

**A changed COMMAND does not rebuild anything** in reggae's binary backend. Fix the way a binary is
linked and the binary stays as it was, with the failure it caused. Delete the artefact before
measuring.

**Never edit a build input while the matrix runs.** `tools/test-report.sh` aborts and says so if
`./build` is rebuilt underneath it, because every row after that point describes the rebuild rather
than the target. That guard fired twice in one night, both times correctly, both times because of
an edit made while a run was in flight.

## Where the port stands, measured

Linux, twice on the same commit:

    # totals: 1199 pass, 0 fail, 0 skip

Windows, on that same commit: **1197 of the 1200 targets confirmed passing** — 1119 recorded by the
report before it was cut short, and 78 more run by hand afterwards, including all 58 `sample_*`
(the libsample corner-case suite, which did not exist on Windows at all until this round) and
`dub-consumer`, which builds an application OUTSIDE the checkout against the packaged binding.

Three are long meta-gates that could not be run to completion there. None of them is product code —
each is a battery that checks another gate, each passes on Linux, and each of the gates they check
passes individually on Windows:

| target | Linux | Windows |
|---|---|---|
| `license-package-mutations` | 289 s | killed at 2400 s |
| `expected-fails-run` | 776 s | not completed |
| `docs-numbers` | 339 s | not completed |

The reason is not a defect, it is I/O: `license-package-mutations` copies a 34 MB package and
re-hashes 800 files thirty-five times, and NTFS is far slower than ext4 at many-small-file work.

## Two harness problems this exposed, both measured

**A long run does not survive its shell.** `tools/test-report.sh` invokes `./build` once per target,
on purpose, so every row is an isolated verdict. Past a few thousand forks the MSYS emulated `fork`
stops working:

    [main] sh dofork: child -1 - forked process died unexpectedly,
           exit code 0xC0000142, errno 11        (STATUS_DLL_INIT_FAILED)
    tools/test-report.sh: fork: retry: Resource temporarily unavailable

That is why three full matrices ended at 1063, 1109 and 1120 rows with no totals line and nothing in
the error file. `autorebase.bat` helps and does not cure it.

**And `ps` does not see these processes.** MSYS's `ps` reported zero while `Get-Process` listed six
`build.exe` from six different hours — every run believed dead was alive, competing for the machine
and for the same `.build` directory. Observe Windows processes with PowerShell, never with `ps`.

**Both point at the same fix**, which is also the one that makes the matrix fast:

    1200 targets, 212 min, 10.6 s average — and a `./build` with NOTHING to do costs 7.9 s
    ./build -n <target>    7.6-8.0 s   the rerun check is not the cost
    ./build <5 targets>    7.6 s       five targets for the price of one

Batching is the whole win: twenty per invocation turns 160 minutes of startup into ~10 and cuts the
fork count by the same factor. What it costs is knowing which target in a failing batch failed —
recovered by re-running that batch one target at a time, which is cheap because failures are rare.

`reggae -b ninja` is not the shortcut it looks like: the ninja backend refuses this build's shape —
`Cannot have a custom rule with no $in or $out` — and almost every test here is a `Target.phony`
whose verdict is what it prints, not a file it writes. Sixty-seven sites would have to grow real
outputs, and a stamp file existing is not the same claim as a command having run.
