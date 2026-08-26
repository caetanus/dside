# SPDX-FileCopyrightText: 2026 Marcelo A Caetano
# SPDX-License-Identifier: BSL-1.0
#
# FETCH A Qt RELEASE FROM Qt'S OWN REPOSITORY, because the tool that usually does it cannot.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/win/get-qt.ps1 `
#              -Version 6.11.1 -Dest C:/Qt
#
# `aqtinstall` 3.3.0 — the newest on PyPI — asks for
#     .../desktop/qt6_6111/qt6_6111/Updates.xml     -> 404
# because Qt SPLIT the per-release repository by architecture and the real path is
#     .../desktop/qt6_6111/qt6_6111_msvc2022_64/Updates.xml
# It reports the miss as "Failed to download checksum ... This may happen on unofficial mirrors",
# which reads like a network problem and is not one.
#
# The repository is an ordinary HTTP index, so this reads the same Updates.xml, resolves each
# package's archives, VERIFIES THE PUBLISHED sha256 and unpacks. It is not a general installer: it
# knows the module set this build needs and nothing else, which is the point — a machine rebuilt
# from it has exactly the Qt the matrix was measured against.
#
# Extraction is `python -m py7zr`. System32's tar.exe reads the 7-Zip CONTAINER and then says
#     tar.exe: LZMA codec is unsupported
# on the very first archive, which is every archive Qt publishes. py7zr is already on the machine
# as an aqtinstall dependency, and it is the same library aqt would have unpacked with.
param(
    [string]   $Version = "6.11.1",
    [string]   $Arch    = "win64_msvc2022_64",
    [string]   $Dest    = "C:/Qt",
    # qtbase, qtdeclarative, qtsvg, qttools and qttranslations all ship in the BASE package, so the
    # only names here are the separate addons this build actually references: Qt6WebChannel and
    # Qt6Positioning (WebEngine's dependencies) and Qt6ShaderTools. See the Qt6* grep in
    # reggaefile.d + generator/spec*.json — nothing else is asked for anywhere.
    [string[]] $Modules = @("qtwebchannel", "qtpositioning", "qtshadertools"),
    # WebEngine lives in a DIFFERENT repository (extensions/, not desktop/) and is the single
    # largest download here. `-SkipWebEngine` leaves it out; the webengine-* targets then have no
    # Qt6WebEngineCore to bind and disappear from the graph, which the matrix will show as missing
    # rows rather than as failures.
    #
    # A SWITCH, not a [bool]: invoked through `powershell -File`, every argument arrives as a
    # STRING, and `-WithWebEngine:$false` reached the parameter as the literal text `$false`:
    #     Nao e possivel converter o valor "System.String" no tipo "System.Boolean".
    # A switch has no value to convert.
    [switch]   $SkipWebEngine,
    [string]   $Base = "https://download.qt.io/online/qtsdkrepository/windows_x86",
    [string]   $Python = "C:/Python312/python.exe"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$v    = $Version -replace '\.', ''          # 6.11.1 -> 6111
$sfx  = $Arch -replace '^win64_', ''        # win64_msvc2022_64 -> msvc2022_64
# ASCII ONLY INSIDE CODE, comments aside: PowerShell reads a .ps1 with no BOM in the ANSI code
# page, and an em dash in a STRING literal came back as bytes that closed the quote early:
#     Token 'needed' inesperado na expressao ou instrucao.
# The other scripts here have kept their punctuation because theirs is all in comments.
if (-not (Test-Path -LiteralPath $Python)) { throw "get-qt: no $Python - py7zr unpacks the archives" }
& $Python -m py7zr --help *> $null
if ($LASTEXITCODE -ne 0) { throw "get-qt: $Python has no py7zr (pip install py7zr)" }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("qtdl-" + $v)
New-Item -ItemType Directory -Force -Path $tmp, $Dest | Out-Null

# One repository: read its Updates.xml, return a map of package name -> @{Version, Archives}.
function Get-Repo($url) {
    $xml = [xml](Invoke-WebRequest -Uri "$url/Updates.xml" -UseBasicParsing).Content
    $m = @{}
    foreach ($p in $xml.Updates.PackageUpdate) {
        if (-not $p.DownloadableArchives) { continue }
        $m[$p.Name] = @{
            Version  = $p.Version
            Archives = @($p.DownloadableArchives -split ',' | ForEach-Object { $_.Trim() } |
                         Where-Object { $_ })
        }
    }
    return $m
}

# ...and one package out of it, verified and unpacked. The published .sha256 is plain
# `sha256sum` format, so the comparison is the hash and nothing else.
function Get-Package($repo, $map, $name) {
    if (-not $map.ContainsKey($name)) { throw "get-qt: $name is not in this repository" }
    $pkg = $map[$name]
    foreach ($a in $pkg.Archives) {
        $url = "$repo/$name/$($pkg.Version)$a"
        $out = Join-Path $tmp $a
        if (-not (Test-Path -LiteralPath $out)) {
            Write-Output ("  fetch " + $a)
            Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
        }
        $want = ((Invoke-WebRequest -Uri "$url.sha256" -UseBasicParsing).Content -split '\s+')[0]
        $have = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLower()
        if ($want.ToLower() -ne $have) {
            Remove-Item -LiteralPath $out -Force
            throw "get-qt: sha256 mismatch for $a (published $want, got $have)"
        }
        Write-Output ("  unpack " + $a)
        # The archives carry `<version>/<arch>/…` at the top, so -Dest is C:/Qt and the release
        # lands beside the ones already there.
        & $Python -m py7zr x $out $Dest
        if ($LASTEXITCODE -ne 0) { throw "get-qt: py7zr failed on $a" }
    }
}

$desktop = "$Base/desktop/qt6_$v/qt6_${v}_$sfx"
Write-Output ("repository: " + $desktop)
$map = Get-Repo $desktop

Get-Package $desktop $map "qt.qt6.$v.$Arch"
foreach ($m in $Modules) { Get-Package $desktop $map "qt.qt6.$v.addons.$m.$Arch" }

if (-not $SkipWebEngine) {
    # A SEPARATE REPOSITORY, and it is not an oversight in Qt's layout: WebEngine ships under
    # extensions/ with its own versioning. Asking the desktop repo for it answers "not in this
    # repository", which is why this says so explicitly rather than silently skipping.
    $ext = "$Base/extensions/qtwebengine/$v/$sfx"
    Write-Output ("repository: " + $ext)
    Get-Package $ext (Get-Repo $ext) "extensions.qtwebengine.$v.$Arch"
}

$prefix = Join-Path $Dest ($Version + "/" + $sfx)
if (-not (Test-Path -LiteralPath (Join-Path $prefix "include/QtCore/qconfig.h"))) {
    throw "get-qt: unpacked, but $prefix has no include/QtCore/qconfig.h"
}
Write-Output ""
Write-Output ("get-qt: " + $Version + " is at " + $prefix)
Write-Output "  set QTDIR6 to it (tools/win/runreport.ps1 -Qt6 <prefix>) and re-run the preflight."
