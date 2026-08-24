# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# BUILD libsample.a FROM SHIBOKEN'S TEST SOURCES — the PowerShell half of the libsample step.
#
#   libsample.ps1 -Src <libsample dir> -Min <libminimal dir> -Umbrella <sample_all.h>
#                 -Build <dir> -Lib <path> -Pic "<flag or empty>" -ObjExt .obj
#
# The sources are COPIED OUT of the pyside-setup checkout, because xiboca reads them through a
# `source_filter` pointing at this directory and the umbrella header has to sit beside them. The
# directory is wiped, not patched: a header that upstream removed must not survive into the next
# run and keep its symbols in the archive.
#
# `main.cpp` is skipped — it is the upstream test runner's own entry point and would give the
# archive a `main`.
param(
    [Parameter(Mandatory = $true)][string] $Src,
    [Parameter(Mandatory = $true)][string] $Min,
    [Parameter(Mandatory = $true)][string] $Umbrella,
    [Parameter(Mandatory = $true)][string] $Build,
    [Parameter(Mandatory = $true)][string] $Lib,
    [string] $Pic    = '',
    [string] $ObjExt = '.obj'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'proc.ps1')

if (Test-Path -LiteralPath $Build) { Remove-Item -LiteralPath $Build -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Build | Out-Null

Copy-Item -Path (Join-Path $Src '*.h')   -Destination $Build -Force
Copy-Item -Path (Join-Path $Src '*.cpp') -Destination $Build -Force
Copy-Item -LiteralPath (Join-Path $Min 'libminimalmacros.h') -Destination $Build -Force
Copy-Item -LiteralPath $Umbrella -Destination $Build -Force

# The one edit the sh half makes with `sed -i`: upstream reaches its sibling by relative path, and
# here the two headers are in the same directory. Read and written explicitly so the file keeps LF
# and no BOM — Set-Content would give it the ANSI code page and CRLF.
$macros = Join-Path $Build 'libsamplemacros.h'
$t = [System.IO.File]::ReadAllText($macros)
[System.IO.File]::WriteAllText($macros, $t.Replace('../libminimal/libminimalmacros.h',
                                                   'libminimalmacros.h'))

$clang = (Get-Command clang++ -ErrorAction Stop).Source
$picArgs = $Pic -split '\s+' | Where-Object { $_ }

Push-Location -LiteralPath $Build
try {
    foreach ($c in Get-ChildItem -LiteralPath $Build -Filter *.cpp -File) {
        if ($c.Name -eq 'main.cpp') { continue }
        $obj = [System.IO.Path]::GetFileNameWithoutExtension($c.Name) + $ObjExt
        # Upstream's own tests compile with warnings; the sh half sends them to /dev/null. -Capture
        # does the same, and Invoke-Proc still fails loudly if the compile itself fails.
        $rc = Invoke-Proc -Exe $clang -ProcArgs (@('-std=c++17') + $picArgs +
                  @('-DLIBSAMPLE_BUILD', '-I.', '-c', $c.Name, '-o', $obj)) -Capture
        if ($rc -ne 0) { Write-Output $script:ProcOut; exit $rc }
    }
    $objs = Get-ChildItem -LiteralPath $Build -Filter ("*" + $ObjExt) -File |
            ForEach-Object { $_.FullName }
    if ($objs.Count -eq 0) { Write-Output "libsample: nothing compiled from $Src"; exit 1 }

    # A response file, for the same reason shims.ps1 uses one: Windows has a command-line length
    # limit that `ar` on POSIX does not.
    $llvmlib = (Get-Command llvm-lib -ErrorAction Stop).Source
    if (Test-Path -LiteralPath $Lib) { Remove-Item -LiteralPath $Lib -Force }
    $rsp = $Lib + '.rsp'
    Set-Content -LiteralPath $rsp -Value $objs
    exit (Invoke-Proc -Exe $llvmlib -ProcArgs @(("/OUT:" + $Lib), ("@" + $rsp)))
}
finally { Pop-Location }
