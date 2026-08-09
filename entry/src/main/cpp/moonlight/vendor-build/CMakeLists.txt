cmake_minimum_required(VERSION 3.5.0)
project(remotedesk_moonlight_vendor LANGUAGES C CXX)

# This is an isolated provenance/build gate. It consumes the same project-owned
# target boundary as the product graph but has no path to rdpnapi, NAPI, ArkUI,
# or the protocol registry.
if(NOT DEFINED REMOTEDESK_OPENSSL_ROOT)
    message(FATAL_ERROR "REMOTEDESK_OPENSSL_ROOT is required")
endif()

set(REMOTEDESK_MOONLIGHT_OPENSSL_ROOT "${REMOTEDESK_OPENSSL_ROOT}")
# Preserve the receipt script's stable archive paths while sharing all target
# policy with entry/src/main/cpp/moonlight/CMakeLists.txt.
set(REMOTEDESK_MOONLIGHT_UPSTREAM_BINARY_DIR
    "${CMAKE_CURRENT_BINARY_DIR}/moonlight-common-c-build")
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/.." moonlight-project)

add_custom_target(moonlight_vendor_static
    DEPENDS moonlight-common-c enet)
