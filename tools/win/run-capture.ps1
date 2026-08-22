# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# RUN A PROGRAM AND CAPTURE ITS STDOUT INTO A FILE — `prog args > out` for a step whose output path
# reggae substitutes.
#
#   run-capture.ps1 -Exe <path> -Out <file> -ArgsB64 <base64> [-Ok 0,3] [-Sort] [-QtBin <dir>]
#
# THE ARGUMENTS ARRIVE ENCODED and the OUTPUT PATH does not, and that split is the whole design:
# reggae substitutes $out into the command TEXT, so it must be a plain argument; while the tool's
# own arguments cannot be plain ones, because PowerShell's parameter binder reads them before this
# script does and dies with AmbiguousParameter. The arguments are known when the graph is built,
# the output path is not — so each travels the only way it can.
#
# `-Ok` lists the exit codes that count as success. Exit 3 from qmltc-d means "partial": members
# were skipped and reported, which is failure for a fixture except where the REFUSAL is the thing
# under test.
param(
    [Parameter(Mandatory = $true)][string] $Exe,
    [Parameter(Mandatory = $true)][string] $Out,
    [string] $ArgsB64 = '',
    [string] $Ok      = '0',
    [string] $QtBin   = '',
    [switch] $Sort
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$env:QT_QPA_PLATFORM   = 'offscreen'

if ($QtBin) { $env:PATH = "$QtBin;$env:PATH" }

$argv = @()
if ($ArgsB64) {
    $txt = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($ArgsB64))
    $argv = @($txt -split "`n" | Where-Object { $_ -ne '' })
}

if (-not [System.IO.Path]::IsPathRooted($Exe)) { $Exe = Join-Path (Get-Location).Path $Exe }

$lines = if ($argv.Count -gt 0) { & $Exe @argv 2>$null } else { & $Exe 2>$null }
$code  = $LASTEXITCODE
if ($Sort) { $lines = $lines | Sort-Object }

# Written before the verdict, exactly as `prog > out; rc=$?` does: the file is the evidence even
# when the run failed, and a gate that compares it must see what was produced.
#
# WriteAllText with explicit LF, not `>` or Set-Content: 5.1 redirection writes UTF-16 and
# Set-Content writes the ANSI code page, both with CRLF, and these files are read back by our own
# tools and compared against what a POSIX run produces.
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null
[System.IO.File]::WriteAllText($Out, (($lines -join "`n") + "`n"))

$okCodes = @($Ok -split ',' | ForEach-Object { [int]$_ })
if ($okCodes -notcontains $code) { exit $code }
exit 0
