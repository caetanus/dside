# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# COMPILE A BINDING'S C++ SHIMS INTO ONE ARCHIVE — the PowerShell half of the shims step.
#
#   shims.ps1 -GenDir <dir> -ObjDir <dir> -Lib <path> -Cxx <flags> -Priv <flags>
#             -QmlEnabled yes|no -StubSuffix "" | "_stub" -ObjExt .obj -QmlFlag <file>
#
# The object directory is WIPED, not patched: `rm -f qtdmoc_qml*.o` left every other stale object
# in the glob, so a .cpp the generator stopped emitting kept its symbols in the archive for ever.
# The archive is rebuilt from exactly what this run compiled.
#
# THE QML UNIT lands under a different object name when the binding has no QtQml, compiled from the
# same source with QTD_ENABLE_QML undefined: its own `#else` bodies ARE the stubs, written by
# whoever wrote the function. Only the object NAME differs, which is what the composition canary
# reads.
param(
    [Parameter(Mandatory = $true)][string] $GenDir,
    [Parameter(Mandatory = $true)][string] $ObjDir,
    [Parameter(Mandatory = $true)][string] $Lib,
    [Parameter(Mandatory = $true)][string] $Cxx,
    [string] $Priv       = '',
    [Parameter(Mandatory = $true)][string] $QmlEnabled,
    [string] $StubSuffix = '',
    [string] $ObjExt     = '.obj',
    [Parameter(Mandatory = $true)][string] $QmlFlag
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# EVERY child goes through Invoke-Proc, never `&`. Two reasons, both measured: `&` cannot run a
# program with no file extension, and — the one that showed up only under the full matrix — when a
# native command writes to stderr, PowerShell renders it through the console host, and detached
# from a terminal that host has nothing to talk to:
#
#     Erro interno "Nao ha processo na outra ponta do pipe" … SetConsoleWindowTitle,shims.ps1
#
# It failed on exactly the targets whose compile produced WARNINGS, and passed on the ones whose
# shims were already cached and printed nothing.
. (Join-Path $PSScriptRoot 'proc.ps1')
$clang   = (Get-Command clang++ -ErrorAction Stop).Source
$llvmlib = (Get-Command llvm-lib -ErrorAction Stop).Source

if (Test-Path -LiteralPath $ObjDir) { Remove-Item -LiteralPath $ObjDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $ObjDir | Out-Null
if (Test-Path -LiteralPath $Lib) { Remove-Item -LiteralPath $Lib -Force }

# The build RECORDS its own decision, so the composition canary reads a fact instead of inferring
# one from the symbols in the archive.
Set-Content -LiteralPath $QmlFlag -Value $QmlEnabled -NoNewline:$false

# One flag string per side, split the way a command line would.
$cxxArgs  = $Cxx  -split '\s+' | Where-Object { $_ }
$privArgs = $Priv -split '\s+' | Where-Object { $_ }

foreach ($c in Get-ChildItem -LiteralPath $GenDir -Filter *.cpp -File) {
    $b = [System.IO.Path]::GetFileNameWithoutExtension($c.Name)
    if ($b -eq 'qtdmoc_qml') { $b = 'qtdmoc_qml' + $StubSuffix }
    $extra = if ($b -in @('qtdmoc', 'qtdmoc_qml', 'qtdmoc_qml_stub')) { $privArgs } else { @() }
    $obj = Join-Path $ObjDir ($b + $ObjExt)
    $rc = Invoke-Proc -Exe $clang -ProcArgs (@() + $cxxArgs + $extra + @('-c', $c.FullName, '-o', $obj))
    if ($rc -ne 0) { exit $rc }
}

$objs = Get-ChildItem -LiteralPath $ObjDir -Filter ("*" + $ObjExt) -File | ForEach-Object { $_.FullName }
if ($objs.Count -eq 0) { Write-Error "shims: nothing compiled from $GenDir" }

# A response file: Windows has a command-line length limit that `ar` on POSIX does not, and a
# binding names a few thousand objects — `llvm-lib: Argument list too long`.
$rsp = $Lib + '.rsp'
Set-Content -LiteralPath $rsp -Value $objs
exit (Invoke-Proc -Exe $llvmlib -ProcArgs @(("/OUT:" + $Lib), ("@" + $rsp)))
