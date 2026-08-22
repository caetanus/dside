# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# RUN A BUILT BINARY, on Windows, without a POSIX shell.
#
# Invoked as
#
#   powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tools\win\run-exe.ps1 `
#       [-QtBin <dir>] [-Platform offscreen] [-Env NAME=VALUE ...] -Exe <path> [args...]
#
# WHY A FILE AND NOT `-Command`/`-EncodedCommand`. reggae substitutes $in/$out into the command
# TEXT at execution time, so anything we pre-encode is opaque to it — the path has to arrive as an
# ARGUMENT. `-EncodedCommand` refuses trailing arguments outright ("a command is already specified
# with -Command or -EncodedCommand"), and `-Command` does the same. `-File` is the one form that
# takes them, and measured through the real chain (D's executeShell -> cmd.exe -> powershell) an
# argument survives with its backslashes: `ARG:[.reggae\objs\y-bin]`.
#
# EXIT CODES, which everything else depends on. Measured through the same chain:
#   an explicit `exit 3`                                  -> 3
#   a child process failing, forwarded via $LASTEXITCODE  -> 7
#   a PowerShell error under $ErrorActionPreference=Stop  -> 1
param(
    [string]   $QtBin    = '',
    [string]   $Platform = '',
    [string[]] $Env      = @(),
    [Parameter(Mandatory = $true)][string] $Exe,
    [Parameter(ValueFromRemainingArguments = $true)][string[]] $Rest = @()
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # else PowerShell 5.1 writes a #< CLIXML banner to stderr

# Windows resolves a DLL through the executable's directory and then PATH — there is no rpath — so
# in a dual-target build a Qt5 binary otherwise finds Qt6's DLLs, or none, and dies before main
# with exit 127. Which Qt this binary needs is a property of the TARGET, so the caller says.
if ($QtBin) { $env:PATH = "$QtBin;$env:PATH" }
if ($Platform) { $env:QT_QPA_PLATFORM = $Platform }
foreach ($e in $Env) {
    $i = $e.IndexOf('=')
    if ($i -lt 1) { Write-Error "run-exe: -Env expects NAME=VALUE, got '$e'" }
    Set-Item -Path ("env:" + $e.Substring(0, $i)) -Value $e.Substring($i + 1)
}

# A relative path must be said to BE a path. PowerShell resolves a bare name against the command
# search path just as sh does, and `.reggae\objs\x-bin` is a bare name to both.
if (-not [System.IO.Path]::IsPathRooted($Exe)) { $Exe = Join-Path (Get-Location).Path $Exe }
if (-not (Test-Path -LiteralPath $Exe)) { Write-Error "run-exe: no such file: $Exe" }

if ($Rest.Count -gt 0) { & $Exe @Rest } else { & $Exe }
exit $LASTEXITCODE
