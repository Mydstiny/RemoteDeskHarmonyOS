# CMake toolchain for cross-compiling FreeRDP to HarmonyOS ARM64
# Usage:
#   cmake .. -DCMAKE_TOOLCHAIN_FILE=../toolchain_ohos.cmake \
#            -DWITH_CLIENT=ON -DWITH_SERVER=OFF \
#            -DBUILD_SHARED_LIBS=OFF -DWITH_FFMPEG=OFF \
#            -DWITH_SSE2=OFF -DWITH_NEON=ON

# Target system
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# OHOS SDK path (override with env var OHOS_SDK_NATIVE)
if(DEFINED ENV{OHOS_SDK_NATIVE})
    set(OHOS_SDK_NATIVE $ENV{OHOS_SDK_NATIVE})
else()
    set(OHOS_SDK_NATIVE /opt/ohos-sdk/native)
endif()

message(STATUS "OHOS SDK NATIVE: ${OHOS_SDK_NATIVE}")

# LLVM toolchain
set(OHOS_LLVM ${OHOS_SDK_NATIVE}/llvm)
set(CMAKE_C_COMPILER ${OHOS_LLVM}/bin/clang)
set(CMAKE_CXX_COMPILER ${OHOS_LLVM}/bin/clang++)
set(CMAKE_ASM_COMPILER ${OHOS_LLVM}/bin/clang)
set(CMAKE_AR ${OHOS_LLVM}/bin/llvm-ar)
set(CMAKE_RANLIB ${OHOS_LLVM}/bin/llvm-ranlib)
set(CMAKE_STRIP ${OHOS_LLVM}/bin/llvm-strip)

# Sysroot
set(OHOS_SYSROOT ${OHOS_SDK_NATIVE}/sysroot)
set(CMAKE_SYSROOT ${OHOS_SYSROOT})

# Find root for CMake package detection
set(CMAKE_FIND_ROOT_PATH ${OHOS_SYSROOT})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Compiler flags
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -target aarch64-linux-ohos -fPIC")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -target aarch64-linux-ohos -fPIC")
set(CMAKE_ASM_FLAGS "${CMAKE_ASM_FLAGS} -target aarch64-linux-ohos")

# Linker flags
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -fuse-ld=lld")
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -fuse-ld=lld")

# FreeRDP-specific: only build client, no server
set(WITH_CLIENT ON CACHE BOOL "Build client libraries")
set(WITH_SERVER OFF CACHE BOOL "Build server libraries")
set(WITH_FFMPEG OFF CACHE BOOL "Build FFmpeg support")
set(WITH_SSE2 OFF CACHE BOOL "Build SSE2 optimizations")
set(WITH_NEON ON CACHE BOOL "Build NEON optimizations")
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build shared libraries")
set(WITH_MANPAGES OFF CACHE BOOL "Build man pages")
set(WITH_PULSE OFF CACHE BOOL "Build PulseAudio support")
set(WITH_ALSA OFF CACHE BOOL "Build ALSA support")
set(WITH_CUPS OFF CACHE BOOL "Build CUPS support")
set(WITH_PCSC OFF CACHE BOOL "Build PC/SC support")
set(WITH_JPEG OFF CACHE BOOL "Build JPEG support")
