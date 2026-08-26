# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# LAUNCH THE RECORD EXECUTION ON WINDOWS, so it outlives the ssh session that started it.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/win/runreport.ps1
#
# Three things this exists for, all of them measured on the VM rather than guessed:
#
# 1. `setsid nohup … &` FROM MSYS DOES NOT SURVIVE THE CONNECTION. Three full matrices died at
#    1063, 1109 and 1120 rows with nothing in the error file and no `# totals:` line — the shell
#    that started them was reaped with the ssh session, and a report that stops mid-list looks
#    exactly like one that finished. `Start-Process -NoNewWindow -PassThru` is a native process
#    with no parent shell to lose. (`tmux` also survives; see 2 for why it is not enough.)
#
# 2. AN ssh SESSION DOES NOT INHERIT THE USER'S ENVIRONMENT. Windows OpenSSH runs as a service, so
#    `QTDIR6`, `QTDIR5` and the toolchain directories set in the user's profile are simply absent.
#    A matrix launched from `bash -c` with only PATH fixed up produced a header reading
#        # Qt6= Qt5=none | caps: qmlcachegen= Qt6QmlCompiler=
#    and 137 failures out of 137 — a run whose every row described the missing environment. The
#    environment is therefore stated HERE, where the record execution begins, not in a profile that
#    the launcher may or may not see.
#
# 3. IT IS THE ONE FILE THAT SAYS WHAT THIS MACHINE IS. Every number in the report is a property of
#    (platform, Qt release, compiler release); the defaults below are the pairing the Windows
#    figures in docs/ were measured against. Override them on the command line when the machine
#    changes — and expect the baselines to move with them.
param(
    [string] $Repo    = $(if ($env:QTD_REPO) { $env:QTD_REPO } else { "C:/Users/caetano/dside" }),
    [string] $Tsv     = "C:/Users/caetano/win-report.tsv",
    [string] $Err     = "C:/Users/caetano/win-report.err",
    [string] $Qt6     = $(if ($env:QTDIR6) { $env:QTDIR6 } else { "C:/Qt/6.11.1/msvc2022_64" }),
    [string] $Qt5     = $(if ($env:QTDIR5) { $env:QTDIR5 } else { "C:/Qt/5.15.2/msvc2019_64" }),
    [string] $Timeout = "900",
    [string] $Batch   = "20",
    # A GLOB, for re-running the targets a fix was about without paying for 1200. The report takes
    # one as its first argument; the default runs everything, which is what a record execution is.
    [string] $Filter  = "*",
    # ...and `-Wait` for exactly that case: a subset finishes in minutes, so blocking and printing
    # the rows beats polling a file. A full matrix should never use it — see point 1 above.
    [switch] $Wait
)

$ErrorActionPreference = 'Stop'

# THE TOOLCHAIN, IN FRONT OF WHATEVER PATH THE SERVICE HANDED US. `C:\msys64\usr\bin` first
# because the gates are `sh` scripts; note that `C:\msys64\mingw64\bin` is deliberately NOT here.
# It carries MSYS's own MinGW Qt6, and a `qmake6` from a Qt that is not the one being built against
# is how `qmltc-optlevels-controls-Basic` came to be handed another Qt's Controls corpus.
$toolchain = @(
    "C:\msys64\usr\bin"
    "C:\Python312"
    "C:\Python312\Scripts"
    "C:\Users\caetano\llvm\bin"
    "C:\D\ldc2-1.42.0-windows-x64\bin"
    "C:\D\dmd2\windows\bin64"
) -join ';'
$env:PATH = $toolchain + ';' + $env:PATH

$env:QTDIR6 = $Qt6
$env:QTDIR5 = $Qt5
# QTDIR is what a single-Qt machine sets and several gates still read; point it at the 6 so a gate
# that asks the unsuffixed name gets the same installation as one that asks for 6.
$env:QTDIR   = $Qt6
$env:TARGET_TIMEOUT = $Timeout
$env:BATCH          = $Batch

foreach ($p in @($Repo, $Qt6, $Qt5)) {
    if (-not (Test-Path -LiteralPath $p)) { throw "runreport: $p does not exist" }
}

Set-Location -LiteralPath $Repo
foreach ($f in @($Tsv, $Err)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }

# `*` IS NOT PASSED, IT IS OMITTED — and the difference is a report that measures nothing. The
# MSYS runtime expands wildcards in the command line when an MSYS program is started by a native
# Windows process, so `sh.exe tools/test-report.sh *` reached the script as
#     tools/test-report.sh CONTRIBUTING.md LICENSE README.md …
# the filter became a filename, no target matched, and the run signed off `0 pass, 0 fail, 0 skip`
# with the commit and the Qt release in its header. The report now refuses an empty selection; this
# is the other half, and it is why the default filter is expressed by ABSENCE rather than by `*`.
$argv = @("tools/test-report.sh")
if ($Filter -ne "*") { $argv += $Filter }
$p = Start-Process -FilePath "C:/msys64/usr/bin/sh.exe" `
     -ArgumentList $argv `
     -RedirectStandardOutput $Tsv -RedirectStandardError $Err -NoNewWindow -PassThru
Write-Output ("pid=" + $p.Id + " tsv=" + $Tsv + " err=" + $Err)
if ($Wait) {
    $p.WaitForExit()
    Get-Content -LiteralPath $Tsv
    Get-Content -LiteralPath $Err | Select-Object -Last 20
}
# POLL THE ROW COUNT AND REQUIRE `# totals:`. A report without that line is a report that was
# killed, not one that passed — which is the whole reason point 1 above is written down.
