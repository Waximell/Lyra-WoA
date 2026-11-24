<#
.SYNOPSIS
    Builds the nine? no - the five C++ wrapper DLLs Lyra needs on Windows, plus every
    dependency DLL they link against, into release/native/dist-windows/.

.DESCRIPTION
    Steps:
      1. locate (or bootstrap) vcpkg
      2. vcpkg install the third-party libraries (single Release build)
      3. fetch the Binomial basis_universal transcoder sources (gitignored subdir)
      4. cmake configure + build native/{Basis,Jxl,OpenEXR,OpenJPEG,TIFF}Wrapper
      5. rename <name>_native.dll -> lib<name>_native.dll (the names NativeLibraryLoader
         looks for) and copy the vcpkg runtime DLLs alongside them

    The output directory is consumed by the "app" job, which drops it into
    <publish>/lib/Windows.
#>
[CmdletBinding()]
param(
    [string]$Triplet   = 'arm64-windows-release',
    [string]$Arch      = 'ARM64',
    [string]$OutDir    = 'release/native/dist-windows',
    [string]$VcpkgRoot = '',
    [switch]$SkipVcpkgInstall
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# repo root = parent of ci/
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

# The five wrapper targets, and the file name Lyra.Core's NativeLibraryLoader expects.
$wrappers = [ordered]@{
    'BasisWrapper'   = @{ Target = 'basis_native'; Out = 'libbasis_native.dll'  }
    'JxlWrapper'     = @{ Target = 'jxl_native';   Out = 'libjxl_native.dll'    }
    'OpenEXRWrapper' = @{ Target = 'exr_native';   Out = 'libexr_native.dll'    }
    'OpenJPEGWrapper'= @{ Target = 'j2k_native';   Out = 'libj2k_native.dll'    }
    'TIFFWrapper'    = @{ Target = 'tiff_native';  Out = 'libtiff_native.dll'   }
}

# Ports needed by the wrappers, plus libheif with only the codecs we can redistribute
# cheaply (HEVC decode via libde265, AV1 decode/encode via aom). x265 is deliberately
# left out: it is an *encoder* (GPL) and nothing in Lyra encodes HEIF.
$ports = @(
    'zstd'
    'openjpeg'
    'tiff'
    'openexr'
    'libjxl'
    'aom'
    'libde265'
    'libheif[aom,libde265]'
)

function Write-Step([string]$msg) {
    Write-Host ''
    Write-Host "==> $msg" -ForegroundColor Cyan
}

# ------------------------------------------------------- 0. toolchain report ---
Write-Step 'toolchain'
Write-Host "PROCESSOR_ARCHITECTURE: $env:PROCESSOR_ARCHITECTURE"
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vswhere) {
    & $vswhere -all -products * -format json |
        ConvertFrom-Json |
        ForEach-Object { '  VS {0} {1} -> {2}' -f $_.installationVersion, $_.displayName, $_.installationPath }
} else {
    Write-Host "  vswhere not found at $vswhere"
}
cmake --version | Select-Object -First 1
Write-Host 'NOTE: the generator is not pinned - CMake picks the newest Visual Studio'
Write-Host '      instance (the windows-11-arm label moved from VS 17 2022 to VS 18 2026).'

# ---------------------------------------------------------------- 1. vcpkg -----
Write-Step 'locating vcpkg'
if (-not $VcpkgRoot) { $VcpkgRoot = $env:VCPKG_INSTALLATION_ROOT }
if (-not $VcpkgRoot -or -not (Test-Path (Join-Path $VcpkgRoot 'vcpkg.exe'))) {
    $VcpkgRoot = @('C:\vcpkg', (Join-Path $repo '.vcpkg')) |
        Where-Object { Test-Path (Join-Path $_ 'vcpkg.exe') } |
        Select-Object -First 1
}
if (-not $VcpkgRoot) {
    $VcpkgRoot = Join-Path $repo '.vcpkg'
    Write-Host "bootstrapping vcpkg into $VcpkgRoot"
    git clone --depth 1 https://github.com/microsoft/vcpkg $VcpkgRoot
    if ($LASTEXITCODE -ne 0) { throw 'git clone of vcpkg failed' }
    & (Join-Path $VcpkgRoot 'bootstrap-vcpkg.bat') -disableMetrics
    if ($LASTEXITCODE -ne 0) { throw 'vcpkg bootstrap failed' }
}
$vcpkg = Join-Path $VcpkgRoot 'vcpkg.exe'
Write-Host "vcpkg: $vcpkg"
& $vcpkg version

$installed = Join-Path $VcpkgRoot "installed\$Triplet"
$toolchain = Join-Path $VcpkgRoot 'scripts\buildsystems\vcpkg.cmake'
if (-not (Test-Path $toolchain)) { throw "vcpkg toolchain not found: $toolchain" }

# ------------------------------------------------------------ 2. libraries -----
if (-not $SkipVcpkgInstall) {
    Write-Step "vcpkg install ($Triplet): $($ports -join ' ')"
    & $vcpkg install @ports `
        --triplet $Triplet `
        --overlay-triplets "$repo\ci\triplets" `
        --clean-after-build
    if ($LASTEXITCODE -ne 0) { throw "vcpkg install failed with exit code $LASTEXITCODE" }
} else {
    Write-Host 'skipping vcpkg install (-SkipVcpkgInstall)'
}

if (-not (Test-Path $installed)) { throw "vcpkg install tree missing: $installed" }

# ------------------------------------------------- 3. basis_universal sources ---
Write-Step 'fetching basis_universal transcoder sources'
$basisDir = Join-Path $repo 'native\BasisWrapper\basis_universal'
if (-not (Test-Path (Join-Path $basisDir 'transcoder\basisu_transcoder.cpp'))) {
    if (Test-Path $basisDir) { Remove-Item $basisDir -Recurse -Force }
    # Only transcoder/ is compiled... but with BASISD_SUPPORT_KTX2_ZSTD the transcoder does
    # `#include "../zstd/zstd.h"`, so the vendored zstd/ headers must be present too.
    git clone --depth 1 --filter=blob:none --sparse `
        https://github.com/BinomialLLC/basis_universal $basisDir
    if ($LASTEXITCODE -ne 0) { throw 'git clone of basis_universal failed' }
    git -C $basisDir sparse-checkout set transcoder zstd
    if ($LASTEXITCODE -ne 0) { throw 'git sparse-checkout of basis_universal failed' }
} else {
    Write-Host 'basis_universal already present'
}
if (-not (Test-Path (Join-Path $basisDir 'zstd\zstd.h'))) {
    Write-Host 'adding zstd/ to the sparse checkout (transcoder includes ../zstd/zstd.h)'
    git -C $basisDir sparse-checkout set transcoder zstd
    if ($LASTEXITCODE -ne 0) { throw 'git sparse-checkout set transcoder zstd failed' }
}

# ------------------------------------------------------------ 4. wrappers ------
foreach ($name in $wrappers.Keys) {
    $target = $wrappers[$name].Target
    $src    = Join-Path $repo "native\$name"
    $bin    = Join-Path $repo "build\native-$name"

    Write-Step "cmake configure $name"
    # No -G: the runner label moved from "Visual Studio 17 2022" to "Visual Studio 18
    # 2026" in 2026, and CMake's default generator is whichever VS is installed newest.
    cmake -S $src -B $bin `
        -A $Arch `
        "-DCMAKE_TOOLCHAIN_FILE=$toolchain" `
        "-DVCPKG_TARGET_TRIPLET=$Triplet" `
        "-DCMAKE_PREFIX_PATH=$installed" `
        -DCMAKE_BUILD_TYPE=Release
    if ($LASTEXITCODE -ne 0) {
        $cache = Join-Path $bin 'CMakeCache.txt'
        if (Test-Path $cache) { Select-String '^CMAKE_GENERATOR' $cache }
        throw "cmake configure failed for $name"
    }
    Select-String '^CMAKE_GENERATOR:INTERNAL=' (Join-Path $bin 'CMakeCache.txt') | ForEach-Object { "    $($_.Line)" }

    Write-Step "cmake build $name ($target)"
    cmake --build $bin --config Release --parallel
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed for $name" }
}

# ------------------------------------------------------------- 5. collect ------
Write-Step "collecting into $OutDir"
$out = Join-Path $repo $OutDir
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out -Force | Out-Null

$manifest = @()
foreach ($name in $wrappers.Keys) {
    $target = $wrappers[$name].Target
    $want   = $wrappers[$name].Out
    $dll = Get-ChildItem (Join-Path $repo "build\native-$name") -Recurse -Filter "$target.dll" -File |
        Where-Object { $_.FullName -match '\\Release\\' } |
        Select-Object -First 1
    if (-not $dll) {
        $dll = Get-ChildItem (Join-Path $repo "build\native-$name") -Recurse -Filter "$target.dll" -File |
            Select-Object -First 1
    }
    if (-not $dll) { throw "build output $target.dll not found for $name" }
    Copy-Item $dll.FullName (Join-Path $out $want) -Force
    $manifest += "wrapper   $want  <-  $($dll.FullName.Substring($repo.Length + 1))  ($([math]::Round($dll.Length/1MB,2)) MB)"
}

# vcpkg runtime DLLs: the wrappers link them dynamically, so they must sit next to
# the wrappers inside lib/Windows for the Windows loader to resolve them.
$vcpkgBin = Join-Path $installed 'bin'
$depCount = 0
if (Test-Path $vcpkgBin) {
    foreach ($dll in Get-ChildItem $vcpkgBin -Filter *.dll -File) {
        $destName = $dll.Name
        if ($destName -ieq 'heif.dll') { $destName = 'libheif.dll' }   # loader's fixed name
        $dest = Join-Path $out $destName
        if ($destName -ieq 'libheif.dll' -and (Test-Path $dest)) { continue }
        Copy-Item $dll.FullName $dest -Force
        $depCount++
        $manifest += "vcpkg-dep $destName  ($([math]::Round($dll.Length/1MB,2)) MB)"
    }
} else {
    Write-Warning "no vcpkg bin directory at $vcpkgBin"
}

# App-local VC++ runtime: the wrappers use the dynamic CRT, and msvcp140.dll is not
# part of Windows. Ship it (documented app-local deployment) so the zip runs on a
# clean machine.
foreach ($vcr in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    $cand = Join-Path $env:SystemRoot "System32\$vcr"
    if ((Test-Path $cand) -and -not (Test-Path (Join-Path $out $vcr))) {
        Copy-Item $cand (Join-Path $out $vcr) -Force
        $manifest += "vc-runtime $vcr"
    } elseif (-not (Test-Path $cand)) {
        Write-Warning "VC runtime not found on runner: $cand"
    }
}

$manifest | Set-Content (Join-Path $repo 'release\native\dist-windows.manifest.txt') -Encoding utf8

Write-Step 'dist contents'
Get-ChildItem $out -File | Sort-Object Name |
    ForEach-Object { '{0,-28} {1,8:N2} MB' -f $_.Name, ($_.Length / 1MB) }

Write-Host ''
Write-Host "OK: $((Get-ChildItem $out -File).Count) files ($depCount vcpkg deps) in $OutDir" -ForegroundColor Green
