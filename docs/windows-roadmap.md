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

1. **MS x64 calling convention on the explicit-`self` shims.**
   The pattern `pragma(mangle,"…") extern(C++) Ret __Class_m(void* self, …)` assumes the
   SysV/Itanium convention (`this` = first pointer arg, and its sret handling). On **MS
   x64 the ordering of `this` and the by-value-return (`sret`) slot differs.** Re-prove
   `sret` + `const` + by-value member calls on ldc **and** dmd targeting
   `-windows-msvc` before relying on the shim pattern. If this doesn't hold, the emission
   strategy for member calls needs an MS-ABI variant — this is the highest risk.

2. **Archive-DCE without `--start-group`.**
   The linker's archive-member selection (which replaces the manual import-closure BFS —
   see the Linux proof: dmd linking the full webengine binding directly fails on an
   unreferenced inline symbol, but the same objects in an archive link clean) exists in
   link.exe / lld-link too, but circular refs (libbinding ↔ libshims ↔ Qt) are handled
   without a group: list the archive twice, or merge. Confirm the webengine-style
   unreferenced-inline case is still dropped. Likely yes (MSVC linkers do member
   selection), but this is the exact thing to validate.

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
