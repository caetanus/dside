---
name: windows-build
description: Building and testing this project on Windows (MSVC ABI) — the VM, the two Qt installations, the environment a run needs, and the failure modes whose symptom never matches their cause. Use when a target fails on Windows, when adding a build step that must work there, or when touching xiboca's ABI decisions.
---

# The Windows side of this build

## The machine

    ssh caetano@192.168.0.128          # MSYS/git-bash shell, no Visual Studio installed
    /c/Users/caetano/dside             # the clone
    /c/Users/caetano/llvm/bin          # clang++, lld-link, llvm-nm, llvm-lib
    /c/Qt/6.10.3/msvc2022_64           # Qt6 x64
    /c/Qt/5.15.2/msvc2019_64           # Qt5 x64 (installed with aqtinstall, see below)
    /c/Python312                       # needed by the .sh gates

A run needs, and the last two matter:

    export PATH=/usr/bin:/c/Python312:/c/Users/caetano/llvm/bin:$PATH
    export QTDIR6=/c/Qt/6.10.3/msvc2022_64
    export QTDIR5=/c/Qt/5.15.2/msvc2019_64
    export QTDIR=$QTDIR6
    cd /c/Users/caetano/dside && ./build.exe <target>

Qt's own bin directories are deliberately NOT on PATH: each target puts its own Qt there when it
runs, because a dual-target build has two and only the target knows which it needs.

Installing another Qt: the online installer wants an interactive login; `aqt` pulls the same
official mirrors and takes under a minute.

    aqt install-qt windows desktop 5.15.2 win64_msvc2019_64      # run from C:\Qt

In Qt 5.15 `qtdeclarative`/`qttools` are part of the base package — passing them with `-m` fails.

## Everything the environment hands us is an MSYS path

`QTDIR=/c/Qt/…` and every entry of `PATH` are MSYS-form. clang++, lld-link and ldc2 are native
Windows programs that know nothing about `/c`, and **none of them says so**:

| Symptom | Cause |
|---|---|
| `fatal error: 'QString' file not found` | `-I/c/Qt/…` |
| `undefined symbol: QCoreApplication::QCoreApplication` | lld-link reads a leading `/` as an OPTION and silently ignores the library |
| a PATH scan finds nothing where the tool plainly is | `/c/Users/…/llvm/bin` |

`nativePath()` in `reggae/qtd_build.d` converts `/c/x` and `/cygdrive/c/x` to `C:/x`; `msysPath()`
goes back, for a value that has to live INSIDE a `PATH` list (where `:` is the separator, so a
drive letter is unparseable). MSYS also separates `PATH` with `:`, so only a piece that *starts* as
an MSYS path may be split on it — `C:/llvm/bin` split on `:` gives `C` and `/llvm/bin`.

Keep every path in a command in **forward slashes**. The one place that produced a native separator
was `modulePrivateFlags` (it comes from `dirEntries`), and the flag `-I…/QtQml\6.10.3` arrived as
`-I…/QtQml6.10.3`, so clang reported a private header "not found" that was plainly there.

## Asking Qt, without pkg-config

There is no pkg-config. `QtProbe` answers the six questions from `QTDIR5`/`QTDIR6` — and a module's
dependencies, include directory, library name and `-D` all come from Qt's own shipped metadata:

    <prefix>/mkspecs/modules/qt_lib_widgets.pri
      QT.widgets.name    = QtWidgets      the include directory
      QT.widgets.module  = Qt6Widgets     the library base name
      QT.widgets.depends =  core gui      what pkg-config's Requires: gives for free
      QT.widgets.DEFINES = QT_WIDGETS_LIB the define the headers are written against

Omitting the last one is invisible until something is guarded by it: `#ifdef QT_QML_LIB` skipped an
include and the file failed 600 lines later with `incomplete type 'QQmlProperty'`.

A spec's `qt_marker` describes a distribution layout (`/qt6/`, `/qt/`). Against `C:/Qt/5.15.2/…`
the case differs, every header is filtered out, and xiboca reports **`discovered 0 classes` and
exits 0**. The build replaces the marker with the prefix it resolved.

## The MSVC ABI is not the Itanium ABI

| | Itanium (Linux) | MS x64 |
|---|---|---|
| member returning by value | `f(sret, this, …)` | **`f(this, sret, …)`** |
| inline member of an exported class | absent from the .so | **exported** — reimplementing it is a duplicate symbol |
| "this class is exported" | `clang_getCursorVisibility` == Default | `__declspec(dllimport)`; visibility answers **Invalid for every class** |
| `delete p` on a polymorphic type | destructor, then the CALLER's `operator delete` | vtable slot 0 (`??_G`) with a deleting flag — the free happens **inside the defining DLL** |

The first one is measured in `tests/abi/windows/` and is why `needsSretShim()` routes such members
through a C++ shim (a free function has the same shape on both ABIs). It did not look like an ABI
problem: the GC raised `OutOfMemoryError`, allocating an array whose length came from uninitialised
stack.

The last one means a replaced global `operator delete` cannot observe a Qt object being freed —
`tests/wrapper/nonqobject.d` states that instead of asserting it.

Symbols the emitter names itself live in `abiSym()` in `xiboca/emit_cxx.d`, one entry per purpose.
**Read them from the library, never compute them**:

    llvm-nm --defined-only Qt5Core.lib | grep '??0QByteArray@@QEAA@PEBD'

## Toolchain differences the build already answers

`cxxPic()` (no `-fPIC`), `arCmd()` (llvm-lib with a response file — Windows has a command-line
length limit `ar` does not), `objExt()` (`.obj`), `cxxRuntimeLibs()` (no `-lstdc++`), `exeName()`
(`moc.exe`), and `-L/LIBPATH:` for libclang handed over as `DFLAGS` — **not** as `LIB`, which dmd's
`sc.ini` overwrites.

## Running a target

Commands go through PowerShell (`tools/win/*.ps1`); the gates stay `.sh`. Before writing or
debugging any of it, read the `powershell-commands` skill — several of its traps report success.

**Verify a Windows target by reading its OUTPUT, not its exit code.** That rule is here because a
runner that could not start any binary reported 13 of 13 passing.
