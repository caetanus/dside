# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# COMPILE A BINDING'S D SOURCES INTO ONE ARCHIVE — the PowerShell half of the binding-lib step.
#
#   dlib.ps1 -GenDir <dir> -ObjDir <dir> -Lib <path> -Dc ldc2|dmd [-Oq] [-ObjExt .obj]
#
# Every .d under GenDir, compiled in one invocation with -I. from inside GenDir so module names
# resolve by directory. -oq (ldc2) keeps the fully-qualified module name in the object file, so two
# modules with the same basename in different packages do not overwrite each other.
param(
    [Parameter(Mandatory = $true)][string] $GenDir,
    [Parameter(Mandatory = $true)][string] $ObjDir,
    [Parameter(Mandatory = $true)][string] $Lib,
    [Parameter(Mandatory = $true)][string] $Dc,
    [switch] $Oq,
    [string] $ObjExt = '.obj'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

if (Test-Path -LiteralPath $ObjDir) { Remove-Item -LiteralPath $ObjDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $ObjDir | Out-Null

Push-Location -LiteralPath $GenDir
try {
    # Relative paths, as `find . -name "*.d"` gives on POSIX: the compiler derives module names
    # from them, and an absolute path here makes every module a root module.
    $srcs = Get-ChildItem -Recurse -Filter *.d -File |
            ForEach-Object { [System.IO.Path]::GetRelativePath((Get-Location).Path, $_.FullName) }
    if ($srcs.Count -eq 0) { Write-Error "dlib: no .d sources under $GenDir" }

    # A COMMAND-LINE LENGTH LIMIT applies here too — a binding is ~800 modules. Both ldc2 and dmd
    # read a response file with @, one argument per line.
    $rsp = Join-Path $ObjDir 'srcs.rsp'
    $args = @('-c')
    if ($Oq) { $args += '-oq' }
    $args += @("-od=$ObjDir", '-I.')
    Set-Content -LiteralPath $rsp -Value ($args + $srcs)
    & $Dc ("@" + $rsp)
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally { Pop-Location }

$objs = Get-ChildItem -LiteralPath $ObjDir -Filter ("*" + $ObjExt) -File | ForEach-Object { $_.FullName }
if ($objs.Count -eq 0) { Write-Error "dlib: nothing compiled from $GenDir" }
$rsp2 = $Lib + '.rsp'
Set-Content -LiteralPath $rsp2 -Value $objs
& llvm-lib ("/OUT:" + $Lib) ("@" + $rsp2)
exit $LASTEXITCODE
