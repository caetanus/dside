---
name: powershell-commands
description: Writing PowerShell that a build runs on Windows — what Windows PowerShell 5.1 cannot do, how arguments and exit codes actually travel, and the traps that fail SILENTLY. Use when composing, debugging or reviewing any .ps1 this build emits or invokes, or when a Windows target "passes" without producing output.
---

# PowerShell for build commands

Everything here was measured on the machine, not read. Each entry says what the symptom looked
like, because none of them looks like its cause.

## The chain a command travels

reggae's binary backend runs each command through D's `std.process.executeShell`, which on Windows
is `%COMSPEC% /C <command>`. That cannot be redirected: modern D takes the shell from `nativeShell`,
a compile-time constant, so setting `COMSPEC` does nothing (`tools/win/shcomspec.d` records that
dead end). **cmd.exe is always in the middle**, whatever the inner shell is.

Consequences, all measured:

| In the command TEXT | What happens |
|---|---|
| `\|`, `&`, `>`, `<`, `^` | cmd parses them first. `case "$0" in /*\|?:*)` became a pipe: `'?:*)' is not recognised as an internal or external command`. |
| a backslash | does not survive in any quoting — `a\b\c` arrives as `abc`, single-quoted, double-quoted and escaped alike. |
| a backslash in an ARGUMENT | survives intact: `ARG:[a\b\c]`. |

So: **paths go in arguments, never in command text.** Inside a `.ps1` FILE none of this applies —
cmd never sees the file — so pipes and backslashes are free there.

## Getting a command to PowerShell

`-EncodedCommand` and `-Command` both **refuse trailing arguments**:

    Cannot process the command because a command is already specified with -Command or -EncodedCommand

`-File script.ps1 args…` is the only form that takes them. That matters because reggae substitutes
`$in`/`$out` into the command **text** at execution time, so anything encoded is opaque to it.

The rule that follows, and it is the design of `tools/win/*.ps1`:

* a value **known when the graph is built** may travel encoded (base64 of UTF-16LE);
* a value **reggae substitutes** must travel as a plain argument.

Do not hand a step's own parameters over as trailing arguments: PowerShell's parameter binder reads
them before the script does, matches them against the script's parameters *and the common ones*,
and dies with `AmbiguousParameter,<script>.ps1`. `ValueFromRemainingArguments` does not prevent it.

Do not guess name-versus-value from a leading dash either — the value of `-Cxx` is a flags string
starting with `-I…`, and the run said `Falta um argumento para o parâmetro 'Cxx'`.

## `& $exe` cannot run an extensionless binary — and says so by succeeding

The call operator resolves a program through `PATHEXT`. Binaries named `wraptest-ldc2-bin` or
`qmltc-d` (whatever `-of=` was given) are not found; the error is **not terminating**;
`$LASTEXITCODE` is never set; and `exit $LASTEXITCODE` with `$null` exits **zero**.

That reported a sweep of 13 targets as passing with nothing having run — the logs contained no
output from any of them — and gave a "captured" one-byte file from a tool that produces four
kilobytes by hand.

Always go through `tools/win/proc.ps1` (`Invoke-Proc`), which uses `System.Diagnostics.Process`:
CreateProcess has no PATHEXT rule, and a process that cannot start is a failure that says so.

## Windows PowerShell 5.1 is .NET Framework

`[System.Environment]::Version` → `4.0.30319`. Anything added in .NET Core is absent, and the
failure is `MethodNotFound` / a missing property, far from the cause:

* `[System.IO.Path]::GetRelativePath` — use `Resolve-Path -Relative`;
* `ProcessStartInfo.ArgumentList` — quote by hand the way `CommandLineToArgvW` un-quotes
  (backslashes are literal except before a quote, where they double; a quote takes one backslash).

5.1 also has **no `&&`** — that is PowerShell 7. A sequence is `Run`/`if ($rc -ne 0) { exit $rc }`:
PowerShell carries on after a native program fails.

## Writing files a POSIX run will be compared against

Never `>` and never `Set-Content`: 5.1 redirection writes **UTF-16**, `Set-Content` writes the
**ANSI code page**, and both write **CRLF**. Use

    [System.IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"))

which is UTF-8 without BOM and explicit LF — the same bytes the sh side produces.

## Two more that cost a run each

* `$a[1..($a.Count-1)]` with ONE element is a **descending** range and returns element 0 — a
  program gets passed to itself as an argument.
* 5.1 writes a `#< CLIXML` progress banner to **stderr** unless `$ProgressPreference =
  'SilentlyContinue'`. It lands inside gate output.

## Checklist for a new .ps1 here

1. `$ErrorActionPreference = 'Stop'`, `$ProgressPreference = 'SilentlyContinue'`.
2. Dot-source `proc.ps1` and run everything through `Invoke-Proc`.
3. Paths reggae substitutes → plain parameters. Everything else → encoded, or literals in the file.
4. Return the child's exit code, and fail loudly when nothing ran.
5. Verify by reading the target's OUTPUT, not its exit code.
