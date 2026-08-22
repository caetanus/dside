# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# START A PROCESS THAT MAY HAVE NO FILE EXTENSION — dot-sourced by the other tools/win scripts.
#
# THIS FILE EXISTS BECAUSE `& $exe` LIED. PowerShell's call operator resolves a program the way a
# command name resolves: through PATHEXT. The binaries this build produces are named `wraptest-ldc2
# -bin`, `qmltc-d` — no extension, because that is what `-of=` was given — so `&` does not find
# them. It is not a terminating error, `$LASTEXITCODE` is never set, and `exit $LASTEXITCODE` with
# $null exits ZERO. A whole sweep of targets reported OK with nothing having run: the logs had no
# output from any of them.
#
# CreateProcess has no such rule, and neither does the .NET wrapper over it. So every run goes
# through this, and a process that could not be started is a failure that says so.
#
# Invoke-Proc returns the exit code; with -Capture it also fills $script:ProcOut with stdout lines.
function Quote-Arg {
    param([string] $a)
    if ($a -ne '' -and $a -notmatch '[\s"]') { return $a }
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.Append('"')
    $bs = 0
    foreach ($ch in $a.ToCharArray()) {
        if ($ch -eq '\') { $bs++; continue }
        if ($ch -eq '"') { $null = $sb.Append('\' * (2 * $bs + 1)); $bs = 0 }
        else             { $null = $sb.Append('\' * $bs);           $bs = 0 }
        $null = $sb.Append($ch)
    }
    $null = $sb.Append('\' * (2 * $bs))
    $null = $sb.Append('"')
    return $sb.ToString()
}

function Invoke-Proc {
    param(
        [Parameter(Mandatory = $true)][string] $Exe,
        [string[]] $ProcArgs = @(),
        [switch]   $Capture
    )

    if (-not [System.IO.Path]::IsPathRooted($Exe)) { $Exe = Join-Path (Get-Location).Path $Exe }
    # Write-Output, not Write-Error. The error stream is rendered by the console host, and
    # detached from a terminal that host has nothing to talk to — so the diagnosis disappears
    # exactly when it is needed, leaving an empty log and a non-zero exit. stdout is a plain pipe.
    if (-not (Test-Path -LiteralPath $Exe)) { Write-Output "proc: no such file: $Exe"; exit 127 }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $Exe
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = [bool]$Capture
    $psi.WorkingDirectory       = (Get-Location).Path
    # ProcessStartInfo.ArgumentList is .NET Core 2.1; this is .NET Framework 4.0.30319 (measured,
    # not assumed — the same trap as GetRelativePath). So the arguments are quoted by hand, the way
    # CommandLineToArgvW un-quotes them: backslashes are literal EXCEPT before a quote, where they
    # double, and a quote is escaped with one backslash.
    $psi.Arguments = ($ProcArgs | ForEach-Object { Quote-Arg $_ }) -join ' '

    try { $p = [System.Diagnostics.Process]::Start($psi) }
    catch { Write-Output ("proc: could not start " + $Exe + ": " + $_.Exception.Message); exit 126 }
    if (-not $p) { Write-Output "proc: could not start: $Exe"; exit 126 }
    # Read BEFORE waiting: a child that fills the pipe blocks for ever if nobody drains it.
    if ($Capture) { $script:ProcOut = $p.StandardOutput.ReadToEnd() -split "`r?`n" }
    $p.WaitForExit()
    return $p.ExitCode
}
