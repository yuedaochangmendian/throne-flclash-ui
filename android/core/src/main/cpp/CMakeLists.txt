cmake_minimum_required(VERSION 3.22.1)

# The JNI shim for the self-owned kernel bridge. Links the Go shared library
# (libthrone.so, extracted from ThroneCore.aar into ../jniLibs) so the throne_*
# C ABI and the JNI thunks live in the same process — the bettbox shape.

project("core")

if (NOT "${CMAKE_BUILD_TYPE}" STREQUAL "Debug")
    add_compile_options(-O3)
    add_compile_options(-flto)
    add_compile_options(-g0)
    add_compile_options(-ffunction-sections -fdata-sections)
    add_compile_options(-fno-exceptions -fno-rtti)

    add_link_options(
            -flto
            -Wl,--gc-sections
            -Wl,--strip-all
            -Wl,--exclude-libs=ALL
    )

    if (${ANDROID_ABI} STREQUAL "arm64-v8a" OR ${ANDROID_ABI} STREQUAL "x86_64")
        add_link_options(-Wl,-z,max-page-size=16384)
    endif ()

    add_compile_options(-fvisibility=hidden -fvisibility-inlines-hidden)
endif ()

set(LIB_GOJNI_PATH "${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libthrone.so")

# The dual-path guard: the unpatched ThroneCore.aar has no throne_* ABI yet. The
# symbol name lives in the .so's string table, so a string probe distinguishes
# the patched library from the old one without linking anything.
set(HAS_THRONE_ABI OFF)
if (EXISTS ${LIB_GOJNI_PATH})
    file(STRINGS ${LIB_GOJNI_PATH} HAS_THRONE_ABI REGEX "throne_register_callbacks")
endif ()

if (HAS_THRONE_ABI)
    message(STATUS "libthrone.so carries the throne_* ABI for ${ANDROID_ABI}")
    add_compile_definitions(LIBCORE)
    include_directories(${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI})
    link_directories(${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI})
    add_library(${CMAKE_PROJECT_NAME} SHARED
            jni_helper.cpp
            core.cpp)
    target_link_libraries(${CMAKE_PROJECT_NAME}
            throne
            log)
else ()
    message(WARNING "libthrone.so has no throne_* ABI for ${ANDROID_ABI}; building the shim without the kernel bridge")
    add_library(${CMAKE_PROJECT_NAME} SHARED
            jni_helper.cpp
            core.cpp)
endif ()
