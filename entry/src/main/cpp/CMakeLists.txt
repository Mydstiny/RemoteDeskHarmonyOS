# CMakeLists.txt — 鸿蒙PC双协议远程桌面客户端 Native 构建配置
#
# 构建目标：
#   rdpnapi — 主 NAPI 模块共享库，包含：
#     - 扩展框架 (extensions/)
#     - RDP 协议适配器 (rdp/)
#     - RustDesk 协议适配器 (rustdesk/)
#     - 共享渲染管线 (render/)
#     - 音频管线 (audio/)
#     - 安全管理 (security/)

cmake_minimum_required(VERSION 3.5.0)
project(rdpnapi)

# Non-sensitive build identity. The values are exported through the existing
# NAPI VERSION object for field diagnostics; they never enter protocol frames.
set(REMOTEDESK_GIT_SHORT_SHA "unknown")
execute_process(
    COMMAND git rev-parse --short=12 HEAD
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/../../../..
    RESULT_VARIABLE REMOTEDESK_GIT_RESULT
    OUTPUT_VARIABLE REMOTEDESK_GIT_OUTPUT
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
)
if(REMOTEDESK_GIT_RESULT EQUAL 0 AND REMOTEDESK_GIT_OUTPUT MATCHES "^[0-9a-fA-F]+$")
    set(REMOTEDESK_GIT_SHORT_SHA "${REMOTEDESK_GIT_OUTPUT}")
endif()
string(TIMESTAMP REMOTEDESK_BUILD_TIME_UTC "%Y-%m-%dT%H:%M:%SZ" UTC)

# ============================================================
# 源文件清单
# ============================================================

# -- 通用工具 --
set(COMMON_SOURCES
    common/safe_log.cpp
    input/remote_cursor_snapshot.cpp
)

# -- 扩展框架 --
set(EXTENSION_SOURCES
    extensions/extension_loader_napi.cpp
    extensions/session_teardown_executor.cpp
)

# -- 协议适配器 --
set(PROTOCOL_SOURCES
    rdp/freerdp_adapter.cpp
    rdp/rdp_audio_policy.cpp
    rdp/rdp_auth_identity_policy.cpp
    rdp/rdp_auth_mode_policy.cpp
    rdp/rdp_background_frame_cache.cpp
    rdp/rdp_damage_accumulator.cpp
    rdp/rdp_frame_scheduler.cpp
    rdp/rdp_gl_upload_gate.cpp
    rdp/rdp_graphics_lifecycle.cpp
    rdp/rdp_frame_pump.cpp
    rdp/rdp_file_clipboard_bridge.cpp
    rdp/rdp_file_clipboard_offer.cpp
    rustdesk/rustdesk_bridge.cpp
)

# -- 渲染管线 --
set(RENDER_SOURCES
    render/gl_renderer.cpp
    render/hw_decoder.cpp
    render/software_decoder.cpp
    video/video_activity_state.cpp
    render/video_backpressure_controller.cpp
    render/video_perf_counters.cpp
)

# -- 音频管线 --
set(AUDIO_SOURCES
    audio/audio_activity_state.cpp
    audio/audio_queue_policy.cpp
    audio/audio_player.cpp
    audio/audio_capturer.cpp
    audio/input_handler.cpp
    audio/clipboard_bridge.cpp
)

# -- SSH 适配器 --
set(SSH_SOURCES
    ssh/ssh_adapter.cpp
    ssh/ssh_forwarding_manager.cpp
    ssh/ssh_session_manager.cpp
    ssh/ssh_key_tool.cpp
)

# -- VNC 适配器 --
set(VNC_SOURCES
    vnc/vnc_adapter.cpp
    vnc/vnc_cursor_protocol.cpp
    vnc/vnc_des.cpp
    vnc/vnc_rfb_protocol.cpp
    vnc/vnc_certificate_probe.cpp
    vnc/vnc_transport.cpp
    vnc/vnc_rfb_engine.cpp
)

# -- 终端核心 (Rust terminal_core NAPI bridge) --
set(TERMINAL_SOURCES
    terminal/terminal_core_napi.cpp
    terminal/ssh_terminal_renderer.cpp
    terminal/ssh_terminal_renderer_napi.cpp
)

# -- 安全管理 --
set(SECURITY_SOURCES
    security/crypto_utils.cpp
    security/host_locker.cpp
    security/security_napi.cpp
)

# -- NAPI 入口 --
set(NAPI_ENTRY
    napi_init.cpp
)

# 合并所有源文件
set(ALL_SOURCES
    ${NAPI_ENTRY}
    ${COMMON_SOURCES}
    ${EXTENSION_SOURCES}
    ${PROTOCOL_SOURCES}
    ${SSH_SOURCES}
    ${RENDER_SOURCES}
    ${AUDIO_SOURCES}
    ${SECURITY_SOURCES}
    ${VNC_SOURCES}
    ${TERMINAL_SOURCES}
)

# ============================================================
# 头文件搜索路径
# ============================================================

include_directories(
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/common
    ${CMAKE_CURRENT_SOURCE_DIR}/extensions
    ${CMAKE_CURRENT_SOURCE_DIR}/rdp
    ${CMAKE_CURRENT_SOURCE_DIR}/rustdesk
    ${CMAKE_CURRENT_SOURCE_DIR}/render
    ${CMAKE_CURRENT_SOURCE_DIR}/audio
    ${CMAKE_CURRENT_SOURCE_DIR}/security
    ${CMAKE_CURRENT_SOURCE_DIR}/ssh
    ${CMAKE_CURRENT_SOURCE_DIR}/vnc
    ${CMAKE_CURRENT_SOURCE_DIR}/terminal
)

# ============================================================
# 原生单元测试 (纯 C++ 策略测试, 不依赖 OHOS NAPI/GL)
# ============================================================
option(RDP_BUILD_TESTS "Build lightweight native unit tests" OFF)
option(RDP_TESTS_ONLY "Configure only lightweight native unit tests" OFF)
option(RDP_BUILD_CALLBACK_TESTS "Build OHOS production callback-entry barrier tests" OFF)
if(RDP_BUILD_TESTS)
    # Compile the actual VNC transport and RFB engine into the host test
    # target as a link/ABI gate. Wire-level decisions are additionally
    # exercised through the pure protocol helpers, but this prevents the
    # production VNC sources from silently drifting out of the test build.
    find_package(OpenSSL REQUIRED)
    find_package(ZLIB REQUIRED)
    add_executable(rdp_native_tests
        test/test_main.cpp
        ../../test/cpp/extension_registry_test.cpp
        test/perf_test.cpp
        test/video_backpressure_test.cpp
        test/software_decode_latency_policy_test.cpp
        test/remote_cursor_snapshot_test.cpp
        test/rustdesk_display_switch_gate_test.cpp
        test/video_perf_counters_test.cpp
        test/ssh_terminal_diagnostics_test.cpp
        test/ssh_auth_policy_test.cpp
        test/ssh_auth_prompt_broker_test.cpp
        test/ssh_pty_recovery_policy_test.cpp
        test/ssh_reconnect_policy_test.cpp
        test/ssh_network_lifecycle_policy_test.cpp
        test/ssh_session_manager_test.cpp
        test/ssh_pending_connect_registry_test.cpp
        test/ssh_route_policy_test.cpp
        test/ssh_forwarding_manager_test.cpp
        test/ssh_sftp_operation_policy_test.cpp
        test/video_activity_state_test.cpp
        test/rdp_audio_policy_test.cpp
        test/audio_queue_policy_test.cpp
        test/audio_activity_state_test.cpp
        test/rdp_frame_pump_contract_test.cpp
        test/rdp_redraw_notifier_test.cpp
        test/rdp_presentation_metrics_test.cpp
        test/rdp_shutdown_state_test.cpp
        test/session_teardown_executor_test.cpp
        test/session_registry_test.cpp
        test/disconnect_request_registry_test.cpp
        test/rdp_background_frame_cache_test.cpp
        test/rdp_damage_accumulator_test.cpp
        test/rdp_frame_scheduler_test.cpp
        test/rdp_transform_refresh_policy_test.cpp
        test/rdp_gl_upload_gate_test.cpp
        test/rdp_graphics_lifecycle_test.cpp
        test/rdp_certificate_policy_test.cpp
        test/rdp_gateway_policy_test.cpp
        test/rdp_negotiation_parser_test.cpp
        test/rdp_auth_identity_policy_test.cpp
        test/rdp_auth_mode_policy_test.cpp
        test/rdp_performance_policy_test.cpp
        test/transfer_runtime_status_test.cpp
        test/rdp_input_queue_test.cpp
        test/rdp_file_clipboard_offer_test.cpp
        test/gl_surface_lifecycle_policy_test.cpp
        test/native_image_context_policy_test.cpp
        test/presentation_geometry_policy_test.cpp
        test/decoder_recovery_policy_test.cpp
        test/software_decoder_callback_gate_test.cpp
        test/decoder_callback_gate_test.cpp
        test/decoder_callback_lifecycle_policy_test.cpp
        test/callback_admission_context_test.cpp
        test/rustdesk_ffi_lifetime_policy_test.cpp
        test/rustdesk_connection_continuity_owner_test.cpp
        test/rustdesk_connection_continuity_executor_test.cpp
        test/decoder_pipeline_lifecycle_policy_test.cpp
        test/safe_log_test.cpp
        test/vnc_des_test.cpp
        test/vnc_cursor_protocol_test.cpp
        test/vnc_transport_policy_test.cpp
        test/vnc_certificate_probe_test.cpp
        common/safe_log.cpp
        input/remote_cursor_snapshot.cpp
        ssh/ssh_forwarding_manager.cpp
        ssh/ssh_session_manager.cpp
        rdp/rdp_audio_policy.cpp
        rdp/rdp_auth_identity_policy.cpp
        rdp/rdp_auth_mode_policy.cpp
        rdp/rdp_background_frame_cache.cpp
        rdp/rdp_damage_accumulator.cpp
        rdp/rdp_frame_scheduler.cpp
        rdp/rdp_gl_upload_gate.cpp
        rdp/rdp_graphics_lifecycle.cpp
        rdp/rdp_file_clipboard_offer.cpp
        audio/audio_queue_policy.cpp
        audio/audio_activity_state.cpp
        video/video_activity_state.cpp
        render/video_backpressure_controller.cpp
        render/video_perf_counters.cpp
        extensions/session_teardown_executor.cpp
        vnc/vnc_des.cpp
        vnc/vnc_cursor_protocol.cpp
        vnc/vnc_rfb_protocol.cpp
        vnc/vnc_certificate_probe.cpp
        vnc/vnc_transport.cpp
        vnc/vnc_rfb_engine.cpp
        test/vnc_rfb_protocol_test.cpp
    )
    target_include_directories(rdp_native_tests PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
    )
    # Policy/executor tests may use the explicit test-only ticket factory;
    # never enable this definition on the production rdpnapi target.
    target_compile_definitions(rdp_native_tests PRIVATE
        RDP_NATIVE_CALLBACK_TESTING=1
        RDP_TESTS_ONLY=1
    )
    # RDP_TESTS_ONLY returns before the production-wide C++ standard block
    # below. Keep the standalone host test target explicit so headers using
    # std::optional and other C++17 facilities compile consistently.
    target_compile_features(rdp_native_tests PRIVATE cxx_std_17)
    target_include_directories(rdp_native_tests PRIVATE ${OPENSSL_INCLUDE_DIR})
    target_link_libraries(rdp_native_tests PRIVATE OpenSSL::SSL OpenSSL::Crypto ZLIB::ZLIB)
endif()

if(RDP_TESTS_ONLY)
    if(NOT RDP_BUILD_TESTS)
        message(FATAL_ERROR "RDP_TESTS_ONLY requires RDP_BUILD_TESTS=ON")
    endif()
    message(STATUS "Configured lightweight native tests only")
    return()
endif()


# ============================================================
# FFmpeg 软件解码后备 (VP8/VP9/AV1)
# ============================================================
option(ENABLE_FFMPEG_SOFTDEC "Enable FFmpeg VP8/VP9/AV1 software decoder fallback" ON)
set(FFMPEG_SOFTDEC_LIBS "")
set(FFMPEG_SOFTDEC_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../libs/ffmpeg-ohos/${OHOS_ARCH})

if(ENABLE_FFMPEG_SOFTDEC AND
   EXISTS ${FFMPEG_SOFTDEC_DIR}/include/libavcodec/avcodec.h AND
   EXISTS ${FFMPEG_SOFTDEC_DIR}/lib/libavcodec.a AND
   EXISTS ${FFMPEG_SOFTDEC_DIR}/lib/libavutil.a AND
   EXISTS ${FFMPEG_SOFTDEC_DIR}/lib/libswscale.a)
    include_directories(${FFMPEG_SOFTDEC_DIR}/include)
    add_definitions(-DUSE_FFMPEG_SOFTWARE_DECODER)
    set(FFMPEG_SOFTDEC_LIBS
        ${FFMPEG_SOFTDEC_DIR}/lib/libavcodec.a
        ${FFMPEG_SOFTDEC_DIR}/lib/libswscale.a
        ${FFMPEG_SOFTDEC_DIR}/lib/libavutil.a
    )
    message(STATUS "FFmpeg soft decoder enabled: ${FFMPEG_SOFTDEC_DIR}")
else()
    message(WARNING
        "FFmpeg soft decoder disabled: missing libs in ${FFMPEG_SOFTDEC_DIR}. "
        "Run scripts/build_ffmpeg_softdec_ohos.sh ${OHOS_ARCH} for VP8/VP9/AV1 software decode.")
endif()

# ============================================================
# OpenSSL + libssh2 第三方库 (交叉编译产出)
# ============================================================

set(OPENSSL_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../libs/openssl/install)
set(LIBSSH2_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../libs/libssh2/install)

include_directories(
    ${OPENSSL_DIR}/include
    ${LIBSSH2_DIR}/include
)

# ============================================================
# FreeRDP 3.x 静态库 (交叉编译产出) — RDP-1
# ============================================================
option(USE_REAL_FREERDP "Use real FreeRDP 3.x client library" OFF)
option(RDP_STRICT_WARNINGS "Treat native warnings as errors for acceptance builds" OFF)

if(USE_REAL_FREERDP)
    add_definitions(-DUSE_REAL_FREERDP -DWITH_FREERDP_DEPRECATED)

    # The prebuilt FreeRDP headers intentionally expose a small set of
    # deprecated compatibility entry points. Keep the exemption on the one
    # production translation unit that calls those third-party APIs; project
    # sources and all other headers remain under -Werror.
    if(RDP_STRICT_WARNINGS)
        set_source_files_properties(rdp/freerdp_adapter.cpp PROPERTIES
            COMPILE_OPTIONS "-Wno-deprecated-declarations")
    endif()

    set(FREERDP_PREBUILT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../libs/freerdp-ohos/${OHOS_ARCH})

    # FreeRDP 头文件路径:
    #   freerdp/include/              — 公共 API (<freerdp/freerdp.h>, <freerdp/client.h>, ...)
    #   freerdp/winpr/include/        — WinPR API (<winpr/wtypes.h>, <winpr/thread.h>, ...)
    #   libs/freerdp-ohos/${OHOS_ARCH}/include/       — 生成的 freerdp/config.h
    #   libs/freerdp-ohos/${OHOS_ARCH}/winpr/include/ — 生成的 winpr/config.h
    include_directories(
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../../freerdp/include
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../../freerdp/winpr/include
        ${FREERDP_PREBUILT_DIR}/include
        ${FREERDP_PREBUILT_DIR}/winpr/include
    )

    message(STATUS "RDP: USE_REAL_FREERDP=ON (prebuilt_dir=${FREERDP_PREBUILT_DIR})")
else()
    message(STATUS "RDP: Using skeleton (USE_REAL_FREERDP=OFF)")
endif()

# ============================================================
# 编译器设置
# ============================================================

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# 启用异常和 RTTI
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fexceptions -frtti")

# RustDesk 真实核心: 使用 librustdesk_ffi.a 的 protobuf 协议实现
# 注释此行回退到 IPC/Experimental 模式
add_definitions(-DRUSTDESK_USE_REAL_CORE)

# 优化级别：Debug 无优化，Release O2
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O0 -g")
else()
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -O2 -DNDEBUG")
endif()

# 警告选项
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra")
if(RDP_STRICT_WARNINGS)
    # OHOS clang can report the injected --gcc-toolchain argument as unused;
    # this is a toolchain diagnostic, not a source warning. Keep that single
    # narrow exemption explicit for strict cross-architecture builds.
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Werror -Wno-unused-command-line-argument")
endif()

# ============================================================
# 构建目标 (必须先于 target_link_libraries)
# ============================================================

# 定义共享库目标
add_library(rdpnapi SHARED ${ALL_SOURCES})
target_compile_definitions(rdpnapi PRIVATE
    REMOTEDESK_GIT_SHORT_SHA="${REMOTEDESK_GIT_SHORT_SHA}"
    REMOTEDESK_BUILD_TIME_UTC="${REMOTEDESK_BUILD_TIME_UTC}"
)

# VNC full-screen ZRLE decode is production-rate code even in a signed Debug
# HAP used for on-device diagnostics. Keep symbols and assertions, but compile
# only the hot wire/decode sources with optimization so Debug does not turn a
# 5.4 MP frame into an artificial multi-second bottleneck.
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    set_property(SOURCE
        vnc/vnc_rfb_protocol.cpp
        vnc/vnc_transport.cpp
        vnc/vnc_rfb_engine.cpp
        APPEND PROPERTY COMPILE_OPTIONS -O2)
endif()

# 输出名称
set_target_properties(rdpnapi PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/libs
)

# ============================================================
# 链接库
# ============================================================

# NAPI 核心库
target_link_libraries(rdpnapi PUBLIC
    libace_napi.z.so       # NAPI 运行时
    libace_ndk.z.so        # XComponent Native Window (OH_NativeXComponent)
    libhilog_ndk.z.so      # HiLog 日志
)

# OpenGL ES 3.0 + EGL (渲染管线)
target_link_libraries(rdpnapi PUBLIC
    libEGL.so              # EGL 上下文管理
    libGLESv3.so           # OpenGL ES 3.0
    libnative_image.so     # NativeImage 零拷贝纹理
    libnative_window.so    # SurfaceId -> OHNativeWindow
    libnative_drawing.so   # OH_Drawing 终端画布
)

# 多媒体 (硬件解码)
target_link_libraries(rdpnapi PUBLIC
    libnative_media_codecbase.so  # OH_AVCodec 基础
    libnative_media_core.so       # 多媒体核心
    libnative_media_vdec.so       # 视频解码器
)


# 软件解码后备 (VP8/VP9/AV1, 静态 FFmpeg)
if(FFMPEG_SOFTDEC_LIBS)
    target_link_libraries(rdpnapi PUBLIC
        ${FFMPEG_SOFTDEC_LIBS}
    )
endif()

# 音频 (OHAudio)
target_link_libraries(rdpnapi PUBLIC
    libohaudio.so          # OHAudio 渲染器/采集器
)

# OHOS system network observer used by RustDesk continuity. Host focused
# tests do not link this platform library; OHOS real/no-real targets do.
if(OHOS_ARCH)
    target_link_libraries(rdpnapi PUBLIC libnet_connection.so)
endif()

# 安全 (HUKS + CryptoArchitectureKit)
target_link_libraries(rdpnapi PUBLIC
    libhuks_ndk.z.so       # HUKS 通用密钥库
    libohcrypto.so         # CryptoArchitectureKit (KDF/Digest/Rand)
    libz.so                # OHOS system zlib (VNC ZRLE / FreeRDP)
)

# SSH2 支持 (OpenSSL + libssh2, 静态链接, ABI分目录)
add_library(ssl STATIC IMPORTED)
set_target_properties(ssl PROPERTIES
    IMPORTED_LOCATION ${OPENSSL_DIR}/${OHOS_ARCH}/lib/libssl.a
)
add_library(crypto STATIC IMPORTED)
set_target_properties(crypto PROPERTIES
    IMPORTED_LOCATION ${OPENSSL_DIR}/${OHOS_ARCH}/lib/libcrypto.a
)
add_library(ssh2 STATIC IMPORTED)
set_target_properties(ssh2 PROPERTIES
    IMPORTED_LOCATION ${LIBSSH2_DIR}/${OHOS_ARCH}/lib/libssh2.a
)

target_link_libraries(rdpnapi PUBLIC
    ssh2
    ssl
    crypto
)

# ============================================================
# FreeRDP 3.x 链接 (USE_REAL_FREERDP=ON 时启用)
# ============================================================
if(USE_REAL_FREERDP)
    set(FREERDP_LIB_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../libs/freerdp-ohos/${OHOS_ARCH})

    if(NOT EXISTS ${FREERDP_LIB_DIR}/libfreerdp3.a OR
       NOT EXISTS ${FREERDP_LIB_DIR}/libwinpr3.a OR
       NOT EXISTS ${FREERDP_LIB_DIR}/libfreerdp-client-channels.a)
        message(FATAL_ERROR
            "RDP: missing FreeRDP prebuilt libs in ${FREERDP_LIB_DIR}. "
            "Run scripts/build_freerdp_ohos.sh all from Git Bash first.")
    endif()

    add_library(freerdp3 STATIC IMPORTED)
    set_target_properties(freerdp3 PROPERTIES
        IMPORTED_LOCATION ${FREERDP_LIB_DIR}/libfreerdp3.a
    )

    add_library(winpr3 STATIC IMPORTED)
    set_target_properties(winpr3 PROPERTIES
        IMPORTED_LOCATION ${FREERDP_LIB_DIR}/libwinpr3.a
    )

    add_library(freerdp_client_channels STATIC IMPORTED)
    set_target_properties(freerdp_client_channels PROPERTIES
        IMPORTED_LOCATION ${FREERDP_LIB_DIR}/libfreerdp-client-channels.a
    )

    target_link_libraries(rdpnapi PUBLIC
        freerdp_client_channels
        freerdp3
        winpr3
    )
    if(FFMPEG_SOFTDEC_LIBS)
        target_link_libraries(rdpnapi PUBLIC
            ${FFMPEG_SOFTDEC_LIBS}
        )
    endif()

    message(STATUS "RDP: Linked FreeRDP core/client/channel libs from ${FREERDP_LIB_DIR}")
endif()

# RustDesk FFI 静态库
if(OHOS_ARCH STREQUAL "x86_64")
    set(RUSTDESK_FFI_TARGET x86_64-unknown-linux-ohos)
    set(RUSTDESK_FFI_CLANG_TARGET x86_64-linux-ohos)
    set(RUSTDESK_FFI_LIB ${CMAKE_CURRENT_SOURCE_DIR}/../../../../rustdesk_ffi/target/x86_64-unknown-linux-ohos/release/librustdesk_ffi.a)
elseif(OHOS_ARCH STREQUAL "arm64-v8a" OR OHOS_ARCH STREQUAL "aarch64")
    set(RUSTDESK_FFI_TARGET aarch64-unknown-linux-ohos)
    set(RUSTDESK_FFI_CLANG_TARGET aarch64-linux-ohos)
    set(RUSTDESK_FFI_LIB ${CMAKE_CURRENT_SOURCE_DIR}/../../../../rustdesk_ffi/target/aarch64-unknown-linux-ohos/release/librustdesk_ffi.a)
else()
    message(FATAL_ERROR
        "RustDesk: unsupported OHOS_ARCH='${OHOS_ARCH}'. "
        "Expected x86_64 or arm64-v8a.")
endif()

message(STATUS "RustDesk: selected FFI target=${RUSTDESK_FFI_TARGET} library=${RUSTDESK_FFI_LIB}")

set(RUSTDESK_FFI_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../rustdesk_ffi)
set(RUSTDESK_PROTO_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../rustdesk_vendor/libs/hbb_common/protos)
set(RUSTDESK_OPUS_LIB_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../../libs/opus-ohos/${OHOS_ARCH})
set(RUSTDESK_OPUS_LIBRARY ${RUSTDESK_OPUS_LIB_DIR}/libopus.a)
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/ResolveRustCargo.cmake)
resolve_rustdesk_rust_toolchain(
    RUSTDESK_CARGO_EXECUTABLE
    RUSTDESK_RUSTC_EXECUTABLE)
string(TOUPPER "${RUSTDESK_FFI_TARGET}" RUSTDESK_FFI_TARGET_ENV_UPPER)
string(REPLACE "-" "_"
    RUSTDESK_FFI_TARGET_ENV_UPPER "${RUSTDESK_FFI_TARGET_ENV_UPPER}")

# Cargo target configuration otherwise resolves `clang++` through PATH. That
# fails when DevEco is launched from Finder because its IDE build environment
# does not inherit the shell toolchain PATH. Mirror scripts/macos_env.sh here
# with CMake's already selected OHOS compiler and sysroot.
if(CMAKE_SYSROOT AND EXISTS "${CMAKE_SYSROOT}")
    set(RUSTDESK_OHOS_SYSROOT "${CMAKE_SYSROOT}")
else()
    get_filename_component(RUSTDESK_OHOS_LLVM_BIN
        "${CMAKE_CXX_COMPILER}" DIRECTORY)
    get_filename_component(RUSTDESK_OHOS_LLVM_DIR
        "${RUSTDESK_OHOS_LLVM_BIN}" DIRECTORY)
    get_filename_component(RUSTDESK_OHOS_NATIVE_ROOT
        "${RUSTDESK_OHOS_LLVM_DIR}" DIRECTORY)
    set(RUSTDESK_OHOS_SYSROOT "${RUSTDESK_OHOS_NATIVE_ROOT}/sysroot")
endif()
if(NOT EXISTS "${CMAKE_CXX_COMPILER}" OR
   NOT EXISTS "${RUSTDESK_OHOS_SYSROOT}")
    message(FATAL_ERROR
        "RustDesk: incomplete OHOS C++ toolchain: "
        "compiler=${CMAKE_CXX_COMPILER}, sysroot=${RUSTDESK_OHOS_SYSROOT}")
endif()

# Cargo splits RUSTFLAGS on spaces, which corrupts a Windows DevEco sysroot
# such as "C:/Program Files/...". CARGO_ENCODED_RUSTFLAGS uses ASCII unit
# separators and therefore preserves each linker argument as one rustc token.
string(ASCII 31 RUSTDESK_CARGO_RUSTFLAG_SEPARATOR)
set(RUSTDESK_CARGO_ENCODED_RUSTFLAGS
    "-Clink-arg=--target=${RUSTDESK_FFI_CLANG_TARGET}${RUSTDESK_CARGO_RUSTFLAG_SEPARATOR}-Clink-arg=--sysroot=${RUSTDESK_OHOS_SYSROOT}")

if(NOT EXISTS ${RUSTDESK_PROTO_DIR}/message.proto OR NOT EXISTS ${RUSTDESK_PROTO_DIR}/rendezvous.proto)
    message(FATAL_ERROR
        "RustDesk: missing protocol definitions in ${RUSTDESK_PROTO_DIR}. "
        "Restore the tracked hbb_common protobuf files before building the HAP.")
endif()

file(GLOB_RECURSE RUSTDESK_FFI_SOURCES CONFIGURE_DEPENDS
    ${RUSTDESK_FFI_DIR}/src/*.rs
    ${RUSTDESK_PROTO_DIR}/*.proto
)

if(NOT EXISTS ${RUSTDESK_OPUS_LIBRARY})
    message(FATAL_ERROR
        "RustDesk: missing ${RUSTDESK_OPUS_LIBRARY}. "
        "Run scripts/build_rustdesk_ffi_ohos.sh ${OHOS_ARCH} before building the HAP.")
endif()

add_custom_command(
    OUTPUT ${RUSTDESK_FFI_LIB}
    COMMAND ${CMAKE_COMMAND} -E env
        "OPUS_LIB_DIR=${RUSTDESK_OPUS_LIB_DIR}"
        "CC_${RUSTDESK_FFI_TARGET}=${CMAKE_C_COMPILER}"
        "CXX_${RUSTDESK_FFI_TARGET}=${CMAKE_CXX_COMPILER}"
        "AR_${RUSTDESK_FFI_TARGET}=${CMAKE_AR}"
        "RUSTC=${RUSTDESK_RUSTC_EXECUTABLE}"
        "CARGO_TARGET_${RUSTDESK_FFI_TARGET_ENV_UPPER}_LINKER=${CMAKE_CXX_COMPILER}"
        "CARGO_ENCODED_RUSTFLAGS=${RUSTDESK_CARGO_ENCODED_RUSTFLAGS}"
        ${RUSTDESK_CARGO_EXECUTABLE} build --release --target ${RUSTDESK_FFI_TARGET}
    WORKING_DIRECTORY ${RUSTDESK_FFI_DIR}
    DEPENDS
        ${RUSTDESK_FFI_DIR}/Cargo.toml
        ${RUSTDESK_FFI_DIR}/Cargo.lock
        ${RUSTDESK_FFI_DIR}/build.rs
        ${RUSTDESK_FFI_DIR}/.cargo/config.toml
        ${RUSTDESK_OPUS_LIBRARY}
        ${RUSTDESK_FFI_SOURCES}
    COMMENT "Building RustDesk FFI for ${RUSTDESK_FFI_TARGET}"
    VERBATIM
)
add_custom_target(rustdesk_ffi_build DEPENDS ${RUSTDESK_FFI_LIB})
add_dependencies(rdpnapi rustdesk_ffi_build)

add_library(rustdesk_ffi STATIC IMPORTED)
set_target_properties(rustdesk_ffi PROPERTIES
    IMPORTED_LOCATION ${RUSTDESK_FFI_LIB}
)
target_link_libraries(rdpnapi PUBLIC rustdesk_ffi)

if(RDP_BUILD_CALLBACK_TESTS)
    if(NOT USE_REAL_FREERDP)
        message(FATAL_ERROR
            "RDP_BUILD_CALLBACK_TESTS requires USE_REAL_FREERDP=ON so the "
            "callback carrier always registers all 9 production entries")
    endif()
    target_compile_definitions(rdpnapi PRIVATE RDP_NATIVE_CALLBACK_TESTING=1)
    add_executable(rdp_callback_tests
        test/callback_entry_integration_test.cpp
    )
    target_compile_definitions(rdp_callback_tests PRIVATE RDP_NATIVE_CALLBACK_TESTING=1)
    target_include_directories(rdp_callback_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
    target_compile_features(rdp_callback_tests PRIVATE cxx_std_17)
    target_link_libraries(rdp_callback_tests PRIVATE rdpnapi)
endif()
