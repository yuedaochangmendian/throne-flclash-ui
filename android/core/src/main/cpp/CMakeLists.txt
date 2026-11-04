cmake_minimum_required(VERSION 3.22.1)

# The JNI shim for the self-owned kernel bridge. Links the Go shared library
# (libgojni.so, extracted from ThroneCore.aar into ../jniLibs) so the throne_*
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

set(LIB_GOJNI_PATH "${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libgojni.so")

if (EXISTS ${LIB_GOJNI_PATH})
    message(STATUS "Found libgojni.so for ABI ${ANDROID_ABI}")
    add_compile_definitions(LIBCORE)
    include_directories(${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI})
    link_directories(${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI})
    add_library(${CMAKE_PROJECT_NAME} SHARED
            jni_helper.cpp
            core.cpp)
    target_link_libraries(${CMAKE_PROJECT_NAME}
            gojni)
else ()
    message(WARNING "Not found libgojni.so for ABI ${ANDROID_ABI}; building without the kernel bridge")
    add_library(${CMAKE_PROJECT_NAME} SHARED
            jni_helper.cpp
            core.cpp)
endif ()
