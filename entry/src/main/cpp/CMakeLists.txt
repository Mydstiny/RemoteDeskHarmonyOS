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
    render/shared_session_context.cpp
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

# -- Moonlight native ownership and bounded Host API protocol core --
set(MOONLIGHT_HOST_API_SOURCE
    moonlight/core/MoonlightHostApi.cpp
)
set(MOONLIGHT_SECURE_IDENTITY_SOURCES
    moonlight/security/MoonlightSecureIdentity.cpp
    moonlight/security/MoonlightSecureIdentityPlatform.cpp
)
set(MOONLIGHT_PAIRING_SOURCE
    moonlight/pairing/MoonlightPairingManager.cpp
)
set(MOONLIGHT_HOST_CONTROL_SOURCE
    moonlight/control/MoonlightHostControl.cpp
)
set(MOONLIGHT_BRIDGE_SOURCE
    moonlight/bridge/MoonlightNativeBridge.cpp
)
set(MOONLIGHT_NAPI_SOURCE
    moonlight/moonlight_napi.cpp
)
set(MOONLIGHT_HTTP_RESPONSE_FRAMING_SOURCE
    moonlight/runtime/MoonlightHttpResponseFraming.cpp
)
set(MOONLIGHT_HTTP_REQUEST_FORMATTING_SOURCE
    moonlight/runtime/MoonlightHttpRequestFormatting.cpp
)
set(MOONLIGHT_REQUEST_UUID_SOURCE
    moonlight/runtime/MoonlightRequestUuid.cpp
)
set(MOONLIGHT_PRODUCT_RUNTIME_SOURCE
    ${MOONLIGHT_HTTP_REQUEST_FORMATTING_SOURCE}
    ${MOONLIGHT_HTTP_RESPONSE_FRAMING_SOURCE}
    ${MOONLIGHT_REQUEST_UUID_SOURCE}
    moonlight/runtime/MoonlightProductRuntime.cpp
    moonlight/runtime/MoonlightProductStreamingRuntime.cpp
)
set(MOONLIGHT_STREAM_CONFIG_SOURCE
    moonlight/media/MoonlightStreamConfig.cpp
)
set(MOONLIGHT_COMMON_C_ADAPTER_SOURCE
    moonlight/media/MoonlightCommonCAdapter.cpp
)
set(MOONLIGHT_VIDEO_BRIDGE_SOURCE
    moonlight/media/MoonlightVideoBridge.cpp
)
set(MOONLIGHT_VIDEO_DECODER_SINK_SOURCE
    moonlight/media/MoonlightVideoDecoderSink.cpp
)
set(MOONLIGHT_VIDEO_DECODER_SINK_PLATFORM_SOURCE
    moonlight/media/MoonlightVideoDecoderSinkPlatform.cpp
)
set(MOONLIGHT_VIDEO_SURFACE_LIFECYCLE_SOURCE
    moonlight/media/MoonlightVideoSurfaceLifecycle.cpp
)
set(MOONLIGHT_AUDIO_BRIDGE_SOURCE
    moonlight/media/MoonlightAudioBridge.cpp
)
set(MOONLIGHT_AUDIO_BRIDGE_PLATFORM_SOURCE
    moonlight/media/MoonlightAudioBridgePlatform.cpp
)
set(MOONLIGHT_AUDIO_PLAYER_SINK_SOURCE
    moonlight/media/MoonlightAudioPlayerSink.cpp
)
set(MOONLIGHT_AUDIO_PLAYER_SINK_PLATFORM_SOURCE
    moonlight/media/MoonlightAudioPlayerSinkPlatform.cpp
)
set(MOONLIGHT_PRODUCT_MEDIA_PORT_SOURCE
    moonlight/media/MoonlightProductMediaPort.cpp
    moonlight/media/MoonlightProductSessionMediaPort.cpp
)
set(MOONLIGHT_MEDIA_CLOCK_STATS_SOURCE
    moonlight/media/MoonlightMediaClockStats.cpp
)
set(MOONLIGHT_INPUT_BRIDGE_SOURCE
    moonlight/input/MoonlightInputBridge.cpp
)
set(MOONLIGHT_PRODUCT_INPUT_SOURCES
    moonlight/input/MoonlightCommonCInputPort.cpp
    moonlight/input/MoonlightProductInputRuntime.cpp
    moonlight/input/MoonlightGameControllerListener.cpp
)
set(MOONLIGHT_KEYBOARD_MAPPER_SOURCE
    moonlight/input/MoonlightKeyboardMapper.cpp
)
set(MOONLIGHT_POINTER_MAPPER_SOURCE
    moonlight/input/MoonlightPointerMapper.cpp
)
set(MOONLIGHT_TOUCH_MAPPER_SOURCE
    moonlight/input/MoonlightTouchMapper.cpp
)
set(MOONLIGHT_CONTROLLER_MAPPER_SOURCE
    moonlight/input/MoonlightControllerMapper.cpp
)
set(MOONLIGHT_CONTROLLER_FEEDBACK_SOURCE
    moonlight/input/MoonlightControllerFeedback.cpp
)
set(MOONLIGHT_INPUT_FLUSH_POLICY_SOURCE
    moonlight/input/MoonlightInputFlushPolicy.cpp
)
set(MOONLIGHT_CONTROLLER_AGGREGATOR_SOURCE
    moonlight/input/MoonlightControllerAggregator.cpp
)
set(MOONLIGHT_GAME_CONTROLLER_LISTENER_SOURCE
    moonlight/input/MoonlightGameControllerListener.cpp
)
set(MOONLIGHT_SOURCES
    moonlight/core/MoonlightSessionOwner.cpp
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
    ${MOONLIGHT_SOURCES}
    # N2-07 hidden exact-owner adapter. It is product-linked so its calls to
    # the one AudioPlayer registry are ABI-checked, but it has no NAPI/session
    # caller until S1 media lifecycle wiring.
    ${MOONLIGHT_AUDIO_PLAYER_SINK_SOURCE}
    ${MOONLIGHT_AUDIO_PLAYER_SINK_PLATFORM_SOURCE}
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
option(MOONLIGHT_BUILD_PLATFORM_PROBE
    "Build the standalone Moonlight API/ABI compile-link probe" OFF)
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
        test/moonlight_host_api_test.cpp
        test/moonlight_http_request_formatting_test.cpp
        test/moonlight_http_response_framing_test.cpp
        test/moonlight_request_uuid_test.cpp
        test/moonlight_secure_identity_test.cpp
        test/moonlight_pairing_manager_test.cpp
        test/moonlight_host_control_test.cpp
        test/moonlight_native_bridge_test.cpp
        test/moonlight_stream_config_test.cpp
        test/moonlight_session_owner_test.cpp
        test/moonlight_common_c_adapter_test.cpp
        test/moonlight_video_bridge_test.cpp
        test/moonlight_video_decoder_sink_test.cpp
        test/moonlight_video_surface_lifecycle_test.cpp
        test/moonlight_audio_bridge_test.cpp
        test/moonlight_audio_player_sink_test.cpp
        test/moonlight_media_clock_stats_test.cpp
        test/moonlight_input_bridge_test.cpp
        test/moonlight_keyboard_mapper_test.cpp
        test/moonlight_pointer_mapper_test.cpp
        test/moonlight_touch_mapper_test.cpp
        test/moonlight_controller_mapper_test.cpp
        test/moonlight_controller_feedback_test.cpp
        test/moonlight_input_flush_policy_test.cpp
        test/moonlight_controller_aggregator_test.cpp
        test/moonlight_game_controller_listener_test.cpp
        test/moonlight_product_input_runtime_test.cpp
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
        moonlight/core/MoonlightHostApi.cpp
        ${MOONLIGHT_HTTP_REQUEST_FORMATTING_SOURCE}
        ${MOONLIGHT_HTTP_RESPONSE_FRAMING_SOURCE}
        ${MOONLIGHT_REQUEST_UUID_SOURCE}
        moonlight/core/MoonlightSessionOwner.cpp
        moonlight/security/MoonlightSecureIdentity.cpp
        moonlight/pairing/MoonlightPairingManager.cpp
        moonlight/control/MoonlightHostControl.cpp
        ${MOONLIGHT_BRIDGE_SOURCE}
        ${MOONLIGHT_STREAM_CONFIG_SOURCE}
        ${MOONLIGHT_COMMON_C_ADAPTER_SOURCE}
        ${MOONLIGHT_VIDEO_BRIDGE_SOURCE}
        ${MOONLIGHT_VIDEO_DECODER_SINK_SOURCE}
        ${MOONLIGHT_VIDEO_SURFACE_LIFECYCLE_SOURCE}
        ${MOONLIGHT_AUDIO_BRIDGE_SOURCE}
        ${MOONLIGHT_AUDIO_BRIDGE_PLATFORM_SOURCE}
        ${MOONLIGHT_AUDIO_PLAYER_SINK_SOURCE}
        ${MOONLIGHT_MEDIA_CLOCK_STATS_SOURCE}
        ${MOONLIGHT_INPUT_BRIDGE_SOURCE}
        ${MOONLIGHT_KEYBOARD_MAPPER_SOURCE}
        ${MOONLIGHT_POINTER_MAPPER_SOURCE}
        ${MOONLIGHT_TOUCH_MAPPER_SOURCE}
        ${MOONLIGHT_CONTROLLER_MAPPER_SOURCE}
        ${MOONLIGHT_CONTROLLER_FEEDBACK_SOURCE}
        ${MOONLIGHT_INPUT_FLUSH_POLICY_SOURCE}
        ${MOONLIGHT_CONTROLLER_AGGREGATOR_SOURCE}
        ${MOONLIGHT_GAME_CONTROLLER_LISTENER_SOURCE}
        moonlight/input/MoonlightCommonCInputPort.cpp
        moonlight/input/MoonlightProductInputRuntime.cpp
        vnc/vnc_des.cpp
        vnc/vnc_cursor_protocol.cpp
        vnc/vnc_rfb_protocol.cpp
        vnc/vnc_certificate_probe.cpp
        vnc/vnc_transport.cpp
        vnc/vnc_rfb_engine.cpp
        test/vnc_keymap_test.cpp
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
        RDP_MOONLIGHT_HOST_OPUS_TEST=1
    )
    # RDP_TESTS_ONLY returns before the production-wide C++ standard block
    # below. Keep the standalone host test target explicit so headers using
    # std::optional and other C++17 facilities compile consistently.
    target_compile_features(rdp_native_tests PRIVATE cxx_std_17)
    target_include_directories(rdp_native_tests PRIVATE ${OPENSSL_INCLUDE_DIR})
    find_library(REMOTEDESK_HOST_OPUS_LIBRARY NAMES opus REQUIRED)
    target_link_libraries(rdp_native_tests PRIVATE
        OpenSSL::SSL OpenSSL::Crypto ZLIB::ZLIB
        ${REMOTEDESK_HOST_OPUS_LIBRARY}
    )
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

# Build the Host API core as a private archive. Until its typed N-API owner is
# introduced, no product translation unit references it, so the linker verifies
# the cross-ABI object without pulling it into librdpnapi.so. Once referenced,
# --exclude-libs keeps implementation and libc++ template details local.
add_library(remotedesk_moonlight_host_api STATIC ${MOONLIGHT_HOST_API_SOURCE})
target_compile_features(remotedesk_moonlight_host_api PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_host_api PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_compile_options(remotedesk_moonlight_host_api PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
set_target_properties(remotedesk_moonlight_host_api PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# N1-05 secure-identity boundary. As with the Host API core, this archive is
# cross-compiled but remains unreferenced by product code until the signed-HAP
# runtime backend is proven. Platform symbols therefore cannot alter the HAP's
# current dependency or exported-symbol surface.
add_library(remotedesk_moonlight_secure_identity STATIC
    ${MOONLIGHT_SECURE_IDENTITY_SOURCES}
)
target_compile_features(remotedesk_moonlight_secure_identity PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_secure_identity PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${OPENSSL_DIR}/include
)
target_compile_options(remotedesk_moonlight_secure_identity PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
set_target_properties(remotedesk_moonlight_secure_identity PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# N1-06 pairing protocol/state-machine boundary. This archive consumes only
# the project-owned Host API and secure identity contracts. It is compiled and
# linked privately but remains unreferenced by product code, so no pairing,
# trust, UI, cloud, or capability path is reachable from the signed HAP.
add_library(remotedesk_moonlight_pairing STATIC ${MOONLIGHT_PAIRING_SOURCE})
target_compile_features(remotedesk_moonlight_pairing PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_pairing PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${OPENSSL_DIR}/include
)
target_compile_options(remotedesk_moonlight_pairing PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
target_link_libraries(remotedesk_moonlight_pairing PRIVATE
    remotedesk_moonlight_host_api
    remotedesk_moonlight_secure_identity
)
set_target_properties(remotedesk_moonlight_pairing PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# N1-07 host-control orchestration boundary. It consumes the existing Host API
# and remains unreferenced by product/NAPI code until the runtime identity and
# authenticated transport receipts exist. Catalog snapshots are process-local;
# this target has no ArkTS cache, RDB, cloud, media, or input dependency.
add_library(remotedesk_moonlight_host_control STATIC ${MOONLIGHT_HOST_CONTROL_SOURCE})
target_compile_features(remotedesk_moonlight_host_control PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_host_control PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${OPENSSL_DIR}/include
)
target_compile_options(remotedesk_moonlight_host_control PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
target_link_libraries(remotedesk_moonlight_host_control PRIVATE
    remotedesk_moonlight_host_api
)
set_target_properties(remotedesk_moonlight_host_control PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# N1-08 typed bridge and N-API owner. Keep this boundary in a private archive
# and link it after the product's existing static dependencies. The rdpnapi
# --exclude-libs contract preserves the established dynamic ABI when libc++
# emits duplicate COMDAT helpers and keeps bridge implementation details local.
# Only MoonlightNapi::Init is referenced by napi_init.cpp.
add_library(remotedesk_moonlight_bridge STATIC
    ${MOONLIGHT_BRIDGE_SOURCE}
    ${MOONLIGHT_NAPI_SOURCE}
    ${MOONLIGHT_PRODUCT_RUNTIME_SOURCE}
)
target_compile_features(remotedesk_moonlight_bridge PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_bridge PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${OPENSSL_DIR}/include
)
target_link_libraries(remotedesk_moonlight_bridge PRIVATE
    remotedesk_moonlight_host_control
    remotedesk_moonlight_pairing
    remotedesk_moonlight_host_api
    remotedesk_moonlight_secure_identity
)
set_target_properties(remotedesk_moonlight_bridge PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# N2-01 pure requested/effective stream-offer resolver. It has no common-c,
# N-API, ArkTS, media, audio, input, network, or database include/link edge.
# Cross-compiling the private archive proves both product ABIs while the lack of
# a product caller keeps all runtime/release capability truth unchanged.
add_library(remotedesk_moonlight_stream_config STATIC
    ${MOONLIGHT_STREAM_CONFIG_SOURCE}
)
target_compile_features(remotedesk_moonlight_stream_config PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_stream_config PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_compile_options(remotedesk_moonlight_stream_config PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
set_target_properties(remotedesk_moonlight_stream_config PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# N2-02 sole common-c adapter. The public header remains project-owned C++17;
# only its implementation sees Limelight.h and the official callback structs.
# It stays in an unreferenced private archive until media/runtime proof exists.
add_library(remotedesk_moonlight_common_c_adapter STATIC
    ${MOONLIGHT_COMMON_C_ADAPTER_SOURCE}
)
target_compile_features(remotedesk_moonlight_common_c_adapter PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_common_c_adapter PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_compile_options(remotedesk_moonlight_common_c_adapter PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
target_link_libraries(remotedesk_moonlight_common_c_adapter PRIVATE
    remotedesk_moonlight_stream_config
)
set_target_properties(remotedesk_moonlight_common_c_adapter PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# N2-03 decode-unit ownership/assembly boundary. It has no OH_AVCodec, Surface,
# NAPI, ArkTS, UI, or common-c dependency and remains dormant until N2-04.
add_library(remotedesk_moonlight_video_bridge STATIC
    ${MOONLIGHT_VIDEO_BRIDGE_SOURCE}
)
target_compile_features(remotedesk_moonlight_video_bridge PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_video_bridge PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_compile_options(remotedesk_moonlight_video_bridge PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
target_link_libraries(remotedesk_moonlight_video_bridge PRIVATE
    remotedesk_moonlight_stream_config
)
set_target_properties(remotedesk_moonlight_video_bridge PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)
target_link_libraries(remotedesk_moonlight_common_c_adapter PRIVATE
    remotedesk_moonlight_video_bridge
)

# N2-04 exact-owner decoder sink plus the N2-05 pure Surface lifecycle. The
# lifecycle/status implementation is host-tested; the OHOS translation unit
# may only consume the existing shared
# decoder/renderer owner APIs and remains unreferenced until a runtime-proven
# renderer binding is injected by the future session coordinator.
add_library(remotedesk_moonlight_video_decoder_sink STATIC
    ${MOONLIGHT_VIDEO_DECODER_SINK_SOURCE}
    ${MOONLIGHT_VIDEO_DECODER_SINK_PLATFORM_SOURCE}
    ${MOONLIGHT_VIDEO_SURFACE_LIFECYCLE_SOURCE}
)
target_compile_features(remotedesk_moonlight_video_decoder_sink PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_video_decoder_sink PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_compile_options(remotedesk_moonlight_video_decoder_sink PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
target_link_libraries(remotedesk_moonlight_video_decoder_sink PRIVATE
    remotedesk_moonlight_video_bridge
)
set_target_properties(remotedesk_moonlight_video_decoder_sink PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# N2-06 borrowed Opus callback -> bounded owned decode -> S16LE handoff.
# The archive has no product/NAPI caller and deliberately does not include or
# link the existing OHAudio owner. The platform translation unit consumes only
# the already pinned libopus 1.5.2-fixed artifact selected later in this file.
add_library(remotedesk_moonlight_audio_bridge STATIC
    ${MOONLIGHT_AUDIO_BRIDGE_SOURCE}
    ${MOONLIGHT_AUDIO_BRIDGE_PLATFORM_SOURCE}
)
target_compile_features(remotedesk_moonlight_audio_bridge PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_audio_bridge PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_compile_options(remotedesk_moonlight_audio_bridge PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
set_target_properties(remotedesk_moonlight_audio_bridge PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# Product-only composition of the existing exact-owner video, Opus and shared
# OHAudio seams. Construction is per Moonlight session; it creates no global
# renderer, decoder, queue or worker.
add_library(remotedesk_moonlight_product_media STATIC
    ${MOONLIGHT_PRODUCT_MEDIA_PORT_SOURCE}
)
target_compile_features(remotedesk_moonlight_product_media PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_product_media PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_compile_options(remotedesk_moonlight_product_media PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
target_link_libraries(remotedesk_moonlight_product_media PRIVATE
    remotedesk_moonlight_audio_bridge
    remotedesk_moonlight_video_decoder_sink
    remotedesk_moonlight_video_bridge
    remotedesk_moonlight_common_c_adapter
)
set_target_properties(remotedesk_moonlight_product_media PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# N2-08 fixed-window native aggregation. Keep it as a private hidden archive:
# the product build compiles and ABI-checks it, while the absence of a session
# coordinator caller cannot instantiate STL helpers in rdpnapi's dynamic ABI.
add_library(remotedesk_moonlight_media_clock_stats STATIC
    ${MOONLIGHT_MEDIA_CLOCK_STATS_SOURCE}
)
target_compile_features(remotedesk_moonlight_media_clock_stats PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_media_clock_stats PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_compile_options(remotedesk_moonlight_media_clock_stats PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
set_target_properties(remotedesk_moonlight_media_clock_stats PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# N3-01 exact-owner input admission/router. It remains a hidden private
# archive with no product caller until the later mapping and NAPI tasks.
add_library(remotedesk_moonlight_input_bridge STATIC
    ${MOONLIGHT_INPUT_BRIDGE_SOURCE}
)
target_compile_features(remotedesk_moonlight_input_bridge PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_input_bridge PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_compile_options(remotedesk_moonlight_input_bridge PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
set_target_properties(remotedesk_moonlight_input_bridge PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# N3-02 HarmonyOS-key to official Moonlight keyboard contract. It remains a
# hidden private archive with no InputHandler, NAPI, ArkTS, UI, or product
# caller until the later input assembly tasks.
add_library(remotedesk_moonlight_keyboard_mapper STATIC
    ${MOONLIGHT_KEYBOARD_MAPPER_SOURCE}
)
target_compile_features(remotedesk_moonlight_keyboard_mapper PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_keyboard_mapper PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_compile_options(remotedesk_moonlight_keyboard_mapper PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
set_target_properties(remotedesk_moonlight_keyboard_mapper PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# N3-03 content-rect, relative pointer, five-button, and high-resolution
# scroll contract. It remains a hidden private archive with no InputHandler,
# NAPI, ArkTS, UI, platform capture, or product caller.
add_library(remotedesk_moonlight_pointer_mapper STATIC
    ${MOONLIGHT_POINTER_MAPPER_SOURCE}
)
target_compile_features(remotedesk_moonlight_pointer_mapper PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_pointer_mapper PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_compile_options(remotedesk_moonlight_pointer_mapper PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
set_target_properties(remotedesk_moonlight_pointer_mapper PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# N3-04 direct-touch and touchpad gesture contract. It reuses the N3-03
# pointer transaction layer and remains a hidden private archive with no
# InputHandler, NAPI, ArkTS, UI, platform listener, or product caller.
add_library(remotedesk_moonlight_touch_mapper STATIC
    ${MOONLIGHT_TOUCH_MAPPER_SOURCE}
)
target_compile_features(remotedesk_moonlight_touch_mapper PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_touch_mapper PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_compile_options(remotedesk_moonlight_touch_mapper PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
set_target_properties(remotedesk_moonlight_touch_mapper PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)
target_link_libraries(remotedesk_moonlight_touch_mapper PRIVATE
    remotedesk_moonlight_pointer_mapper
)

# N3-05 API 23 physical-controller projection. The mapper is deliberately
# limited to one stable slot until two-controller real-device evidence exists.
# It remains a hidden private archive with no GameControllerKit listener,
# InputHandler, NAPI, ArkTS, UI, cloud, or product caller.
add_library(remotedesk_moonlight_controller_mapper STATIC
    ${MOONLIGHT_CONTROLLER_MAPPER_SOURCE}
)
target_compile_features(remotedesk_moonlight_controller_mapper PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_controller_mapper PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_compile_options(remotedesk_moonlight_controller_mapper PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
set_target_properties(remotedesk_moonlight_controller_mapper PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)
target_link_libraries(remotedesk_moonlight_controller_mapper PRIVATE
    remotedesk_moonlight_input_bridge
)

# N3-06 capability-gated controller feedback contract. API 23 has no proven
# official haptics/LED/sensor/battery surface, so product evidence is all false.
# This remains a hidden private archive with no listener or product caller.
add_library(remotedesk_moonlight_controller_feedback STATIC
    ${MOONLIGHT_CONTROLLER_FEEDBACK_SOURCE}
)
target_compile_features(remotedesk_moonlight_controller_feedback PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_controller_feedback PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_compile_options(remotedesk_moonlight_controller_feedback PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
set_target_properties(remotedesk_moonlight_controller_feedback PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)
target_link_libraries(remotedesk_moonlight_controller_feedback PRIVATE
    remotedesk_moonlight_input_bridge
)

# N3-07 single input-release orchestrator. It composes the existing mapper and
# input-bridge contracts and remains dormant with no product or UI caller.
add_library(remotedesk_moonlight_input_flush_policy STATIC
    ${MOONLIGHT_INPUT_FLUSH_POLICY_SOURCE}
)
target_compile_features(remotedesk_moonlight_input_flush_policy PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_input_flush_policy PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_compile_options(remotedesk_moonlight_input_flush_policy PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
set_target_properties(remotedesk_moonlight_input_flush_policy PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)
target_link_libraries(remotedesk_moonlight_input_flush_policy PRIVATE
    remotedesk_moonlight_touch_mapper
    remotedesk_moonlight_pointer_mapper
    remotedesk_moonlight_keyboard_mapper
    remotedesk_moonlight_controller_mapper
    remotedesk_moonlight_input_bridge
)

# N3-08 fixed-capacity physical/virtual controller aggregator and normalized
# layout validator. It reuses N3-05/N3-07 for the only controller wire path,
# slot ownership, backpressure, lifecycle release, and source handoff. This
# archive remains dormant with no GameController listener, NAPI, ArkTS, UI,
# cloud, thread, queue, or product caller.
add_library(remotedesk_moonlight_controller_aggregator STATIC
    ${MOONLIGHT_CONTROLLER_AGGREGATOR_SOURCE}
)
target_compile_features(remotedesk_moonlight_controller_aggregator PRIVATE
    cxx_std_17
)
target_include_directories(remotedesk_moonlight_controller_aggregator PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_compile_options(remotedesk_moonlight_controller_aggregator PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
set_target_properties(remotedesk_moonlight_controller_aggregator PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)
target_link_libraries(remotedesk_moonlight_controller_aggregator PRIVATE
    remotedesk_moonlight_input_flush_policy
    remotedesk_moonlight_controller_mapper
)

# S1-05A sole product input assembly. Semantic platform input is mapped by the
# existing N3-02..N3-08 layers and projected to official LiSend* calls by one
# synchronous port. GameControllerKit is registered only while an exact
# Moonlight session owns this runtime; other protocols never initialize it.
add_library(remotedesk_moonlight_product_input STATIC
    ${MOONLIGHT_PRODUCT_INPUT_SOURCES}
)
target_compile_features(remotedesk_moonlight_product_input PRIVATE cxx_std_17)
target_include_directories(remotedesk_moonlight_product_input PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_compile_options(remotedesk_moonlight_product_input PRIVATE
    -fvisibility=hidden
    -fvisibility-inlines-hidden
)
set_target_properties(remotedesk_moonlight_product_input PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)
target_link_libraries(remotedesk_moonlight_product_input PRIVATE
    remotedesk_moonlight_controller_aggregator
    remotedesk_moonlight_input_flush_policy
    remotedesk_moonlight_controller_mapper
    remotedesk_moonlight_touch_mapper
    remotedesk_moonlight_pointer_mapper
    remotedesk_moonlight_keyboard_mapper
    remotedesk_moonlight_input_bridge
    remotedesk_moonlight_common_c_adapter
)
if(CMAKE_SYSTEM_NAME STREQUAL "OHOS")
    # Keep GameControllerKit outside librdpnapi's mandatory dependency graph.
    # The Moonlight-only listener resolves it when an exact stream session
    # activates physical-controller input; libdl is a static SDK shim.
    target_link_libraries(remotedesk_moonlight_product_input PRIVATE dl)
endif()
target_link_libraries(remotedesk_moonlight_bridge PRIVATE
    remotedesk_moonlight_product_input
)

# 定义共享库目标
add_library(rdpnapi SHARED ${ALL_SOURCES})
target_compile_definitions(rdpnapi PRIVATE
    REMOTEDESK_GIT_SHORT_SHA="${REMOTEDESK_GIT_SHORT_SHA}"
    REMOTEDESK_BUILD_TIME_UTC="${REMOTEDESK_BUILD_TIME_UTC}"
)
target_link_libraries(rdpnapi PRIVATE
    remotedesk_moonlight_product_media
    remotedesk_moonlight_product_input
    remotedesk_moonlight_controller_aggregator
    remotedesk_moonlight_input_flush_policy
    remotedesk_moonlight_controller_feedback
    remotedesk_moonlight_controller_mapper
    remotedesk_moonlight_touch_mapper
    remotedesk_moonlight_pointer_mapper
    remotedesk_moonlight_keyboard_mapper
    remotedesk_moonlight_input_bridge
    remotedesk_moonlight_media_clock_stats
    remotedesk_moonlight_audio_bridge
    remotedesk_moonlight_video_decoder_sink
    remotedesk_moonlight_video_bridge
    remotedesk_moonlight_common_c_adapter
    remotedesk_moonlight_stream_config
    remotedesk_moonlight_host_control
    remotedesk_moonlight_pairing
    remotedesk_moonlight_host_api
    remotedesk_moonlight_secure_identity
    libhuks_ndk.z.so
    libasset_ndk.z.so
)
target_link_options(rdpnapi PRIVATE
    "-Wl,--exclude-libs,libremotedesk_moonlight_host_control.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_pairing.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_host_api.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_secure_identity.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_bridge.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_stream_config.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_common_c_adapter.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_video_bridge.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_video_decoder_sink.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_audio_bridge.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_product_media.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_product_input.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_media_clock_stats.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_input_bridge.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_keyboard_mapper.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_pointer_mapper.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_touch_mapper.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_controller_mapper.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_controller_feedback.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_input_flush_policy.a"
    "-Wl,--exclude-libs,libremotedesk_moonlight_controller_aggregator.a"
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
    libqos.so                     # 前台解码/呈现线程 QoS
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

# N1-02 build-only Moonlight boundary. The pinned common-c/ENet archives are
# linked privately and expose no NAPI or runtime registration. Product sources
# do not inherit upstream include paths or definitions; callable/session work
# begins in later checkpoints.
set(REMOTEDESK_MOONLIGHT_OPENSSL_ROOT "${OPENSSL_DIR}")
add_subdirectory(moonlight)
target_link_libraries(rdpnapi PRIVATE remotedesk_moonlight_common)
target_link_libraries(remotedesk_moonlight_common_c_adapter PRIVATE
    remotedesk_moonlight_common
)

# Explicitly built in N2-02 receipts. Calling the hidden smoke symbol forces
# the otherwise dormant archive to resolve all official common-c entry points.
file(GENERATE
    OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/moonlight_common_c_adapter_link_probe.cpp"
    CONTENT "#include \"moonlight/media/MoonlightCommonCAdapter.h\"\nint main() { return remotedesk::moonlight::MoonlightCommonCAdapter::productionLinkSmoke(); }\n"
)
add_executable(moonlight_common_c_adapter_link_probe EXCLUDE_FROM_ALL
    "${CMAKE_CURRENT_BINARY_DIR}/moonlight_common_c_adapter_link_probe.cpp"
)
set_target_properties(moonlight_common_c_adapter_link_probe PROPERTIES
    EXPORT_COMPILE_COMMANDS OFF
)
target_compile_features(moonlight_common_c_adapter_link_probe PRIVATE cxx_std_17)
target_include_directories(moonlight_common_c_adapter_link_probe PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_link_libraries(moonlight_common_c_adapter_link_probe PRIVATE
    remotedesk_moonlight_common_c_adapter
    remotedesk_moonlight_common
)

# G0 compile/link probe. This target is opt-in and excluded from rdpnapi/HAP,
# so introducing the capability gate cannot change any existing protocol's
# runtime dependency graph. Runtime probing is added later through a typed
# in-app NAPI boundary after its owner/lifecycle contract exists.
if(MOONLIGHT_BUILD_PLATFORM_PROBE)
    add_executable(moonlight_platform_link_probe EXCLUDE_FROM_ALL
        moonlight/probe/moonlight_platform_link_probe.cpp
    )
    target_compile_features(moonlight_platform_link_probe PRIVATE cxx_std_17)
    target_include_directories(moonlight_platform_link_probe PRIVATE
        ${OPENSSL_DIR}/include
    )
    target_link_libraries(moonlight_platform_link_probe PRIVATE
        remotedesk_moonlight_secure_identity
        libnative_media_codecbase.so
        libohaudio.so
        libohgame_controller.z.so
        libhuks_ndk.z.so
        libasset_ndk.z.so
        libohinput.so
        libnet_connection.so
        ssl
        crypto
    )
    set_target_properties(moonlight_platform_link_probe PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/moonlight-probe
    )
endif()

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

# Reuse the exact same pinned archive as RustDesk. This link-only edge does not
# create another Opus build/version; the dormant Moonlight archive is not
# pulled into rdpnapi until a future product media port references it.
target_link_libraries(remotedesk_moonlight_audio_bridge PRIVATE
    ${RUSTDESK_OPUS_LIBRARY}
)

# Build explicitly in N2-06 receipts. It forces the otherwise dormant platform
# port to resolve the multistream create/decode/destroy/version ABI without
# adding a product/NAPI caller or a file to the signed HAP.
file(GENERATE
    OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/moonlight_audio_bridge_link_probe.cpp"
    CONTENT "#include \"moonlight/media/MoonlightAudioBridge.h\"\nint main() { return remotedesk::moonlight::MoonlightAudioBridge::productionLinkSmoke(); }\n"
)
add_executable(moonlight_audio_bridge_link_probe EXCLUDE_FROM_ALL
    "${CMAKE_CURRENT_BINARY_DIR}/moonlight_audio_bridge_link_probe.cpp"
)
set_target_properties(moonlight_audio_bridge_link_probe PROPERTIES
    EXPORT_COMPILE_COMMANDS OFF
)
target_compile_features(moonlight_audio_bridge_link_probe PRIVATE cxx_std_17)
target_include_directories(moonlight_audio_bridge_link_probe PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)
target_link_libraries(moonlight_audio_bridge_link_probe PRIVATE
    remotedesk_moonlight_audio_bridge
    ${RUSTDESK_OPUS_LIBRARY}
)

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

# Deliberately last: existing product/static-library COMDAT definitions retain
# their established visibility before the dormant Moonlight bridge is pulled.
target_link_libraries(rdpnapi PRIVATE remotedesk_moonlight_bridge)

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
