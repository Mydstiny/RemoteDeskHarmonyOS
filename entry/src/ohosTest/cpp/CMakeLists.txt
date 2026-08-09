cmake_minimum_required(VERSION 3.5.0)
project(native_callback_entry_ohostest)

# This CMake file is selected only by the ohosTest target in
# entry/build-profile.json5.  Keeping the switch explicit prevents the
# production target from accidentally consuming this source tree.
option(RDP_OHOS_TEST_NATIVE_CALLBACK_ENTRY
    "Build the application-namespace callback-entry integration addon" OFF)
if(NOT RDP_OHOS_TEST_NATIVE_CALLBACK_ENTRY)
    message(FATAL_ERROR
        "The ohosTest native carrier requires "
        "-DRDP_OHOS_TEST_NATIVE_CALLBACK_ENTRY=ON")
endif()

if(NOT USE_REAL_FREERDP)
    message(FATAL_ERROR
        "NativeCallbackEntryIntegration requires real FreeRDP so all 9 "
        "production callback entries are present")
endif()

set(MAIN_CPP_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../main/cpp)

# Reuse the production source graph in a test-only host library.  This is a
# separate target and output name; the default target still configures the
# production CMake file and its librdpnapi.so without RDP_NATIVE_CALLBACK_TESTING.
# No raw test executable is added here.
set(RDP_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(RDP_TESTS_ONLY OFF CACHE BOOL "" FORCE)
set(RDP_BUILD_CALLBACK_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(${MAIN_CPP_DIR} callback_entry_production_host EXCLUDE_FROM_ALL)

target_compile_definitions(rdpnapi PRIVATE
    RDP_NATIVE_CALLBACK_TESTING=1
    RDP_OHOS_TEST_NATIVE_CALLBACK_ENTRY=1
)
set_target_properties(rdpnapi PROPERTIES
    OUTPUT_NAME rdpnapi_callback_test_host
)

add_library(native_callback_entry_integration SHARED
    native_callback_entry_integration.cpp
    ${MAIN_CPP_DIR}/test/callback_entry_integration_test.cpp
)
target_compile_features(native_callback_entry_integration PRIVATE cxx_std_17)
target_compile_definitions(native_callback_entry_integration PRIVATE
    RDP_NATIVE_CALLBACK_TESTING=1
    RDP_OHOS_TEST_NATIVE_CALLBACK_ENTRY=1
    USE_REAL_FREERDP=1
)
target_compile_options(native_callback_entry_integration PRIVATE
    -Wall
    -Wextra
    -Werror
    -Wno-unused-command-line-argument
)
target_include_directories(native_callback_entry_integration PRIVATE
    ${MAIN_CPP_DIR}
    ${MAIN_CPP_DIR}/test
    ${MAIN_CPP_DIR}/common
    ${MAIN_CPP_DIR}/extensions
    ${MAIN_CPP_DIR}/rdp
    ${MAIN_CPP_DIR}/rustdesk
    ${MAIN_CPP_DIR}/render
    ${MAIN_CPP_DIR}/audio
    ${MAIN_CPP_DIR}/security
    ${MAIN_CPP_DIR}/ssh
    ${MAIN_CPP_DIR}/vnc
    ${MAIN_CPP_DIR}/terminal
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../freerdp/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../freerdp/winpr/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../libs/freerdp-ohos/${OHOS_ARCH}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../libs/freerdp-ohos/${OHOS_ARCH}/winpr/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../libs/ffmpeg-ohos/${OHOS_ARCH}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../libs/openssl/install/include
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../../libs/libssh2/install/include
)
target_link_libraries(native_callback_entry_integration PRIVATE rdpnapi)
set_target_properties(native_callback_entry_integration PROPERTIES
    OUTPUT_NAME native_callback_entry_integration
)
