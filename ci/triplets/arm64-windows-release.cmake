# Custom vcpkg triplet for Lyra's Windows ARM64 release build.
#
# Why not the stock arm64-windows triplet:
#   * VCPKG_BUILD_TYPE=release  -> vcpkg normally builds Debug *and* Release for every
#     port; on a 4 vCPU arm64 runner that roughly doubles wall time for aom/libjxl.
#   * Everything else is stock (dynamic CRT, dynamic libs), because the wrappers in
#     native/*/CMakeLists.txt are plain DLLs and the published bundle ships the
#     dependency DLLs next to them.
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE dynamic)
set(VCPKG_BUILD_TYPE release)
