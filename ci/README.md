# ci/ — Windows ARM64 (Windows on ARM) build

Everything here exists to produce a runnable `win-arm64` bundle on GitHub's **native
ARM64 runner** (`windows-11-arm`) — there is no local toolchain on the target machine,
and native ARM64 binaries cannot be cross-built from the x64 release zip.

| File | Purpose |
| --- | --- |
| `.github/workflows/build-woa.yml` | 3 jobs: `probe` → `native` → `app` |
| `ci/build-native.ps1` | vcpkg deps + `native/*Wrapper` CMake builds + DLL staging |
| `ci/fetch-nuget-natives.ps1` | pulls SDL3 / libSkiaSharp / libHarfBuzzSharp for a RID from NuGet |
| `ci/verify-package.ps1` | asserts the nine natives exist, are ARM64 and import-resolvable |
| `ci/triplets/arm64-windows-release.cmake` | stock `arm64-windows` + Release-only (halves build time) |

## Why the wrapper DLLs ship with extra dependency DLLs

The official x64 release contains exactly nine DLLs and **all of them import only
`KERNEL32.dll`**: upstream statically linked every third-party library (and the CRT) into
the wrappers. Reproducing that here means static vcpkg triplets, which brings its own
problems — notably `libheif` builds as a static library under a static triplet (so there is
no `libheif.dll` to ship at all) and a static CRT inside several C++ DLLs that pass objects
across module boundaries is a heap-ownership hazard.

So this build takes the supported, boring route instead:

* vcpkg triplet `arm64-windows-release` (dynamic CRT, dynamic libraries, Release only),
* five wrapper DLLs renamed to the names `NativeLibraryLoader` looks for
  (`basis_native.dll` → `libbasis_native.dll`, …),
* every `installed/<triplet>/bin/*.dll` copied alongside them, plus the app-local VC++
  runtime (`msvcp140.dll`, `vcruntime140*.dll`), which Windows does not ship.

The bundle is therefore larger and has more files than the official x64 one, but every
import resolves from inside `lib/Windows`. Tightening this into a self-contained
nine-file set is a later optimisation, not a prerequisite for "it runs".

## Runner

`windows-11-arm` is a **native ARM64** Windows 11 machine: Visual Studio Enterprise
2026 (18.12, at `C:\Program Files\Microsoft Visual Studio\18\Enterprise`, with the
`VC.Tools.ARM64` toolset), CMake 4.5, Ninja, and vcpkg at `C:\vcpkg`. The label used to
point at the VS 2022 image, so nothing here pins a generator name — CMake picks the newest
installed Visual Studio and `-A ARM64` selects the architecture.

## Known gaps

* Third-party UI/GPU tests are not run: the runner has no GPU, and SDL/OpenGL paths
  cannot be exercised on a headless ARM64 machine.
* `libheif` is built with `aom` + `libde265` (AV1 + HEVC decode). `x265` (GPL encoder),
  `dav1d` and the JPEG/JPEG-2000 codecs inside HEIF are left out on purpose.
* CI proves the bundle *builds and is structurally complete*; whether OpenGL comes up on
  real WoA hardware still has to be checked by launching it there.
