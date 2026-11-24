<#
.SYNOPSIS
    Verifies a published Lyra bundle: the nine native libraries NativeLibraryLoader asks
    for are present, are built for the expected CPU architecture, and every DLL they
    import is either shipped alongside them or is part of Windows.

.DESCRIPTION
    Runs the same checks locally against the official x64 zip (with -ExpectMachine x64)
    as it does in CI for arm64, so the checks themselves are proven before CI relies on
    them.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Dir,
    [ValidateSet('arm64', 'x64', 'x86')] [string]$ExpectMachine = 'arm64',
    [string]$LibSubdir = 'lib\Windows',
    # Override to check a subset (the probe job only has the NuGet-provided natives).
    [string[]]$Required = @(),
    # Only a published bundle has the launcher; the staging directories do not.
    [switch]$RequireExe
)

$ErrorActionPreference = 'Stop'

$machineNames = @{ 0x8664 = 'x64'; 0xAA64 = 'arm64'; 0x14c = 'x86'; 0x1c4 = 'arm' }
$expected = @{ arm64 = 0xAA64; x64 = 0x8664; x86 = 0x14c }[$ExpectMachine]

# The exact set Lyra.Core/src/NativeLibraryLoader.cs loads, in order.
$defaultRequired = @(
    'SDL3.dll'
    'libheif.dll'
    'libexr_native.dll'
    'libj2k_native.dll'
    'libtiff_native.dll'
    'libbasis_native.dll'
    'libjxl_native.dll'
    'libSkiaSharp.dll'
    'libHarfBuzzSharp.dll'
)
$required = if ($Required.Count -gt 0) { $Required } else { $defaultRequired }

$root = Resolve-Path $Dir
$libDir = Join-Path $root $LibSubdir
if (-not (Test-Path $libDir)) { $libDir = $root }   # tolerated: natives next to the exe

function Get-PeMachine([string]$path) {
    $fs = [IO.File]::OpenRead($path)
    try {
        $br = New-Object IO.BinaryReader($fs)
        $fs.Position = 0x3C
        $e = $br.ReadInt32()
        $fs.Position = $e
        $sig = $br.ReadUInt32()
        if ($sig -ne 0x00004550) { return $null }    # 'PE\0\0'
        return $br.ReadUInt16()
    } finally { $fs.Dispose() }
}

function Get-PeImports([string]$path) {
    $b = [IO.File]::ReadAllBytes($path)
    $e = [BitConverter]::ToInt32($b, 0x3C)
    $coff = $e + 4
    $numSec = [BitConverter]::ToUInt16($b, $coff + 2)
    $optSize = [BitConverter]::ToUInt16($b, $coff + 16)
    $opt = $coff + 20
    $magic = [BitConverter]::ToUInt16($b, $opt)
    $dd = if ($magic -eq 0x20b) { $opt + 112 } else { $opt + 96 }
    $impRva = [BitConverter]::ToUInt32($b, $dd + 8)
    if ($impRva -eq 0) { return @() }
    $secTab = $opt + $optSize
    $secs = @()
    for ($i = 0; $i -lt $numSec; $i++) {
        $o = $secTab + $i * 40
        $secs += [pscustomobject]@{
            VA    = [BitConverter]::ToUInt32($b, $o + 12)
            VSize = [BitConverter]::ToUInt32($b, $o + 8)
            Raw   = [BitConverter]::ToUInt32($b, $o + 20)
        }
    }
    $script:secs = $secs
    function Rva2Off($rva) {
        foreach ($s in $script:secs) {
            if ($rva -ge $s.VA -and $rva -lt ($s.VA + $s.VSize)) { return [int]($rva - $s.VA + $s.Raw) }
        }
        return -1
    }
    $names = @()
    $o = Rva2Off $impRva
    if ($o -lt 0) { return @() }
    while ($true) {
        $nameRva = [BitConverter]::ToUInt32($b, $o + 12)
        if ($nameRva -eq 0) { break }
        $no = Rva2Off $nameRva
        if ($no -lt 0 -or $no -ge $b.Length) { break }
        $end = $no
        while ($end -lt $b.Length -and $b[$end] -ne 0) { $end++ }
        $names += [Text.Encoding]::ASCII.GetString($b, $no, $end - $no)
        $o += 20
    }
    return $names
}

$failures = @()
Write-Host "verifying $root  (expect $ExpectMachine)" -ForegroundColor Cyan
Write-Host ("{0,-26} {1,-10} {2,10}  {3}" -f 'file', 'machine', 'size', 'imports')

$shipped = @{}
Get-ChildItem $libDir -Filter *.dll -File | ForEach-Object { $shipped[$_.Name.ToLower()] = $true }

foreach ($name in $required) {
    $path = Join-Path $libDir $name
    if (-not (Test-Path $path)) {
        $failures += "missing required native library: $name"
        Write-Host ("{0,-26} {1}" -f $name, 'MISSING') -ForegroundColor Red
        continue
    }
    $m = Get-PeMachine $path
    $mName = if ($m -and $machineNames.ContainsKey([int]$m)) { $machineNames[[int]$m] } else { "0x{0:X}" -f $m }
    $ok = ([int]$m -eq [int]$expected)
    if (-not $ok) { $failures += "$name is $mName, expected $ExpectMachine" }
    $imports = Get-PeImports $path
    $unresolved = @()
    foreach ($imp in $imports) {
        $k = $imp.ToLower()
        if ($shipped.ContainsKey($k)) { continue }
        # API sets (api-ms-win-crt-*, ext-ms-*) are resolved by the loader through the
        # apiset schema and usually have no file on disk, so don't look for them.
        if ($imp -match '^(api-ms-win-|ext-ms-)') { continue }
        if (Test-Path (Join-Path $env:SystemRoot "System32\$imp")) { continue }
        $unresolved += $imp
    }
    if ($unresolved.Count -gt 0) {
        $failures += "$name imports DLLs that are neither shipped nor in Windows: $($unresolved -join ', ')"
    }
    $color = if ($ok -and $unresolved.Count -eq 0) { 'Green' } else { 'Red' }
    Write-Host ("{0,-26} {1,-10} {2,8:N2} MB  {3}" -f $name, $mName, ((Get-Item $path).Length / 1MB),
        ($(if ($unresolved.Count) { 'UNRESOLVED: ' + ($unresolved -join ',') } else { "$($imports.Count) imports ok" }))) -ForegroundColor $color
}

# The launcher itself should be the target architecture too.
$exe = Get-ChildItem $root -Filter 'LyraViewer.exe' -File -Recurse |
    Sort-Object { $_.DirectoryName.Length } | Select-Object -First 1
if ($exe) {
    $m = Get-PeMachine $exe.FullName
    $mName = if ($m -and $machineNames.ContainsKey([int]$m)) { $machineNames[[int]$m] } else { "0x{0:X}" -f $m }
    $ok = ([int]$m -eq [int]$expected)
    if (-not $ok) { $failures += "LyraViewer.exe is $mName, expected $ExpectMachine" }
    Write-Host ("{0,-26} {1,-10} {2,8:N2} MB" -f 'LyraViewer.exe', $mName, ($exe.Length / 1MB)) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
} elseif ($RequireExe) {
    $failures += 'LyraViewer.exe not found in the bundle'
}

$totalMb = [math]::Round(((Get-ChildItem $root -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 1)
Write-Host "`nbundle size: $totalMb MB, DLLs in ${LibSubdir}: $($shipped.Count)"

if ($failures.Count -gt 0) {
    Write-Host "`nFAILED:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red; Write-Host "::error::$_" }
    exit 1
}
Write-Host "`nOK: $($required.Count) required natives present, $ExpectMachine, imports resolvable" -ForegroundColor Green
