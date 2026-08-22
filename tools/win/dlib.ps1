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
. (Join-Path $PSScriptRoot 'proc.ps1')   # every child through CreateProcess, see shims.ps1

if (Test-Path -LiteralPath $ObjDir) { Remove-Item -LiteralPath $ObjDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $ObjDir | Out-Null

Push-Location -LiteralPath $GenDir
try {
    # Relative paths, as `find . -name "*.d"` gives on POSIX: the compiler derives module names
    # from them, and an absolute path here makes every module a root module.
    # Resolve-Path -Relative, not [System.IO.Path]::GetRelativePath: that method arrived in
    # .NET Core 2.1 and PowerShell 5.1 runs on .NET Framework, where it does not exist —
    # `MethodNotFound,ForEachObjectCommand`.
    $srcs = Get-ChildItem -Recurse -Filter *.d -File |
            ForEach-Object { (Resolve-Path -LiteralPath $_.FullName -Relative) }
    if ($srcs.Count -eq 0) { Write-Error "dlib: no .d sources under $GenDir" }

    # A COMMAND-LINE LENGTH LIMIT applies here too — a binding is ~800 modules. Both ldc2 and dmd
    # read a response file with @, one argument per line.
    $rsp = Join-Path $ObjDir 'srcs.rsp'
    $args = @('-c')
    if ($Oq) { $args += '-oq' }
    $args += @("-od=$ObjDir", '-I.')
    Set-Content -LiteralPath $rsp -Value ($args + $srcs)
    $rc = Invoke-Proc -Exe (Get-Command $Dc -ErrorAction Stop).Source -ProcArgs @(("@" + $rsp))
    if ($rc -ne 0) { exit $rc }
} finally { Pop-Location }

$objs = Get-ChildItem -LiteralPath $ObjDir -Filter ("*" + $ObjExt) -File | ForEach-Object { $_.FullName }
if ($objs.Count -eq 0) { Write-Error "dlib: nothing compiled from $GenDir" }
$rsp2 = $Lib + '.rsp'
Set-Content -LiteralPath $rsp2 -Value $objs
exit (Invoke-Proc -Exe (Get-Command llvm-lib -ErrorAction Stop).Source `
                 -ProcArgs @(("/OUT:" + $Lib), ("@" + $rsp2)))
