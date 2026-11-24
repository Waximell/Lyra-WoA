<#
.SYNOPSIS
    Bundles the per-architecture Lyra MSIX packages into one .msixbundle and signs it.

.DESCRIPTION
    MakeAppx generates the BundleManifest.xml itself from the packages in -MsixDir:
    every package must share Identity Name, Publisher and Version, and must already
    be signed - the bundle only wraps them, then gets its own signature.

    Windows picks the package that matches the machine architecture at install time,
    so one .msixbundle serves both x64 and ARM64.

.PARAMETER MsixDir
    Directory holding exactly the .msix files to bundle (one per architecture).

.PARAMETER OutFile
    Destination .msixbundle path.

.PARAMETER CertPath
    PFX holding the code-signing key. Same identity as the packages must be signed with.

.PARAMETER CertPassword
    PFX password.

.EXAMPLE
    ./ci/bundle-msix.ps1 -MsixDir out/msix -OutFile out/LyraViewer.msixbundle `
        -CertPath signing.pfx -CertPassword $env:PFX_PASSWORD
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MsixDir,
    [Parameter(Mandatory)][string]$OutFile,
    [Parameter(Mandatory)][string]$CertPath,
    [Parameter(Mandatory)][string]$CertPassword
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

    throw "$Name.exe not found - install the Windows SDK (MakeAppx/SignTool)."
}

$MsixDir = [IO.Path]::GetFullPath($MsixDir, $PWD)
$OutFile = [IO.Path]::GetFullPath($OutFile, $PWD)
$CertPath = [IO.Path]::GetFullPath($CertPath, $PWD)

if (-not (Test-Path $MsixDir)) { throw "MsixDir '$MsixDir' not found." }
if (-not (Test-Path $CertPath)) { throw "CertPath '$CertPath' not found." }

$packages = @(Get-ChildItem $MsixDir -Filter *.msix -File)
if ($packages.Count -lt 2) {
    throw "Need at least two .msix packages to bundle, found $($packages.Count) in '$MsixDir'."
}
Write-Host "==> bundling $($packages.Count) package(s):"
$packages | ForEach-Object { '    {0,-40} {1,8:N2} MB' -f $_.Name, ($_.Length / 1MB) }

$makeappx = Find-SdkTool 'makeappx'
$signtool = Find-SdkTool 'signtool'

$outDir = Split-Path -Parent $OutFile
if ($outDir) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
if (Test-Path $OutFile) { Remove-Item $OutFile -Force }

Write-Host '==> makeappx bundle'
& $makeappx bundle /d $MsixDir /p $OutFile /o
if ($LASTEXITCODE -ne 0) { throw "makeappx bundle failed ($LASTEXITCODE)" }
if (-not (Test-Path $OutFile)) { throw 'makeappx bundle produced no output.' }

Write-Host '==> signtool sign'
& $signtool sign /fd SHA256 /f $CertPath /p $CertPassword `
    /tr 'http://timestamp.digicert.com' /td SHA256 $OutFile
if ($LASTEXITCODE -ne 0) { throw "signtool sign failed ($LASTEXITCODE)" }

$bundle = Get-Item $OutFile
'bundle: {0} ({1:N2} MB)' -f $bundle.Name, ($bundle.Length / 1MB)
'SHA256: {0}' -f (Get-FileHash $OutFile -Algorithm SHA256).Hash
