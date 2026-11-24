<#
.SYNOPSIS
    Pulls the three prebuilt native DLLs that come from NuGet (SDL3, SkiaSharp, HarfBuzz)
    for a given RID and drops them into the native staging directory.

.DESCRIPTION
    Lyra.Core.csproj references SkiaSharp.NativeAssets.Linux (so Linux builds work) but no
    Windows/arm64 native assets, and SDL3-CS.Native is deprecated but does ship
    runtimes/win-arm64/native/SDL3.dll. Rather than editing the project file, this script
    restores the project, reads the exact package versions that restore resolved, and then
    restores a throwaway project referencing the matching *.NativeAssets.Win32 packages.

    Versions are resolved, never guessed, so HarfBuzzSharp's native DLL always matches the
    managed HarfBuzzSharp.dll that SkiaSharp pulled in.
#>
[CmdletBinding()]
param(
    [string]$OutDir   = 'release/native/dist-windows',
    [string]$Rid      = 'win-arm64',
    [string]$Project  = 'Lyra.Core/Lyra.Core.csproj',
    [switch]$SkipRestore
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

function Write-Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Fail([string]$m) { Write-Host "::error::$m"; throw $m }

$out = Join-Path $repo $OutDir
New-Item -ItemType Directory -Path $out -Force | Out-Null
$packages = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $env:USERPROFILE '.nuget\packages' }

if (-not $SkipRestore) {
    Write-Step "dotnet restore $Project -r $Rid"
    dotnet restore $Project -r $Rid
    if ($LASTEXITCODE -ne 0) { Fail "restore failed for $Project ($Rid)" }
}

$assetsPath = Join-Path (Split-Path -Parent $Project) 'obj\project.assets.json'
if (-not (Test-Path $assetsPath)) { Fail "no project.assets.json at $assetsPath" }
$assets = Get-Content $assetsPath -Raw | ConvertFrom-Json

function Get-ResolvedVersion([string]$packageId) {
    $hit = $assets.libraries.PSObject.Properties |
        Where-Object { $_.Name -like "$packageId/*" } |
        Select-Object -First 1
    if (-not $hit) { return $null }
    return ($hit.Name -split '/')[1]
}

$skiaVer = Get-ResolvedVersion 'SkiaSharp'
$hbVer   = Get-ResolvedVersion 'HarfBuzzSharp'
$sdlVer  = Get-ResolvedVersion 'SDL3-CS.Native'
Write-Host "resolved: SkiaSharp=$skiaVer  HarfBuzzSharp=$hbVer  SDL3-CS.Native=$sdlVer"
if (-not $skiaVer) { Fail 'SkiaSharp version not found in project.assets.json' }

# --- native asset packages that the project does not reference -----------------
$probeDir = Join-Path ([IO.Path]::GetTempPath()) ("lyra-natives-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
$refs = @("    <PackageReference Include=`"SkiaSharp.NativeAssets.Win32`" Version=`"$skiaVer`" />")
if ($hbVer) { $refs += "    <PackageReference Include=`"HarfBuzzSharp.NativeAssets.Win32`" Version=`"$hbVer`" />" }
$probeProject = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
  </PropertyGroup>
  <ItemGroup>
$($refs -join "`n")
  </ItemGroup>
</Project>
"@
$probeFile = Join-Path $probeDir 'probe.csproj'
Set-Content $probeFile $probeProject -Encoding utf8

Write-Step "restoring probe project for $Rid native assets"
dotnet restore $probeFile -r $Rid --packages $probeDir\pkgs
if ($LASTEXITCODE -ne 0) {
    Fail "could not restore SkiaSharp.NativeAssets.Win32 $skiaVer / HarfBuzzSharp.NativeAssets.Win32 $hbVer for $Rid"
}

$probePkgs = Join-Path $probeDir 'pkgs'
function Copy-RidNatives([string]$baseDir, [string]$label) {
    $src = Join-Path $baseDir "runtimes\$Rid\native"
    if (-not (Test-Path $src)) {
        $avail = @()
        $runtimes = Join-Path $baseDir 'runtimes'
        if (Test-Path $runtimes) { $avail = (Get-ChildItem $runtimes -Directory).Name }
        Fail "$label does not ship runtimes/$Rid/native (available RIDs: $($avail -join ', '))"
    }
    foreach ($f in Get-ChildItem $src -File -Filter *.dll) {
        Copy-Item $f.FullName (Join-Path $out $f.Name) -Force
        "{0,-28} <- {1}" -f $f.Name, $label | Write-Host
    }
}

# Restoring with -r <rid> drags in whole runtime packs (Microsoft.NETCore.App.Runtime.*,
# WPF/DIASymReader natives, 90 MB pdb files...). Only these two packages may contribute.
$wantPackages = @('skiasharp.nativeassets.win32', 'harfbuzzsharp.nativeassets.win32')

# NuGet's --packages layout is <id>/<version>/, so the runtimes folder sits two levels down.
$found = 0
foreach ($idDir in Get-ChildItem $probePkgs -Directory) {
    if ($wantPackages -notcontains $idDir.Name.ToLower()) {
        Write-Host "  skip package $($idDir.Name)"
        continue
    }
    foreach ($verDir in Get-ChildItem $idDir.FullName -Directory) {
        if (-not (Test-Path (Join-Path $verDir.FullName 'runtimes'))) { continue }
        Copy-RidNatives $verDir.FullName "$($idDir.Name)/$($verDir.Name)"
        $found++
    }
}
if ($found -eq 0) {
    $listing = Get-ChildItem $probePkgs -Directory | ForEach-Object {
        "$($_.Name)[$((Get-ChildItem $_.FullName -Directory).Name -join ',')]"
    }
    Fail "no package under $probePkgs carried runtimes/ (found: $($listing -join ' '))"
}

# --- SDL3 straight out of the restored package --------------------------------
if ($sdlVer) {
    $sdlBase = Join-Path $packages "sdl3-cs.native\$sdlVer"
    if (Test-Path $sdlBase) { Copy-RidNatives $sdlBase 'sdl3-cs.native' }
    else { Write-Warning "SDL3-CS.Native $sdlVer not in $packages" }
} else {
    Write-Warning 'SDL3-CS.Native not found in assets; SDL3.dll must come from publish output'
}

Remove-Item $probeDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Step "dist now contains"
Get-ChildItem $out -File | Sort-Object Name | ForEach-Object { '{0,-28} {1,8:N2} MB' -f $_.Name, ($_.Length / 1MB) }

$required = @('SDL3.dll','libSkiaSharp.dll','libHarfBuzzSharp.dll')
$missing = $required | Where-Object { -not (Test-Path (Join-Path $out $_)) }
if ($missing) { Fail "missing NuGet-provided natives: $($missing -join ', ')" }
Write-Host 'OK: NuGet natives staged' -ForegroundColor Green
