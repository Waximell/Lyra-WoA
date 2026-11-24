<#
.SYNOPSIS
    Packs a published Lyra bundle into a signed MSIX for Windows on ARM.

.DESCRIPTION
    The MSIX is deliberately "the loose bundle plus a package wrapper": the publish
    output is copied verbatim into the layout (single-file exe, lib\Windows\..., even
    the leftover .pdb files), an AppxManifest.xml is added, the app icon is expanded
    into the full tile/logo asset set - including the targetsize + unplated variants
    that the taskbar and Start menu look for - resources.pri is generated so the shell
    can resolve those variants, then makeappx packs and signtool signs.

    Needs the Windows SDK (makeappx.exe, makepri.exe, signtool.exe). No ARM64 machine
    is required: the package architecture is declared in the manifest, so this runs on
    any x64 machine/runner.

.PARAMETER PublishDir
    dotnet publish output (LyraViewer.exe, lib\Windows\...).

.PARAMETER OutFile
    Destination .msix path.

.PARAMETER CertPath
    PFX holding the code-signing key. Its Subject must equal -Publisher.

.PARAMETER CertPassword
    PFX password.

.PARAMETER Architecture
    ProcessorArchitecture written into the manifest: arm64 (default), x64 or x86.
    The publish output must already be built for that architecture.

.EXAMPLE
    ./ci/build-msix.ps1 -PublishDir out/publish -OutFile out/LyraViewer.msix `
        -CertPath signing.pfx -CertPassword $env:PFX_PASSWORD -Version 0.6.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PublishDir,
    [Parameter(Mandatory)][string]$OutFile,
    [Parameter(Mandatory)][string]$CertPath,
    [Parameter(Mandatory)][string]$CertPassword,
    [string]$Version = '0.6.0.0',
    [string]$Publisher = 'CN=Waximell, C=CN',
    [ValidateSet('arm64', 'x64', 'x86')][string]$Architecture = 'arm64',
    [string]$AppIcon = (Join-Path $PSScriptRoot '..\Lyra.Core\Resources\AppIcon.png'),
    [string]$ManifestTemplate = (Join-Path $PSScriptRoot '..\packaging\msix\AppxManifest.xml'),
    [string]$WorkDir
)

$ErrorActionPreference = 'Stop'

function Find-SdkTool {
    param([Parameter(Mandatory)][string]$Name)

    $roots = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'),
        (Join-Path $env:ProgramFiles 'Windows Kits\10\bin')
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $found = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'x64' } |
            Where-Object { Test-Path (Join-Path $_ "$Name.exe") } |
            Select-Object -First 1
        if ($found) { return (Join-Path $found "$Name.exe") }
    }

    $cmd = Get-Command "$Name.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    throw "$Name.exe not found - install the Windows SDK (MakeAppx/MakePri/SignTool)."
}

# ---------------------------------------------------------------------------
# Normalise inputs
# ---------------------------------------------------------------------------

$Version = ((($Version.Split('.') + @('0', '0', '0', '0'))[0..3]) -join '.')
if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    throw "Version must be four numeric parts, got '$Version'."
}

$PublishDir = [IO.Path]::GetFullPath($PublishDir, $PWD)
$OutFile = [IO.Path]::GetFullPath($OutFile, $PWD)
$CertPath = [IO.Path]::GetFullPath($CertPath, $PWD)
$AppIcon = [IO.Path]::GetFullPath($AppIcon, $PWD)
$ManifestTemplate = [IO.Path]::GetFullPath($ManifestTemplate, $PWD)

if (-not (Test-Path (Join-Path $PublishDir 'LyraViewer.exe'))) {
    throw "PublishDir '$PublishDir' does not contain LyraViewer.exe."
}
if (-not (Test-Path $AppIcon)) { throw "App icon '$AppIcon' not found." }
if (-not (Test-Path $ManifestTemplate)) { throw "Manifest template '$ManifestTemplate' not found." }
if (-not (Test-Path $CertPath)) { throw "Certificate '$CertPath' not found." }

$work = if ($WorkDir) { [IO.Path]::GetFullPath($WorkDir, $PWD) } else {
    [IO.Path]::GetFullPath((Join-Path $PWD 'out/msix-work'), $PWD)
}
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
$layout = Join-Path $work 'layout'
New-Item -ItemType Directory -Path $layout -Force | Out-Null

$makeappx = Find-SdkTool 'makeappx'
$makepri = Find-SdkTool 'makepri'
$signtool = Find-SdkTool 'signtool'

Write-Host "==> makeappx  : $makeappx"
Write-Host "==> makepri   : $makepri"
Write-Host "==> signtool  : $signtool"
Write-Host "==> version   : $Version"
Write-Host "==> publisher : $Publisher"

# ---------------------------------------------------------------------------
# 1. Layout = publish output, verbatim
# ---------------------------------------------------------------------------

Write-Host '==> copying publish output into the layout'
Copy-Item (Join-Path $PublishDir '*') $layout -Recurse -Force
$files = Get-ChildItem $layout -Recurse -File
'{0} files, {1:N1} MB' -f $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB) | Write-Host

# ---------------------------------------------------------------------------
# 2. Tile / logo assets from the project icon
# ---------------------------------------------------------------------------
#
# The shell needs more than a single 44x44 file:
#   - Square44x44Logo.targetsize-*.png            taskbar / small views
#   - ...targetsize-*_altform-unplated.png        taskbar, no plate behind the art
#   - scale-* variants                            Start menu, high DPI
# Without resources.pri (step 3) these are not resolved and Windows falls back to
# the generic executable icon.

Write-Host '==> generating tile assets from the app icon'
Add-Type -AssemblyName System.Drawing
$assets = Join-Path $layout 'Assets'
New-Item -ItemType Directory -Path $assets -Force | Out-Null

$source = [System.Drawing.Image]::FromFile($AppIcon)
try {
    # The project icon is a 256x256 rounded tile with ~9% transparent margin on
    # every side.  Cropping to the artwork is what makes the shell icons read as
    # "one size bigger": each asset is filled to 100% of its canvas afterwards,
    # nothing is scaled down to make room for padding.
    $srcBmp = [System.Drawing.Bitmap]$source
    $minX = $srcBmp.Width; $minY = $srcBmp.Height; $maxX = -1; $maxY = -1
    for ($y = 0; $y -lt $srcBmp.Height; $y++) {
        for ($x = 0; $x -lt $srcBmp.Width; $x++) {
            if ($srcBmp.GetPixel($x, $y).A -gt 8) {
                if ($x -lt $minX) { $minX = $x }
                if ($x -gt $maxX) { $maxX = $x }
                if ($y -lt $minY) { $minY = $y }
                if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }

    if ($maxX -lt 0) { throw "App icon '$AppIcon' is fully transparent." }

    $art = $srcBmp.Clone(
        [System.Drawing.Rectangle]::new($minX, $minY, ($maxX - $minX + 1), ($maxY - $minY + 1)),
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    Write-Host ("artwork: {0}x{1} cropped from {2}x{3}" -f $art.Width, $art.Height, $srcBmp.Width, $srcBmp.Height)

    function Save-Icon {
        param([int]$Width, [int]$Height, [string]$Path, [switch]$FitSquare)

        $bmp = [System.Drawing.Bitmap]::new($Width, $Height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            if ($FitSquare) {
                # Wide tile: square artwork at full height, centred, no shrink.
                $side = [Math]::Min($Width, $Height)
                $x = [int](($Width - $side) / 2)
                $y = [int](($Height - $side) / 2)
                $g.DrawImage($art, $x, $y, $side, $side)
            }
            else {
                $g.DrawImage($art, 0, 0, $Width, $Height)
            }
        }
        finally { $g.Dispose() }
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    }

    $square44 = @(
        @{ File = 'Square44x44Logo.png';           Size = 44 }
        @{ File = 'Square44x44Logo.scale-100.png'; Size = 44 }
        @{ File = 'Square44x44Logo.scale-125.png'; Size = 55 }
        @{ File = 'Square44x44Logo.scale-150.png'; Size = 66 }
        @{ File = 'Square44x44Logo.scale-200.png'; Size = 88 }
    )
    foreach ($item in $square44) {
        Save-Icon -Width $item.Size -Height $item.Size -Path (Join-Path $assets $item.File)
    }

    foreach ($size in 16, 24, 32, 48, 256) {
        Save-Icon -Width $size -Height $size -Path (Join-Path $assets ('Square44x44Logo.targetsize-{0}.png' -f $size))
        Save-Icon -Width $size -Height $size -Path (Join-Path $assets ('Square44x44Logo.targetsize-{0}_altform-unplated.png' -f $size))
    }

    $square150 = @(
        @{ File = 'Square150x150Logo.png';           Size = 150 }
        @{ File = 'Square150x150Logo.scale-100.png'; Size = 150 }
        @{ File = 'Square150x150Logo.scale-125.png'; Size = 188 }
        @{ File = 'Square150x150Logo.scale-150.png'; Size = 225 }
        @{ File = 'Square150x150Logo.scale-200.png'; Size = 300 }
    )
    foreach ($item in $square150) {
        Save-Icon -Width $item.Size -Height $item.Size -Path (Join-Path $assets $item.File)
    }

    $wide = @(
        @{ File = 'Wide310x150Logo.png';           Width = 310; Height = 150 }
        @{ File = 'Wide310x150Logo.scale-100.png'; Width = 310; Height = 150 }
        @{ File = 'Wide310x150Logo.scale-125.png'; Width = 388; Height = 188 }
        @{ File = 'Wide310x150Logo.scale-150.png'; Width = 465; Height = 225 }
        @{ File = 'Wide310x150Logo.scale-200.png'; Width = 620; Height = 300 }
    )
    foreach ($item in $wide) {
        Save-Icon -Width $item.Width -Height $item.Height -Path (Join-Path $assets $item.File) -FitSquare
    }

    $store = @(
        @{ File = 'StoreLogo.png';           Size = 50 }
        @{ File = 'StoreLogo.scale-100.png'; Size = 50 }
        @{ File = 'StoreLogo.scale-125.png'; Size = 63 }
        @{ File = 'StoreLogo.scale-150.png'; Size = 75 }
        @{ File = 'StoreLogo.scale-200.png'; Size = 100 }
    )
    foreach ($item in $store) {
        Save-Icon -Width $item.Size -Height $item.Size -Path (Join-Path $assets $item.File)
    }

    $art.Dispose()
}
finally { $source.Dispose() }

(Get-ChildItem $assets -File).Count | ForEach-Object { "$_ asset files generated" } | Write-Host

# ---------------------------------------------------------------------------
# 3. Manifest + resources.pri
# ---------------------------------------------------------------------------

Write-Host '==> writing AppxManifest.xml'
$manifest = (Get-Content $ManifestTemplate -Raw).
    Replace('__PUBLISHER__', $Publisher).
    Replace('__VERSION__', $Version).
    Replace('__ARCH__', $Architecture)
[IO.File]::WriteAllText((Join-Path $layout 'AppxManifest.xml'), $manifest, [Text.UTF8Encoding]::new($false))

Write-Host '==> generating resources.pri'
$priConfig = Join-Path $work 'priconfig.xml'
& $makepri createconfig /cf $priConfig /dq en-US /o | Out-Null
if ($LASTEXITCODE -ne 0) { throw "makepri createconfig failed ($LASTEXITCODE)" }
& $makepri new /pr $layout /cf $priConfig /of (Join-Path $layout 'resources.pri') /o | Out-Null
if ($LASTEXITCODE -ne 0) { throw "makepri new failed ($LASTEXITCODE)" }
if (-not (Test-Path (Join-Path $layout 'resources.pri'))) { throw 'resources.pri was not produced.' }

# ---------------------------------------------------------------------------
# 4. Pack + sign
# ---------------------------------------------------------------------------

$unsigned = Join-Path $work 'unsigned.msix'
Write-Host '==> makeappx pack'
& $makeappx pack /d $layout /p $unsigned /o
if ($LASTEXITCODE -ne 0) { throw "makeappx pack failed ($LASTEXITCODE)" }

Write-Host '==> signtool sign'
& $signtool sign /fd SHA256 /f $CertPath /p $CertPassword /tr 'http://timestamp.digicert.com' /td SHA256 $unsigned
if ($LASTEXITCODE -ne 0) { throw "signtool sign failed ($LASTEXITCODE)" }


# ---------------------------------------------------------------------------
# 5. Publish the artifact
# ---------------------------------------------------------------------------

$outDir = Split-Path $OutFile -Parent
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
Move-Item $unsigned $OutFile -Force

$info = Get-Item $OutFile
$hash = (Get-FileHash $OutFile -Algorithm SHA256).Hash
Write-Host ''
Write-Host ("MSIX   : {0}" -f $info.FullName)
Write-Host ("Size   : {0:N1} MB" -f ($info.Length / 1MB))
Write-Host ("SHA256 : {0}" -f $hash)
