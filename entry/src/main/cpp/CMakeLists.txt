cmake_minimum_required(VERSION 3.16)
project(rdpnapi VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Collect sources from subdirectories
file(GLOB EXTENSIONS_SRC   extensions/*.cpp)
file(GLOB RDP_SRC          rdp/*.cpp)
file(GLOB RUSTDESK_SRC     rustdesk/*.cpp)
file(GLOB RENDER_SRC       render/*.cpp)
file(GLOB AUDIO_SRC        audio/*.cpp)
file(GLOB SECURITY_SRC     security/*.cpp)

# NAPI module init
set(NAPI_SRC napi_init.cpp)

# FreeRDP static library path
set(FREERDP_LIB_DIR ${CMAKE_SOURCE_DIR}/../../../freerdp/build_ohos/install/lib)
set(FREERDP_INCLUDE_DIR ${CMAKE_SOURCE_DIR}/../../../freerdp/build_ohos/install/include)

# RustDesk FFI static library path
set(RUSTDESK_LIB_DIR ${CMAKE_SOURCE_DIR}/../../../rustdesk_ffi/target/aarch64-unknown-linux-ohos/release)

find_library(FREERDP_LIB freerdp PATHS ${FREERDP_LIB_DIR} NO_DEFAULT_PATH)
find_library(FREERDP_CLIENT_LIB freerdp-client PATHS ${FREERDP_LIB_DIR} NO_DEFAULT_PATH)
find_library(FREERDP_CHANNELS_LIB freerdp-channels PATHS ${FREERDP_LIB_DIR} NO_DEFAULT_PATH)
find_library(WINPR_LIB winpr PATHS ${FREERDP_LIB_DIR} NO_DEFAULT_PATH)

set(RUSTDESK_FFI_LIB ${RUSTDESK_LIB_DIR}/librustdesk_ffi.a)

# OHOS system libraries
set(OHOS_LIBS
    GLESv3
    EGL
    native_image
    native_window
    OH_AVCodec
    OHAudio
    huks_ndk.z
    hilog_ndk.z
    ace_ndk.z
    uv
    z
)

# Create shared library
add_library(rdpnapi SHARED
    ${NAPI_SRC}
    ${EXTENSIONS_SRC}
    ${RDP_SRC}
    ${RUSTDESK_SRC}
    ${RENDER_SRC}
    ${AUDIO_SRC}
    ${SECURITY_SRC}
)

target_include_directories(rdpnapi PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/extensions
    ${FREERDP_INCLUDE_DIR}
)

target_link_libraries(rdpnapi PRIVATE
    ${FREERDP_LIB}
    ${FREERDP_CLIENT_LIB}
    ${FREERDP_CHANNELS_LIB}
    ${WINPR_LIB}
    ${RUSTDESK_FFI_LIB}
    ${OHOS_LIBS}
    c++
    log
)

set_target_properties(rdpnapi PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)
