# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# WHAT A WINDOWS MACHINE NEEDS BEFORE IT CAN RUN THIS BUILD, checked one item at a time and named
# with the command that supplies it.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/win/preflight.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/win/preflight.ps1 -Install
#
# This is a CHECKER first. Every item below was missing on the VM at some point, and each absence
# reported itself as something else entirely — `diffutils` missing made a differential gate say the
# outputs agreed, a missing DejaVu made a rendering comparison fail on font fallback, no Defender
# exclusion turned a 20-minute matrix into a 2-hour one. A list of prerequisites that is only in a
# person's memory is a machine that cannot be rebuilt.
#
# `-Install` does the two families that are idempotent and reversible: `pacman -S --needed` and
# `pip install`. Qt, LLVM, the D compilers and the Defender exclusions are NAMED, not performed —
# they place gigabytes or change a security policy, and that is the operator's call.
param([switch] $Install)

$ErrorActionPreference = 'Stop'
$script:missing = @()

function Need($what, $ok, $fix) {
    if ($ok) { Write-Output ("  ok    " + $what) }
    else {
        Write-Output ("  MISS  " + $what)
        Write-Output ("        -> " + $fix)
        $script:missing += $what
    }
}

$msys   = 'C:\msys64'
$pacman = Join-Path $msys 'usr\bin\pacman.exe'

Write-Output 'MSYS2 --------------------------------------------------------------------'
Need 'MSYS2 at C:\msys64' (Test-Path -LiteralPath $pacman) `
     'https://www.msys2.org/ — the gates are sh scripts and this is the sh'

if (Test-Path -LiteralPath $pacman) {
    # diffutils: NOT in the default install. Without it `diff` is absent and a gate that compares
    # two outputs reports the comparison it could not make as agreement.
    # tmux: not default either, and `screen` is not packaged at all. A long run needs to outlive
    # the session that started it — though tools/win/runreport.ps1 is the answer that does not
    # depend on a terminal multiplexer at all.
    foreach ($p in @('diffutils', 'tmux')) {
        $have = (& $pacman -Q $p 2>$null)
        if (-not $have -and $Install) {
            & $pacman -S --needed --noconfirm $p | Out-Null
            $have = (& $pacman -Q $p 2>$null)
        }
        Need ("pacman: " + $p) ([bool]$have) ("pacman -S --needed " + $p)
    }
    # ...AND WHAT MUST NOT BE THERE, or must at least not be on PATH first. MSYS ships its own
    # MinGW Qt6, and a `qmake6` from a Qt that is not the one QTDIR6 names is how one Qt's bindings
    # came to be judged against another Qt's Controls corpus. The build now prefers the named
    # prefix, so this is a warning rather than a failure — but a PATH that puts C:\msys64\mingw64\bin
    # in front of the toolchain will still hand Qt DLLs to a process expecting the MSVC build.
    if (Test-Path -LiteralPath (Join-Path $msys 'mingw64\bin\qmake6.exe')) {
        Write-Output '  warn  MSYS ships a MinGW Qt6 (mingw-w64-x86_64-qt6-base)'
        Write-Output '        -> keep C:\msys64\mingw64\bin OFF the build PATH; QTDIR6 is the Qt'
    }
}

Write-Output 'Toolchain ----------------------------------------------------------------'
$llvm = 'C:\Users\caetano\llvm\bin\clang++.exe'
Need 'clang++ (LLVM 19.x, MSVC target)' (Test-Path -LiteralPath $llvm) `
     'https://github.com/llvm/llvm-project/releases — needs llvm-lib and lld-link beside it'
foreach ($t in @('llvm-lib.exe', 'lld-link.exe')) {
    Need ("  " + $t) (Test-Path -LiteralPath (Join-Path (Split-Path $llvm) $t)) `
         'part of the same LLVM release; the archive step and the link step need them'
}
Need 'Visual Studio Build Tools (link.exe, the CRT and the SDK)' `
     (Test-Path 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC') `
     'the MSVC toolchain — ldc2 and dmd both link through it on this target'
Need 'ldc2' ([bool](Get-Command ldc2 -EA SilentlyContinue)) `
     'https://github.com/ldc-developers/ldc/releases (windows-x64)'
Need 'dmd'  ([bool](Get-Command dmd  -EA SilentlyContinue)) `
     'https://downloads.dlang.org/releases/2.x/ (windows .7z, use bin64)'

Write-Output 'Qt -----------------------------------------------------------------------'
$qt6 = ''
foreach ($pair in @(@('QTDIR6', 'C:/Qt/6.11.1/msvc2022_64'), @('QTDIR5', 'C:/Qt/5.15.2/msvc2019_64'))) {
    $var = $pair[0]; $def = $pair[1]
    $val = [Environment]::GetEnvironmentVariable($var)
    if (-not $val) { $val = $def }
    if ($var -eq 'QTDIR6') { $qt6 = $val }
    Need ($var + ' -> ' + $val) (Test-Path -LiteralPath $val) `
         ('tools/win/get-qt.ps1 -Version <x.y.z> — or set ' + $var + ' to an existing prefix')
}

Write-Output 'Python -------------------------------------------------------------------'
$py = 'C:\Python312\python.exe'
Need 'Python 3.12' (Test-Path -LiteralPath $py) 'https://www.python.org/downloads/windows/'
if (Test-Path -LiteralPath $py) {
    # sphinx builds the manual with warnings as errors (docs-sphinx); aqtinstall is how Qt got here.
    foreach ($m in @('sphinx', 'aqtinstall')) {
        $have = (& $py -m pip show $m 2>$null)
        if (-not $have -and $Install) {
            & $py -m pip install --quiet $m
            $have = (& $py -m pip show $m 2>$null)
        }
        Need ("pip: " + $m) ([bool]$have) ("C:\Python312\python.exe -m pip install " + $m)
    }
}

Write-Output 'Corpora and fixtures -----------------------------------------------------'
$pyside = 'C:\Users\caetano\pyside-setup'
Need 'pyside-setup checkout' (Test-Path -LiteralPath $pyside) `
     'git clone https://code.qt.io/pyside/pyside-setup — libsample builds from its test sources'
# IN THE Qt PREFIX, not in C:\Windows\Fonts. Qt ships no fonts any more and its offscreen platform
# reads `<prefix>/lib/fonts`; a machine with DejaVu installed system-wide and nothing in that
# directory answers
#     QFontDatabase: Cannot find font directory C:/Qt/6.11.1/msvc2022_64/lib/fonts.
# and the target fails on "the run was not silent". This check looked at the system directory and
# reported ok about a Qt that had no fonts at all - which is what a fresh install is.
$fontDir = Join-Path $qt6 'lib/fonts'
$fonts = Get-ChildItem $fontDir -Filter '*.ttf' -EA SilentlyContinue
Need ("fonts in " + $fontDir) ([bool]$fonts) `
     'copy DejaVu*.ttf there (https://dejavu-fonts.github.io/); Qt no longer ships fonts'

Write-Output 'Performance --------------------------------------------------------------'
# NOT correctness, but the difference between a matrix that finishes in an evening and one that
# does not: Defender scans every object file the build writes and every process it spawns.
$excl = @()
try { $excl = (Get-MpPreference).ExclusionPath } catch { }
foreach ($d in @('C:\Users\caetano\dside', 'C:\msys64', 'C:\Users\caetano\llvm')) {
    Need ('Defender exclusion: ' + $d) ($excl -contains $d) `
         ('Add-MpPreference -ExclusionPath "' + $d + '"   (elevated)')
}

Write-Output '--------------------------------------------------------------------------'
if ($script:missing.Count -eq 0) {
    Write-Output 'preflight: this machine has everything the build asks for'
    exit 0
}
Write-Output ('preflight: ' + $script:missing.Count + ' item(s) missing, listed above')
exit 1
