/**
 * rustdesk_bridge.cpp — RustDesk 协议适配器
 *
 * 双模式架构:
 *   1. RD_MODE_IPC (默认, 生产安全): Unix Domain Socket → rustdesk_helper 进程
 *      - 不实现 RustDesk 私有协议, 仅 IPC 转发
 *      - 密码/密钥通过 IPC 加密通道传输
 *      - AGPL 许可证隔离
 *
 *   2. RD_MODE_EXPERIMENTAL (RUSTDESK_EXPERIMENTAL 宏, 仅 dev):
 *      - 手写 TCP 握手骨架 (仅用于协议研究/开发调试)
 *      - 密码明文发送风险 — 不得用于正式构建
 */

#include "rustdesk_bridge.h"
#include "rustdesk_display_control_plane.h"
#include "rustdesk_ffi_lifetime_policy.h"
#include "rustdesk_ipc.h"
#include "rustdesk_multi_canvas_policy.h"
#include "common/happy_eyeballs_connector.h"
#include "common/safe_log.h"
#include "extensions/extension_registry.h"
#include "render/hw_decoder.h"
#include "render/video_perf_counters.h"
#include "rustdesk_peer_presentation_policy.h"
#include <hilog/log.h>
#include <algorithm>
#include <condition_variable>
#include <cctype>
#include <future>
#include <memory>
#include <string>
#include <system_error>
#include <thread>
#include <unordered_set>

// Rust FFI 函数声明 (extern "C", 来自 librustdesk_ffi.a)
#ifdef RUSTDESK_USE_REAL_CORE
extern "C" {
    void* rustdesk_connect(
        const void* cfg,
        void (*on_frame)(const void*, void*),
        void (*on_audio)(const void*, void*),
        void (*on_cursor)(const void*, void*),
        void (*on_disconnect)(int, const char*, void*),
        void* user_data);
    void* rustdesk_connect_v2(
        const void* cfg,
        void (*on_frame)(const void*, void*),
        void (*on_audio)(const void*, void*),
        void (*on_cursor)(const void*, void*),
        void (*on_disconnect)(int, const char*, void*),
        void (*on_display)(const void*, void*),
        void* user_data);
    void* rustdesk_connect_v3(
        const void* cfg,
        void (*on_frame)(const void*, void*),
        void (*on_audio)(const void*, void*),
        void (*on_cursor)(const void*, void*),
        void (*on_disconnect)(int, const char*, void*),
        void (*on_display)(const void*, void*),
        void (*on_auth)(int, const char*, void*),
        void* user_data);
    void* rustdesk_connect_v4(
        const void* cfg,
        void (*on_frame)(const void*, void*),
        void (*on_audio)(const void*, void*),
        void (*on_cursor)(const void*, void*),
        void (*on_disconnect)(int, const char*, void*),
        void (*on_display)(const void*, void*),
        void (*on_auth)(int, const char*, void*),
        void (*on_progress)(int, const char*, void*),
        void* user_data);
    void* rustdesk_connect_v5(
        const void* cfg,
        void (*on_frame)(const void*, void*),
        void (*on_audio)(const void*, void*),
        void (*on_cursor)(const void*, void*),
        void (*on_disconnect)(int, const char*, void*),
        void (*on_display)(const void*, void*),
        void (*on_auth)(int, const char*, void*),
        void (*on_progress)(int, const char*, void*),
        bool (*on_peer_platform)(const char*, void*),
        void* user_data);
    void* rustdesk_connect_v6(
        const void* cfg,
        void (*on_frame)(const void*, void*),
        void (*on_audio)(const void*, void*),
        void (*on_cursor)(const void*, void*),
        void (*on_disconnect)(int, const char*, void*),
        void (*on_display)(const void*, void*),
        void (*on_auth)(int, const char*, void*),
        void (*on_progress)(int, const char*, void*),
        bool (*on_peer_platform)(const char*, void*),
        void* user_data);
    void  rustdesk_disconnect(void* handle);
    void  rustdesk_cancel_pending_connect();
    void  rustdesk_cancel_pending_connect_for_session(uint64_t session_id);
    bool  rustdesk_submit_2fa(const char* code);
    bool  rustdesk_submit_2fa_for_session(uint64_t session_id, const char* code);
    void  rustdesk_send_key(void* handle, unsigned int scancode, bool pressed);
    void  rustdesk_send_mouse(void* handle, int x, int y, unsigned int button, bool pressed);
    void  rustdesk_send_mouse_wheel(void* handle, int x, int y, int delta);
    bool  rustdesk_send_mouse_wheel_2d(void* handle, int x, int y);
    void  rustdesk_send_text(void* handle, const char* text);
    bool  rustdesk_change_display_resolution(void* handle, int display, int width, int height);
    bool  rustdesk_send_touch_scale(void* handle, int scale);
    bool  rustdesk_send_touch_pan(void* handle, int phase, int x, int y);
    int   rustdesk_send_file(void* handle, uint64_t transfer_id, const char* remote_path,
                             const unsigned char* data, unsigned int len);
    struct RustDeskFfiTransferStatus { uint32_t state; uint64_t transferId; uint64_t transferredBytes;
        uint64_t totalBytes; uint32_t diagnosticCode; };
    bool  rustdesk_get_transfer_status(void* handle, RustDeskFfiTransferStatus* out_status);
    size_t rustdesk_get_transfer_error(void* handle, char* buffer, size_t buffer_len);
    void  rustdesk_send_clipboard(void* handle, const unsigned char* data, unsigned int len);
    size_t rustdesk_get_clipboard(void* handle, unsigned char* buffer, size_t buffer_len);
    bool  rustdesk_request_frame_refresh(void* handle);
    bool  rustdesk_report_video_pressure(void* handle, int level);
    struct RustDeskFfiStreamStats {
        uint32_t version;
        uint32_t state;
        uint32_t last_delay_ms;
        uint32_t target_bitrate_kbps;
        uint64_t video_messages;
        uint64_t video_frames;
        uint64_t keyframes;
        uint64_t encoded_bytes;
        uint64_t audio_frames;
        uint64_t cadence_gaps;
        uint64_t max_cadence_gap_ms;
        uint64_t test_delay_count;
        int32_t actual_codec;
        int32_t width;
        int32_t height;
        int32_t connection_path;
    };
    bool  rustdesk_get_stream_stats(void* handle, RustDeskFfiStreamStats* out_stats);
    struct RustDeskFfiQualityState {
        uint32_t version;
        int32_t rawQuality;
        int32_t effectiveQuality;
        int32_t sentQuality;
        int32_t profile;
        uint32_t fps;
        uint64_t requestedGeneration;
        uint64_t appliedGeneration;
        uint32_t updateStatus;
        uint32_t reserved;
    };
    bool  rustdesk_set_image_quality(void* handle, int quality);
    bool  rustdesk_get_quality_state(void* handle, RustDeskFfiQualityState* out_state);
    struct RustDeskFfiPermissionState {
        uint32_t version;
        uint32_t knownMask;
        uint32_t enabledMask;
        uint32_t reserved;
    };
    bool  rustdesk_get_permission_state(void* handle, RustDeskFfiPermissionState* out_state);
    struct RustDeskFfiDisplaySnapshot {
        uint32_t version;
        int32_t currentDisplay;
        int32_t width;
        int32_t height;
        int32_t originalWidth;
        int32_t originalHeight;
        int32_t scaleMilli;
        uint32_t geometryEpoch;
        uint32_t resolutionCount;
    };
    struct RustDeskFfiResolution { int32_t width; int32_t height; };
    struct RustDeskFfiDisplayInfoSnapshot {
        int32_t display;
        int32_t x;
        int32_t y;
        int32_t width;
        int32_t height;
        int32_t originalWidth;
        int32_t originalHeight;
        int32_t scaleMilli;
        uint8_t online;
        uint8_t cursorEmbedded;
        uint8_t reserved[2];
        uint32_t nameLen;
        uint8_t name[128];
        uint32_t resolutionOffset;
        uint32_t resolutionCount;
    };
    bool  rustdesk_get_display_snapshot(void* handle, RustDeskFfiDisplaySnapshot* out_snapshot,
                                        RustDeskFfiResolution* out_resolutions, size_t capacity);
    bool  rustdesk_get_display_list(void* handle, RustDeskFfiDisplayInfoSnapshot* out_displays,
                                    size_t display_capacity, RustDeskFfiResolution* out_resolutions,
                                    size_t resolution_capacity, size_t* out_display_count,
                                    size_t* out_resolution_count);
    bool  rustdesk_switch_display(void* handle, int display);
    bool  rustdesk_capture_displays(void* handle, const int* displays, size_t count);
    bool  rustdesk_refresh_video_display(void* handle, int display);
    size_t rustdesk_last_error(char* buffer, size_t buffer_len);
    const char* rustdesk_version();
}

static constexpr uint32_t kRustDeskStreamStatsVersion = 1;
static constexpr uint32_t kRustDeskQualityStateVersion = 1;
static constexpr uint32_t kRustDeskPermissionStateVersion = 1;
static constexpr uint32_t kRustDeskPermissionKeyboard = 1U << 0;
static constexpr uint32_t kRustDeskPermissionClipboard = 1U << 2;
static constexpr uint32_t kRustDeskPermissionFile = 1U << 4;
static constexpr uint32_t kRustDeskDisplaySnapshotVersion = 1;
static constexpr uint32_t kRustDeskVideoFrameAbiVersion = 2;
static_assert(sizeof(RustDeskFfiStreamStats) == 96,
              "RustDeskStreamStats ABI size changed; update both sides together");
static_assert(alignof(RustDeskFfiStreamStats) == 8,
              "RustDeskStreamStats ABI alignment changed");
static_assert(offsetof(RustDeskFfiStreamStats, version) == 0);
static_assert(offsetof(RustDeskFfiStreamStats, state) == 4);
static_assert(offsetof(RustDeskFfiStreamStats, last_delay_ms) == 8);
static_assert(offsetof(RustDeskFfiStreamStats, target_bitrate_kbps) == 12);
static_assert(offsetof(RustDeskFfiStreamStats, video_messages) == 16);
static_assert(offsetof(RustDeskFfiStreamStats, video_frames) == 24);
static_assert(offsetof(RustDeskFfiStreamStats, keyframes) == 32);
static_assert(offsetof(RustDeskFfiStreamStats, encoded_bytes) == 40);
static_assert(offsetof(RustDeskFfiStreamStats, audio_frames) == 48);
static_assert(offsetof(RustDeskFfiStreamStats, cadence_gaps) == 56);
static_assert(offsetof(RustDeskFfiStreamStats, max_cadence_gap_ms) == 64);
static_assert(offsetof(RustDeskFfiStreamStats, test_delay_count) == 72);
static_assert(offsetof(RustDeskFfiStreamStats, actual_codec) == 80);
static_assert(offsetof(RustDeskFfiStreamStats, width) == 84);
static_assert(offsetof(RustDeskFfiStreamStats, height) == 88);
static_assert(offsetof(RustDeskFfiStreamStats, connection_path) == 92);
static_assert(sizeof(RustDeskFfiQualityState) == 48,
              "RustDeskQualityState ABI size changed; update both sides together");
static_assert(alignof(RustDeskFfiQualityState) == 8,
              "RustDeskQualityState ABI alignment changed");
static_assert(offsetof(RustDeskFfiQualityState, version) == 0);
static_assert(offsetof(RustDeskFfiQualityState, rawQuality) == 4);
static_assert(offsetof(RustDeskFfiQualityState, effectiveQuality) == 8);
static_assert(offsetof(RustDeskFfiQualityState, sentQuality) == 12);
static_assert(offsetof(RustDeskFfiQualityState, profile) == 16);
static_assert(offsetof(RustDeskFfiQualityState, fps) == 20);
static_assert(offsetof(RustDeskFfiQualityState, requestedGeneration) == 24);
static_assert(offsetof(RustDeskFfiQualityState, appliedGeneration) == 32);
static_assert(offsetof(RustDeskFfiQualityState, updateStatus) == 40);
static_assert(sizeof(RustDeskFfiPermissionState) == 16,
              "RustDeskPermissionState ABI size changed; update both sides together");
static_assert(alignof(RustDeskFfiPermissionState) == 4,
              "RustDeskPermissionState ABI alignment changed");
static_assert(sizeof(RustDeskFfiDisplaySnapshot) == 36,
              "RustDeskDisplaySnapshot ABI size changed; update both sides together");
static_assert(alignof(RustDeskFfiDisplaySnapshot) == 4,
              "RustDeskDisplaySnapshot ABI alignment changed");
static_assert(offsetof(RustDeskFfiDisplaySnapshot, version) == 0);
static_assert(offsetof(RustDeskFfiDisplaySnapshot, currentDisplay) == 4);
static_assert(offsetof(RustDeskFfiDisplaySnapshot, width) == 8);
static_assert(offsetof(RustDeskFfiDisplaySnapshot, height) == 12);
static_assert(offsetof(RustDeskFfiDisplaySnapshot, originalWidth) == 16);
static_assert(offsetof(RustDeskFfiDisplaySnapshot, originalHeight) == 20);
static_assert(offsetof(RustDeskFfiDisplaySnapshot, scaleMilli) == 24);
static_assert(offsetof(RustDeskFfiDisplaySnapshot, geometryEpoch) == 28);
static_assert(offsetof(RustDeskFfiDisplaySnapshot, resolutionCount) == 32);
static_assert(sizeof(RustDeskFfiResolution) == 8,
              "RustDeskResolution ABI size changed; update both sides together");
static_assert(sizeof(RustDeskFfiDisplayInfoSnapshot) == 176,
              "RustDeskDisplayInfoSnapshot ABI size changed; update both sides together");
static_assert(alignof(RustDeskFfiDisplayInfoSnapshot) == 4,
              "RustDeskDisplayInfoSnapshot ABI alignment changed");
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, display) == 0);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, x) == 4);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, y) == 8);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, width) == 12);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, height) == 16);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, originalWidth) == 20);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, originalHeight) == 24);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, scaleMilli) == 28);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, online) == 32);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, cursorEmbedded) == 33);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, nameLen) == 36);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, name) == 40);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, resolutionOffset) == 168);
static_assert(offsetof(RustDeskFfiDisplayInfoSnapshot, resolutionCount) == 172);
#endif
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <poll.h>
#include <unistd.h>
#include <fcntl.h>
#include <cstring>
#include <cerrno>
#include <cstdlib>
#include <cstddef>
#include <vector>
#include <thread>
#include <atomic>
#include <mutex>
#include <chrono>
#include <future>
#include <pthread.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0002
#define LOG_TAG "RUSTDESK_BRIDGE"

#define RD_DEFAULT_TCP_PORT  21116
#define RD_IPC_CONNECT_TIMEOUT 5

// 运行时 socket 路径 (可被 ArkTS setHelperSocketPath NAPI 覆盖)
static std::string g_socketPath = RD_IPC_SOCKET_PATH_DEFAULT;
const char* g_rustdeskHelperSocketPath = RD_IPC_SOCKET_PATH_DEFAULT;

// A RustDesk adapter is shared by the extension registry. Keep cursor
// generations process-wide so reconnecting the same numeric session id cannot
// make a late N-API result look current.
static std::atomic<uint64_t> g_nextRustDeskCursorGeneration {1};

// FFI callbacks are delivered with one opaque user-data pointer for the whole
// stream. Carry the generation captured when the handle was created so a
// callback from a torn-down stream cannot mutate the next session's cursor
// store after reconnecting with the same numeric session id.
struct RustDeskFfiCallbackContext {
    void* impl = nullptr;
    std::shared_ptr<void> implKeepAlive;
    uint64_t generation = 0;
    uint64_t ownerToken = 0;
    uint64_t admissionEpoch = 0;
};

namespace {

// rustdesk_disconnect() joins the Rust stream thread.  Keep re-entrant
// disconnects non-blocking until the current FFI callback has returned.
thread_local bool g_inRustDeskFfiCallback = false;

class RustDeskFfiCallbackScope final {
public:
    RustDeskFfiCallbackScope() : previous_(g_inRustDeskFfiCallback) {
        g_inRustDeskFfiCallback = true;
    }
    ~RustDeskFfiCallbackScope() {
        if (active_ != nullptr &&
            active_->fetch_sub(1, std::memory_order_acq_rel) == 1 &&
            condition_ != nullptr) {
            condition_->notify_all();
        }
        g_inRustDeskFfiCallback = previous_;
    }
    RustDeskFfiCallbackScope(const RustDeskFfiCallbackScope&) = delete;
    RustDeskFfiCallbackScope& operator=(const RustDeskFfiCallbackScope&) = delete;

    void track(std::atomic<uint32_t>* active, std::mutex* mutex,
               std::condition_variable* condition) {
        if (active_ != nullptr || active == nullptr || mutex == nullptr ||
            condition == nullptr) {
            return;
        }
        active_ = active;
        mutex_ = mutex;
        condition_ = condition;
        active_->fetch_add(1, std::memory_order_acq_rel);
    }

private:
    bool previous_ = false;
    std::atomic<uint32_t>* active_ = nullptr;
    std::mutex* mutex_ = nullptr;
    std::condition_variable* condition_ = nullptr;
};

class RustDeskCleanupGateScope final {
public:
    explicit RustDeskCleanupGateScope(
        const std::shared_ptr<std::promise<void>>& gate) noexcept : gate_(gate) {}
    ~RustDeskCleanupGateScope() noexcept {
        if (!gate_) { return; }
        try {
            gate_->set_value();
        } catch (...) {
            // The cleanup worker must never turn a callback unwind into a
            // second exception. A duplicate signal only means it is awake.
        }
    }
    RustDeskCleanupGateScope(const RustDeskCleanupGateScope&) = delete;
    RustDeskCleanupGateScope& operator=(const RustDeskCleanupGateScope&) = delete;

private:
    const std::shared_ptr<std::promise<void>>& gate_;
};

template<typename ImplType>
static bool IsRustDeskCallbackOwnerActive(
    const ImplType* impl, const RustDeskFfiCallbackContext* context) {
    if (impl == nullptr || context == nullptr || context->generation == 0 ||
        context->ownerToken == 0) {
        return false;
    }
    const Render::DecoderSessionIdentity owner {
        impl->sessionId.load(std::memory_order_acquire),
        context->generation,
        context->ownerToken,
    };
    return Render::SharedSessionSinkOwnerLease().accepts(owner);
}

static std::string rdLowercase(std::string value) {
    for (char& character : value) {
        character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    }
    return value;
}

static RustDeskTransportErrorClass rdClassifyTransportMessage(
    int state, const char* message) {
    if (state == 0) {
        return RustDeskTransportErrorClass::None;
    }
    const std::string text = rdLowercase(message ? message : "");
    const auto contains = [&text](const char* needle) {
        return text.find(needle) != std::string::npos;
    };
    if (contains("2fa") || contains("two-factor") || contains("two factor")) {
        return RustDeskTransportErrorClass::TwoFactor;
    }
    if (contains("approval") || contains("approve") || contains("consent")) {
        return RustDeskTransportErrorClass::Approval;
    }
    if (contains("auth") || contains("password") || contains("credential")) {
        return RustDeskTransportErrorClass::Auth;
    }
    if (contains("license")) return RustDeskTransportErrorClass::License;
    if (contains("key") || contains("public key") || contains("access key")) {
        return RustDeskTransportErrorClass::Key;
    }
    if (contains("protocol") || contains("handshake")) {
        return RustDeskTransportErrorClass::Protocol;
    }
    if (contains("crypto") || contains("decrypt") || contains("encrypt")) {
        return RustDeskTransportErrorClass::Crypto;
    }
    if (contains("connection reset") || contains("reset by peer") ||
        contains("os error 104")) {
        return RustDeskTransportErrorClass::Reset;
    }
    if (contains("connection aborted") || contains("aborted") ||
        contains("os error 103")) {
        return RustDeskTransportErrorClass::Aborted;
    }
    if (contains("broken pipe") || contains("brokenpipe") || contains("os error 32")) {
        return RustDeskTransportErrorClass::BrokenPipe;
    }
    if (contains("timed out") || contains("timeout") || contains("os error 110")) {
        return RustDeskTransportErrorClass::Timeout;
    }
    if (contains("network is unreachable") || contains("network unreachable") ||
        contains("os error 101")) {
        return RustDeskTransportErrorClass::Unreachable;
    }
    if (contains("network is down") || contains("network down") || contains("os error 100")) {
        return RustDeskTransportErrorClass::NetworkDown;
    }
    // Unknown stream failures are not retried. Retrying authentication or
    // protocol failures is worse than surfacing them to the existing UI.
    return RustDeskTransportErrorClass::Unknown;
}

} // namespace

// ============================================================
// RustDesk 真实 TCP 连接 (在独立线程中运行)
// ============================================================
static int rdConnectTcpEndpoint(const std::string& host, uint32_t port, int timeoutMs) {
    if (host.empty() || port == 0 || port > 65535 || timeoutMs <= 0) {
        errno = EINVAL;
        return -1;
    }
    remotedesk::net::ConnectOptions options;
    options.deadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(timeoutMs);
    remotedesk::net::ConnectResult connection;
    const remotedesk::net::ResolveResult resolution =
        remotedesk::net::ResolveAndConnectTcp(
            host, std::to_string(port), options, connection);
    if (resolution.status != remotedesk::net::ResolveStatus::Ready) {
        errno = resolution.status == remotedesk::net::ResolveStatus::TimedOut
            ? ETIMEDOUT : resolution.status == remotedesk::net::ResolveStatus::Cancelled
                ? ECANCELED : resolution.status == remotedesk::net::ResolveStatus::ResourceExhausted
                    ? EAGAIN : EHOSTUNREACH;
        return -1;
    }
    if (connection.status != remotedesk::net::ConnectStatus::Connected ||
        connection.descriptor < 0) {
        errno = connection.status == remotedesk::net::ConnectStatus::TimedOut
            ? ETIMEDOUT : connection.status == remotedesk::net::ConnectStatus::Cancelled
                ? ECANCELED : (connection.lastError == 0 ? EHOSTUNREACH
                                                         : connection.lastError);
        return -1;
    }
    return connection.descriptor;
}

static void rdRealConnectThread(RdIpcConnectReq req, int ipcClientFd) {
    req.host[sizeof(req.host) - 1] = '\0';
    req.peerId[sizeof(req.peerId) - 1] = '\0';
    const std::string endpointId = SafeLog::HashForLog(req.host);
    const std::string peerId = SafeLog::HashForLog(req.peerId);
    OH_LOG_INFO(LOG_APP,
                "[RustDesk-REAL] 开始连接 endpointId=%{public}s port=%{public}u peerId=%{public}s",
                endpointId.c_str(), req.port, peerId.c_str());

    int tcpFd = rdConnectTcpEndpoint(req.host, req.port, 5000);
    if (tcpFd < 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-REAL] TCP 连接失败: %{public}s", strerror(errno));
        uint8_t errAck[6] = {1, 0, 0, 0, RD_IPC_CONNECT_ACK, 0x03};
        send(ipcClientFd, errAck, 6, 0);
        return;
    }
    struct timeval tv;
    tv.tv_sec = 5;
    tv.tv_usec = 0;
    setsockopt(tcpFd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(tcpFd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    OH_LOG_INFO(LOG_APP, "[RustDesk-REAL] ✓ TCP 已连接 fd=%{public}d", tcpFd);

    // RustDesk 协议握手: 发送 SYN 包
    // RustDesk 使用自定义二进制协议, 第一条消息是握手请求
    // 格式: [4 bytes len LE] [protobuf message]
    // 先尝试读取服务器可能发送的 greeting
    uint8_t buf[4096];
    // 发送 RustDesk 握手 (基于 RDCM magic + version)
    uint8_t handshake[20] = {0};
    memcpy(handshake, "RDCM", 4);
    handshake[4] = 0x01;  // version
    // 填充 peer ID hash
    uint32_t peerHash = 0;
    for (size_t i = 0; i < strlen(req.peerId) && i < 128; i++) {
        peerHash = peerHash * 31 + (uint8_t)req.peerId[i];
    }
    memcpy(handshake + 8, &peerHash, 4);
    ssize_t sent = send(tcpFd, handshake, sizeof(handshake), 0);
    OH_LOG_INFO(LOG_APP, "[RustDesk-REAL] 握手已发送 %{public}zd bytes, 等待响应...", sent);

    // 等待服务器响应
    ssize_t n = recv(tcpFd, buf, sizeof(buf), 0);
    if (n > 0) {
        OH_LOG_INFO(LOG_APP, "[RustDesk-REAL] 服务器响应 %{public}zd bytes: %{public}02X %{public}02X %{public}02X %{public}02X ...",
                    n, buf[0], buf[1], buf[2], buf[3]);
    } else if (n == 0) {
        OH_LOG_WARN(LOG_APP, "[RustDesk-REAL] 服务器关闭连接");
    } else {
        OH_LOG_WARN(LOG_APP, "[RustDesk-REAL] recv 错误: %{public}s", strerror(errno));
    }

    // TODO: 完整 RustDesk 协议实现
    // 成功连接 (暂时返回 ACK 表示 TCP 层面连接成功)
    uint8_t okAck[6] = {1, 0, 0, 0, RD_IPC_CONNECT_ACK, 0x00};
    send(ipcClientFd, okAck, 6, 0);
    OH_LOG_INFO(LOG_APP, "[RustDesk-REAL] ACK 已发送");
}

void rdSetHelperSocketPath(const char* path) {
    if (path && path[0] != '\0') {
        g_socketPath = path;
        g_rustdeskHelperSocketPath = g_socketPath.c_str();
        OH_LOG_INFO(LOG_APP,
                    "[RustDesk-IPC] socket 路径已更新 pathId=%{public}s",
                    SafeLog::HashForLog(g_rustdeskHelperSocketPath).c_str());
    }
}

// helper 二进制路径 (由 ArkTS setHelperSocketPath 同一调用设置)
static std::string g_helperBinPath;

void rdSetHelperBinPath(const char* path) {
    if (path && path[0] != '\0') {
        g_helperBinPath = path;
        OH_LOG_INFO(LOG_APP,
                    "[RustDesk-IPC] helper 路径已设置 pathId=%{public}s",
                    SafeLog::HashForLog(path).c_str());
    }
}

// ============================================================
// 内置 IPC 服务端 (替代独立 helper 进程)
// 运行在 pthread 中, 省去 dlopen/SELinux/namespace 问题
// ============================================================
static pthread_t g_helperThread = 0;
static volatile bool g_helperRunning = false;

static void* rdHelperThreadFn(void* arg) {
    const char* socketPath = (const char*)arg;
    OH_LOG_INFO(LOG_APP,
                "[RustDesk-IPC] helper 线程启动 socketPathId=%{public}s",
                SafeLog::HashForLog(socketPath).c_str());

    // 删掉旧 socket 文件
    unlink(socketPath);

    int listenFd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listenFd < 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] helper socket() 失败: %{public}s", strerror(errno));
        return nullptr;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socketPath, sizeof(addr.sun_path) - 1);

    if (bind(listenFd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] helper bind() 失败: %{public}s", strerror(errno));
        close(listenFd);
        return nullptr;
    }

    if (listen(listenFd, 1) < 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] helper listen() 失败: %{public}s", strerror(errno));
        close(listenFd);
        return nullptr;
    }

    OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper 监听中...");
    g_helperRunning = true;

    while (g_helperRunning) {
        int clientFd = accept(listenFd, nullptr, nullptr);
        if (clientFd < 0) {
            if (errno == EINTR) { continue; }
            break;
        }
        OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper 客户端已连接 fd=%{public}d", clientFd);

        // 简单帧循环: 读 5 字节头 → 读 payload → 处理
        uint8_t header[5];
        std::vector<uint8_t> payload;
        while (g_helperRunning) {
            ssize_t n = recv(clientFd, header, 5, 0);
            if (n <= 0) { break; }
            uint32_t payloadSize = (uint32_t)header[0] | ((uint32_t)header[1] << 8) |
                                   ((uint32_t)header[2] << 16) | ((uint32_t)header[3] << 24);
            uint8_t msgType = header[4];
            if (payloadSize > RD_IPC_MAX_PAYLOAD) { break; }

            payload.resize(payloadSize);
            size_t off = 0;
            while (off < payloadSize) {
                n = recv(clientFd, payload.data() + off, payloadSize - off, 0);
                if (n <= 0) { break; }
                off += (size_t)n;
            }
            if (off < payloadSize) { break; }

            // 处理消息
            switch (msgType) {
                case RD_IPC_CONNECT_REQ: {  // 0x01
                    OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper CONNECT_REQ payload=%{public}u bytes", payloadSize);
                    if (payloadSize >= sizeof(RdIpcConnectReq)) {
                        RdIpcConnectReq req;
                        memcpy(&req, payload.data(), sizeof(RdIpcConnectReq));
                        // 在独立线程中发起真实 RustDesk TCP 连接
                        std::thread realConn(rdRealConnectThread, req, clientFd);
                        realConn.detach();
                        // ACK 由 realConn 线程发送 (连接结果)
                    } else {
                        uint8_t errAck[6] = {1, 0, 0, 0, RD_IPC_CONNECT_ACK, 0xFF};
                        send(clientFd, errAck, 6, 0);
                    }
                    break;
                }
                case RD_IPC_DISCONNECT:  // 0x03
                    OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper DISCONNECT");
                    break;
                case RD_IPC_INPUT_KEY:    // 0x10
                case RD_IPC_INPUT_MOUSE:  // 0x11
                case RD_IPC_INPUT_WHEEL:  // 0x12
                case RD_IPC_INPUT_TEXT:   // 0x13
                    break;  // TODO: 转发到 RustDesk core
                case RD_IPC_PING: {       // 0xFE → PONG
                    uint8_t pong[6] = {1, 0, 0, 0, RD_IPC_PONG, 0};
                    send(clientFd, pong, 6, 0);
                    break;
                }
                default:
                    OH_LOG_WARN(LOG_APP, "[RustDesk-IPC] helper 未知消息 0x%{public}02X", msgType);
                    break;
            }
        }
        close(clientFd);
        OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper 客户端断开");
    }

    close(listenFd);
    unlink(socketPath);
    OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper 线程退出");
    return nullptr;
}

static bool rdTryStartHelper() {
    if (g_helperRunning) {
        return true;
    }
    std::string sockPath = g_socketPath;
    char* pathCopy = strdup(sockPath.c_str());
    int rc = pthread_create(&g_helperThread, nullptr, rdHelperThreadFn, pathCopy);
    if (rc != 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] pthread_create 失败: %{public}d", rc);
        free(pathCopy);
        return false;
    }
    pthread_detach(g_helperThread);
    g_helperThread = 0;
    OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper 线程已启动, 等待 socket...");
    usleep(200000);  // 200ms
    return g_helperRunning;
}

// ============================================================
// 公共: Impl + 元信息 (两种模式共享)
// ============================================================

struct RustDeskBridge::Impl {
    TransferRuntimeStatus  transferStatus;
    std::atomic<uint64_t>  nextTransferId {1};
    ConnectionConfig        config;
    ConnectionState         state = ConnectionState::DISCONNECTED;
    VideoFrameCallback      videoCallback;
    AudioDataCallback       audioCallback;
    ConnectionStateCallback stateCallback;
    RustDeskDisplayStateCallback displayStateCallback;
    RustDeskDisplayControlPlane displayControl;
    std::unordered_set<int> capturedDisplays;
    std::mutex              mutex;
    std::atomic<uint64_t>   connectSerial {0};
    std::atomic<bool>       disconnectRequested {false};
    std::atomic<bool>       ffiStreamEnded {false};
    std::atomic<uint64_t>   sessionId {0};
    std::atomic<uint64_t>   cursorGeneration {0};
    std::atomic<uint64_t>   ownerToken {0};
    RustDeskBridge::ContinuityGenerationCallback continuityGenerationCallback;
    std::atomic<uint64_t>   ffiAdmissionEpoch {1};
    std::mutex              continuityAdmissionMutex;
    std::shared_ptr<RustDeskConnectionContinuityExecutor> continuityExecutor =
        std::make_shared<RustDeskConnectionContinuityExecutor>();
    RustDeskContinuityQuiesceState continuityQuiesce;
    std::atomic<bool>         awaitingFirstGenerationFrame {false};
    std::atomic<uint64_t>     nextContinuityAttemptToken {1};
    std::atomic<uint64_t>     continuityAttemptToken {0};
    std::atomic<uint32_t>     continuityConnectCallCount {0};
    std::atomic<bool>         continuityNetworkCallCancelled {false};
    std::atomic<bool>         networkAvailable {true};
    std::atomic<uint64_t>     networkGeneration {0};
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    std::function<void()> firstFrameClaimHook;
    std::function<void(int)> continuityAttemptStageHook;
    std::function<int(uint64_t, uint64_t)> continuityConnectResultHook;
#endif
    std::atomic<uint64_t>   callbackVideoFrames {0};
    std::atomic<uint64_t>   callbackVideoBytes {0};
    std::atomic<uint64_t>   callbackKeyframes {0};
    std::atomic<int>        callbackCodec {-1};
    std::atomic<int>        callbackWidth {0};
    std::atomic<int>        callbackHeight {0};
    std::atomic<RustDeskPresentation::PeerPlatformCategory> peerPlatform {
        RustDeskPresentation::PeerPlatformCategory::Unknown};
    std::atomic<uint64_t>   lastFrameAtMs {0};
    std::atomic<uint64_t>   callbackAdmissionRejects {0};
    RemoteCursorStore       cursorStore;
    int                     ipcFd = -1;   // IPC socket fd (IPC 模式)
    int                     sockFd = -1;  // TCP socket fd (实验模式)
#ifdef RUSTDESK_USE_REAL_CORE
    std::shared_ptr<RustDeskFfiCallbackContext> ffiCallbackContext;
    std::atomic<uint32_t> ffiCallbackActive {0};
    std::mutex ffiCallbackMutex;
    std::condition_variable ffiCallbackCv;
    // FFI connect() 在后台执行，但不能 detach：断开时必须等待它结束，
    // 否则旧连接可能在下一次连接已经开始后仍持有 rendezvous/relay 资源。
    std::thread              ffiConnectThread;
    std::shared_ptr<std::atomic<bool>> ffiConnectDone =
        std::make_shared<std::atomic<bool>>(true);
    // 流线程通过 onFfiDisconnect 回调结束时，不能从自身 join；把延迟释放
    // 的线程保留下来，由 disconnect() 统一 join，避免释放任务悬空。
    std::vector<std::thread> ffiCleanupThreads;
    std::vector<std::shared_ptr<std::atomic<bool>>> ffiCleanupDone;
    // Workers handed to the process-wide deferred join owner keep the FFI
    // callback context alive until their underlying Rust thread has joined.
    std::atomic<uint32_t> ffiDeferredJoinCount {0};
    // Count every rustdesk_connect_v6() call until its returned handle has
    // completed rustdesk_disconnect(). A raw callback user-data pointer may
    // be read before the callback-active counter can be incremented.
    std::atomic<uint32_t> ffiHandleJoinPending {0};
    // Last-resort queue used only if a callback cleanup worker cannot be
    // created. It is drained by continuity maintenance or explicit teardown.
    std::vector<void*> ffiDeferredHandles;
#endif

    void setState(ConnectionState s, const std::string& msg = "") {
        ConnectionStateCallback cb;
        {
            std::lock_guard<std::mutex> lock(mutex);
            state = s;
            cb = stateCallback;
        }
        if (cb) { cb(s, msg); }
    }

    ~Impl() {
        if (continuityExecutor) {
            continuityExecutor->setCallbacks({});
            continuityExecutor->shutdown();
            (void)RustDeskConnectionContinuityExecutor::shutdownDeferredWithin(
                std::chrono::milliseconds(500));
        }
    }
};

static uint64_t rdSteadyNowMs() {
    using Clock = std::chrono::steady_clock;
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
        Clock::now().time_since_epoch()).count());
}

#ifdef RUSTDESK_USE_REAL_CORE
static RustDeskFfiLifetime::CallbackContextRegistry<
    RustDeskFfiCallbackContext>& rdFfiCallbackRegistry() {
    // Deliberately leak the registry at process exit. Native callbacks can be
    // racing library shutdown, and static destruction would reintroduce a
    // use-after-free at the registry boundary.
    static auto* registry = new RustDeskFfiLifetime::CallbackContextRegistry<
        RustDeskFfiCallbackContext>();
    return *registry;
}

static std::shared_ptr<RustDeskFfiCallbackContext>
rdAcquireFfiCallbackContext(void* userData) {
    return rdFfiCallbackRegistry().acquire(userData);
}

static bool rdPublishFfiCallbackContext(
    const std::shared_ptr<RustDeskFfiCallbackContext>& context) {
    return rdFfiCallbackRegistry().publish(context);
}

static void rdRetireFfiCallbackContextLocked(RustDeskBridge::Impl* impl) {
    if (impl == nullptr ||
        !RustDeskFfiLifetime::CanRetireCallbackContext(
            impl->ffiHandleJoinPending.load(std::memory_order_acquire),
            impl->ffiCallbackActive.load(std::memory_order_acquire),
            impl->displayControl.hasHandle(),
            impl->ffiDeferredJoinCount.load(std::memory_order_acquire),
            !impl->ffiDeferredHandles.empty())) {
        return;
    }
    const auto context = impl->ffiCallbackContext;
    (void)rdFfiCallbackRegistry().retire(context);
    impl->ffiCallbackContext.reset();
}

static void rdReleaseFfiHandleReservation(RustDeskBridge::Impl* impl) {
    if (impl == nullptr) {
        return;
    }
    const uint32_t previous = impl->ffiHandleJoinPending.fetch_sub(
        1, std::memory_order_acq_rel);
    if (previous == 0) {
        impl->ffiHandleJoinPending.store(0, std::memory_order_release);
        OH_LOG_ERROR(LOG_APP,
            "[RustDesk-FFI] handle join reservation underflow");
    }
}

static void rdDisconnectFfiHandle(RustDeskBridge::Impl* impl, void* handle) {
    if (handle != nullptr) {
        rustdesk_disconnect(handle);
    }
    rdReleaseFfiHandleReservation(impl);
}

static void rdQueueDeferredFfiHandle(RustDeskBridge::Impl* impl, void* handle) {
    if (impl == nullptr || handle == nullptr) {
        return;
    }
    try {
        std::lock_guard<std::mutex> lock(impl->mutex);
        impl->ffiDeferredHandles.push_back(handle);
        OH_LOG_WARN(LOG_APP,
            "[RustDesk-FFI] handle cleanup queued for maintenance handle=%{public}p pending=%{public}u",
            handle,
            impl->ffiHandleJoinPending.load(std::memory_order_acquire));
    } catch (...) {
        // There is no safe callback-thread fallback. Keeping the reservation
        // prevents context retirement; process teardown will report the leak.
        OH_LOG_ERROR(LOG_APP,
            "[RustDesk-FFI] deferred handle queue allocation failed handle=%{public}p",
            handle);
    }
}

static void rdDrainDeferredFfiHandles(RustDeskBridge::Impl* impl) {
    if (impl == nullptr || g_inRustDeskFfiCallback ||
        impl->ffiCallbackActive.load(std::memory_order_acquire) != 0) {
        return;
    }
    std::vector<void*> handles;
    {
        std::lock_guard<std::mutex> lock(impl->mutex);
        handles.swap(impl->ffiDeferredHandles);
    }
    for (void* handle : handles) {
        rdDisconnectFfiHandle(impl, handle);
    }
}

static bool rdCanRetireFfiCallbackContextLocked(
    const RustDeskBridge::Impl* impl) {
    if (impl == nullptr) {
        return false;
    }
    return RustDeskFfiLifetime::CanRetireCallbackContext(
        impl->ffiHandleJoinPending.load(std::memory_order_acquire),
        impl->ffiCallbackActive.load(std::memory_order_acquire),
        impl->displayControl.hasHandle(),
        impl->ffiDeferredJoinCount.load(std::memory_order_acquire),
        !impl->ffiDeferredHandles.empty());
}

struct RustDeskFfiConnectReservation final {
    explicit RustDeskFfiConnectReservation(RustDeskBridge::Impl* impl)
        : impl_(impl) {
        if (impl_ != nullptr) {
            impl_->ffiHandleJoinPending.fetch_add(1, std::memory_order_acq_rel);
        }
    }

    ~RustDeskFfiConnectReservation() {
        if (impl_ != nullptr && !transferred_) {
            rdReleaseFfiHandleReservation(impl_);
        }
    }

    void transferToHandleOwner() {
        transferred_ = true;
    }

private:
    RustDeskBridge::Impl* impl_ = nullptr;
    bool transferred_ = false;
};

struct RustDeskFfiVideoFrameV1 {
    const uint8_t* data;
    size_t         size;
    int            width;
    int            height;
    int            codec;
    uint64_t       timestamp;
    bool           isKeyFrame;
};

struct RustDeskFfiVideoFrameV2 {
    const uint8_t* data;
    size_t         size;
    int            width;
    int            height;
    int            codec;
    uint64_t       timestamp;
    bool           isKeyFrame;
    int            display;
    uint32_t       abiVersion;
    uint32_t       structSize;
};

static_assert(sizeof(RustDeskFfiVideoFrameV1) == 48,
              "RustDesk V1 video frame ABI size changed; update both sides together");
static_assert(alignof(RustDeskFfiVideoFrameV1) == 8,
              "RustDesk V1 video frame ABI alignment changed");
static_assert(offsetof(RustDeskFfiVideoFrameV1, data) == 0);
static_assert(offsetof(RustDeskFfiVideoFrameV1, size) == 8);
static_assert(offsetof(RustDeskFfiVideoFrameV1, width) == 16);
static_assert(offsetof(RustDeskFfiVideoFrameV1, height) == 20);
static_assert(offsetof(RustDeskFfiVideoFrameV1, codec) == 24);
static_assert(offsetof(RustDeskFfiVideoFrameV1, timestamp) == 32);
static_assert(offsetof(RustDeskFfiVideoFrameV1, isKeyFrame) == 40);
static_assert(sizeof(RustDeskFfiVideoFrameV2) == 56,
              "RustDesk V2 video frame ABI size changed; update both sides together");
static_assert(alignof(RustDeskFfiVideoFrameV2) == 8,
              "RustDesk V2 video frame ABI alignment changed");
static_assert(offsetof(RustDeskFfiVideoFrameV2, data) == 0);
static_assert(offsetof(RustDeskFfiVideoFrameV2, size) == 8);
static_assert(offsetof(RustDeskFfiVideoFrameV2, width) == 16);
static_assert(offsetof(RustDeskFfiVideoFrameV2, height) == 20);
static_assert(offsetof(RustDeskFfiVideoFrameV2, codec) == 24);
static_assert(offsetof(RustDeskFfiVideoFrameV2, timestamp) == 32);
static_assert(offsetof(RustDeskFfiVideoFrameV2, isKeyFrame) == 40);
static_assert(offsetof(RustDeskFfiVideoFrameV2, display) == 44);
static_assert(offsetof(RustDeskFfiVideoFrameV2, abiVersion) == 48);
static_assert(offsetof(RustDeskFfiVideoFrameV2, structSize) == 52);

struct RustDeskFfiAudioData {
    const uint8_t* data;
    size_t         size;
    int            sampleRate;
    int            channels;
    uint64_t       timestamp;
};

struct RustDeskFfiCursorUpdate {
    uint32_t       kind;
    uint64_t       shapeId;
    int            x;
    int            y;
    int            width;
    int            height;
    int            hotX;
    int            hotY;
    const uint8_t* rgba;
    size_t         rgbaLen;
    bool           visible;
};

static std::atomic<uint64_t> g_ffiVideoFrameCount {0};
static std::atomic<uint64_t> g_ffiAudioFrameCount {0};
static std::atomic<uint64_t> g_ffiMouseSendCount {0};
static std::atomic<uint64_t> g_ffiKeySendCount {0};
static std::atomic<uint64_t> g_ffiWheelSendCount {0};
static std::atomic<uint64_t> g_ffiCursorCacheMissCount {0};
static std::atomic<uint64_t> g_ffiTextSendCount {0};
static std::atomic<uint64_t> g_ffiFileSendCount {0};
static std::atomic<uint64_t> g_ffiCursorShapeCount {0};
static std::atomic<uint64_t> g_ffiCursorPositionCount {0};
static std::atomic<uint64_t> g_ffiCursorVisibilityCount {0};

static const char* rdCodecName(int codec) {
    switch (codec) {
        case -1: return "AUTO";
        case 0: return "H264";
        case 1: return "H265";
        case 2: return "VP8";
        case 3: return "VP9";
        case 4: return "AV1";
        default: return "UNKNOWN";
    }
}

static CodecType rdCodecType(int codec) {
    switch (codec) {
        case 1: return CodecType::H265;
        case 2: return CodecType::VP8;
        case 3: return CodecType::VP9;
        case 4: return CodecType::AV1;
        case 0:
        default:
            return CodecType::H264;
    }
}

static int rdFfiCodecPreference(CodecType codec) {
    switch (codec) {
        case CodecType::AUTO: return 0;
        case CodecType::VP8: return 1;
        case CodecType::VP9: return 2;
        case CodecType::AV1: return 3;
        case CodecType::H265: return 5;
        case CodecType::H264:
        default:
            return 4;
    }
}

void RustDeskBridge::onFfiFrame(const void* framePtr, void* userData) {
    RustDeskFfiCallbackScope callbackScope;
    const auto context = rdAcquireFfiCallbackContext(userData);
    auto* impl = context ? static_cast<RustDeskBridge::Impl*>(context->impl) : nullptr;
    if (impl) {
        callbackScope.track(&impl->ffiCallbackActive, &impl->ffiCallbackMutex,
                            &impl->ffiCallbackCv);
    }
    auto* ffiFrame = static_cast<const RustDeskFfiVideoFrameV2*>(framePtr);
    const char* rejectReason = nullptr;
    if (!context) {
        rejectReason = "missing_context";
    } else if (!impl) {
        rejectReason = "missing_impl";
    } else if (context->generation != impl->cursorGeneration.load(std::memory_order_acquire)) {
        rejectReason = "generation_mismatch";
    } else if (context->ownerToken == 0 ||
               context->ownerToken != impl->ownerToken.load(std::memory_order_acquire)) {
        rejectReason = "owner_mismatch";
    } else if (context->admissionEpoch == 0 ||
               context->admissionEpoch != impl->ffiAdmissionEpoch.load(std::memory_order_acquire)) {
        rejectReason = "admission_epoch_mismatch";
    } else if (impl->disconnectRequested.load(std::memory_order_acquire)) {
        rejectReason = "disconnect_requested";
    } else if (impl->ffiStreamEnded.load(std::memory_order_acquire)) {
        rejectReason = "stream_ended";
    } else if (!impl->continuityQuiesce.decoderAllowed()) {
        rejectReason = "decoder_quiesced";
    } else if (!IsRustDeskCallbackOwnerActive(impl, context.get())) {
        rejectReason = "inactive_callback_owner";
    } else if (!ffiFrame || !ffiFrame->data || ffiFrame->size == 0) {
        rejectReason = "empty_frame";
    }
    if (rejectReason != nullptr) {
        if (impl) {
            const uint64_t rejected = impl->callbackAdmissionRejects.fetch_add(
                1, std::memory_order_relaxed) + 1;
            if (rejected <= 8 || rejected % 300 == 0) {
                OH_LOG_WARN(LOG_APP,
                    "[RustDesk-FFI] frame rejected before dispatch reason=%{public}s count=%{public}llu generation=%{public}llu owner=%{public}llu epoch=%{public}llu",
                    rejectReason,
                    static_cast<unsigned long long>(rejected),
                    static_cast<unsigned long long>(context ? context->generation : 0),
                    static_cast<unsigned long long>(context ? context->ownerToken : 0),
                    static_cast<unsigned long long>(context ? context->admissionEpoch : 0));
            }
        }
        return;
    }

    const Render::DecoderSessionIdentity callbackOwner {
        impl->sessionId.load(std::memory_order_acquire),
        context->generation,
        context->ownerToken,
    };
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(callbackOwner);
    if (!sinkLease) {
        return;
    }
    if (ffiFrame->abiVersion < kRustDeskVideoFrameAbiVersion ||
        ffiFrame->structSize < sizeof(RustDeskFfiVideoFrameV2)) {
        OH_LOG_WARN(LOG_APP,
            "[RustDesk-FFI] reject unsupported V2 frame abi=%{public}u size=%{public}u",
            ffiFrame->abiVersion,
            ffiFrame->structSize);
        return;
    }

    // A multi-canvas capture set may contain displays other than the single
    // interactive canvas. Forward those frames to the session callback as a
    // preview lane without letting them mutate the ACK/keyframe switch gate.
    // The Extension layer routes them only to an exact per-display decoder;
    // its legacy active decoder still rejects the same frame.
    VideoFrameCallback previewCallback;
    const RustDeskDisplaySwitchGateSnapshot gateSnapshot =
        impl->displayControl.snapshot();
    {
        std::lock_guard<std::mutex> lock(impl->mutex);
        const bool explicitlyCaptured =
            impl->capturedDisplays.find(ffiFrame->display) !=
            impl->capturedDisplays.end();
        if (RustDeskShouldRouteMultiCanvasPreview(
                ffiFrame->display, gateSnapshot.confirmedDisplay,
                gateSnapshot.pendingDisplay, gateSnapshot.inputBlocked,
                explicitlyCaptured)) {
            previewCallback = impl->videoCallback;
        }
    }
    if (previewCallback) {
        VideoFrame previewFrame;
        previewFrame.data = ffiFrame->data;
        previewFrame.size = ffiFrame->size;
        previewFrame.width = ffiFrame->width;
        previewFrame.height = ffiFrame->height;
        previewFrame.codec = rdCodecType(ffiFrame->codec);
        previewFrame.timestamp = ffiFrame->timestamp;
        previewFrame.isKeyFrame = ffiFrame->isKeyFrame;
        previewFrame.display = ffiFrame->display;
        previewCallback(previewFrame);
    }

    // dispatchFrame owns the production lease through active-display
    // publication and the complete video callback. beginDisplaySwitch() takes
    // the same boundary, so a newer generation cannot overtake this frame.
    impl->displayControl.dispatchFrame(
        ffiFrame->display,
        ffiFrame->isKeyFrame,
        [&]() {
            return context->generation ==
                    impl->cursorGeneration.load(std::memory_order_acquire) &&
                context->ownerToken == impl->ownerToken.load(std::memory_order_acquire) &&
                context->admissionEpoch == impl->ffiAdmissionEpoch.load(std::memory_order_acquire) &&
                !impl->disconnectRequested.load(std::memory_order_acquire) &&
                !impl->ffiStreamEnded.load(std::memory_order_acquire) &&
                IsRustDeskCallbackOwnerActive(impl, context.get());
        },
        [&](const RustDeskDisplaySwitchGateDecision& displayDecision) {
    RustDeskDisplayStateCallback displayCallback;
    if (displayDecision.publishDisplay) {
        std::lock_guard<std::mutex> lock(impl->mutex);
        displayCallback = impl->displayStateCallback;
    }
    if (displayCallback) {
        // Publish the selected display before forwarding its keyframe so the
        // decoder accepts the same frame that releases the input barrier.
        displayCallback(displayDecision.display);
    }

    uint64_t index = ++g_ffiVideoFrameCount;
    impl->callbackVideoFrames.fetch_add(1, std::memory_order_relaxed);
    impl->callbackVideoBytes.fetch_add(static_cast<uint64_t>(ffiFrame->size), std::memory_order_relaxed);
    if (ffiFrame->isKeyFrame) {
        impl->callbackKeyframes.fetch_add(1, std::memory_order_relaxed);
    }
    impl->callbackCodec.store(ffiFrame->codec, std::memory_order_relaxed);
    impl->callbackWidth.store(ffiFrame->width, std::memory_order_relaxed);
    impl->callbackHeight.store(ffiFrame->height, std::memory_order_relaxed);
    impl->lastFrameAtMs.store(rdSteadyNowMs(), std::memory_order_release);
    VideoFrameCallback cb;
    {
        std::lock_guard<std::mutex> lock(impl->mutex);
        cb = impl->videoCallback;
    }
    {
        using Clock = std::chrono::steady_clock;
        static std::mutex cadenceMutex;
        static bool cadenceInitialized = false;
        static Clock::time_point lastFrameAt;
        static Clock::time_point windowStartedAt;
        static uint64_t windowFrames = 0;
        static uint64_t windowMaxGapMs = 0;
        static uint64_t cadenceGapCount = 0;

        const auto now = Clock::now();
        std::lock_guard<std::mutex> cadenceLock(cadenceMutex);
        if (!cadenceInitialized) {
            cadenceInitialized = true;
            lastFrameAt = now;
            windowStartedAt = now;
        } else {
            const auto gapMs = static_cast<uint64_t>(
                std::chrono::duration_cast<std::chrono::milliseconds>(now - lastFrameAt).count());
            if (gapMs > windowMaxGapMs) {
                windowMaxGapMs = gapMs;
            }
            if (gapMs > 200) {
                cadenceGapCount++;
                if (cadenceGapCount <= 8 || cadenceGapCount % 30 == 0) {
                    OH_LOG_WARN(LOG_APP,
                        "[RustDesk-FFI] ffi video cadence gap=%{public}llu total=%{public}llu window=%{public}llu codec=%{public}s pts=%{public}llu",
                        static_cast<unsigned long long>(gapMs),
                        static_cast<unsigned long long>(index),
                        static_cast<unsigned long long>(windowFrames),
                        rdCodecName(ffiFrame->codec),
                        static_cast<unsigned long long>(ffiFrame->timestamp));
                }
            }
            lastFrameAt = now;
        }
        windowFrames++;
        const auto windowMs = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(now - windowStartedAt).count());
        if (windowMs >= 1000) {
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] ffi video window frames=%{public}llu total=%{public}llu max_gap=%{public}llu codec=%{public}s size=%{public}dx%{public}d",
                static_cast<unsigned long long>(windowFrames),
                static_cast<unsigned long long>(index),
                static_cast<unsigned long long>(windowMaxGapMs),
                rdCodecName(ffiFrame->codec),
                ffiFrame->width,
                ffiFrame->height);
            windowStartedAt = now;
            windowFrames = 0;
            windowMaxGapMs = 0;
        }
    }
    if (index <= 3 || index % 300 == 0) {
        OH_LOG_INFO(LOG_APP,
            "[RustDesk-FFI] stream video #%{public}llu codec=%{public}s frame=%{public}dx%{public}d size=%{public}zu key=%{public}s pts=%{public}llu cb=%{public}s",
            static_cast<unsigned long long>(index),
            rdCodecName(ffiFrame->codec),
            ffiFrame->width,
            ffiFrame->height,
            ffiFrame->size,
            ffiFrame->isKeyFrame ? "yes" : "no",
            static_cast<unsigned long long>(ffiFrame->timestamp),
            cb ? "yes" : "no");
    }

    if (cb) {
        VideoFrame frame;
        frame.data = ffiFrame->data;
        frame.size = ffiFrame->size;
        frame.width = ffiFrame->width;
        frame.height = ffiFrame->height;
        frame.codec = rdCodecType(ffiFrame->codec);
        frame.timestamp = ffiFrame->timestamp;
        frame.isKeyFrame = ffiFrame->isKeyFrame;
        frame.display = ffiFrame->display;
        cb(frame);
    }
        });

    const uint64_t frameGeneration = context->generation;
    const uint64_t frameOwnerToken = context->ownerToken;
    const uint64_t frameAdmissionEpoch = context->admissionEpoch;
    if (impl->awaitingFirstGenerationFrame.exchange(false, std::memory_order_acq_rel)) {
        RustDeskConnectionContinuityExecutor::ActionAdmission admission =
            [impl, frameGeneration, frameOwnerToken, frameAdmissionEpoch]() {
                return impl->cursorGeneration.load(std::memory_order_acquire) ==
                        frameGeneration &&
                    impl->ownerToken.load(std::memory_order_acquire) == frameOwnerToken &&
                    impl->ffiAdmissionEpoch.load(std::memory_order_acquire) ==
                        frameAdmissionEpoch &&
                    !impl->disconnectRequested.load(std::memory_order_acquire) &&
                    !impl->ffiStreamEnded.load(std::memory_order_acquire);
            };
#if defined(RDP_NATIVE_CALLBACK_TESTING)
        std::function<void()> firstFrameClaimHook;
        {
            std::lock_guard<std::mutex> lock(impl->continuityAdmissionMutex);
            firstFrameClaimHook = impl->firstFrameClaimHook;
        }
        if (firstFrameClaimHook) {
            firstFrameClaimHook();
        }
#endif
        impl->continuityExecutor->firstGenerationFrameArrived(std::move(admission));
    }
}

void RustDeskBridge::onFfiAudio(const void* audioPtr, void* userData) {
    RustDeskFfiCallbackScope callbackScope;
    const auto context = rdAcquireFfiCallbackContext(userData);
    auto* impl = context ? static_cast<RustDeskBridge::Impl*>(context->impl) : nullptr;
    if (impl) {
        callbackScope.track(&impl->ffiCallbackActive, &impl->ffiCallbackMutex,
                            &impl->ffiCallbackCv);
    }
    auto* ffiAudio = static_cast<const RustDeskFfiAudioData*>(audioPtr);
    if (!context || !impl ||
        context->generation != impl->cursorGeneration.load(std::memory_order_acquire) ||
        context->ownerToken == 0 ||
        context->ownerToken != impl->ownerToken.load(std::memory_order_acquire) ||
        context->admissionEpoch == 0 ||
        context->admissionEpoch != impl->ffiAdmissionEpoch.load(std::memory_order_acquire) ||
        impl->disconnectRequested.load(std::memory_order_acquire) ||
        impl->ffiStreamEnded.load(std::memory_order_acquire) ||
        !impl->continuityQuiesce.audioAllowed() ||
        !IsRustDeskCallbackOwnerActive(impl, context.get()) ||
        !ffiAudio || !ffiAudio->data || ffiAudio->size == 0) {
        return;
    }

    const Render::DecoderSessionIdentity callbackOwner {
        impl->sessionId.load(std::memory_order_acquire),
        context->generation,
        context->ownerToken,
    };
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(callbackOwner);
    if (!sinkLease) {
        return;
    }

    const int channels = ffiAudio->channels > 0 ? ffiAudio->channels : 2;
    const size_t bytesPerFrame = static_cast<size_t>(channels) * 2;
    if (ffiAudio->size < bytesPerFrame * 120 ||
        (bytesPerFrame > 0 && (ffiAudio->size % bytesPerFrame) != 0)) {
        uint64_t skipped = ++g_ffiAudioFrameCount;
        if (skipped <= 5 || skipped % 200 == 0) {
            OH_LOG_WARN(LOG_APP,
                "[RustDesk-FFI] skip non-pcm audio #%{public}llu size=%{public}zu rate=%{public}d channels=%{public}d",
                static_cast<unsigned long long>(skipped),
                ffiAudio->size,
                ffiAudio->sampleRate,
                ffiAudio->channels);
        }
        return;
    }

    uint64_t index = ++g_ffiAudioFrameCount;
    if (index <= 3 || index % 100 == 0) {
        OH_LOG_INFO(LOG_APP,
            "[RustDesk-FFI] stream audio #%{public}llu size=%{public}zu rate=%{public}d channels=%{public}d",
            static_cast<unsigned long long>(index),
            ffiAudio->size,
            ffiAudio->sampleRate,
            ffiAudio->channels);
    }

    AudioDataCallback cb;
    {
        std::lock_guard<std::mutex> lock(impl->mutex);
        cb = impl->audioCallback;
    }
    if (cb) {
        AudioData audio;
        audio.data = ffiAudio->data;
        audio.size = ffiAudio->size;
        audio.sampleRate = ffiAudio->sampleRate;
        audio.channels = ffiAudio->channels;
        audio.timestamp = ffiAudio->timestamp;
        cb(audio);
    }
}

void RustDeskBridge::onFfiCursor(const void* cursorPtr, void* userData) {
    RustDeskFfiCallbackScope callbackScope;
    const auto context = rdAcquireFfiCallbackContext(userData);
    auto* impl = context ? static_cast<RustDeskBridge::Impl*>(context->impl) : nullptr;
    if (impl) {
        callbackScope.track(&impl->ffiCallbackActive, &impl->ffiCallbackMutex,
                            &impl->ffiCallbackCv);
    }
    auto* cursor = static_cast<const RustDeskFfiCursorUpdate*>(cursorPtr);
    if (!context || !impl || !cursor) {
        return;
    }
    // Serialize the generation check with setSessionIdentity() and the
    // cursor-store mutation. Checking the atomic generation first and then
    // mutating later leaves a reconnect-sized TOCTOU window.
    std::lock_guard<std::mutex> lock(impl->mutex);
    if (context->generation == 0 ||
        context->generation != impl->cursorGeneration.load(std::memory_order_acquire) ||
        context->ownerToken == 0 ||
        context->ownerToken != impl->ownerToken.load(std::memory_order_acquire) ||
        context->admissionEpoch == 0 ||
        context->admissionEpoch != impl->ffiAdmissionEpoch.load(std::memory_order_acquire) ||
        impl->disconnectRequested.load(std::memory_order_acquire) ||
        impl->ffiStreamEnded.load(std::memory_order_acquire) ||
        !IsRustDeskCallbackOwnerActive(impl, context.get())) {
        return;
    }

    switch (cursor->kind) {
        case 0: {
            if (!cursor->rgba || cursor->rgbaLen == 0 || cursor->rgbaLen > kRemoteCursorMaxBytes) {
                OH_LOG_WARN(LOG_APP,
                    "[RustDesk-FFI] cursor shape rejected id=%{public}llu bytes=%{public}zu",
                    static_cast<unsigned long long>(cursor->shapeId), cursor->rgbaLen);
                return;
            }
            std::vector<uint8_t> rgba(cursor->rgba, cursor->rgba + cursor->rgbaLen);
            const bool accepted = impl->cursorStore.setShapeIfGeneration(
                context->generation, cursor->shapeId, cursor->width, cursor->height,
                cursor->hotX, cursor->hotY, rgba);
            const uint64_t index = ++g_ffiCursorShapeCount;
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] cursor shape #%{public}llu id=%{public}llu size=%{public}dx%{public}d hot=%{public}d,%{public}d accepted=%{public}s",
                static_cast<unsigned long long>(index),
                static_cast<unsigned long long>(cursor->shapeId), cursor->width, cursor->height,
                cursor->hotX, cursor->hotY, accepted ? "yes" : "no");
            break;
        }
        case 1: {
            impl->cursorStore.setPositionIfGeneration(context->generation, cursor->x, cursor->y);
            const uint64_t index = ++g_ffiCursorPositionCount;
            if (index <= 10 || index % 300 == 0) {
                OH_LOG_INFO(LOG_APP,
                    "[RustDesk-FFI] cursor position #%{public}llu x=%{public}d y=%{public}d",
                    static_cast<unsigned long long>(index), cursor->x, cursor->y);
            }
            break;
        }
        case 2: {
            impl->cursorStore.setVisibleIfGeneration(context->generation, cursor->visible);
            const uint64_t index = ++g_ffiCursorVisibilityCount;
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] cursor visibility #%{public}llu visible=%{public}s",
                static_cast<unsigned long long>(index), cursor->visible ? "yes" : "no");
            break;
        }
        case 3: {
            const uint64_t index = ++g_ffiCursorCacheMissCount;
            if (index <= 10 || index % 100 == 0) {
                OH_LOG_WARN(LOG_APP,
                    "[RustDesk-FFI] cursor cache miss #%{public}llu id=%{public}llu preserve_previous=true",
                    static_cast<unsigned long long>(index),
                    static_cast<unsigned long long>(cursor->shapeId));
            }
            // Diagnostic-only update. Do not mutate the cursor store: its
            // last valid protocol shape remains the authoritative display.
            break;
        }
        default:
            break;
    }
}

void RustDeskBridge::onFfiDisplay(const void* snapshotPtr, void* userData) {
    RustDeskFfiCallbackScope callbackScope;
    const auto context = rdAcquireFfiCallbackContext(userData);
    auto* impl = context ? static_cast<RustDeskBridge::Impl*>(context->impl) : nullptr;
    if (impl) {
        callbackScope.track(&impl->ffiCallbackActive, &impl->ffiCallbackMutex,
                            &impl->ffiCallbackCv);
    }
    auto* snapshot = static_cast<const RustDeskFfiDisplaySnapshot*>(snapshotPtr);
    if (!context || !impl ||
        context->generation != impl->cursorGeneration.load(std::memory_order_acquire) ||
        context->ownerToken == 0 ||
        context->ownerToken != impl->ownerToken.load(std::memory_order_acquire) ||
        context->admissionEpoch == 0 ||
        context->admissionEpoch != impl->ffiAdmissionEpoch.load(std::memory_order_acquire) ||
        impl->disconnectRequested.load(std::memory_order_acquire) ||
        impl->ffiStreamEnded.load(std::memory_order_acquire) ||
        !IsRustDeskCallbackOwnerActive(impl, context.get()) ||
        !snapshot || snapshot->version != kRustDeskDisplaySnapshotVersion ||
        snapshot->currentDisplay < 0) {
        return;
    }

    impl->displayControl.dispatchDisplay(
        snapshot->currentDisplay,
        [&]() {
            return context->generation ==
                    impl->cursorGeneration.load(std::memory_order_acquire) &&
                context->ownerToken == impl->ownerToken.load(std::memory_order_acquire) &&
                context->admissionEpoch == impl->ffiAdmissionEpoch.load(std::memory_order_acquire) &&
                !impl->disconnectRequested.load(std::memory_order_acquire) &&
                !impl->ffiStreamEnded.load(std::memory_order_acquire) &&
                IsRustDeskCallbackOwnerActive(impl, context.get());
        },
        [&](const RustDeskDisplaySwitchGateDecision& decision) {
            RustDeskDisplayStateCallback callback;
            {
                std::lock_guard<std::mutex> lock(impl->mutex);
                callback = impl->displayStateCallback;
            }
            if (callback) {
                callback(decision.display);
            }
        });
}

void RustDeskBridge::onFfiAuth(int state, const char* message, void* userData) {
    RustDeskFfiCallbackScope callbackScope;
    const auto context = rdAcquireFfiCallbackContext(userData);
    auto* impl = context ? static_cast<RustDeskBridge::Impl*>(context->impl) : nullptr;
    if (impl) {
        callbackScope.track(&impl->ffiCallbackActive, &impl->ffiCallbackMutex,
                            &impl->ffiCallbackCv);
    }
    if (!context || !impl) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(impl->mutex);
        if (context->generation == 0 ||
            context->generation != impl->cursorGeneration.load(std::memory_order_acquire) ||
            context->ownerToken == 0 ||
            context->ownerToken != impl->ownerToken.load(std::memory_order_acquire) ||
            context->admissionEpoch == 0 ||
            context->admissionEpoch != impl->ffiAdmissionEpoch.load(std::memory_order_acquire) ||
            impl->disconnectRequested.load(std::memory_order_acquire)) {
            return;
        }
    }
    const char* eventMessage = message ? message : "RustDesk Peer authentication required";
    if (state == 0) {
        OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] Peer 2FA accepted");
        return;
    }
    if (state == 2) {
        OH_LOG_WARN(LOG_APP, "[RustDesk-FFI] Peer 2FA code rejected");
    } else {
        OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] Peer 2FA pending");
    }
    impl->setState(ConnectionState::AUTHENTICATING, eventMessage);
}

void RustDeskBridge::onFfiProgress(int stage, const char* message, void* userData) {
    RustDeskFfiCallbackScope callbackScope;
    const auto context = rdAcquireFfiCallbackContext(userData);
    auto* impl = context ? static_cast<RustDeskBridge::Impl*>(context->impl) : nullptr;
    if (impl) {
        callbackScope.track(&impl->ffiCallbackActive, &impl->ffiCallbackMutex,
                            &impl->ffiCallbackCv);
    }
    if (!context || !impl || context->generation == 0 ||
        context->generation != impl->cursorGeneration.load(std::memory_order_acquire) ||
        context->ownerToken == 0 ||
        context->ownerToken != impl->ownerToken.load(std::memory_order_acquire) ||
        context->admissionEpoch == 0 ||
        context->admissionEpoch != impl->ffiAdmissionEpoch.load(std::memory_order_acquire) ||
        impl->disconnectRequested.load(std::memory_order_acquire) ||
        impl->ffiStreamEnded.load(std::memory_order_acquire)) {
        return;
    }
    const char* progressMessage = message ? message : "RustDesk: 正在连接";
    OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] handshake stage=%{public}d msg=%{public}s",
                stage, progressMessage);
    impl->setState(ConnectionState::CONNECTING, progressMessage);
}

bool RustDeskBridge::onFfiPeerPlatform(const char* platform, void* userData) {
    RustDeskFfiCallbackScope callbackScope;
    const auto context = rdAcquireFfiCallbackContext(userData);
    auto* impl = context ? static_cast<RustDeskBridge::Impl*>(context->impl) : nullptr;
    if (impl) {
        callbackScope.track(&impl->ffiCallbackActive, &impl->ffiCallbackMutex,
                            &impl->ffiCallbackCv);
    }
    if (!context || !impl || context->generation == 0 ||
        context->generation != impl->cursorGeneration.load(std::memory_order_acquire) ||
        context->ownerToken == 0 ||
        context->ownerToken != impl->ownerToken.load(std::memory_order_acquire) ||
        context->admissionEpoch == 0 ||
        context->admissionEpoch != impl->ffiAdmissionEpoch.load(std::memory_order_acquire) ||
        impl->disconnectRequested.load(std::memory_order_acquire) ||
        impl->ffiStreamEnded.load(std::memory_order_acquire) ||
        !IsRustDeskCallbackOwnerActive(impl, context.get())) {
        return false;
    }

    const char* peerPlatform = platform ? platform : "";
    const RustDeskPresentation::PeerPlatformCategory platformCategory =
        RustDeskPresentation::ClassifyPeerPlatform(peerPlatform);
    impl->peerPlatform.store(platformCategory, std::memory_order_release);
    const Render::NativeImagePresentationMode presentationMode =
        RustDeskPresentation::NativeImageModeForPeerPlatform(peerPlatform);
    const Render::DecoderSessionIdentity presentationOwner {
        impl->sessionId.load(std::memory_order_acquire),
        context->generation,
        context->ownerToken,
    };
    const bool published = DecoderNapi::SetActiveNativeImagePresentationMode(
        presentationOwner, presentationMode);
    OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] authenticated peer platformCategory=%{public}s NativeImage presentation=%{public}s ownerPublished=%{public}s",
                RustDeskPresentation::PeerPlatformCategoryName(platformCategory),
                Render::NativeImagePresentationModeName(presentationMode),
                published ? "yes" : "no");
    return published;
}

void RustDeskBridge::onFfiDisconnect(int state, const char* message, void* userData) noexcept try {
    RustDeskFfiCallbackScope callbackScope;
    const auto context = rdAcquireFfiCallbackContext(userData);
    auto* impl = context ? static_cast<RustDeskBridge::Impl*>(context->impl) : nullptr;
    if (impl) {
        callbackScope.track(&impl->ffiCallbackActive, &impl->ffiCallbackMutex,
                            &impl->ffiCallbackCv);
    }
    bool wasConnected = false;
    bool requested = false;
    bool stale = false;
    uint64_t currentGeneration = 0;
    void* endedHandle = nullptr;
    std::shared_ptr<std::promise<void>> cleanupGate;
    RustDeskCleanupGateScope cleanupGateScope(cleanupGate);
    bool queueEndedHandleAfterUnlock = false;
    if (!context || !impl) {
        stale = true;
    } else {
        std::lock_guard<std::mutex> admissionLock(impl->continuityAdmissionMutex);
        auto displayLease = impl->displayControl.acquireDisplayLease();
        std::lock_guard<std::mutex> lock(impl->mutex);
        currentGeneration = impl->cursorGeneration.load(std::memory_order_acquire);
        if (context->generation == 0 || context->generation != currentGeneration ||
            context->ownerToken == 0 ||
            context->ownerToken != impl->ownerToken.load(std::memory_order_acquire) ||
            context->admissionEpoch == 0 ||
            context->admissionEpoch != impl->ffiAdmissionEpoch.load(std::memory_order_acquire)) {
            stale = true;
        } else {
            impl->ffiStreamEnded.store(true, std::memory_order_release);
            displayLease.reset();
            wasConnected = impl->state == ConnectionState::CONNECTED;
            requested = impl->disconnectRequested.load(std::memory_order_acquire);
            // disconnect() already applies the visibility transition for the
            // requested teardown. Do not repeat it after setSessionIdentity()
            // has prepared the next session's fallback shape.
            if (!requested && !impl->cursorStore.setVisibleIfGeneration(
                    context->generation, false)) {
                stale = true;
            }
            if (!stale && !requested) {
                // The FFI callback runs on the streaming thread. Move
                // ownership out here and release it on a separate thread
                // after this callback returns. The cleanup thread is retained
                // by Impl and joined from disconnect().
                endedHandle = impl->displayControl.detachHandle();
                if (endedHandle != nullptr) {
                    OH_LOG_INFO(LOG_APP,
                        "[RustDesk-FFI] scheduling stale handle cleanup=%{public}p reason=stream-ended",
                        endedHandle);
                    std::thread cleanupThread;
                    bool cleanupWorkerOwnsHandle = false;
                    try {
                        cleanupGate = std::make_shared<std::promise<void>>();
                        std::future<void> cleanupReady = cleanupGate->get_future();
                        const auto cleanupDone =
                            std::make_shared<std::atomic<bool>>(false);
                        const std::shared_ptr<void> implKeepAlive = context->implKeepAlive;
                        // Allocate both parallel owner slots before creating a
                        // worker. Once the thread exists, publishing its
                        // noexcept move and shared completion fence cannot
                        // leave only one vector updated.
                        impl->ffiCleanupThreads.reserve(
                            impl->ffiCleanupThreads.size() + 1);
                        impl->ffiCleanupDone.reserve(
                            impl->ffiCleanupDone.size() + 1);
                        cleanupThread = std::thread(
                            [endedHandle, cleanupDone, impl, implKeepAlive,
                             cleanupReady = std::move(cleanupReady)]() mutable {
                                // rustdesk_disconnect joins the streaming thread.
                                // Waiting for the callback to return is mandatory;
                                // otherwise this worker could join its own callback
                                // thread and deadlock.
                                cleanupReady.wait();
                                rdDisconnectFfiHandle(impl, endedHandle);
                                cleanupDone->store(true, std::memory_order_release);
                            });
                        cleanupWorkerOwnsHandle = true;
                        impl->ffiCleanupThreads.emplace_back(std::move(cleanupThread));
                        impl->ffiCleanupDone.push_back(cleanupDone);
                    } catch (...) {
                        OH_LOG_ERROR(LOG_APP,
                            "[RustDesk-FFI] cleanup worker start failed; handle retained=%{public}p",
                            endedHandle);
                        // A successfully created worker is the sole owner of
                        // endedHandle even if publication unexpectedly fails.
                        // It captures Impl keep-alive and is fenced until this
                        // callback returns, so detaching the still-local
                        // worker is safer than publishing the handle twice.
                        if (cleanupThread.joinable()) {
                            cleanupThread.detach();
                        }
                        if (!cleanupWorkerOwnsHandle) {
                            // rdQueueDeferredFfiHandle locks impl->mutex. This
                            // callback still holds that mutex here, so defer
                            // the queue operation until after the admission
                            // scope has released it.
                            queueEndedHandleAfterUnlock = true;
                        }
                    }
                }
            }
        }
    }
    if (queueEndedHandleAfterUnlock) {
        rdQueueDeferredFfiHandle(impl, endedHandle);
    }
    if (stale) {
        OH_LOG_INFO(LOG_APP,
            "[RustDesk-FFI] stale disconnect callback ignored generation=%{public}llu current=%{public}llu",
            context ? static_cast<unsigned long long>(context->generation) : 0ULL,
            static_cast<unsigned long long>(currentGeneration));
        return;
    }
    if (requested) {
        OH_LOG_INFO(LOG_APP,
            "[RustDesk-FFI] stream stopped state=%{public}d msg=%{public}s connected=%{public}s requested=%{public}s",
            state,
            message ? message : "",
            wasConnected ? "yes" : "no",
            requested ? "yes" : "no");
        return;
    }
    if (impl) {
        const char* stopMessage = message ? message : "RustDesk stream stopped";
        if (state == 0) {
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] stream ended normally state=%{public}d msg=%{public}s connected=%{public}s requested=%{public}s",
                state, stopMessage, wasConnected ? "yes" : "no", "no");
            impl->setState(ConnectionState::DISCONNECTED, stopMessage);
        } else {
            OH_LOG_WARN(LOG_APP,
                "[RustDesk-FFI] stream stopped state=%{public}d msg=%{public}s connected=%{public}s requested=%{public}s",
                state, stopMessage, wasConnected ? "yes" : "no", "no");
            const RustDeskTransportErrorClass errorClass =
                rdClassifyTransportMessage(state, stopMessage);
            const uint64_t eventGeneration = context->generation;
            const uint64_t eventOwnerToken = context->ownerToken;
            const uint64_t eventAdmissionEpoch = context->admissionEpoch;
            const uint64_t eventSessionId =
                impl->sessionId.load(std::memory_order_acquire);
            RustDeskTransportEvent event {
                true,
                errorClass,
                impl->networkGeneration.load(std::memory_order_acquire),
                false,
                impl->networkAvailable.load(std::memory_order_acquire),
                rdSteadyNowMs(),
            };
            RustDeskConnectionContinuityExecutor::ActionAdmission admission =
                [impl, eventSessionId, eventGeneration, eventOwnerToken,
                 eventAdmissionEpoch]() {
                    return impl->sessionId.load(std::memory_order_acquire) ==
                            eventSessionId &&
                        impl->cursorGeneration.load(std::memory_order_acquire) ==
                            eventGeneration &&
                        impl->ownerToken.load(std::memory_order_acquire) ==
                            eventOwnerToken &&
                        impl->ffiAdmissionEpoch.load(std::memory_order_acquire) ==
                            eventAdmissionEpoch &&
                        !impl->disconnectRequested.load(std::memory_order_acquire);
                };
            (void)impl->continuityExecutor->onTransportEvent(
                event, std::move(admission));
        }
    }
} catch (const std::exception& ex) {
    OH_LOG_ERROR(LOG_APP,
        "[RustDesk-FFI] disconnect callback exception contained: %{public}s",
        ex.what());
} catch (...) {
    OH_LOG_ERROR(LOG_APP,
        "[RustDesk-FFI] disconnect callback exception contained: unknown");
}
#endif

RustDeskBridge::RustDeskBridge(RustDeskMode mode)
    : impl_(std::make_shared<Impl>()), mode_(mode) {
    RustDeskConnectionContinuityExecutor::Callbacks continuityCallbacks;
    continuityCallbacks.fastQuiesce = [this]() {
        applyContinuityFastQuiesce();
    };
    continuityCallbacks.publishVisibleState = [this](const std::string& event) {
        if (event == "REAUTH") {
            impl_->setState(ConnectionState::AUTHENTICATING,
                "Continuity|event=REAUTH");
        } else if (event == "FAILED" ||
                   event == "FAILED_RETRY_BUDGET_EXHAUSTED") {
            impl_->setState(ConnectionState::ERROR,
                "Continuity|event=FAILED");
        } else if (event == "WAITING_NETWORK") {
            impl_->setState(ConnectionState::DISCONNECTED,
                "Continuity|event=WAITING_NETWORK");
        } else if (event == "CONNECTED") {
            impl_->setState(ConnectionState::CONNECTED,
                "Continuity|event=CONNECTED");
        } else {
            impl_->setState(ConnectionState::RECONNECTING,
                std::string("Continuity|event=") + event);
        }
    };
    continuityCallbacks.makeAttemptTicket = [this]() {
        RustDeskConnectionContinuityExecutor::AttemptTicket ticket;
        const auto impl = impl_;
        ticket.sessionId = impl->sessionId.load(std::memory_order_acquire);
        ticket.sessionGeneration = impl->cursorGeneration.load(std::memory_order_acquire);
        ticket.ownerToken = impl->ownerToken.load(std::memory_order_acquire);
        ticket.admissionEpoch = impl->ffiAdmissionEpoch.load(std::memory_order_acquire);
        ticket.attemptToken = impl->nextContinuityAttemptToken.fetch_add(
            1, std::memory_order_relaxed);
        impl->continuityAttemptToken.store(ticket.attemptToken,
                                           std::memory_order_release);
        const uint64_t sessionId = ticket.sessionId;
        const uint64_t generation = ticket.sessionGeneration;
        const uint64_t ownerToken = ticket.ownerToken;
        const uint64_t admissionEpoch = ticket.admissionEpoch;
        const uint64_t attemptToken = ticket.attemptToken;
        ticket.validator = [impl, sessionId, generation, ownerToken,
                            admissionEpoch, attemptToken]() {
            return impl->sessionId.load(std::memory_order_acquire) == sessionId &&
                impl->cursorGeneration.load(std::memory_order_acquire) == generation &&
                impl->ownerToken.load(std::memory_order_acquire) == ownerToken &&
                impl->ffiAdmissionEpoch.load(std::memory_order_acquire) == admissionEpoch &&
                impl->continuityAttemptToken.load(std::memory_order_acquire) == attemptToken &&
                !impl->disconnectRequested.load(std::memory_order_acquire);
        };
        return ticket;
    };
    continuityCallbacks.prepareAttemptTicket = [this](
        const RustDeskConnectionContinuityExecutor::AttemptTicket& source) {
        const auto prepared = prepareContinuityAttempt(source);
        return prepared.value_or(
            RustDeskConnectionContinuityExecutor::PreparedAttemptTicket {});
    };
    continuityCallbacks.startAttemptWithPreparedTicket = [this](
        const RustDeskConnectionContinuityExecutor::PreparedAttemptTicket& ticket) {
        return startContinuityAttempt(ticket);
    };
    continuityCallbacks.cancelAttempt = [this]() {
#ifdef RUSTDESK_USE_REAL_CORE
        rustdesk_cancel_pending_connect_for_session(
            impl_->sessionId.load(std::memory_order_acquire));
#endif
    };
    continuityCallbacks.maintenancePoll = [this](uint64_t nowMs) {
        onContinuityMaintenance(nowMs);
    };
    continuityCallbacks.firstGenerationReady = [this]() {
        std::lock_guard<std::mutex> lock(impl_->continuityAdmissionMutex);
        if (impl_->disconnectRequested.load(std::memory_order_acquire) ||
            impl_->ffiStreamEnded.load(std::memory_order_acquire)) {
            return;
        }
        impl_->continuityQuiesce.reopenPresentationAfterFirstFrame();
        impl_->continuityQuiesce.reopenAudioAfterPrebuffer();
    };
    impl_->continuityExecutor->setCallbacks(std::move(continuityCallbacks));
    const char* modeLabel = (mode == RustDeskMode::IPC) ? "IPC" :
        (mode == RustDeskMode::FFI ? "FFI" : "EXPERIMENTAL");
    OH_LOG_INFO(LOG_APP, "[RustDesk] RustDeskBridge created (mode=%{public}s)", modeLabel);
}

void RustDeskBridge::setSessionIdentity(uint64_t sessionId) {
    const uint64_t generation =
        g_nextRustDeskCursorGeneration.fetch_add(1, std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> admissionLock(impl_->continuityAdmissionMutex);
        impl_->ffiAdmissionEpoch.fetch_add(1, std::memory_order_acq_rel);
        impl_->ffiStreamEnded.store(true, std::memory_order_release);
        impl_->continuityAttemptToken.store(0, std::memory_order_release);
        impl_->continuityNetworkCallCancelled.store(true, std::memory_order_release);
        impl_->awaitingFirstGenerationFrame.store(false, std::memory_order_release);
    }
    auto displayLease = impl_->displayControl.acquireDisplayLease();
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->sessionId.store(sessionId, std::memory_order_release);
        impl_->cursorGeneration.store(generation, std::memory_order_release);
        impl_->ownerToken.store(0, std::memory_order_release);
        impl_->callbackVideoFrames.store(0, std::memory_order_release);
        impl_->callbackVideoBytes.store(0, std::memory_order_release);
        impl_->callbackKeyframes.store(0, std::memory_order_release);
        impl_->callbackCodec.store(-1, std::memory_order_release);
        impl_->callbackWidth.store(0, std::memory_order_release);
        impl_->callbackHeight.store(0, std::memory_order_release);
        impl_->peerPlatform.store(
            RustDeskPresentation::PeerPlatformCategory::Unknown,
            std::memory_order_release);
        impl_->lastFrameAtMs.store(0, std::memory_order_release);
    }
    impl_->continuityExecutor->begin(sessionId, generation, rdSteadyNowMs());
    impl_->continuityQuiesce.reopen();
    displayLease.reset();
    impl_->cursorStore.reset(sessionId, "rustdesk", generation);
    // RustDesk does not guarantee that an unchanged cursor shape is repeated
    // after every UI/surface handoff. This local bootstrap shape is explicitly
    // marked non-authoritative so ArkUI can keep a stable circle affordance
    // until the protocol supplies the real cursor bitmap.
    impl_->cursorStore.setFallbackShape();
    impl_->cursorStore.setVisible(true);
}

void RustDeskBridge::setSessionOwnerToken(uint64_t ownerToken) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->ownerToken.store(ownerToken, std::memory_order_release);
}

void RustDeskBridge::setContinuityGenerationCallback(
    ContinuityGenerationCallback callback) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->continuityGenerationCallback = std::move(callback);
}

void RustDeskBridge::onNetworkChanged(bool available, uint64_t networkGeneration) {
    impl_->networkAvailable.store(available, std::memory_order_release);
    impl_->networkGeneration.store(networkGeneration, std::memory_order_release);
    if (mode_ != RustDeskMode::FFI) {
        return;
    }
    impl_->continuityExecutor->onNetworkAvailable(
        available, networkGeneration, rdSteadyNowMs());
}

RustDeskContinuityQuiesceSnapshot RustDeskBridge::continuityQuiesceSnapshot() const {
    return impl_->continuityQuiesce.snapshot();
}

std::optional<RustDeskConnectionContinuityExecutor::PreparedAttemptTicket>
RustDeskBridge::prepareContinuityAttempt(
    const RustDeskConnectionContinuityExecutor::AttemptTicket& source) {
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    std::function<void(int)> stageHook;
    {
        std::lock_guard<std::mutex> lock(impl_->continuityAdmissionMutex);
        stageHook = impl_->continuityAttemptStageHook;
    }
    if (stageHook) {
        stageHook(0);
    }
#endif

    const uint64_t attemptToken =
        impl_->nextContinuityAttemptToken.fetch_add(1, std::memory_order_relaxed);
    RustDeskConnectionContinuityExecutor::PreparedAttemptTicket prepared;
    {
        std::lock_guard<std::mutex> admissionLock(impl_->continuityAdmissionMutex);
        if (!source.valid() || !source.validator || !source.validator() ||
            source.sessionId != impl_->sessionId.load(std::memory_order_acquire) ||
            source.sessionGeneration != impl_->cursorGeneration.load(std::memory_order_acquire) ||
            source.ownerToken != impl_->ownerToken.load(std::memory_order_acquire) ||
            source.admissionEpoch != impl_->ffiAdmissionEpoch.load(std::memory_order_acquire) ||
            impl_->disconnectRequested.load(std::memory_order_acquire)) {
            return std::nullopt;
        }
        const uint64_t sessionId = source.sessionId;
        const uint64_t sessionGeneration = source.sessionGeneration;
        const uint64_t ownerToken = source.ownerToken;
        // A transport reconnect is a new FFI stream, not a new native sink
        // owner. Keep the decoder/renderer owner stable and rotate only the
        // FFI admission epoch so callbacks from the retired stream are still
        // rejected without dropping the active video pipeline.
        const uint64_t admissionEpoch =
            impl_->ffiAdmissionEpoch.fetch_add(1, std::memory_order_acq_rel) + 1;
        impl_->continuityAttemptToken.store(attemptToken, std::memory_order_release);
        impl_->ffiStreamEnded.store(true, std::memory_order_release);
        impl_->awaitingFirstGenerationFrame.store(
            mode_ == RustDeskMode::FFI, std::memory_order_release);
        impl_->continuityNetworkCallCancelled.store(false, std::memory_order_release);
        prepared.sessionId = sessionId;
        prepared.sessionGeneration = sessionGeneration;
        prepared.ownerToken = ownerToken;
        prepared.admissionEpoch = admissionEpoch;
        prepared.attemptToken = attemptToken;
        prepared.validator = [impl = impl_, sessionId, sessionGeneration,
                              ownerToken, admissionEpoch, attemptToken]() {
            return impl->sessionId.load(std::memory_order_acquire) == sessionId &&
                impl->cursorGeneration.load(std::memory_order_acquire) == sessionGeneration &&
                impl->ownerToken.load(std::memory_order_acquire) == ownerToken &&
                impl->ffiAdmissionEpoch.load(std::memory_order_acquire) == admissionEpoch &&
                impl->continuityAttemptToken.load(std::memory_order_acquire) == attemptToken &&
                !impl->disconnectRequested.load(std::memory_order_acquire);
        };
    }

#if defined(RDP_NATIVE_CALLBACK_TESTING)
    if (stageHook) {
        stageHook(1);
    }
#endif
    if (!prepared.valid() || !prepared.validator()) {
        return std::nullopt;
    }

    auto displayLease = impl_->displayControl.acquireDisplayLease();
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->callbackVideoFrames.store(0, std::memory_order_release);
        impl_->callbackVideoBytes.store(0, std::memory_order_release);
        impl_->callbackKeyframes.store(0, std::memory_order_release);
        impl_->callbackCodec.store(-1, std::memory_order_release);
        impl_->callbackWidth.store(0, std::memory_order_release);
        impl_->callbackHeight.store(0, std::memory_order_release);
        impl_->peerPlatform.store(
            RustDeskPresentation::PeerPlatformCategory::Unknown,
            std::memory_order_release);
        impl_->lastFrameAtMs.store(0, std::memory_order_release);
    }
    displayLease.reset();
    impl_->cursorStore.reset(prepared.sessionId, "rustdesk", prepared.sessionGeneration);
    impl_->cursorStore.setFallbackShape();
    impl_->cursorStore.setVisible(true);

    ContinuityGenerationCallback generationCallback;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        generationCallback = impl_->continuityGenerationCallback;
    }
    const bool activated = !generationCallback ||
        (prepared.validator() && generationCallback(
            prepared.sessionId, prepared.sessionGeneration, prepared.ownerToken));
    if (!activated || !prepared.validator()) {
        std::lock_guard<std::mutex> admissionLock(impl_->continuityAdmissionMutex);
        if (impl_->continuityAttemptToken.load(std::memory_order_acquire) ==
            prepared.attemptToken) {
            impl_->continuityAttemptToken.store(0, std::memory_order_release);
        }
        return std::nullopt;
    }
    impl_->continuityQuiesce.reopenGenerationAdmission();
    return prepared;
}

bool RustDeskBridge::startContinuityAttempt(
    const RustDeskConnectionContinuityExecutor::PreparedAttemptTicket& ticket) {
    if (mode_ != RustDeskMode::FFI || !ticket.valid() ||
        !ticket.validator || !ticket.validator()) {
        return false;
    }

#ifdef RUSTDESK_USE_REAL_CORE
    // The old stream owns the callback context until its cleanup worker has
    // joined. A new FFI context is not published across that boundary.
    rdDrainDeferredFfiHandles(impl_.get());
    std::thread completedConnect;
    std::vector<std::thread> completedCleanup;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (impl_->ffiConnectThread.joinable()) {
            if (!impl_->ffiConnectDone ||
                !impl_->ffiConnectDone->load(std::memory_order_acquire)) {
                return false;
            }
            completedConnect = std::move(impl_->ffiConnectThread);
            impl_->ffiConnectDone = std::make_shared<std::atomic<bool>>(true);
        }
        for (const auto& done : impl_->ffiCleanupDone) {
            if (!done || !done->load(std::memory_order_acquire)) {
                return false;
            }
        }
        completedCleanup = std::move(impl_->ffiCleanupThreads);
        impl_->ffiCleanupDone.clear();
    }
    if (completedConnect.joinable()) {
        completedConnect.join();
    }
    for (std::thread& worker : completedCleanup) {
        if (worker.joinable()) {
            worker.join();
        }
    }
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (!rdCanRetireFfiCallbackContextLocked(impl_.get())) {
            return false;
        }
        rdRetireFfiCallbackContextLocked(impl_.get());
    }
#endif

    ConnectionConfig reconnectConfig;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        reconnectConfig = impl_->config;
    }
    if (reconnectConfig.host.empty() && !reconnectConfig.rdDirectIp) {
        return false;
    }

#if defined(RDP_NATIVE_CALLBACK_TESTING)
    std::function<void(int)> stageHook;
    {
        std::lock_guard<std::mutex> lock(impl_->continuityAdmissionMutex);
        stageHook = impl_->continuityAttemptStageHook;
    }
    if (stageHook) {
        stageHook(2);
    }
    if (!ticket.validator()) {
        return false;
    }
#endif

    {
        std::lock_guard<std::mutex> admissionLock(impl_->continuityAdmissionMutex);
        if (!ticket.validator() ||
            impl_->continuityNetworkCallCancelled.load(std::memory_order_acquire)) {
            return false;
        }
        // This counter is incremented at the last cancellable admission
        // boundary. A disconnect after this point can discard the result, but
        // cannot allow it to publish a new handle or state.
        impl_->continuityConnectCallCount.fetch_add(1, std::memory_order_acq_rel);
    }

#if defined(RDP_NATIVE_CALLBACK_TESTING)
    if (stageHook) {
        stageHook(3);
    }
    if (!ticket.validator()) {
        return false;
    }
    std::function<int(uint64_t, uint64_t)> resultHook;
    {
        std::lock_guard<std::mutex> lock(impl_->continuityAdmissionMutex);
        resultHook = impl_->continuityConnectResultHook;
    }
    if (resultHook) {
        const int result = resultHook(ticket.sessionGeneration, ticket.attemptToken);
        const bool succeeded = result == 0 && ticket.validator() &&
            !impl_->continuityNetworkCallCancelled.load(std::memory_order_acquire);
        impl_->continuityExecutor->recordAttemptResult(succeeded, rdSteadyNowMs());
        return succeeded;
    }
#endif

    const int result = connectInternal(reconnectConfig, &ticket);
    if (result != 0) {
        if (ticket.validator()) {
            impl_->continuityExecutor->recordAttemptResult(false, rdSteadyNowMs());
        }
        return false;
    }
    return true;
}

void RustDeskBridge::applyContinuityFastQuiesce() {
    const uint64_t startedAt = rdSteadyNowMs();
    impl_->continuityQuiesce.closeForTransportLoss();
    impl_->ffiStreamEnded.store(true, std::memory_order_release);
    // This bridge has no additional platform audio/decoder stop call. The
    // FFI handle is detached by onFfiDisconnect and joined by the continuity
    // worker before a new context is published.
    impl_->continuityQuiesce.markDeferredDestroyComplete();
    impl_->continuityQuiesce.recordFastQuiesceDuration(
        rdSteadyNowMs() - startedAt);
}

void RustDeskBridge::onContinuityMaintenance(uint64_t /*nowMs*/) {
#ifdef RUSTDESK_USE_REAL_CORE
    rdDrainDeferredFfiHandles(impl_.get());
    std::vector<std::thread> completed;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (impl_->ffiConnectThread.joinable() && impl_->ffiConnectDone &&
            impl_->ffiConnectDone->load(std::memory_order_acquire)) {
            completed.push_back(std::move(impl_->ffiConnectThread));
            impl_->ffiConnectDone = std::make_shared<std::atomic<bool>>(true);
        }
        size_t index = 0;
        while (index < impl_->ffiCleanupThreads.size()) {
            if (index >= impl_->ffiCleanupDone.size() ||
                !impl_->ffiCleanupDone[index] ||
                !impl_->ffiCleanupDone[index]->load(std::memory_order_acquire)) {
                ++index;
                continue;
            }
            completed.push_back(std::move(impl_->ffiCleanupThreads[index]));
            impl_->ffiCleanupThreads.erase(impl_->ffiCleanupThreads.begin() + index);
            impl_->ffiCleanupDone.erase(impl_->ffiCleanupDone.begin() + index);
        }
    }
    for (std::thread& worker : completed) {
        if (worker.joinable()) {
            worker.join();
        }
    }
    rdDrainDeferredFfiHandles(impl_.get());
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (!impl_->ffiConnectThread.joinable() &&
            impl_->ffiCleanupThreads.empty() &&
            rdCanRetireFfiCallbackContextLocked(impl_.get())) {
            rdRetireFfiCallbackContextLocked(impl_.get());
        }
    }
#endif
}

uint64_t RustDeskBridge::sessionGeneration() const {
    return impl_->cursorGeneration.load(std::memory_order_acquire);
}

bool RustDeskBridge::reportVideoPressureForSession(uint64_t sessionId,
                                                   uint64_t generation,
                                                   uint64_t ownerToken,
                                                   int level) {
    if (sessionId == 0 || generation == 0 || ownerToken == 0 ||
        impl_->sessionId.load(std::memory_order_acquire) != sessionId ||
        impl_->cursorGeneration.load(std::memory_order_acquire) != generation ||
        impl_->ownerToken.load(std::memory_order_acquire) != ownerToken) {
        return false;
    }
    reportVideoPressure(level);
    return true;
}

bool RustDeskBridge::setImageQuality(int quality) {
#ifdef RUSTDESK_USE_REAL_CORE
    if (quality < 0 || quality > 2 || mode_ != RustDeskMode::FFI ||
        impl_->disconnectRequested.load(std::memory_order_acquire) ||
        impl_->ffiStreamEnded.load(std::memory_order_acquire)) {
        return false;
    }
    auto handleLease = impl_->displayControl.acquireHandle();
    return handleLease && rustdesk_set_image_quality(handleLease.get(), quality);
#else
    (void)quality;
    return false;
#endif
}

bool RustDeskBridge::submitTwoFactorCode(const std::string& code) {
#ifdef RUSTDESK_USE_REAL_CORE
    if (mode_ == RustDeskMode::FFI) {
        const uint64_t sessionId = impl_->sessionId.load(std::memory_order_acquire);
        return rustdesk_submit_2fa_for_session(sessionId, code.c_str());
    }
#else
    (void)code;
#endif
    return false;
}

RustDeskDiagnosticsStats RustDeskBridge::getDiagnostics() const {
    RustDeskDiagnosticsStats result;
    result.sessionId = impl_->sessionId.load(std::memory_order_acquire);
    result.receivedFrames = impl_->callbackVideoFrames.load(std::memory_order_acquire);
    result.receivedBytes = impl_->callbackVideoBytes.load(std::memory_order_acquire);
    result.keyframes = impl_->callbackKeyframes.load(std::memory_order_acquire);
    result.lastFrameAtMs = impl_->lastFrameAtMs.load(std::memory_order_acquire);
    result.codec = impl_->callbackCodec.load(std::memory_order_acquire);
    result.width = impl_->callbackWidth.load(std::memory_order_acquire);
    result.height = impl_->callbackHeight.load(std::memory_order_acquire);
    result.peerPlatform = RustDeskPresentation::PeerPlatformCategoryName(
        impl_->peerPlatform.load(std::memory_order_acquire));
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        RustDeskFfiStreamStats ffiStats {};
        const bool snapshotRead = rustdesk_get_stream_stats(handleLease.get(), &ffiStats);
        if (snapshotRead && ffiStats.version == kRustDeskStreamStatsVersion) {
            result.supported = true;
            result.latencyMs = ffiStats.test_delay_count > 0 ?
                static_cast<int>(ffiStats.last_delay_ms) : -1;
            result.targetBitrateKbps = static_cast<int>(ffiStats.target_bitrate_kbps);
            result.videoMessages = ffiStats.video_messages;
            result.audioFrames = ffiStats.audio_frames;
            result.cadenceGaps = ffiStats.cadence_gaps;
            result.maxCadenceGapMs = ffiStats.max_cadence_gap_ms;
            result.testDelayCount = ffiStats.test_delay_count;
            if (result.codec < 0) result.codec = ffiStats.actual_codec;
            if (result.width <= 0) result.width = ffiStats.width;
            if (result.height <= 0) result.height = ffiStats.height;
            result.connectionPath = ffiStats.connection_path;
        } else if (snapshotRead) {
            OH_LOG_WARN(LOG_APP,
                "[RustDesk-FFI] stream diagnostics snapshot rejected: unsupported ABI version=%{public}u",
                ffiStats.version);
        }
        RustDeskFfiQualityState qualityState {};
        if (rustdesk_get_quality_state(handleLease.get(), &qualityState) &&
            qualityState.version == kRustDeskQualityStateVersion) {
            result.requestedImageQuality = qualityState.rawQuality;
            result.effectiveImageQuality = qualityState.effectiveQuality;
            result.sentImageQuality = qualityState.sentQuality;
            result.qualityProfile = qualityState.profile;
            result.qualityFps = static_cast<int>(qualityState.fps);
            result.qualityRequestedGeneration = qualityState.requestedGeneration;
            result.qualityAppliedGeneration = qualityState.appliedGeneration;
            result.qualityUpdateStatus = static_cast<int>(qualityState.updateStatus);
        }
        RustDeskFfiPermissionState permissionState {};
        if (rustdesk_get_permission_state(handleLease.get(), &permissionState) &&
            permissionState.version == kRustDeskPermissionStateVersion) {
            result.remoteInputPermissionKnown =
                (permissionState.knownMask & kRustDeskPermissionKeyboard) != 0;
            result.remoteInputAllowed = !result.remoteInputPermissionKnown ||
                (permissionState.enabledMask & kRustDeskPermissionKeyboard) != 0;
            result.remoteClipboardPermissionKnown =
                (permissionState.knownMask & kRustDeskPermissionClipboard) != 0;
            result.remoteClipboardAllowed = !result.remoteClipboardPermissionKnown ||
                (permissionState.enabledMask & kRustDeskPermissionClipboard) != 0;
            result.remoteFilePermissionKnown =
                (permissionState.knownMask & kRustDeskPermissionFile) != 0;
            result.remoteFileAllowed = !result.remoteFilePermissionKnown ||
                (permissionState.enabledMask & kRustDeskPermissionFile) != 0;
        }
    }
#endif
    return result;
}

RustDeskDisplayCapabilities RustDeskBridge::getDisplayCapabilities() const {
    RustDeskDisplayCapabilities result;
#ifdef RUSTDESK_USE_REAL_CORE
    RustDeskDisplaySwitchGateSnapshot gate;
    const bool queried = impl_->displayControl.queryDisplayState(
        [&]() {
            return mode_ == RustDeskMode::FFI &&
                !impl_->disconnectRequested.load(std::memory_order_acquire) &&
                !impl_->ffiStreamEnded.load(std::memory_order_acquire);
        },
        [&](void* handle) {
            RustDeskFfiDisplaySnapshot snapshot {};
            RustDeskFfiResolution resolutions[32] {};
            if (!rustdesk_get_display_snapshot(handle, &snapshot, resolutions, 32) ||
                snapshot.version != kRustDeskDisplaySnapshotVersion) {
                return false;
            }
            result.supported = true;
            result.currentDisplay = snapshot.currentDisplay;
            result.width = snapshot.width;
            result.height = snapshot.height;
            result.originalWidth = snapshot.originalWidth;
            result.originalHeight = snapshot.originalHeight;
            result.scaleMilli = snapshot.scaleMilli;
            result.geometryEpoch = snapshot.geometryEpoch;
            const size_t count = std::min<size_t>(snapshot.resolutionCount, 32);
            result.resolutions.reserve(count);
            for (size_t index = 0; index < count; ++index) {
                if (resolutions[index].width > 0 && resolutions[index].height > 0) {
                    result.resolutions.push_back({resolutions[index].width, resolutions[index].height});
                }
            }
            RustDeskFfiDisplayInfoSnapshot ffiDisplays[16] {};
            RustDeskFfiResolution allResolutions[16 * 32] {};
            size_t displayCount = 0;
            size_t resolutionCount = 0;
            if (rustdesk_get_display_list(handle, ffiDisplays, 16, allResolutions,
                                          16 * 32, &displayCount, &resolutionCount)) {
                const size_t safeDisplayCount = std::min<size_t>(displayCount, 16);
                const size_t safeResolutionCount = std::min<size_t>(resolutionCount, 16 * 32);
                result.displays.reserve(safeDisplayCount);
                for (size_t index = 0; index < safeDisplayCount; ++index) {
                    const auto& ffiDisplay = ffiDisplays[index];
                    RustDeskDisplayInfo display;
                    display.display = ffiDisplay.display;
                    display.x = ffiDisplay.x;
                    display.y = ffiDisplay.y;
                    display.width = ffiDisplay.width;
                    display.height = ffiDisplay.height;
                    display.originalWidth = ffiDisplay.originalWidth;
                    display.originalHeight = ffiDisplay.originalHeight;
                    display.scaleMilli = ffiDisplay.scaleMilli;
                    display.online = ffiDisplay.online != 0;
                    display.cursorEmbedded = ffiDisplay.cursorEmbedded != 0;
                    const size_t nameLength =
                        std::min<size_t>(ffiDisplay.nameLen, sizeof(ffiDisplay.name));
                    display.name.assign(
                        reinterpret_cast<const char*>(ffiDisplay.name), nameLength);
                    const size_t offset =
                        std::min<size_t>(ffiDisplay.resolutionOffset, safeResolutionCount);
                    const size_t countForDisplay = std::min<size_t>(
                        ffiDisplay.resolutionCount, safeResolutionCount - offset);
                    display.resolutions.reserve(countForDisplay);
                    for (size_t resolutionIndex = 0;
                         resolutionIndex < countForDisplay;
                         ++resolutionIndex) {
                        const auto& resolution = allResolutions[offset + resolutionIndex];
                        if (resolution.width > 0 && resolution.height > 0) {
                            display.resolutions.push_back(
                                {resolution.width, resolution.height});
                        }
                    }
                    result.displays.push_back(std::move(display));
                }
            }
            // A peer may expose only current-display geometry. Synthesize a
            // one-entry catalog when the complete list is unavailable.
            if (result.displays.empty()) {
                RustDeskDisplayInfo display;
                display.display = result.currentDisplay;
                display.width = result.width;
                display.height = result.height;
                display.originalWidth = result.originalWidth;
                display.originalHeight = result.originalHeight;
                display.scaleMilli = result.scaleMilli;
                display.online = true;
                display.resolutions = result.resolutions;
                result.displays.push_back(std::move(display));
            }
            return true;
        },
        gate);
    if (!queried) {
        return result;
    }
    result.switchGeneration = gate.generation;
    result.readySwitchGeneration = gate.readyGeneration;
    result.pendingDisplay = gate.pendingDisplay;
    result.confirmedDisplay = gate.confirmedDisplay;
    result.inputBlocked = gate.inputBlocked;
#endif
    return result;
}

RustDeskDisplaySwitchRequest RustDeskBridge::beginDisplaySwitch(int display) {
    RustDeskDisplaySwitchRequest result;
#ifdef RUSTDESK_USE_REAL_CORE
    // Rust owns this as one latest-wins ControlInbox transaction. Keeping the
    // official switch/capture/refresh sequence behind one fenced FFI call
    // prevents rapid selections from interleaving partial triples or racing
    // teardown of the opaque Rust client.
    const RustDeskDisplayControlRequest request =
        impl_->displayControl.beginDisplaySwitch(
            display,
            [&]() {
                return mode_ == RustDeskMode::FFI && display < 16 &&
                    !impl_->disconnectRequested.load(std::memory_order_acquire) &&
                    !impl_->ffiStreamEnded.load(std::memory_order_acquire);
            },
            [](void* handle, int target) {
                return rustdesk_switch_display(handle, target);
            });
    result.accepted = request.accepted;
    result.generation = request.generation;
#else
    (void)display;
#endif
    return result;
}

bool RustDeskBridge::switchDisplay(int display) {
    return beginDisplaySwitch(display).accepted;
}

bool RustDeskBridge::captureDisplays(const std::vector<int>& displays) {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        const bool accepted = rustdesk_capture_displays(
            handleLease.get(),
            displays.empty() ? nullptr : displays.data(),
            displays.size());
        if (accepted) {
            std::lock_guard<std::mutex> lock(impl_->mutex);
            impl_->capturedDisplays.clear();
            for (const int display : displays) {
                if (display >= 0 && display < 16) {
                    impl_->capturedDisplays.insert(display);
                }
            }
        }
        return accepted;
    }
#else
    (void)displays;
#endif
    return false;
}

bool RustDeskBridge::refreshVideoDisplay(int display) {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        return rustdesk_refresh_video_display(handleLease.get(), display);
    }
#else
    (void)display;
#endif
    return false;
}

bool RustDeskBridge::changeDisplayResolution(int display, int width, int height) {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        return rustdesk_change_display_resolution(
            handleLease.get(), display, width, height);
    }
#endif
    return false;
}

bool RustDeskBridge::sendTouchScale(int scale) {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        return rustdesk_send_touch_scale(handleLease.get(), scale);
    }
#endif
    return false;
}

bool RustDeskBridge::sendTouchPan(int phase, int x, int y) {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        return rustdesk_send_touch_pan(handleLease.get(), phase, x, y);
    }
#endif
    return false;
}

RemoteCursorSnapshot RustDeskBridge::getRemoteCursorSnapshot(bool includePixels) {
    return impl_->cursorStore.snapshot(includePixels);
}

RustDeskBridge::~RustDeskBridge() {
    bool hasFfiHandle = false;
    bool hasFfiConnectThread = false;
    bool hasFfiCleanupThreads = false;
#ifdef RUSTDESK_USE_REAL_CORE
    hasFfiHandle = impl_->displayControl.hasHandle();
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        hasFfiConnectThread = impl_->ffiConnectThread.joinable();
        hasFfiCleanupThreads = !impl_->ffiCleanupThreads.empty();
    }
#endif
    if (getState() != ConnectionState::DISCONNECTED || hasFfiHandle ||
        hasFfiConnectThread || hasFfiCleanupThreads) {
        disconnect();
    }
}

std::string RustDeskBridge::protocolName() { return "RustDesk"; }
int RustDeskBridge::defaultPort() { return RD_DEFAULT_TCP_PORT; }

std::string RustDeskBridge::protocolVersion() {
    if (mode_ == RustDeskMode::FFI) {
#ifdef RUSTDESK_USE_REAL_CORE
        const char* version = rustdesk_version();
        return version != nullptr ? version : "2.1.0-ffi";
#else
        return "2.1.0-ffi-unavailable";
#endif
    }
    return (mode_ == RustDeskMode::IPC) ? "2.0.0-ipc" : "1.3.0-experimental";
}

// ============================================================
// RD_MODE_IPC: Unix Domain Socket → rustdesk_helper
// ============================================================

static int rdIpcConnect(const char* socketPath, int& fd) {
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] socket(AF_UNIX) failed: %{public}s", strerror(errno));
        return -1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socketPath, sizeof(addr.sun_path) - 1);

    // 非阻塞连接 + 短超时
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    int ret = ::connect(fd, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr));
    if (ret < 0 && errno != EINPROGRESS) {
        OH_LOG_WARN(LOG_APP, "[RustDesk-IPC] connect to helper failed: %{public}s (helper not running?)",
                    strerror(errno));
        close(fd); fd = -1; return -2;
    }
    // 恢复阻塞模式
    fcntl(fd, F_SETFL, flags);

    OH_LOG_INFO(LOG_APP,
                "[RustDesk-IPC] Connected to helper pathId=%{public}s fd=%{public}d",
                SafeLog::HashForLog(socketPath).c_str(), fd);
    return 0;
}

static int rdIpcSendConnectReq(int fd, const ConnectionConfig& cfg) {
    RdIpcConnectReq req;
    memset(&req, 0, sizeof(req));
    strncpy(req.host, cfg.host.c_str(), sizeof(req.host) - 1);
    req.port = static_cast<uint32_t>(cfg.port > 0 ? cfg.port :
        (cfg.rdDirectIp ? 21118 : RD_DEFAULT_TCP_PORT));
    strncpy(req.peerId, cfg.customHostname.c_str(), sizeof(req.peerId) - 1);
    strncpy(req.username, cfg.username.c_str(), sizeof(req.username) - 1);
    req.passwordLen = static_cast<uint32_t>(cfg.password.length());
    req.width = static_cast<uint32_t>(cfg.width > 0 ? cfg.width : 1920);
    req.height = static_cast<uint32_t>(cfg.height > 0 ? cfg.height : 1080);
    req.codec = static_cast<uint32_t>(cfg.codec);
    req.imageQuality = static_cast<uint32_t>(cfg.rdImageQuality);
    req.directIp = cfg.rdDirectIp ? 1 : 0;
    req.directPort = static_cast<uint32_t>(cfg.rdDirectPort > 0 ? cfg.rdDirectPort : 21118);
    req.lanDiscovery = cfg.rdLanDiscovery ? 1 : 0;
    req.privacyMode = cfg.rdPrivacyMode ? 1 : 0;
    req.passwordMode = static_cast<uint32_t>(cfg.rdPasswordMode == 1 ? 1 : 0);
    req.passwordLength = static_cast<uint32_t>(cfg.rdPasswordLength);
    strncpy(req.relayId, cfg.rdRelayId.c_str(), sizeof(req.relayId) - 1);
    strncpy(req.accountId, cfg.rdAccountId.c_str(), sizeof(req.accountId) - 1);

    size_t payloadSize = sizeof(req) + req.passwordLen;
    size_t frameSize = 5 + payloadSize;
    if (frameSize > RD_IPC_MAX_FRAME_SIZE) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] connect req too large: %{public}zu", frameSize);
        return -1;
    }

    auto buf = std::make_unique<uint8_t[]>(frameSize);
    RdIpcFrame::writeHeader(buf.get(), 5, RD_IPC_CONNECT_REQ, static_cast<uint32_t>(payloadSize));
    memcpy(buf.get() + 5, &req, sizeof(req));
    if (req.passwordLen > 0) {
        memcpy(buf.get() + 5 + sizeof(req), cfg.password.c_str(), req.passwordLen);
    }

    ssize_t sent = send(fd, buf.get(), frameSize, 0);
    if (sent < static_cast<ssize_t>(frameSize)) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] connect req send failed: %{public}zd/%{public}zu", sent, frameSize);
        return -1;
    }

    // 等待 ACK
    uint8_t ackBuf[5];
    ssize_t n = recv(fd, ackBuf, 5, 0);
    if (n < 5) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] connect ack recv failed: %{public}zd", n);
        return -1;
    }
    RdIpcMsgType ackType;
    uint32_t ackSize;
    RdIpcFrame::readHeader(ackBuf, 5, ackType, ackSize);
    if (ackType != RD_IPC_CONNECT_ACK) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] unexpected ack type: 0x%{public}02X", ackType);
        return -1;
    }
    uint8_t status = 0;
    if (ackSize > 0) {
        n = recv(fd, &status, 1, 0);
        if (n < 1) {
            OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] connect ack payload recv failed: %{public}zd", n);
            return -1;
        }
    }
    if (status != 0) {
        OH_LOG_ERROR(LOG_APP, "[RustDesk-IPC] helper rejected connect req: status=%{public}u", status);
        return -1;
    }
    OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] ✓ Connect ACK received (payload=%{public}u bytes)", ackSize);
    return 0;
}

static int rdIpcConnectFlow(int fd, const ConnectionConfig& cfg) {
    return rdIpcSendConnectReq(fd, cfg);
}

// ============================================================
// 连接管理 (根据 mode 分发)
// ============================================================

int RustDeskBridge::connect(const ConnectionConfig& cfg) {
    bool hasFfiHandle = false;
    bool hasFfiConnectThread = false;
    bool hasFfiCleanupThreads = false;
    bool hasFfiDeferredWork = false;
#ifdef RUSTDESK_USE_REAL_CORE
    hasFfiHandle = impl_->displayControl.hasHandle();
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        hasFfiConnectThread = impl_->ffiConnectThread.joinable();
        hasFfiCleanupThreads = !impl_->ffiCleanupThreads.empty();
        hasFfiDeferredWork =
            impl_->ffiHandleJoinPending.load(std::memory_order_acquire) != 0 ||
            impl_->ffiDeferredJoinCount.load(std::memory_order_acquire) != 0 ||
            !impl_->ffiDeferredHandles.empty();
    }
#endif
    if (getState() != ConnectionState::DISCONNECTED || hasFfiHandle ||
        hasFfiConnectThread || hasFfiCleanupThreads || hasFfiDeferredWork) {
        disconnect();
    }
    return connectInternal(cfg, nullptr);
}

int RustDeskBridge::connectInternal(
    const ConnectionConfig& cfg,
    const RustDeskConnectionContinuityExecutor::PreparedAttemptTicket* continuityTicket) {
    if (continuityTicket &&
        (!continuityTicket->valid() || !continuityTicket->validator ||
         !continuityTicket->validator())) {
        return -50;
    }
    // setSessionIdentity() can run before connect() tears down a previous FFI
    // stream. Re-seed the store after that teardown so the old disconnect
    // callback cannot leave the new session hidden or carry old revisions.
    const uint64_t sessionId = impl_->sessionId.load(std::memory_order_acquire);
    const uint64_t generation = impl_->cursorGeneration.load(std::memory_order_acquire);
    if (sessionId != 0 && generation != 0) {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->cursorStore.reset(sessionId, "rustdesk", generation);
        impl_->cursorStore.setFallbackShape();
        impl_->cursorStore.setVisible(true);
    }
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->config = cfg;
    }
    impl_->disconnectRequested.store(false);
    impl_->ffiStreamEnded.store(false);
    impl_->continuityNetworkCallCancelled.store(false, std::memory_order_release);
    const uint64_t serial = ++impl_->connectSerial;
    impl_->setState(ConnectionState::CONNECTING, "Connecting...");
    const std::string connectionStrategy = cfg.rdConnectionStrategy.empty()
        ? (cfg.rdDirectIp ? "direct_ip" : "force_relay")
        : cfg.rdConnectionStrategy;

    if (connectionStrategy == "auto") {
        const std::string message =
            "RDERR|stage=strategy|code=auto_unavailable|attempt=" +
            std::to_string(sessionId) +
            "|detail=automatic path is unavailable until NAT and relay fallback validation completes";
        impl_->setState(ConnectionState::ERROR, message);
        OH_LOG_WARN(LOG_APP,
            "[RustDesk] strategy=auto rejected fail-closed; NAT/fallback capability is unavailable");
        return -42;
    }
    if (connectionStrategy != "force_relay" &&
        connectionStrategy != "direct_ip") {
        const std::string message =
            "RDERR|stage=strategy|code=invalid_strategy|attempt=" +
            std::to_string(sessionId) + "|detail=invalid connection strategy";
        impl_->setState(ConnectionState::ERROR, message);
        OH_LOG_ERROR(LOG_APP, "[RustDesk] invalid connection strategy rejected");
        return -43;
    }
    if ((connectionStrategy == "direct_ip") != cfg.rdDirectIp) {
        const std::string message =
            "RDERR|stage=strategy|code=strategy_mode_mismatch|attempt=" +
            std::to_string(sessionId) + "|detail=connection strategy and direct mode disagree";
        impl_->setState(ConnectionState::ERROR, message);
        OH_LOG_ERROR(LOG_APP, "[RustDesk] connection strategy/direct mode mismatch rejected");
        return -44;
    }

    if (cfg.rdAuthMode == 1 && cfg.rdDirectIp) {
        // 点击批准依赖 ID/中继会话返回新的 Hash；直连模式没有这条批准通道。
        impl_->setState(ConnectionState::ERROR,
            "RustDesk remote approval requires rendezvous/relay mode; disable direct connection or use a device password.");
        OH_LOG_WARN(LOG_APP,
            "[RustDesk] remote approval is unavailable in direct mode; refusing ambiguous login");
        return -41;
    }

#ifdef RUSTDESK_USE_REAL_CORE
    if (mode_ == RustDeskMode::FFI) {
        // ---- FFI 模式: 直接调用 librustdesk_ffi.a ----
        OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] Using real core (protobuf protocol)");
        const std::string logHost = SafeLog::HashForLog(cfg.host);
        const int effectivePort = cfg.port > 0 ? cfg.port :
            (cfg.rdDirectIp ? 21118 : RD_DEFAULT_TCP_PORT);
        OH_LOG_INFO(LOG_APP,
                    "[RustDesk-FFI] Connecting endpointId=%{public}s port=%{public}d",
                    logHost.c_str(), effectivePort);
        const std::string ffiPeerId = cfg.rdDirectIp && !cfg.host.empty()
            ? cfg.host
            : (cfg.customHostname.empty() ? cfg.username : cfg.customHostname);
        const std::string logPeer = SafeLog::HashForLog(ffiPeerId);
        const char* serverKeyMode = cfg.rdServerKeyMode == 2 ? "shared" :
            (cfg.rdServerKeyMode == 1 ? "public" : "auto");
        OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] Request peerId=%{public}s strategy=%{public}s serverKeyMode=%{public}s proToken=%{public}s relayFallbackPort=%{public}d",
                    logPeer.c_str(), connectionStrategy.c_str(), serverKeyMode,
                    cfg.rdAccessToken.empty() ? "absent" : "present", cfg.rdRelayPort);

        RustDeskBridge::Impl* impl = impl_.get();
        const std::shared_ptr<Impl> keepAlive = impl_;
        const bool continuityAttempt = continuityTicket != nullptr;
        const RustDeskConnectionContinuityExecutor::PreparedAttemptTicket attemptTicket =
            continuityTicket ? *continuityTicket
                             : RustDeskConnectionContinuityExecutor::PreparedAttemptTicket {};
        const uint64_t callbackGeneration =
            impl_->cursorGeneration.load(std::memory_order_acquire);
        const auto connectDone = std::make_shared<std::atomic<bool>>(false);
        std::thread connectThread([impl, keepAlive, cfg, ffiPeerId, logHost, serial,
                                   callbackGeneration, sessionId, continuityAttempt,
                                   attemptTicket, connectDone]() {
            struct CompletionGuard {
                std::shared_ptr<std::atomic<bool>> done;
                ~CompletionGuard() {
                    if (done) done->store(true, std::memory_order_release);
                }
            } completion {connectDone};
            auto callbackContext = std::make_shared<RustDeskFfiCallbackContext>();
            callbackContext->impl = impl;
            callbackContext->implKeepAlive = keepAlive;
            callbackContext->generation = callbackGeneration;
            callbackContext->ownerToken = impl->ownerToken.load(std::memory_order_acquire);
            callbackContext->admissionEpoch = impl->ffiAdmissionEpoch.load(std::memory_order_acquire);
            RustDeskFfiCallbackContext* callbackUserData = callbackContext.get();
            {
                std::lock_guard<std::mutex> lock(impl->mutex);
                if (serial != impl->connectSerial.load(std::memory_order_acquire) ||
                    callbackGeneration != impl->cursorGeneration.load(std::memory_order_acquire) ||
                    impl->disconnectRequested.load(std::memory_order_acquire) ||
                    (continuityAttempt && (!attemptTicket.valid() ||
                        !attemptTicket.validator || !attemptTicket.validator())) ||
                    impl->ffiCallbackContext != nullptr) {
                    return;
                }
                if (!rdPublishFfiCallbackContext(callbackContext)) {
                    OH_LOG_ERROR(LOG_APP,
                        "[RustDesk-FFI] callback context registry publish failed");
                    return;
                }
                impl->ffiCallbackContext = callbackContext;
            }
            RustDeskFfiConfigV6 ffiCfgV6 = {}; // zero-init policy tail and reserved bytes
            RustDeskFfiConfig& ffiCfg = ffiCfgV6.legacy;
            ffiCfg.host     = cfg.host.c_str();
            ffiCfg.port     = cfg.port > 0 ? cfg.port :
                (cfg.rdDirectIp ? 21118 : RD_DEFAULT_TCP_PORT);
            ffiCfg.key      = cfg.rdServerKey.c_str();
            ffiCfg.username = ffiPeerId.c_str();
            ffiCfg.password = cfg.password.c_str();
            ffiCfg.width    = cfg.width;    // 0 = auto from profile
            ffiCfg.height   = cfg.height;   // 0 = auto from profile
            ffiCfg.codec    = rdFfiCodecPreference(cfg.codec);
            ffiCfg.imageQuality = cfg.rdImageQuality;
            ffiCfg.privacyMode = cfg.rdPrivacyMode;
            ffiCfg.audioEnabled = cfg.rdAudioEnabled;
            // T-121: Default to Balanced profile, allow override
            ffiCfg.profile  = 1; // Balanced
            ffiCfg.fps      = 0; // From profile
            ffiCfg.auth_mode = (cfg.rdAuthMode == 1) ? 1 : 0;
            ffiCfg.key_mode = cfg.rdServerKeyMode;
            ffiCfg.token    = cfg.rdAccessToken.c_str();
            ffiCfg.connection_id = sessionId;
            ffiCfg.relay_fallback_port = cfg.rdRelayPort;
            // T-209: 直连模式映射
            ffiCfg.direct_connection = false;
            if (cfg.rdDirectIp && !cfg.host.empty()) {
                // 仅当 rdDirectIp=true 且 host 非空时才走直连路径
                // host 此时是对端 IP 地址 (ArkTS 侧根据 per-host 配置填入)
                ffiCfg.direct_connection = true;
                OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] direct_connection=true peerId=%{public}s port=%{public}d",
                    logHost.c_str(), ffiCfg.port);
            }
            ffiCfgV6.connection_strategy = cfg.rdDirectIp ? 1 :
                (cfg.rdConnectionStrategy == "auto" ? 2 : 0);
            // UDP/KCP advertisement and AUTO remain product-gated until the
            // fixed hbbs/hbbr + controlled-peer device matrix is accepted.
            ffiCfgV6.nat_traversal_flags = 0;
            ffiCfgV6.nat_probe_serial = 0;
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] ffiCfg codec=%{public}d(%{public}s) quality=%{public}d privacy=%{public}s audio=%{public}s authMode=%{public}d size=%{public}dx%{public}d profile=%{public}d fps=%{public}d relayFallbackPort=%{public}d",
                ffiCfg.codec,
                rdCodecName(static_cast<int>(cfg.codec)),
                ffiCfg.imageQuality,
                ffiCfg.privacyMode ? "on" : "off",
                ffiCfg.audioEnabled ? "on" : "off",
                ffiCfg.auth_mode,
                ffiCfg.width,
                ffiCfg.height,
                ffiCfg.profile,
                ffiCfg.fps,
                ffiCfg.relay_fallback_port);

            // The Rust stream can invoke a callback synchronously during the
            // connect call (the display snapshot is one such path). Reserve
            // the callback context before crossing the FFI boundary and keep
            // the reservation until the returned handle is disconnected.
            RustDeskFfiConnectReservation handleReservation(impl);
            void* ffiHandle = rustdesk_connect_v6(
                &ffiCfgV6, onFfiFrame, onFfiAudio, onFfiCursor, onFfiDisconnect,
                onFfiDisplay, onFfiAuth, onFfiProgress, onFfiPeerPlatform,
                callbackUserData);
            if (ffiHandle != nullptr) {
                handleReservation.transferToHandleOwner();
            }
            bool discardHandle = serial != impl->connectSerial.load() ||
                impl->disconnectRequested.load() || impl->ffiStreamEnded.load() ||
                (continuityAttempt && (!attemptTicket.validator ||
                    !attemptTicket.validator()));
            if (!discardHandle) {
                std::lock_guard<std::mutex> lock(impl->mutex);
                discardHandle = serial != impl->connectSerial.load() ||
                    impl->disconnectRequested.load() || impl->ffiStreamEnded.load() ||
                    (continuityAttempt && (!attemptTicket.validator ||
                        !attemptTicket.validator()));
                if (!discardHandle && ffiHandle != nullptr &&
                    !impl->displayControl.attachHandle(ffiHandle)) {
                    discardHandle = true;
                }
            }
            if (discardHandle) {
                if (ffiHandle != nullptr) {
                    OH_LOG_INFO(LOG_APP,
                        "[RustDesk-FFI] late/ended connect result discarded handle=%{public}p",
                        ffiHandle);
                    rdDisconnectFfiHandle(impl, ffiHandle);
                }
                return;
            }

            if (ffiHandle == nullptr) {
                char errBuf[512] = {0};
                rustdesk_last_error(errBuf, sizeof(errBuf));
                OH_LOG_ERROR(LOG_APP, "[RustDesk-FFI] connection failed: %{public}s", errBuf);
                std::string errMsg = errBuf[0] != '\0'
                    ? std::string("FFI connection failed: ") + errBuf
                    : "FFI connection failed - check host/port and network";
                if (continuityAttempt && attemptTicket.validator &&
                    attemptTicket.validator()) {
                    impl->continuityExecutor->recordAttemptResult(false, rdSteadyNowMs());
                } else {
                    impl->setState(ConnectionState::ERROR, errMsg);
                }
                return;
            }

            const char* connectedMessage = "Connected via Rust FFI (protobuf protocol)";
            ConnectionStateCallback connectedCallback;
            bool publishedConnected = false;
            {
                std::lock_guard<std::mutex> lock(impl->mutex);
                // Publish CONNECTED and verify handle ownership atomically with
                // the disconnect callback. This prevents a stream that ended
                // during connect from being resurrected as CONNECTED.
                if (impl->displayControl.ownsHandle(ffiHandle) &&
                    serial == impl->connectSerial.load() &&
                    !impl->disconnectRequested.load() &&
                    !impl->ffiStreamEnded.load() &&
                    (!continuityAttempt || (attemptTicket.validator &&
                                             attemptTicket.validator()))) {
                    impl->state = ConnectionState::CONNECTED;
                    if (continuityAttempt) {
                        impl->awaitingFirstGenerationFrame.store(
                            true, std::memory_order_release);
                    }
                    connectedCallback = impl->stateCallback;
                    publishedConnected = true;
                }
            }
            if (!publishedConnected) {
                OH_LOG_INFO(LOG_APP,
                    "[RustDesk-FFI] connect completed after teardown, handle=%{public}p",
                    ffiHandle);
                void* orphanHandle = impl->displayControl.detachHandleIf(ffiHandle);
                if (orphanHandle != nullptr) {
                    rdDisconnectFfiHandle(impl, orphanHandle);
                }
                return;
            }
            if (connectedCallback) {
                connectedCallback(ConnectionState::CONNECTED, connectedMessage);
            }
            OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] Connected handle=%{public}p", ffiHandle);
        });
        {
            std::lock_guard<std::mutex> lock(impl_->mutex);
            impl_->ffiConnectThread = std::move(connectThread);
            impl_->ffiConnectDone = connectDone;
        }
        return 0;

    }
#endif

    if (mode_ == RustDeskMode::IPC) {
        // ---- IPC 模式: 连接 rustdesk_helper ----
        if (cfg.rdAuthMode == 1) {
            // helper 当前只转发基础连接帧，尚未暴露 RustDesk 的
            // No Password Access/远端批准状态机；禁止静默降级为空密码登录。
            impl_->setState(ConnectionState::ERROR,
                "RustDesk helper does not support remote approval; use the real FFI core or a device password.");
            OH_LOG_WARN(LOG_APP,
                "[RustDesk-IPC] remote approval is unavailable in helper mode; refusing empty-password fallback");
            return -40;
        }
        int ret = rdIpcConnect(g_socketPath.c_str(), impl_->ipcFd);
        if (ret < 0) {
            // 尝试自动启动 helper
            OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] helper 未运行, 尝试自动启动...");
            if (rdTryStartHelper()) {
                // 重试连接
                ret = rdIpcConnect(g_socketPath.c_str(), impl_->ipcFd);
            }
        }
        if (ret < 0) {
            impl_->setState(ConnectionState::ERROR,
                "Helper not running. Start rustdesk_helper first.");
            return -3;
        }
        ret = rdIpcConnectFlow(impl_->ipcFd, cfg);
        if (ret < 0) {
            impl_->setState(ConnectionState::ERROR, "IPC handshake failed");
            disconnect(); return ret;
        }
        impl_->setState(ConnectionState::CONNECTED,
            "Connected via rustdesk_helper (IPC)");
        OH_LOG_INFO(LOG_APP, "[RustDesk-IPC] ✓ Session routed through helper");
        return 0;
    }
#ifdef RUSTDESK_EXPERIMENTAL
    else {
        // ---- 实验模式: 手写 TCP 握手 (仅 dev) ----
        return connectExperimental(cfg);
    }
#else
    OH_LOG_ERROR(LOG_APP, "[RustDesk] RUSTDESK_EXPERIMENTAL not compiled in."
                 " Only IPC mode is available in this build.");
    impl_->setState(ConnectionState::ERROR,
        "Experimental mode not available. Rebuild with -DRUSTDESK_EXPERIMENTAL.");
    return -99;
#endif
}

void RustDeskBridge::disconnect() {
    disconnectImpl(true);
}

void RustDeskBridge::disconnectImpl(bool cancelContinuity) {
    if (!impl_) {
        return;
    }

    const uint64_t sessionId = impl_->sessionId.load(std::memory_order_acquire);
    const uint64_t disconnectGeneration =
        impl_->cursorGeneration.load(std::memory_order_acquire);

    // Invalidate every queued callback and reconnect ticket before entering a
    // blocking teardown. The admission mutex is deliberately released before
    // any state callback, FFI destructor, or thread join can run.
    {
        std::lock_guard<std::mutex> admissionLock(impl_->continuityAdmissionMutex);
        impl_->ffiAdmissionEpoch.fetch_add(1, std::memory_order_acq_rel);
        impl_->disconnectRequested.store(true, std::memory_order_release);
        impl_->ffiStreamEnded.store(true, std::memory_order_release);
        impl_->continuityAttemptToken.store(0, std::memory_order_release);
        impl_->continuityNetworkCallCancelled.store(true, std::memory_order_release);
        impl_->awaitingFirstGenerationFrame.store(false, std::memory_order_release);
    }
    if (cancelContinuity) {
        impl_->continuityExecutor->cancel();
    }
    applyContinuityFastQuiesce();

#ifdef RUSTDESK_USE_REAL_CORE
    void* ffiHandle = nullptr;
#endif
    {
        auto displayLease = impl_->displayControl.acquireDisplayLease();
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->cursorStore.setVisibleIfGeneration(disconnectGeneration, false);
        displayLease.reset();
#ifdef RUSTDESK_USE_REAL_CORE
        // Detach while the display lifecycle boundary is exclusive. Existing
        // handle leases have drained, and no later FFI call can acquire this
        // pointer. The Rust destructor runs after this boundary is released.
        ffiHandle = impl_->displayControl.detachHandle();
#endif
    }
    ++impl_->connectSerial;
    if (impl_->ipcFd >= 0) {
        shutdown(impl_->ipcFd, SHUT_RDWR);
        close(impl_->ipcFd);
        impl_->ipcFd = -1;
    }

#ifdef RUSTDESK_USE_REAL_CORE
    // FFI 句柄在登录完成前尚未返回，先取消等待中的连接尝试，避免点击返回后
    // 审批等待线程继续占用中继连接。
    rustdesk_cancel_pending_connect_for_session(sessionId);

    std::thread ffiConnectThread;
    std::shared_ptr<std::atomic<bool>> ffiConnectDone;
    std::vector<std::thread> ffiCleanupThreads;
    std::vector<std::shared_ptr<std::atomic<bool>>> ffiCleanupDone;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        ffiConnectThread = std::move(impl_->ffiConnectThread);
        ffiConnectDone = std::move(impl_->ffiConnectDone);
        ffiCleanupThreads = std::move(impl_->ffiCleanupThreads);
        ffiCleanupDone = std::move(impl_->ffiCleanupDone);
        impl_->ffiConnectDone = std::make_shared<std::atomic<bool>>(true);
    }

    const bool callbackThread = g_inRustDeskFfiCallback;
    bool deferredThreadJoin = false;
    const auto deferThread = [&](std::thread worker,
                                 std::shared_ptr<std::atomic<bool>> done) {
        if (!worker.joinable()) {
            return;
        }
        deferredThreadJoin = true;
        impl_->ffiDeferredJoinCount.fetch_add(1, std::memory_order_acq_rel);
        try {
            RustDeskContinuityDeferred::enqueue(
                std::move(worker), impl_, std::move(done),
                [keepAlive = impl_]() noexcept {
                    keepAlive->ffiDeferredJoinCount.fetch_sub(
                        1, std::memory_order_acq_rel);
                });
        } catch (...) {
            impl_->ffiDeferredJoinCount.fetch_sub(1, std::memory_order_acq_rel);
            OH_LOG_ERROR(LOG_APP,
                "[RustDesk-FFI] deferred thread enqueue failed; restoring worker ownership");
            // The deferred queue normally cannot fail after the worker has
            // been created. Keep a failed publication recoverable by putting
            // the worker back under Impl; the next non-callback disconnect or
            // maintenance pass will join it.
            try {
                std::lock_guard<std::mutex> lock(impl_->mutex);
                impl_->ffiCleanupThreads.emplace_back(std::move(worker));
                if (done) {
                    impl_->ffiCleanupDone.push_back(std::move(done));
                }
            } catch (...) {
                OH_LOG_ERROR(LOG_APP,
                    "[RustDesk-FFI] failed to retain deferred worker; terminating to avoid detached teardown");
                std::terminate();
            }
        }
    };

    if (mode_ == RustDeskMode::FFI && ffiHandle != nullptr) {
        if (!callbackThread) {
            rdDisconnectFfiHandle(impl_.get(), ffiHandle);
        } else {
            // rustdesk_disconnect() joins the stream producer. If the bridge
            // is re-entered from an FFI callback, wait for all callbacks to
            // leave before invoking that destructor on a deferred worker.
            auto done = std::make_shared<std::atomic<bool>>(false);
            std::thread handleCleanup([impl = impl_, ffiHandle, done]() {
                {
                    std::unique_lock<std::mutex> lock(impl->ffiCallbackMutex);
                    impl->ffiCallbackCv.wait(lock, [impl]() {
                        return impl->ffiCallbackActive.load(
                                   std::memory_order_acquire) == 0;
                    });
                }
                rdDisconnectFfiHandle(impl.get(), ffiHandle);
                done->store(true, std::memory_order_release);
            });
            deferThread(std::move(handleCleanup), done);
        }
    }

    const auto joinOrDefer = [&](std::thread& worker,
                                 const std::shared_ptr<std::atomic<bool>>& done) {
        if (!worker.joinable()) {
            return;
        }
        if (callbackThread || worker.get_id() == std::this_thread::get_id()) {
            deferThread(std::move(worker), done);
            return;
        }
        const auto joinDeadline = std::chrono::steady_clock::now() +
            std::chrono::milliseconds(500);
        while (done && !done->load(std::memory_order_acquire) &&
               std::chrono::steady_clock::now() < joinDeadline) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        if (done && !done->load(std::memory_order_acquire)) {
            OH_LOG_WARN(LOG_APP,
                "[RustDesk-FFI] disconnect join exceeded 500ms; deferring owned worker cleanup");
            deferThread(std::move(worker), done);
            return;
        }
        worker.join();
    };

    joinOrDefer(ffiConnectThread, ffiConnectDone);
    for (size_t index = 0; index < ffiCleanupThreads.size(); ++index) {
        const auto done = index < ffiCleanupDone.size()
            ? ffiCleanupDone[index] : nullptr;
        joinOrDefer(ffiCleanupThreads[index], done);
    }

    if (!deferredThreadJoin && !callbackThread) {
        std::unique_lock<std::mutex> lock(impl_->ffiCallbackMutex);
        impl_->ffiCallbackCv.wait(lock, [this]() {
            return impl_->ffiCallbackActive.load(std::memory_order_acquire) == 0;
        });
        lock.unlock();
        rdDrainDeferredFfiHandles(impl_.get());
        std::lock_guard<std::mutex> stateLock(impl_->mutex);
        // All FFI callbacks and cleanup workers have quiesced before the
        // generation context is reclaimed. A subsequent connect allocates a
        // fresh context with a fresh generation.
        if (rdCanRetireFfiCallbackContextLocked(impl_.get())) {
            rdRetireFfiCallbackContextLocked(impl_.get());
        } else {
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] callback context retirement deferred pending=%{public}u deferredJoins=%{public}u queuedHandles=%{public}zu",
                impl_->ffiHandleJoinPending.load(std::memory_order_acquire),
                impl_->ffiDeferredJoinCount.load(std::memory_order_acquire),
                impl_->ffiDeferredHandles.size());
        }
    }
#endif

    if (impl_->sockFd >= 0) {
        shutdown(impl_->sockFd, SHUT_RDWR);
        close(impl_->sockFd);
        impl_->sockFd = -1;
    }
    impl_->setState(ConnectionState::DISCONNECTED, "Disconnected");
    OH_LOG_INFO(LOG_APP, "[RustDesk] Disconnected");
}

ConnectionState RustDeskBridge::getState() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->state;
}

// ============================================================
// 输入事件 (IPC 模式: 转发到 helper)
// ============================================================

void RustDeskBridge::sendKey(uint32_t scancode, bool pressed) {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        uint64_t index = ++g_ffiKeySendCount;
        if (index <= 20 || index % 100 == 0) {
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] sendKey #%{public}llu sc=%{public}u pressed=%{public}s",
                static_cast<unsigned long long>(index),
                scancode,
                pressed ? "yes" : "no");
        }
        rustdesk_send_key(handleLease.get(), scancode, pressed);
        if (index <= 20 || index % 100 == 0) {
            char errBuf[512] = {0};
            rustdesk_last_error(errBuf, sizeof(errBuf));
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] rust status after sendKey: %{public}s",
                errBuf);
        }
        return;
    }
#endif
    if (mode_ == RustDeskMode::IPC && impl_->ipcFd >= 0) {
        RdIpcKeyEvent ev = {scancode, static_cast<uint8_t>(pressed ? 1 : 0)};
        uint8_t buf[5 + sizeof(ev)];
        RdIpcFrame::writeHeader(buf, sizeof(buf), RD_IPC_INPUT_KEY, sizeof(ev));
        memcpy(buf + 5, &ev, sizeof(ev));
        send(impl_->ipcFd, buf, sizeof(buf), 0);
    }
    OH_LOG_DEBUG(LOG_APP, "[RustDesk] key sc=%{public}u p=%{public}s", scancode, pressed ? "down" : "up");
}

bool RustDeskBridge::sendKeyEvents(const std::vector<RemoteKeyEvent>& events) {
    if (events.empty()) {
        return false;
    }
#ifdef RUSTDESK_USE_REAL_CORE
    // One lease pins one concrete FFI generation for the complete chord.
    // Continuity detach waits for the lease, so a batch can never straddle
    // the retired and replacement handles.
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI) {
        if (!handleLease) {
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] key transaction rejected without live handle events=%{public}zu",
                events.size());
            return false;
        }
        for (const auto& event : events) {
            rustdesk_send_key(handleLease.get(), event.keyCode, event.pressed);
        }
        OH_LOG_INFO(LOG_APP,
            "[RustDesk-FFI] key transaction submitted events=%{public}zu",
            events.size());
        return true;
    }
#endif
    if (mode_ == RustDeskMode::IPC && impl_->ipcFd >= 0) {
        for (const auto& event : events) {
            sendKey(event.keyCode, event.pressed);
        }
        return true;
    }
    OH_LOG_INFO(LOG_APP,
        "[RustDesk] key transaction rejected without active transport events=%{public}zu",
        events.size());
    return false;
}

void RustDeskBridge::sendMouse(int x, int y, MouseButton button, bool pressed) {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        int buttonValue = static_cast<int>(button);
        uint32_t ffiButton = buttonValue < 0 ? 0xFFFFFFFFu : static_cast<uint32_t>(buttonValue);
        uint64_t index = ++g_ffiMouseSendCount;
        if (index <= 10 || index % 300 == 0) {
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] sendMouse #%{public}llu x=%{public}d y=%{public}d button=%{public}d ffiButton=%{public}u pressed=%{public}s",
                static_cast<unsigned long long>(index),
                x,
                y,
                buttonValue,
                ffiButton,
                pressed ? "yes" : "no");
        }
        rustdesk_send_mouse(handleLease.get(), x, y, ffiButton, pressed);
        return;
    }
#endif
    if (mode_ == RustDeskMode::IPC && impl_->ipcFd >= 0) {
        RdIpcMouseEvent ev = {static_cast<uint16_t>(x), static_cast<uint16_t>(y),
                              static_cast<uint8_t>(button), static_cast<uint8_t>(pressed ? 1 : 0)};
        uint8_t buf[5 + sizeof(ev)];
        RdIpcFrame::writeHeader(buf, sizeof(buf), RD_IPC_INPUT_MOUSE, sizeof(ev));
        memcpy(buf + 5, &ev, sizeof(ev));
        send(impl_->ipcFd, buf, sizeof(buf), 0);
    }
}

void RustDeskBridge::sendMouseWheel(int x, int y, int delta) {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        uint64_t index = ++g_ffiWheelSendCount;
        if (index <= 20 || index % 100 == 0) {
            OH_LOG_INFO(LOG_APP,
                "[RustDesk-FFI] sendWheel #%{public}llu x=%{public}d y=%{public}d delta=%{public}d",
                static_cast<unsigned long long>(index),
                x,
                y,
                delta);
        }
        rustdesk_send_mouse_wheel(handleLease.get(), x, y, delta);
        return;
    }
#endif
    if (mode_ == RustDeskMode::IPC && impl_->ipcFd >= 0) {
        RdIpcWheelEvent ev = {static_cast<uint16_t>(x), static_cast<uint16_t>(y), static_cast<int32_t>(delta)};
        uint8_t buf[5 + sizeof(ev)];
        RdIpcFrame::writeHeader(buf, sizeof(buf), RD_IPC_INPUT_WHEEL, sizeof(ev));
        memcpy(buf + 5, &ev, sizeof(ev));
        send(impl_->ipcFd, buf, sizeof(buf), 0);
    }
}

bool RustDeskBridge::sendTouchpadWheel(int x, int y) {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        return rustdesk_send_mouse_wheel_2d(handleLease.get(), x, y);
    }
#endif
    return false;
}

void RustDeskBridge::sendText(const std::string& text) {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        uint64_t index = ++g_ffiTextSendCount;
        OH_LOG_INFO(LOG_APP,
            "[RustDesk-FFI] sendText #%{public}llu len=%{public}zu",
            static_cast<unsigned long long>(index),
            text.size());
        rustdesk_send_text(handleLease.get(), text.c_str());
        return;
    }
#endif
    if (mode_ == RustDeskMode::IPC && impl_->ipcFd >= 0) {
        size_t payload = text.length();
        size_t frameSize = 5 + payload;
        auto buf = std::make_unique<uint8_t[]>(frameSize);
        RdIpcFrame::writeHeader(buf.get(), 5, RD_IPC_INPUT_TEXT, static_cast<uint32_t>(payload));
        memcpy(buf.get() + 5, text.c_str(), payload);
        send(impl_->ipcFd, buf.get(), frameSize, 0);
    }
}

int RustDeskBridge::sendFileData(const std::string& remotePath, const uint8_t* data, uint32_t len) {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        uint64_t index = ++g_ffiFileSendCount;
        OH_LOG_INFO(LOG_APP,
            "[RustDesk-FFI] sendFileData #%{public}llu pathId=%{public}s len=%{public}u",
            static_cast<unsigned long long>(index),
            SafeLog::HashForLog(remotePath).c_str(),
            len);
        const uint64_t transferId = impl_->nextTransferId.fetch_add(1);
        impl_->transferStatus.markRustDeskProgress(transferId, 0, len);
        return rustdesk_send_file(
            handleLease.get(), transferId, remotePath.c_str(), data, len) == 0
            ? static_cast<int>(transferId) : -1;
    }
#endif
    OH_LOG_WARN(LOG_APP, "[RustDesk-Bridge] sendFileData: FFI mode not available (mode=%{public}d)", static_cast<int>(mode_));
    return -1;
}

SessionTransferStatus RustDeskBridge::getSessionTransferStatus() {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        RustDeskFfiTransferStatus ffi {};
        if (rustdesk_get_transfer_status(handleLease.get(), &ffi)) {
            if (ffi.state == 3) impl_->transferStatus.markRustDeskConfirmed(ffi.transferId, ffi.totalBytes);
            else if (ffi.state == 4) {
                char errorBuffer[512] = {0};
                rustdesk_get_transfer_error(handleLease.get(), errorBuffer, sizeof(errorBuffer));
                const std::string diagnostic = errorBuffer[0] != '\0'
                    ? std::string(errorBuffer)
                    : "remote_transfer_failed";
                const SessionTransferStatus current = impl_->transferStatus.snapshot();
                if (current.rustdeskTransfer != TransferRuntimeState::FAILED ||
                    current.transferId != ffi.transferId ||
                    current.diagnosticCode != diagnostic) {
                    OH_LOG_ERROR(LOG_APP,
                        "[RustDesk-FFI] file transfer failed id=%{public}llu detail=%{public}s",
                        static_cast<unsigned long long>(ffi.transferId),
                        diagnostic.c_str());
                }
                impl_->transferStatus.markRustDeskFailed(ffi.transferId, diagnostic);
            }
            else if (ffi.state == 2) impl_->transferStatus.markRustDeskProgress(ffi.transferId, ffi.transferredBytes, ffi.totalBytes);
        }
    }
#endif
    return impl_->transferStatus.snapshot();
}

void RustDeskBridge::sendClipboardData(const uint8_t* data, uint32_t len) {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        rustdesk_send_clipboard(handleLease.get(), data, len);
        return;
    }
#endif
    OH_LOG_WARN(LOG_APP, "[RustDesk-Bridge] sendClipboardData: FFI mode not available");
}

std::string RustDeskBridge::getClipboardText() {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        const size_t length = rustdesk_get_clipboard(handleLease.get(), nullptr, 0);
        if (length == 0 || length > 65536) return "";
        std::vector<unsigned char> buffer(length);
        const size_t copied =
            rustdesk_get_clipboard(handleLease.get(), buffer.data(), buffer.size());
        if (copied != length) return "";
        return std::string(reinterpret_cast<const char*>(buffer.data()), buffer.size());
    }
#endif
    return "";
}

bool RustDeskBridge::isClipboardReceiveReady() {
#ifdef RUSTDESK_USE_REAL_CORE
    return mode_ == RustDeskMode::FFI && impl_->displayControl.hasHandle();
#else
    return false;
#endif
}

void RustDeskBridge::requestFrameRefresh() {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        const bool ok = rustdesk_request_frame_refresh(handleLease.get());
        OH_LOG_INFO(LOG_APP, "[RustDesk-FFI] requestFrameRefresh sent=%{public}s", ok ? "true" : "false");
        return;
    }
#endif
    OH_LOG_WARN(LOG_APP, "[RustDesk-Bridge] requestFrameRefresh skipped: mode=%{public}d no ffi handle",
                static_cast<int>(mode_));
}

void RustDeskBridge::reportVideoPressure(int level) {
#ifdef RUSTDESK_USE_REAL_CORE
    auto handleLease = impl_->displayControl.acquireHandle();
    if (mode_ == RustDeskMode::FFI && handleLease) {
        rustdesk_report_video_pressure(handleLease.get(), level);
        return;
    }
#else
    (void)level;
#endif
}

// ---- 编码能力 ----
bool RustDeskBridge::supportsCodec(CodecType codec) {
    return codec == CodecType::VP8 || codec == CodecType::VP9 ||
           codec == CodecType::AV1 || codec == CodecType::H264 ||
           codec == CodecType::H265;
}
std::vector<CodecType> RustDeskBridge::supportedCodecs() {
    return {CodecType::VP8, CodecType::VP9, CodecType::AV1, CodecType::H264, CodecType::H265};
}

// ---- 回调 ----
void RustDeskBridge::setVideoCallback(VideoFrameCallback cb) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->videoCallback = std::move(cb);
}

#ifdef RDP_NATIVE_CALLBACK_TESTING
bool RustDeskBridge::InvokeVideoCallbackForTesting(
    const uint8_t* data, size_t size, int width, int height, int codec,
    uint64_t timestamp, bool isKeyFrame, int display, uint64_t generation,
    uint64_t ownerToken) {
#ifdef RUSTDESK_USE_REAL_CORE
    if (!impl_ || !data || size == 0) {
        return false;
    }

    // setSessionIdentity() intentionally starts a generation in the ended
    // state until connectInternal() publishes its FFI stream. The test entry
    // models that publication without opening a socket, while retaining the
    // exact production callback and owner/generation checks below.
    {
        std::lock_guard<std::mutex> admissionLock(impl_->continuityAdmissionMutex);
        if (generation != impl_->cursorGeneration.load(std::memory_order_acquire) ||
            ownerToken == 0 ||
            ownerToken != impl_->ownerToken.load(std::memory_order_acquire) ||
            impl_->disconnectRequested.load(std::memory_order_acquire)) {
            return false;
        }
        impl_->ffiStreamEnded.store(false, std::memory_order_release);
    }

    const uint64_t before = impl_->callbackVideoFrames.load(std::memory_order_acquire);
    auto context = std::make_shared<RustDeskFfiCallbackContext>();
    context->impl = impl_.get();
    context->implKeepAlive = impl_;
    context->generation = generation;
    context->ownerToken = ownerToken;
    context->admissionEpoch = impl_->ffiAdmissionEpoch.load(std::memory_order_acquire);
    if (!rdPublishFfiCallbackContext(context)) {
        return false;
    }
    RustDeskFfiVideoFrameV2 frame {
        data, size, width, height, codec, timestamp, isKeyFrame, display,
        kRustDeskVideoFrameAbiVersion, sizeof(RustDeskFfiVideoFrameV2),
    };
    onFfiFrame(&frame, context.get());
    (void)rdFfiCallbackRegistry().retire(context);
    return impl_->callbackVideoFrames.load(std::memory_order_acquire) != before;
#else
    (void)data;
    (void)size;
    (void)width;
    (void)height;
    (void)codec;
    (void)timestamp;
    (void)isKeyFrame;
    (void)display;
    (void)generation;
    (void)ownerToken;
    return false;
#endif
}

bool RustDeskBridge::InvokeTransportCallbackForTesting(
    int state, const char* errorClass, uint64_t networkGeneration,
    bool userInitiated, uint64_t generation, uint64_t ownerToken) {
#ifdef RUSTDESK_USE_REAL_CORE
    if (!impl_ || generation == 0 || ownerToken == 0) {
        return false;
    }

    const uint64_t before = impl_->continuityQuiesce.snapshot().quiesceCount;
    const uint64_t eventSessionId = impl_->sessionId.load(std::memory_order_acquire);
    const uint64_t eventAdmissionEpoch =
        impl_->ffiAdmissionEpoch.load(std::memory_order_acquire);
    {
        std::lock_guard<std::mutex> admissionLock(impl_->continuityAdmissionMutex);
        if (generation != impl_->cursorGeneration.load(std::memory_order_acquire) ||
            ownerToken != impl_->ownerToken.load(std::memory_order_acquire) ||
            eventAdmissionEpoch !=
                impl_->ffiAdmissionEpoch.load(std::memory_order_acquire) ||
            impl_->disconnectRequested.load(std::memory_order_acquire)) {
            return false;
        }
        // A production disconnect callback arrives after the stream has
        // stopped. Keep this synthetic entry equivalent without requiring a
        // live Rust handle.
        impl_->ffiStreamEnded.store(true, std::memory_order_release);
    }

    RustDeskTransportErrorClass classified =
        RustDeskTransportErrorClassFromString(rdLowercase(errorClass ? errorClass : ""));
    if (classified == RustDeskTransportErrorClass::Unknown) {
        classified = rdClassifyTransportMessage(state, errorClass);
    }
    if (state == 0) {
        classified = RustDeskTransportErrorClass::None;
    }
    RustDeskTransportEvent event {
        state != 0,
        classified,
        networkGeneration,
        userInitiated,
        impl_->networkAvailable.load(std::memory_order_acquire),
        rdSteadyNowMs(),
    };
    RustDeskConnectionContinuityExecutor::ActionAdmission admission =
        [impl = impl_, eventSessionId, generation, ownerToken, eventAdmissionEpoch]() {
            return impl->sessionId.load(std::memory_order_acquire) == eventSessionId &&
                impl->cursorGeneration.load(std::memory_order_acquire) == generation &&
                impl->ownerToken.load(std::memory_order_acquire) == ownerToken &&
                impl->ffiAdmissionEpoch.load(std::memory_order_acquire) == eventAdmissionEpoch &&
                !impl->disconnectRequested.load(std::memory_order_acquire);
        };
    (void)impl_->continuityExecutor->onTransportEvent(event, std::move(admission));
    return impl_->continuityQuiesce.snapshot().quiesceCount > before;
#else
    (void)state;
    (void)errorClass;
    (void)networkGeneration;
    (void)userInitiated;
    (void)generation;
    (void)ownerToken;
    return false;
#endif
}

void RustDeskBridge::SetAttemptDequeuedHookForTesting(std::function<void()> hook) {
    if (impl_) {
        impl_->continuityExecutor->setAttemptDequeuedHookForTesting(std::move(hook));
    }
}

void RustDeskBridge::SetFirstFrameClaimHookForTesting(std::function<void()> hook) {
    std::lock_guard<std::mutex> lock(impl_->continuityAdmissionMutex);
    impl_->firstFrameClaimHook = std::move(hook);
}

void RustDeskBridge::SetContinuityAttemptStageHookForTesting(
    std::function<void(int)> hook) {
    std::lock_guard<std::mutex> lock(impl_->continuityAdmissionMutex);
    impl_->continuityAttemptStageHook = std::move(hook);
}

void RustDeskBridge::SetContinuityConnectResultHookForTesting(
    std::function<int(uint64_t, uint64_t)> hook) {
    std::lock_guard<std::mutex> lock(impl_->continuityAdmissionMutex);
    impl_->continuityConnectResultHook = std::move(hook);
}

void RustDeskBridge::SetContinuityConfigForTesting(const ConnectionConfig& config) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->config = config;
}

uint32_t RustDeskBridge::continuityConnectCallCountForTesting() const {
    return impl_->continuityConnectCallCount.load(std::memory_order_acquire);
}

void RustDeskBridge::ArmFirstGenerationFrameForTesting() {
    {
        std::lock_guard<std::mutex> admissionLock(impl_->continuityAdmissionMutex);
        impl_->ffiAdmissionEpoch.fetch_add(1, std::memory_order_acq_rel);
        impl_->disconnectRequested.store(false, std::memory_order_release);
        impl_->ffiStreamEnded.store(false, std::memory_order_release);
        impl_->continuityAttemptToken.store(0, std::memory_order_release);
        impl_->continuityNetworkCallCancelled.store(false, std::memory_order_release);
    }
    impl_->continuityQuiesce.closeForTransportLoss();
    impl_->continuityQuiesce.reopenGenerationAdmission();
    impl_->awaitingFirstGenerationFrame.store(true, std::memory_order_release);
}
#endif

void RustDeskBridge::setAudioCallback(AudioDataCallback cb) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->audioCallback = std::move(cb);
}
void RustDeskBridge::setConnectionStateCallback(ConnectionStateCallback cb) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->stateCallback = std::move(cb);
}
void RustDeskBridge::setDisplayStateCallback(RustDeskDisplayStateCallback callback) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->displayStateCallback = std::move(callback);
}
// The current core supports configured direct/relay TCP paths only. AUTO/NAT
// coordination and hole punching remain fail-closed until the fixed upstream
// wire contract and IPv4/IPv6 device matrix are implemented.
bool RustDeskBridge::supportsNatTraversal() { return false; }
bool RustDeskBridge::supportsFileTransfer() { return true; }

void registerRustDeskBridge() {
#ifdef RUSTDESK_USE_REAL_CORE
    auto adapter = std::shared_ptr<RustDeskBridge>(new RustDeskBridge(RustDeskMode::FFI));
    OH_LOG_INFO(LOG_APP, "[RustDesk] RustDesk bridge registered (FFI mode, protobuf+NaCl)");
#else
    auto adapter = std::shared_ptr<RustDeskBridge>(new RustDeskBridge(RustDeskMode::IPC));
    OH_LOG_INFO(LOG_APP, "[RustDesk] RustDesk bridge registered (IPC mode, safe)");
#endif
    ExtensionSystem::instance().protocols.registerExt("protocol", "rustdesk", adapter);
}

#ifdef RUSTDESK_EXPERIMENTAL
// ============================================================
// RD_MODE_EXPERIMENTAL: 手写 TCP 握手 (仅 dev/test)
// WARNING: 密码明文发送 — 不得用于正式构建
// ============================================================
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <vector>
#include <random>

int RustDeskBridge::connectExperimental(const ConnectionConfig& cfg) {
    OH_LOG_WARN(LOG_APP, "[RustDesk-EXP] ⚠ EXPERIMENTAL MODE — plaintext password over TCP!");
    int port = cfg.port > 0 ? cfg.port : RD_DEFAULT_TCP_PORT;

    // TCP connect
    impl_->sockFd = rdConnectTcpEndpoint(cfg.host, static_cast<uint32_t>(port), 5000);
    if (impl_->sockFd < 0) {
        impl_->setState(ConnectionState::ERROR, "TCP connect failed");
        return -12;
    }

    // Version exchange
    unsigned char syn[16] = {};
    memcpy(syn, "RDCM", 4); syn[4] = 0x01;
    send(impl_->sockFd, syn, 16, 0);
    unsigned char ack[16];
    recv(impl_->sockFd, ack, 16, 0);

    // ID registration
    if (!cfg.customHostname.empty()) { /* ... */ }

    // ====== WARNING: 明文密码 — 仅实验 ======
    if (!cfg.password.empty()) {
        OH_LOG_WARN(LOG_APP, "[RustDesk-EXP] ⚠ Sending password in PLAINTEXT over TCP (EXPERIMENTAL ONLY)");
        unsigned char auth[260] = {};
        auth[0] = 0x02;
        size_t pwLen = cfg.password.length();
        if (pwLen > 255) pwLen = 255;
        auth[1] = static_cast<uint8_t>(pwLen);
        memcpy(auth + 2, cfg.password.c_str(), pwLen);
        send(impl_->sockFd, auth, pwLen + 2, 0);
        unsigned char result[1];
        if (recv(impl_->sockFd, result, 1, 0) <= 0 || result[0] != 0x00) {
            impl_->setState(ConnectionState::ERROR, "Auth failed");
            return -24;
        }
    }

    impl_->setState(ConnectionState::CONNECTED, "Connected (EXPERIMENTAL, plaintext)");
    OH_LOG_WARN(LOG_APP, "[RustDesk-EXP] ⚠ Connected with PLAINTEXT password — DO NOT USE IN PRODUCTION");
    return 0;
}
#endif // RUSTDESK_EXPERIMENTAL
