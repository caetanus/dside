# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# SERIALIZE A SHARED BUILD NODE, AND SKIP IT WHEN IT IS ALREADY DONE — the PowerShell half of
# guarded() in reggae/qtd_build.d, which on POSIX is `flock` plus `[ output -nt input ]`.
#
#   guard.ps1 -Lock <path> -Output <path> [-Newer a,b,c] -- <program> [args...]
#
# WHY IT EXISTS. reggae's binary backend can schedule a shared diamond node (many apps -> one
# binding's gen/shims/lib) more than once concurrently. Two overlapping `rm -rf … && rebuild` on
# the same output then truncate each other's files.
#
# THE LOCK is a named system mutex, not a lock FILE. A file-based lock has to answer "what if the
# holder died", and Windows answers that for a mutex already: the wait returns AbandonedMutexExcept
# ion and the waiter owns it. The name is derived from -Lock so it still reads as a path in the
# build, and `Global\` so it works across sessions.
param(
    [Parameter(Mandatory = $true)][string]   $Lock,
    [Parameter(Mandatory = $true)][string]   $Output,
    [string[]] $Newer = @(),
    [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)][string[]] $Command
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

if ($Command.Count -gt 0 -and $Command[0] -eq '--') { $Command = $Command[1..($Command.Count - 1)] }
if ($Command.Count -eq 0) { Write-Error "guard: nothing to run" }

# `Newer` arrives as one comma-joined argument (cmd.exe would split a bare list on spaces).
$inputs = @()
foreach ($n in $Newer) { $inputs += ($n -split ',' | Where-Object { $_ }) }

function Test-UpToDate {
    if ($inputs.Count -eq 0) { return $false }        # nothing to compare -> always run
    if (-not (Test-Path -LiteralPath $Output)) { return $false }
    $ot = (Get-Item -LiteralPath $Output).LastWriteTimeUtc
    foreach ($i in $inputs) {
        if (-not (Test-Path -LiteralPath $i)) { return $false }
        # STRICTLY newer, like `-nt`: equal timestamps mean "rebuilt in the same tick", and
        # treating that as up to date is how a stale artefact survives a fast machine.
        if ($ot -le (Get-Item -LiteralPath $i).LastWriteTimeUtc) { return $false }
    }
    return $true
}

if (Test-UpToDate) { exit 0 }

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Lock) | Out-Null
$name = 'Global\dside_' + [System.BitConverter]::ToString(
    [System.Security.Cryptography.MD5]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($Lock.ToLowerInvariant()))).Replace('-', '')

$mutex = New-Object System.Threading.Mutex($false, $name)
try {
    try { $null = $mutex.WaitOne() }
    catch [System.Threading.AbandonedMutexException] { }   # previous holder died; we own it now
    # Re-check under the lock: the run we queued behind may have been the one that produced this.
    if (Test-UpToDate) { exit 0 }
    # NOT $Command[1..($Command.Count-1)]: with a single element that range is 1..0, which
    # PowerShell reads as a DESCENDING range and hands back element 0 — the program would be
    # passed to itself as an argument.
    $exe  = $Command[0]
    $rest = if ($Command.Count -gt 1) { $Command[1 .. ($Command.Count - 1)] } else { @() }
    & $exe @rest
    exit $LASTEXITCODE
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
