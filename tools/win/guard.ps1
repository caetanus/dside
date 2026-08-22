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
# holder died", and Windows answers that for a mutex already: the wait returns
# AbandonedMutexException and the waiter owns it. The name is derived from -Lock so it still reads
# as a path in the build.
#
# `Local\`, not `Global\`: a global name needs SeCreateGlobalPrivilege, which a detached session
# may not have, and the build's concurrency is one process tree anyway. Nothing was gained by
# asking for a privilege we do not need.
# THE INNER STEP ARRIVES BASE64-ENCODED, and that is not decoration. Handed over as trailing
# arguments it is the PowerShell parameter binder that reads them, not this script: `-NoProfile`
# and friends get matched against guard.ps1's own parameters and against the common ones, and the
# run died with `AmbiguousParameter,guard.ps1`. ValueFromRemainingArguments does not stop that —
# binding is attempted first.
#
# Encoding is safe here precisely because these steps have no reggae substitution in them: every
# path is known when the graph is built. A step that needs $in/$out must take it as an argument
# instead (see run-exe.ps1).
param(
    [Parameter(Mandatory = $true)][string] $Lock,
    [Parameter(Mandatory = $true)][string] $Output,
    [string] $Newer = '',
    [Parameter(Mandatory = $true)][string] $Payload
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$script = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($Payload))

# `Newer` arrives comma-joined: cmd.exe would split a bare list on spaces.
$inputs = @($Newer -split ',' | Where-Object { $_ })

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
$name = 'Local\dside_' + [System.BitConverter]::ToString(
    [System.Security.Cryptography.MD5]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($Lock.ToLowerInvariant()))).Replace('-', '')

# EVERY FAILURE IN HERE SAYS SOMETHING, on stdout. An error written to the error stream is
# rendered by the console host, and detached from a terminal that host has nothing to talk to — so
# the one run that failed here produced an empty log and a non-zero exit, which is the least useful
# pair of facts a build step can hand back.
trap {
    Write-Output ("guard: " + $_.Exception.GetType().Name + ": " + $_.Exception.Message)
    Write-Output ("guard: while running: " + $script.Substring(0, [Math]::Min(200, $script.Length)))
    exit 1
}

$mutex = New-Object System.Threading.Mutex($false, $name)
try {
    try { $null = $mutex.WaitOne() }
    catch [System.Threading.AbandonedMutexException] { }   # previous holder died; we own it now
    # Re-check under the lock: the run we queued behind may have been the one that produced this.
    if (Test-UpToDate) { exit 0 }
    $global:LASTEXITCODE = 0
    Invoke-Expression $script
    exit $LASTEXITCODE
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
