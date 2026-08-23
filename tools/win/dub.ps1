# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# BUILD A DUB PACKAGE — the PowerShell half of the xiboca step.
#
#   dub.ps1 -Dir <package dir> [-DFlags "<flags>"]
#
# The sh half is `cd <dir> && DFLAGS="…" dub build --quiet`. Both halves say the same thing; the
# difference is only that here the variable is set in the process environment instead of by a shell
# that is not present.
#
# DFLAGS, not LIB: dmd's own sc.ini sets LIB and overwrites whatever the caller exported, so the
# libclang import library was invisible and the link failed with LNK1104.
param(
    [Parameter(Mandatory = $true)][string] $Dir,
    [string] $DFlags = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'proc.ps1')

if ($DFlags) { $env:DFLAGS = $DFlags }

# Invoke-Proc rather than `&`: dub writes its compiler's warnings to stderr, and PowerShell renders
# native stderr through a console host that does not exist when the build runs detached.
# It starts the child in the CURRENT directory, so `cd <dir>` is said the way PowerShell says it.
$dub = (Get-Command dub -ErrorAction Stop).Source
Push-Location -LiteralPath $Dir
try { exit (Invoke-Proc -Exe $dub -ProcArgs @('build', '--quiet')) }
finally { Pop-Location }
