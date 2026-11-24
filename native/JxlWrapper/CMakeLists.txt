cmake_minimum_required(VERSION 3.10)
project(JxlWrapper LANGUAGES C CXX)

add_library(jxl_native SHARED jxl_native.cpp jxl_native.h)

set_target_properties(jxl_native PROPERTIES
        CXX_STANDARD 17
        CXX_STANDARD_REQUIRED YES
        CXX_EXTENSIONS NO
)

# Cross-platform symbol visibility
if (NOT WIN32)
    target_compile_options(jxl_native PRIVATE -fvisibility=hidden)
endif ()

# --- Prefer pkg-config (Homebrew-friendly) ---
find_package(PkgConfig QUIET)
if (PkgConfig_FOUND)
    pkg_check_modules(JXL QUIET libjxl)
    pkg_check_modules(JXL_THREADS QUIET libjxl_threads)
endif ()

if (JXL_FOUND AND JXL_THREADS_FOUND)
    message(STATUS "libjxl found via pkg-config: ${JXL_VERSION}")
    
    if (WIN32)
        list(REMOVE_ITEM JXL_LIBRARIES m)
        list(REMOVE_ITEM JXL_THREADS_LIBRARIES m)
    endif ()

    target_include_directories(jxl_native PRIVATE ${JXL_INCLUDE_DIRS} ${JXL_THREADS_INCLUDE_DIRS})
    target_link_directories(jxl_native PRIVATE ${JXL_LIBRARY_DIRS} ${JXL_THREADS_LIBRARY_DIRS})
    target_link_libraries(jxl_native PRIVATE ${JXL_LIBRARIES} ${JXL_THREADS_LIBRARIES})
    target_compile_options(jxl_native PRIVATE ${JXL_CFLAGS_OTHER})

else ()
    # --- Fallback: CMake config package (libjxl install tree, etc.) ---
    find_package(libjxl CONFIG QUIET)

    if (TARGET jxl)
        target_link_libraries(jxl_native PRIVATE jxl)
        if (TARGET jxl_threads)
            target_link_libraries(jxl_native PRIVATE jxl_threads)
        endif ()
    else ()
        # vcpkg's libjxl installs headers, libs and .pc files but no CMake config
        # package, and MSVC has no pkg-config, so locate the tree by hand.
        find_path(JXL_INCLUDE_DIR jxl/decode.h)
        find_library(JXL_LIBRARY NAMES jxl libjxl)
        if (NOT JXL_INCLUDE_DIR OR NOT JXL_LIBRARY)
            message(FATAL_ERROR "libjxl not found: no pkg-config, no CMake config, no headers/libs.")
        endif ()
        message(STATUS "libjxl located manually: ${JXL_LIBRARY} (${JXL_INCLUDE_DIR})")

        target_include_directories(jxl_native PRIVATE ${JXL_INCLUDE_DIR})
        target_link_libraries(jxl_native PRIVATE ${JXL_LIBRARY})

        find_library(JXL_THREADS_LIBRARY NAMES jxl_threads libjxl_threads)
        if (JXL_THREADS_LIBRARY)
            target_link_libraries(jxl_native PRIVATE ${JXL_THREADS_LIBRARY})
        endif ()
    endif ()
endif ()
