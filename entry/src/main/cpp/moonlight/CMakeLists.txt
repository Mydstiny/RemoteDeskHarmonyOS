# Project-owned boundary for the exact upstream sources pinned by
# upstream/UPSTREAM.lock.json. Product and standalone receipt builds consume
# this one target definition so warning, OpenSSL, and static/PIC policy cannot
# drift between the two graphs.

if(TARGET moonlight-common-c OR TARGET enet OR
   TARGET remotedesk_moonlight_common)
    message(FATAL_ERROR "Moonlight common targets must be defined exactly once")
endif()
if(NOT OHOS_ARCH STREQUAL "arm64-v8a" AND
   NOT OHOS_ARCH STREQUAL "x86_64")
    message(FATAL_ERROR
        "Moonlight common targets require OHOS_ARCH=arm64-v8a or x86_64")
endif()
if(NOT DEFINED REMOTEDESK_MOONLIGHT_OPENSSL_ROOT)
    message(FATAL_ERROR "REMOTEDESK_MOONLIGHT_OPENSSL_ROOT is required")
endif()

set(REMOTEDESK_MOONLIGHT_UPSTREAM_DIR
    "${CMAKE_CURRENT_LIST_DIR}/upstream/moonlight-common-c")
set(REMOTEDESK_MOONLIGHT_OPENSSL_INCLUDE_DIR
    "${REMOTEDESK_MOONLIGHT_OPENSSL_ROOT}/include")
set(REMOTEDESK_MOONLIGHT_OPENSSL_CRYPTO_LIBRARY
    "${REMOTEDESK_MOONLIGHT_OPENSSL_ROOT}/${OHOS_ARCH}/lib/libcrypto.a")
if(NOT DEFINED REMOTEDESK_MOONLIGHT_UPSTREAM_BINARY_DIR)
    set(REMOTEDESK_MOONLIGHT_UPSTREAM_BINARY_DIR
        "${CMAKE_CURRENT_BINARY_DIR}/moonlight-common-c-build")
endif()

if(NOT EXISTS "${REMOTEDESK_MOONLIGHT_UPSTREAM_DIR}/src/Limelight.h" OR
   NOT EXISTS "${REMOTEDESK_MOONLIGHT_OPENSSL_INCLUDE_DIR}/openssl/crypto.h" OR
   NOT EXISTS "${REMOTEDESK_MOONLIGHT_OPENSSL_CRYPTO_LIBRARY}")
    message(FATAL_ERROR
        "Moonlight common inputs are incomplete: "
        "upstream=${REMOTEDESK_MOONLIGHT_UPSTREAM_DIR}, "
        "openssl=${REMOTEDESK_MOONLIGHT_OPENSSL_ROOT}, abi=${OHOS_ARCH}")
endif()

# These variables are scoped to this subdirectory. The cache option is needed
# because ENet declares ENET_NO_INSTALL with option(); it does not alter any
# existing product target or protocol configuration.
set(BUILD_SHARED_LIBS OFF)
set(ENET_NO_INSTALL ON CACHE BOOL
    "Do not install RemoteDesk's pinned Moonlight ENet" FORCE)
set(OPENSSL_USE_STATIC_LIBS TRUE)
set(OPENSSL_INCLUDE_DIR "${REMOTEDESK_MOONLIGHT_OPENSSL_INCLUDE_DIR}")
set(OPENSSL_CRYPTO_LIBRARY
    "${REMOTEDESK_MOONLIGHT_OPENSSL_CRYPTO_LIBRARY}")
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# moonlight-common-c's Debug mode is a protocol-validation harness rather than
# a shippable diagnostic build: it turns remote-packet assertions into process
# aborts and deliberately drops audio FEC shards to validate reconstruction.
# A debug Harmony HAP must keep our adapter/runtime diagnostics without making
# ordinary UDP input capable of aborting the whole application, so isolate the
# immutable vendor subgraph to its production Release semantics.
set(REMOTEDESK_MOONLIGHT_PARENT_BUILD_TYPE "${CMAKE_BUILD_TYPE}")
set(CMAKE_BUILD_TYPE Release)

add_subdirectory(
    "${REMOTEDESK_MOONLIGHT_UPSTREAM_DIR}"
    "${REMOTEDESK_MOONLIGHT_UPSTREAM_BINARY_DIR}"
)
set(CMAKE_BUILD_TYPE "${REMOTEDESK_MOONLIGHT_PARENT_BUILD_TYPE}")
unset(REMOTEDESK_MOONLIGHT_PARENT_BUILD_TYPE)

get_target_property(REMOTEDESK_MOONLIGHT_COMMON_DEFINITIONS
    moonlight-common-c COMPILE_DEFINITIONS)
if("LC_DEBUG" IN_LIST REMOTEDESK_MOONLIGHT_COMMON_DEFINITIONS OR
   NOT "NDEBUG" IN_LIST REMOTEDESK_MOONLIGHT_COMMON_DEFINITIONS)
    message(FATAL_ERROR
        "Moonlight common-c must use production remote-input semantics")
endif()

get_target_property(REMOTEDESK_MOONLIGHT_COMMON_TARGET_TYPE
    moonlight-common-c TYPE)
get_target_property(REMOTEDESK_MOONLIGHT_ENET_TARGET_TYPE enet TYPE)
if(NOT REMOTEDESK_MOONLIGHT_COMMON_TARGET_TYPE STREQUAL "STATIC_LIBRARY" OR
   NOT REMOTEDESK_MOONLIGHT_ENET_TARGET_TYPE STREQUAL "STATIC_LIBRARY")
    message(FATAL_ERROR
        "Moonlight boundary must produce only static common-c and ENet targets")
endif()

# OHOS Clang 15 reports the SDK-injected --gcc-toolchain argument as unused for
# C compilation. Upstream common-c promotes warnings to errors, so suppress
# only this toolchain diagnostic and only on the two immutable vendor targets.
target_compile_options(moonlight-common-c PRIVATE
    -Wno-unused-command-line-argument)
target_compile_options(enet PRIVATE
    -Wno-unused-command-line-argument)
set_target_properties(moonlight-common-c enet PROPERTIES
    POSITION_INDEPENDENT_CODE ON)

# Consumers get a link edge only. The upstream SYSTEM PUBLIC include paths and
# compile usage requirements are intentionally not added to rdpnapi sources.
add_library(remotedesk_moonlight_common INTERFACE)
target_link_libraries(remotedesk_moonlight_common INTERFACE
    "$<LINK_ONLY:moonlight-common-c>")
