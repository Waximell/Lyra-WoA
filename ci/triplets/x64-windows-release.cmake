# Custom vcpkg triplet for Lyra's Windows x64 release build.
#
# Mirrors arm64-windows-release so both flavours are produced the same way:
#   * VCPKG_BUILD_TYPE=release  -> skip the Debug half of every port.
#   * dynamic CRT + dynamic libs, matching the wrappers in native/*/CMakeLists.txt
#     and the dependency DLLs that ship next to them in the published bundle.
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE dynamic)
set(VCPKG_BUILD_TYPE release)
