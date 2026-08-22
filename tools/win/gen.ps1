# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# REGENERATE A BINDING — the PowerShell half of the gen step.
#
#   gen.ps1 -GenDir <dir> -Xiboca <exe> -Spec <spec.json> -Stamp <file> [-Quiet]
#
# xiboca fully owns GenDir, so it is wiped first: a file the generator stopped emitting must not
# survive into the next run, or its symbols stay in the archive for ever.
param(
    [Parameter(Mandatory = $true)][string] $GenDir,
    [Parameter(Mandatory = $true)][string] $Xiboca,
    [Parameter(Mandatory = $true)][string] $Spec,
    [Parameter(Mandatory = $true)][string] $Stamp,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

if (Test-Path -LiteralPath $GenDir) { Remove-Item -LiteralPath $GenDir -Recurse -Force }

if ($Quiet) { & $Xiboca $Spec *> $null } else { & $Xiboca $Spec > $null }
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Stamp) | Out-Null
# `touch`: create it, or move its timestamp forward if it is already there.
if (Test-Path -LiteralPath $Stamp) { (Get-Item -LiteralPath $Stamp).LastWriteTime = Get-Date }
else { New-Item -ItemType File -Path $Stamp | Out-Null }
