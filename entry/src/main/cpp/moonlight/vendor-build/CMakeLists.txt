cmake_minimum_required(VERSION 3.5.0)
project(remotedesk_moonlight_vendor LANGUAGES C CXX)

# This is an isolated provenance/build gate. It intentionally has no path to
# rdpnapi, NAPI, ArkUI, or the product protocol registry.
if(NOT OHOS_ARCH STREQUAL "arm64-v8a" AND NOT OHOS_ARCH STREQUAL "x86_64")
    message(FATAL_ERROR
        "Moonlight vendor build requires OHOS_ARCH=arm64-v8a or x86_64")
endif()
if(NOT DEFINED REMOTEDESK_OPENSSL_ROOT)
    message(FATAL_ERROR "REMOTEDESK_OPENSSL_ROOT is required")
endif()

set(MOONLIGHT_UPSTREAM_DIR
    ${CMAKE_CURRENT_LIST_DIR}/../upstream/moonlight-common-c)
set(MOONLIGHT_OPENSSL_INCLUDE_DIR ${REMOTEDESK_OPENSSL_ROOT}/include)
set(MOONLIGHT_OPENSSL_CRYPTO_LIBRARY
    ${REMOTEDESK_OPENSSL_ROOT}/${OHOS_ARCH}/lib/libcrypto.a)
if(NOT EXISTS ${MOONLIGHT_UPSTREAM_DIR}/src/Limelight.h OR
   NOT EXISTS ${MOONLIGHT_OPENSSL_INCLUDE_DIR}/openssl/crypto.h OR
   NOT EXISTS ${MOONLIGHT_OPENSSL_CRYPTO_LIBRARY})
    message(FATAL_ERROR
        "Moonlight vendor inputs are incomplete: upstream=${MOONLIGHT_UPSTREAM_DIR}, "
        "openssl=${REMOTEDESK_OPENSSL_ROOT}, abi=${OHOS_ARCH}")
endif()

set(BUILD_SHARED_LIBS OFF CACHE BOOL
    "Build Moonlight vendored dependencies as isolated static libraries" FORCE)
set(ENET_NO_INSTALL ON CACHE BOOL "Do not install isolated vendored ENet" FORCE)
set(OPENSSL_USE_STATIC_LIBS TRUE CACHE BOOL "Use existing OHOS OpenSSL" FORCE)
set(OPENSSL_INCLUDE_DIR ${MOONLIGHT_OPENSSL_INCLUDE_DIR} CACHE PATH
    "Existing OHOS OpenSSL include directory" FORCE)
set(OPENSSL_CRYPTO_LIBRARY ${MOONLIGHT_OPENSSL_CRYPTO_LIBRARY} CACHE FILEPATH
    "Existing OHOS OpenSSL crypto archive" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_subdirectory(${MOONLIGHT_UPSTREAM_DIR} moonlight-common-c-build)

get_target_property(MOONLIGHT_COMMON_TARGET_TYPE moonlight-common-c TYPE)
get_target_property(MOONLIGHT_ENET_TARGET_TYPE enet TYPE)
if(NOT MOONLIGHT_COMMON_TARGET_TYPE STREQUAL "STATIC_LIBRARY" OR
   NOT MOONLIGHT_ENET_TARGET_TYPE STREQUAL "STATIC_LIBRARY")
    message(FATAL_ERROR
        "Moonlight vendor gate must produce only static common-c and ENet targets")
endif()

# OHOS Clang 15 receives --gcc-toolchain from the API 23 toolchain file and
# reports it as unused for C compilation. Upstream common-c intentionally uses
# -Werror; suppress only this toolchain diagnostic on the two isolated vendor
# targets. No upstream file or project-wide compiler flag is changed.
target_compile_options(moonlight-common-c PRIVATE
    -Wno-unused-command-line-argument)
target_compile_options(enet PRIVATE
    -Wno-unused-command-line-argument)

add_custom_target(moonlight_vendor_static
    DEPENDS moonlight-common-c enet)
