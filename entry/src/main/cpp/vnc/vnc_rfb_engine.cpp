/**
 * vnc_rfb_engine.cpp - bounded RFB 3.3/3.7/3.8 client implementation.
 *
 * Supported encodings are intentionally small and auditable: bounded ZRLE,
 * Raw, CopyRect, Cursor, DesktopSize and LastRect. Every rectangle, cursor
 * mask, compressed input and decompressed output is checked before use. The
 * engine never calls the shared video decoder.
 */
#include "vnc_rfb_engine.h"
#include "vnc_des.h"
#include "vnc_rfb_protocol.h"
#include "vnc_transport_policy.h"

#include "common/network_generation_fence.h"
#include "common/safe_log.h"
#if defined(VNC_DIAGNOSTICS) && VNC_DIAGNOSTICS
#define VNC_DIAGNOSTICS_ENABLED 1
#elif !defined(VNC_DIAGNOSTICS) && (defined(__OHOS__) || defined(__MUSL__))
#define VNC_DIAGNOSTICS_ENABLED 1
#else
#define VNC_DIAGNOSTICS_ENABLED 0
#endif

#if VNC_DIAGNOSTICS_ENABLED
#if defined(__OHOS__) || defined(__MUSL__)
#include <hilog/log.h>
#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0009
#define LOG_TAG "VNC_RFB_ENGINE"
#define VNC_DIAG_INFO(...) OH_LOG_INFO(LOG_APP, __VA_ARGS__)
#define VNC_DIAG_WARN(...) OH_LOG_WARN(LOG_APP, __VA_ARGS__)
#else
#define VNC_DIAG_INFO(...) do { } while (0)
#define VNC_DIAG_WARN(...) do { } while (0)
#endif
#else
#define VNC_DIAG_INFO(...) do { } while (0)
#define VNC_DIAG_WARN(...) do { } while (0)
#endif

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <limits>
#include <new>
#include <cstdlib>
#include <deque>
#include <memory>

namespace {

constexpr size_t kMaxReasonBytes = 64 * 1024;
constexpr size_t kMaxDesktopPixels = 16 * 1024 * 1024;
constexpr size_t kMaxRectanglePixels = 8 * 1024 * 1024;
constexpr size_t kMaxZrleCompressedBytes = 64 * 1024 * 1024;
constexpr size_t kMaxClipboardBytes = 1024 * 1024;
constexpr int kMaxFramebufferEdge = 8192;
constexpr int kMaxSecurityTypes = 64;

uint64_t nowMs() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

bool checkedPixelBytes(int width, int height, size_t bytesPerPixel, size_t& bytes) {
    if (width <= 0 || height <= 0 || bytesPerPixel == 0) return false;
    const size_t w = static_cast<size_t>(width);
    const size_t h = static_cast<size_t>(height);
    if (w > std::numeric_limits<size_t>::max() / h) return false;
    const size_t pixels = w * h;
    if (pixels > std::numeric_limits<size_t>::max() / bytesPerPixel) return false;
    bytes = pixels * bytesPerPixel;
    return true;
}

void appendU32(std::vector<uint8_t>& output, uint32_t value) {
    output.push_back(static_cast<uint8_t>((value >> 24) & 0xFF));
    output.push_back(static_cast<uint8_t>((value >> 16) & 0xFF));
    output.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
    output.push_back(static_cast<uint8_t>(value & 0xFF));
}

void secureClear(std::string& value) {
    if (!value.empty()) {
        volatile char* data = value.data();
        for (size_t index = 0; index < value.size(); ++index) data[index] = '\0';
    }
    value.clear();
}

} // namespace

namespace {

// A self-stop can happen from a state/frame callback running on the RFB
// worker. Keep the engine alive until that worker returns, then join it from
// this owner handoff thread. The engine is not detached or reclaimed early.
class VncDeferredJoiner {
public:
    VncDeferredJoiner() : worker_([this]() { run(); }) {}

    void enqueue(std::shared_ptr<VncRfbEngine> engine) {
        if (!engine) return;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (stopping_) {
                // The explicit app-scope owner has been shut down. Keep the
                // engine in the caller's owner rather than silently dropping
                // a joinable worker or detaching it.
                pending_.push_back(std::move(engine));
                return;
            }
            pending_.push_back(std::move(engine));
        }
        condition_.notify_one();
    }

    bool drainWithin(std::chrono::milliseconds timeout) {
        std::unique_lock<std::mutex> lock(mutex_);
        return condition_.wait_for(lock, timeout, [this]() {
            return pending_.empty() && active_ == 0;
        });
    }

    bool shutdownWithin(std::chrono::milliseconds timeout) {
        const auto deadline = std::chrono::steady_clock::now() + timeout;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopping_ = true;
        }
        condition_.notify_all();
        std::unique_lock<std::mutex> lock(mutex_);
        const bool done = condition_.wait_until(lock, deadline, [this]() {
            return workerDone_;
        });
        lock.unlock();
        if (!done || !worker_.joinable() ||
            worker_.get_id() == std::this_thread::get_id()) {
            return done && !worker_.joinable();
        }
        worker_.join();
        return true;
    }

    std::size_t remaining() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return pending_.size() + active_;
    }

private:
    void run() {
        for (;;) {
        std::shared_ptr<VncRfbEngine> engine;
        {
            std::unique_lock<std::mutex> lock(mutex_);
                condition_.wait(lock, [this]() {
                    return stopping_ || !pending_.empty();
                });
                if (pending_.empty() && stopping_) {
                    workerDone_ = true;
                    condition_.notify_all();
                    return;
                }
                engine = std::move(pending_.front());
                pending_.pop_front();
                ++active_;
            }
            // Do not let one stalled engine block completed engines behind it.
            // The owner polls independent done fences and keeps every live
            // engine retained until its own worker exits.
            engine->requestStop();
            if (!engine->workerDoneForDeferredJoin()) {
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    pending_.push_back(std::move(engine));
                    --active_;
                }
                condition_.notify_all();
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }
            engine->joinAfterWorkerDone();
            std::lock_guard<std::mutex> lock(mutex_);
            --active_;
            condition_.notify_all();
        }
    }

    mutable std::mutex mutex_;
    std::condition_variable condition_;
    std::deque<std::shared_ptr<VncRfbEngine>> pending_;
    std::thread worker_;
    bool stopping_ = false;
    bool workerDone_ = false;
    std::size_t active_ = 0;
};

std::mutex g_deferredJoinerOwnerMutex;
VncDeferredJoiner* g_deferredJoinerOwner = nullptr;

VncDeferredJoiner& deferredJoiner() {
    std::lock_guard<std::mutex> lock(g_deferredJoinerOwnerMutex);
    if (g_deferredJoinerOwner == nullptr) {
        g_deferredJoinerOwner = new VncDeferredJoiner();
    }
    return *g_deferredJoinerOwner;
}

} // namespace

VncRfbEngine::VncRfbEngine(const ConnectionConfig& config, VideoFrameCallback frameCallback,
                           StateCallback stateCallback, CursorCallback cursorCallback,
                           uint64_t networkGeneration)
    : config_(config), frameCallback_(std::move(frameCallback)),
      stateCallback_(std::move(stateCallback)),
      cursorCallback_(std::move(cursorCallback)),
      networkGeneration_(networkGeneration == 0
          ? remotedesk::net::ProcessNetworkGenerationFence().snapshot().generation
          : networkGeneration) {}

VncRfbEngine::~VncRfbEngine() {
    if (worker_.joinable() && !stopWithin(std::chrono::milliseconds(500))) {
        // A live engine must remain in the explicit deferred owner. Reaching
        // this destructor with an unfinished worker is a lifecycle contract
        // violation; aborting is fail-closed and bounded, whereas stop()
        // would hide an unbounded join and risk reclaiming callback state.
        std::abort();
    }
}

int VncRfbEngine::start() {
    if (worker_.joinable()) return -16;
    stopRequested_.store(false, std::memory_order_release);
    lastFramebufferRequestAtMs_.store(0, std::memory_order_release);
    // Publish CONNECTING before creating the worker.  The ArkTS session
    // waiter polls getConnectionState immediately after NAPI connect returns;
    // exposing the default DISCONNECTED state during this scheduling window
    // makes it tear down a healthy VNC attempt before TCP can begin.
    state_.store(ConnectionState::CONNECTING, std::memory_order_release);
    {
        std::lock_guard<std::mutex> lock(workerStateMutex_);
        workerDone_ = false;
    }
    try {
        worker_ = std::thread(&VncRfbEngine::run, this);
    } catch (const std::exception&) {
        {
            std::lock_guard<std::mutex> lock(workerStateMutex_);
            workerDone_ = true;
        }
        workerStateCv_.notify_all();
        clearSensitiveConfig();
        releaseCallbacks();
        return -12;
    }
    return 0;
}

void VncRfbEngine::requestStop() {
    const bool wasRequested = stopRequested_.exchange(true, std::memory_order_acq_rel);
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    if (!wasRequested) {
        std::function<void()> observer;
        {
            std::lock_guard<std::mutex> lock(callbackMutex_);
            observer = stopObserver_;
        }
        if (observer) observer();
    }
#else
    (void)wasRequested;
#endif
    // The worker owns SSL/socket teardown. Transport I/O observes the shared
    // stop token and returns through its bounded poll loop, so this method
    // never frees an SSL object concurrently with SSL_connect/read/write.
}

bool VncRfbEngine::isWorkerThread() const {
    return worker_.joinable() && worker_.get_id() == std::this_thread::get_id();
}

void VncRfbEngine::deferStopAndJoin(std::unique_ptr<VncRfbEngine> engine) {
    if (!engine) return;
    deferStopAndJoin(std::shared_ptr<VncRfbEngine>(std::move(engine)));
}

void VncRfbEngine::deferStopAndJoin(std::shared_ptr<VncRfbEngine> engine) {
    if (!engine) return;
    engine->requestStop();
    deferredJoiner().enqueue(std::move(engine));
}

bool VncRfbEngine::drainDeferredJoinsWithin(std::chrono::milliseconds timeout) {
    return deferredJoiner().drainWithin(timeout);
}

bool VncRfbEngine::shutdownDeferredJoinsWithin(std::chrono::milliseconds timeout) {
    VncDeferredJoiner* owner = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_deferredJoinerOwnerMutex);
        owner = g_deferredJoinerOwner;
    }
    if (owner == nullptr) return true;
    const bool done = owner->shutdownWithin(timeout);
    if (done) {
        std::lock_guard<std::mutex> lock(g_deferredJoinerOwnerMutex);
        if (g_deferredJoinerOwner == owner) {
            g_deferredJoinerOwner = nullptr;
            // The worker is joined, but callers that already obtained the raw
            // owner reference may still be returning from a method. Retain the
            // retired owner until process exit rather than racing its delete.
        }
    }
    return done;
}

std::size_t VncRfbEngine::deferredJoinRemaining() {
    std::lock_guard<std::mutex> lock(g_deferredJoinerOwnerMutex);
    return g_deferredJoinerOwner == nullptr ? 0 : g_deferredJoinerOwner->remaining();
}

void VncRfbEngine::stop() {
    requestStop();
    if (isWorkerThread()) {
        // The owning adapter transfers its shared engine to the reaper.
        setState(ConnectionState::DISCONNECTED, "VNC 已断开");
        return;
    }
    if (stopWithin(std::chrono::milliseconds(500))) {
        return;
    }
    // A public stop must never wait beyond its fixed budget. Production
    // engines are shared-owned by VncAdapter; keep the complete engine and
    // its callback state in the same app-scope reaper until the done fence.
    try {
        auto retained = shared_from_this();
        deferStopAndJoin(std::move(retained));
    } catch (const std::bad_weak_ptr&) {
        // A stack/unique test engine cannot be safely retained after this
        // call. Fail closed rather than destroying a live worker or blocking
        // in a default destructor.
        std::abort();
    }
}

bool VncRfbEngine::stopWithin(std::chrono::milliseconds timeout) {
    requestStop();
    if (isWorkerThread()) {
        setState(ConnectionState::DISCONNECTED, "VNC 已断开");
        return false;
    }
    if (!worker_.joinable()) {
        clearSensitiveConfig();
        setState(ConnectionState::DISCONNECTED, "VNC 已断开");
        releaseCallbacks();
        return true;
    }
    std::unique_lock<std::mutex> lock(workerStateMutex_);
    if (!workerStateCv_.wait_for(lock, timeout, [this]() { return workerDone_; })) {
        return false;
    }
    lock.unlock();
    if (worker_.joinable() && worker_.get_id() != std::this_thread::get_id()) {
        worker_.join();
    }
    clearSensitiveConfig();
    setState(ConnectionState::DISCONNECTED, "VNC 已断开");
    releaseCallbacks();
    return true;
}

void VncRfbEngine::waitForWorkerDone() {
    std::unique_lock<std::mutex> lock(workerStateMutex_);
    workerStateCv_.wait(lock, [this]() { return workerDone_ || !worker_.joinable(); });
}

void VncRfbEngine::joinAfterWorkerDone() {
    if (!worker_.joinable() || isWorkerThread()) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(workerStateMutex_);
        if (!workerDone_) {
            return;
        }
    }
    worker_.join();
}

bool VncRfbEngine::workerDoneForDeferredJoin() const {
    std::lock_guard<std::mutex> lock(workerStateMutex_);
    return workerDone_ || !worker_.joinable();
}

ConnectionState VncRfbEngine::state() const {
    return state_.load(std::memory_order_acquire);
}

bool VncRfbEngine::keepsLocalCursorDuringBootstrap() const {
    return keepLocalCursorDuringBootstrap_.load(std::memory_order_acquire);
}

void VncRfbEngine::run() {
    struct WorkerDone {
        VncRfbEngine* engine;
        ~WorkerDone() {
            {
                std::lock_guard<std::mutex> lock(engine->workerStateMutex_);
                engine->workerDone_ = true;
            }
            engine->workerStateCv_.notify_all();
        }
    } workerDone {this};
    struct CallbackRelease {
        VncRfbEngine* engine;
        ~CallbackRelease() { engine->releaseCallbacks(); }
    } callbackRelease {this};
    setState(ConnectionState::CONNECTING, "VNC 正在连接");
    std::string error;
    if (networkGenerationInvalidated()) {
        setState(ConnectionState::RECONNECTING,
                 "VNC 网络已变化，等待重新解析端点");
        clearSensitiveConfig();
        return;
    }
    if (config_.vncSecurityPolicy.empty()) config_.vncSecurityPolicy = "secure_only";
    if (config_.vncSecurityPolicy == "secure_only" && !config_.vncTls) {
        setState(ConnectionState::ERROR, "VNC 安全策略要求 TLS");
        clearSensitiveConfig();
        return;
    }
    if (!vncNativeTransportIsAvailable(config_.vncTransport)) {
        setState(ConnectionState::ERROR, "VNC transport 尚未通过网关协议契约，Native 入口已拒绝");
        clearSensitiveConfig();
        return;
    }
    // 首帧超时是“连接后等待第一帧”的上限；不能把同一个 15 秒值复用作
    // 后续每条服务器消息的空闲超时，否则服务器短暂停顿（例如切换应用
    // 动画间隙）时客户端会阻塞最多 15 秒才重发增量请求，表现为“卡很久
    // 才一帧一帧挪过去”。ioTimeoutMs_ 仍保护大矩形（22.5MB 全帧）读取。
    if (config_.vncFirstFrameTimeoutMs > 0) {
        ioTimeoutMs_ = std::max(1000, config_.vncFirstFrameTimeoutMs);
    }
    idleTimeoutMs_ = 5000;

    VncTransportConfig transportConfig;
    transportConfig.transport = config_.vncTransport;
    transportConfig.host = config_.host;
    transportConfig.port = config_.port;
    transportConfig.serverName = config_.vncServerName;
    transportConfig.tls = config_.vncTls;
    transportConfig.connectTimeoutMs = config_.vncConnectTimeoutMs;
    transportConfig.websocketPath = config_.vncGatewayPath.empty() ? "/vnc" : config_.vncGatewayPath;
    transportConfig.repeaterMode = config_.vncRepeaterMode;
    transportConfig.repeaterTarget = config_.vncRepeaterTarget;
    transportConfig.expectedCertificateFingerprintSha256 =
        config_.vncExpectedCertificateFingerprintSha256;
    transportConfig.cancelled = std::shared_ptr<std::atomic_bool>(
        &stopRequested_, [](std::atomic_bool*) {});
    transportConfig.networkGeneration = networkGeneration_;
    if (config_.vncTransport == "ultravnc_repeater") {
        if (!config_.vncGatewayHost.empty()) transportConfig.host = config_.vncGatewayHost;
        if (config_.vncGatewayPort > 0) transportConfig.port = config_.vncGatewayPort;
    }
    if (transportConfig.serverName.empty() &&
        !vncNormalizeCertificateEndpoint(
            transportConfig.host, transportConfig.port,
            transportConfig.serverName)) {
        setState(ConnectionState::ERROR, "VNC transport endpoint 无效");
        clearSensitiveConfig();
        return;
    }
    if (!transport_.connect(transportConfig, error)) {
        if (stopRequested_.load(std::memory_order_acquire)) {
            setState(ConnectionState::DISCONNECTED, "VNC 连接已取消");
        } else if (networkGenerationInvalidated()) {
            setState(ConnectionState::RECONNECTING,
                     "VNC 网络已变化，等待重新解析端点");
        } else {
            setState(ConnectionState::ERROR, "VNC transport 连接失败: " + error);
        }
        clearSensitiveConfig();
        return;
    }
    if (!handshake(error)) {
        transport_.close();
        if (stopRequested_.load(std::memory_order_acquire)) {
            setState(ConnectionState::DISCONNECTED, "VNC 连接已取消");
        } else if (networkGenerationInvalidated()) {
            setState(ConnectionState::RECONNECTING,
                     "VNC 网络已变化，等待重新解析端点");
        } else {
            setState(ConnectionState::ERROR, "VNC RFB 握手失败: " + error);
        }
        clearSensitiveConfig();
        return;
    }
    VNC_DIAG_INFO(
                "[VNC-DIAG] handshake complete rfb=3.%{public}03d framebuffer=%{public}dx%{public}d firstTimeoutMs=%{public}d ioTimeoutMs=%{public}d",
                negotiatedMinor_, framebufferWidth_, framebufferHeight_,
                config_.vncFirstFrameTimeoutMs, ioTimeoutMs_);
    // The password is only needed for VNC authentication.  Do not retain it
    // for the lifetime of an otherwise long-lived framebuffer session.
    secureClear(config_.password);
    setState(ConnectionState::CONNECTED, "VNC 已连接");
    if (!sendFramebufferUpdateRequest(false, error)) {
        if (networkGenerationInvalidated()) {
            setState(ConnectionState::RECONNECTING,
                     "VNC 网络已变化，等待重新解析端点");
        } else {
            setState(ConnectionState::ERROR, "VNC 首帧请求失败: " + error);
        }
        transport_.close();
        clearSensitiveConfig();
        return;
    }
    VNC_DIAG_INFO("[VNC-DIAG] initial framebuffer update request sent incremental=0 bytes=10");
    if (!receiveLoop(error) && !stopRequested_.load(std::memory_order_acquire) &&
        !networkGenerationInvalidated()) {
        setState(ConnectionState::ERROR, "VNC 会话已结束: " + error);
    }
    transport_.close();
    if (stopRequested_.load(std::memory_order_acquire)) {
        setState(ConnectionState::DISCONNECTED, "VNC 连接已取消");
    } else if (networkGenerationInvalidated()) {
        setState(ConnectionState::RECONNECTING,
                 "VNC 网络已变化，等待重新解析端点");
    } else if (state() != ConnectionState::ERROR) {
        setState(ConnectionState::DISCONNECTED, "VNC 服务器已断开");
    }
    clearSensitiveConfig();
}

bool VncRfbEngine::networkGenerationInvalidated() const {
    return networkGeneration_ == 0 ||
        remotedesk::net::ProcessNetworkGenerationFence().shouldCancel(
            remotedesk::net::NetworkGenerationSnapshot {
                networkGeneration_, true});
}

void VncRfbEngine::releaseCallbacks() {
    std::lock_guard<std::mutex> lock(callbackMutex_);
    frameCallback_ = nullptr;
    stateCallback_ = nullptr;
    cursorCallback_ = nullptr;
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    stopObserver_ = nullptr;
#endif
}

bool VncRfbEngine::handshake(std::string& error) {
    return negotiateVersion(error) && negotiateSecurity(error) && sendClientInit(error) &&
        initializeServer(error) &&
        sendPixelFormatAndEncodings(error);
}

bool VncRfbEngine::negotiateVersion(std::string& error) {
    std::array<uint8_t, 12> serverVersion = {0};
    if (!readBytes(serverVersion.data(), serverVersion.size(), config_.vncAuthTimeoutMs, error)) {
        return false;
    }
    const std::string version(reinterpret_cast<const char*>(serverVersion.data()), serverVersion.size());
    if (version.compare(0, 4, "RFB ") != 0 || version.compare(4, 3, "003") != 0 ||
        version[7] != '.' || version[11] != '\n') {
        error = "server banner is not an RFB version";
        return false;
    }
    for (size_t index = 8; index < 11; ++index) {
        if (!std::isdigit(static_cast<unsigned char>(version[index]))) {
            error = "server RFB version is malformed";
            return false;
        }
    }
    int minor = 0;
    try {
        minor = std::stoi(version.substr(8, 3));
    } catch (...) {
        error = "server RFB version is malformed";
        return false;
    }
    if (minor < 3) {
        error = "RFB versions older than 3.3 are not supported";
        return false;
    }
    negotiatedMinor_ = VncRfbProtocol::normalizeRfbMinor(minor);
    negotiated33_ = negotiatedMinor_ == 3;
    keepLocalCursorDuringBootstrap_.store(
        VncRfbProtocol::keepsLocalCursorDuringBootstrap(negotiatedMinor_),
        std::memory_order_release);
    char response[13] = {0};
    std::snprintf(response, sizeof(response), "RFB 003.%03d\n", negotiatedMinor_);
    return writeBytes(reinterpret_cast<const uint8_t*>(response), 12, error);
}

bool VncRfbEngine::negotiateSecurity(std::string& error) {
    std::vector<uint8_t> offered;
    if (negotiated33_) {
        uint32_t type = 0;
        if (!readU32(type, config_.vncAuthTimeoutMs, error)) return false;
        if (type == 0) {
            std::string reason;
            readReason(reason, error);
            error = reason.empty() ? "VNC server rejected the connection" : reason;
            return false;
        }
        if (type > 255) {
            error = "RFB 3.3 security type is outside the supported range";
            return false;
        }
        offered.push_back(static_cast<uint8_t>(type));
    } else {
        uint8_t count = 0;
        if (!readU8(count, config_.vncAuthTimeoutMs, error)) return false;
        if (count > kMaxSecurityTypes) {
            error = "VNC server offered too many security types";
            return false;
        }
        offered.resize(count);
        if (count > 0 && !readBytes(offered.data(), offered.size(), config_.vncAuthTimeoutMs, error)) return false;
        if (count == 0) {
            std::string reason;
            if (!readReason(reason, error)) return false;
            error = reason.empty() ? "VNC server offered no security type" : reason;
            return false;
        }
    }
    const bool allowNone = config_.vncTls || config_.vncSecurityPolicy != "secure_only";
    bool hasPassword = false;
    bool hasNone = false;
    for (uint8_t type : offered) {
        if (type == 2) hasPassword = true;
        if (type == 1) hasNone = true;
    }
    uint8_t selected = 0;
    if (hasPassword && !config_.password.empty()) selected = 2;
    else if (hasNone && allowNone) selected = 1;
    if (selected == 0) {
        error = hasPassword ? "VNC password is required or the security policy rejected None"
                            : "VNC server offered no supported security type";
        return false;
    }
    // RFB 3.3 sends exactly one 32-bit security type and has no client
    // security-selection write-back.  RFB 3.7/3.8 instead sends a one-byte
    // list count and requires the selected one-byte type.
    if (!negotiated33_ && !writeBytes(&selected, 1, error)) {
        return false;
    }
    if (selected == 2 && !authenticateVncPassword(error)) return false;
    if (!VncRfbProtocol::securityResultExpected(negotiatedMinor_, selected)) {
        return true;
    }
    uint32_t result = 0;
    if (!readU32(result, config_.vncAuthTimeoutMs, error)) return false;
    if (result != 0) {
        std::string reason;
        if (readReason(reason, error) && !reason.empty()) error = reason;
        else error = "VNC security authentication failed";
        return false;
    }
    return true;
}

bool VncRfbEngine::authenticateVncPassword(std::string& error) {
    std::array<uint8_t, 16> challenge = {0};
    if (!readBytes(challenge.data(), challenge.size(), config_.vncAuthTimeoutMs, error)) return false;
    uint8_t key[8] = {0};
    for (size_t index = 0; index < std::min<size_t>(8, config_.password.size()); ++index) {
        key[index] = reverseBits(static_cast<uint8_t>(config_.password[index]));
    }
    std::array<uint8_t, 16> response = {0};
    for (size_t offset = 0; offset < challenge.size(); offset += 8) {
        vncDesEncryptBlock(key, challenge.data() + offset, response.data() + offset);
    }
    return writeBytes(response.data(), response.size(), error);
}

bool VncRfbEngine::sendClientInit(std::string& error) {
    const uint8_t sharedFlag = VncRfbProtocol::clientInitSharedFlag();
    return writeBytes(&sharedFlag, sizeof(sharedFlag), error);
}

bool VncRfbEngine::initializeServer(std::string& error) {
    uint16_t width = 0;
    uint16_t height = 0;
    if (!readU16(width, config_.vncFirstFrameTimeoutMs, error) ||
        !readU16(height, config_.vncFirstFrameTimeoutMs, error)) return false;
    if (width == 0 || height == 0 || width > kMaxFramebufferEdge || height > kMaxFramebufferEdge) {
        error = "VNC desktop size is outside the safe limit";
        return false;
    }
    std::array<uint8_t, 16> pixelFormat = {0};
    if (!readBytes(pixelFormat.data(), pixelFormat.size(), config_.vncFirstFrameTimeoutMs, error)) return false;
    serverPixelFormat_.bitsPerPixel = pixelFormat[0];
    serverPixelFormat_.depth = pixelFormat[1];
    serverPixelFormat_.bigEndian = pixelFormat[2] != 0;
    serverPixelFormat_.trueColor = pixelFormat[3] != 0;
    serverPixelFormat_.redMax = static_cast<uint16_t>((pixelFormat[4] << 8) | pixelFormat[5]);
    serverPixelFormat_.greenMax = static_cast<uint16_t>((pixelFormat[6] << 8) | pixelFormat[7]);
    serverPixelFormat_.blueMax = static_cast<uint16_t>((pixelFormat[8] << 8) | pixelFormat[9]);
    serverPixelFormat_.redShift = pixelFormat[10];
    serverPixelFormat_.greenShift = pixelFormat[11];
    serverPixelFormat_.blueShift = pixelFormat[12];
    if (!serverPixelFormat_.trueColor ||
        (serverPixelFormat_.bitsPerPixel != 8 && serverPixelFormat_.bitsPerPixel != 16 &&
         serverPixelFormat_.bitsPerPixel != 32) ||
        serverPixelFormat_.redMax == 0 || serverPixelFormat_.greenMax == 0 ||
        serverPixelFormat_.blueMax == 0) {
        error = "VNC server pixel format is unsupported";
        return false;
    }
    uint32_t nameLength = 0;
    if (!readU32(nameLength, config_.vncFirstFrameTimeoutMs, error)) return false;
    if (nameLength > kMaxReasonBytes) {
        error = "VNC desktop name is too long";
        return false;
    }
    std::vector<uint8_t> name(nameLength);
    if (nameLength > 0 && !readBytes(name.data(), name.size(), config_.vncFirstFrameTimeoutMs, error)) return false;
    return resizeFramebuffer(width, height, error);
}

bool VncRfbEngine::sendPixelFormatAndEncodings(std::string& error) {
    const uint64_t desktopPixels = static_cast<uint64_t>(framebufferWidth_) *
        static_cast<uint64_t>(framebufferHeight_);
    const int colorDepth = VncRfbProtocol::effectiveTrueColorDepth(
        config_.vncColorDepth, config_.vncImageQualityPreset, desktopPixels,
        negotiatedMinor_);
    effectiveColorDepth_ = colorDepth;
    // SetPixelFormat message type 0 has three padding bytes before the 16-byte format.
    std::vector<uint8_t> setFormat = VncRfbProtocol::buildSetPixelFormat(colorDepth);
    if (!writeBytes(setFormat.data(), setFormat.size(), error)) return false;
    serverPixelFormat_.bitsPerPixel = setFormat[4];
    serverPixelFormat_.depth = setFormat[5];
    serverPixelFormat_.bigEndian = setFormat[6] != 0;
    serverPixelFormat_.trueColor = setFormat[7] != 0;
    serverPixelFormat_.redMax = static_cast<uint16_t>((setFormat[8] << 8) | setFormat[9]);
    serverPixelFormat_.greenMax = static_cast<uint16_t>((setFormat[10] << 8) | setFormat[11]);
    serverPixelFormat_.blueMax = static_cast<uint16_t>((setFormat[12] << 8) | setFormat[13]);
    serverPixelFormat_.redShift = setFormat[14];
    serverPixelFormat_.greenShift = setFormat[15];
    serverPixelFormat_.blueShift = setFormat[16];
    VNC_DIAG_INFO(
                "[VNC-DIAG] pixel format effectiveDepth=%{public}d requestedDepth=%{public}s quality=%{public}s rfbMinor=%{public}d framebuffer=%{public}dx%{public}d",
                colorDepth, config_.vncColorDepth.c_str(), config_.vncImageQualityPreset.c_str(),
                negotiatedMinor_, framebufferWidth_, framebufferHeight_);

    const std::vector<uint8_t> encodings =
        VncRfbProtocol::buildSetEncodings(config_.vncPreferredEncoding);
    VNC_DIAG_INFO(
                "[VNC-DIAG] SetEncodings requested=%{public}s effectivePreference=%{public}s fallback=raw",
                config_.vncPreferredEncoding.c_str(),
                config_.vncPreferredEncoding == "raw" ? "raw" : "zrle");
    return writeBytes(encodings.data(), encodings.size(), error);
}

bool VncRfbEngine::sendFramebufferUpdateRequest(bool incremental, std::string& error) {
    // Serialize refresh requests without holding the input write mutex during
    // the rate-limit wait.
    std::lock_guard<std::mutex> requestLock(framebufferRequestMutex_);
    if (incremental) {
        const uint64_t intervalMs = VncRfbProtocol::framebufferRequestIntervalMs(
            config_.vncFrameRateLimit);
        const uint64_t lastRequestMs = lastFramebufferRequestAtMs_.load(std::memory_order_acquire);
        const uint64_t currentMs = nowMs();
        if (intervalMs > 0 && lastRequestMs > 0 && currentMs < lastRequestMs + intervalMs) {
            std::this_thread::sleep_for(std::chrono::milliseconds(
                lastRequestMs + intervalMs - currentMs));
            if (stopRequested_.load(std::memory_order_acquire)) {
                error = "VNC frame request cancelled";
                return false;
            }
        }
    }
    const std::vector<uint8_t> request = VncRfbProtocol::buildFramebufferUpdateRequest(
        incremental,
        static_cast<uint16_t>(framebufferWidth_),
        static_cast<uint16_t>(framebufferHeight_));
    if (!writeBytes(request.data(), request.size(), error)) return false;
    lastFramebufferRequestAtMs_.store(nowMs(), std::memory_order_release);
    return true;
}

bool VncRfbEngine::receiveLoop(std::string& error) {
    bool firstMessage = true;
    while (!stopRequested_.load(std::memory_order_acquire)) {
        uint8_t type = 0;
        // 首帧仍等待 firstFrameTimeoutMs；后续消息等待独立的空闲超时，
        // 避免服务器动画间隙停顿导致客户端长时间阻塞。
        const int timeout = firstMessage ? config_.vncFirstFrameTimeoutMs : idleTimeoutMs_;
        if (!readU8(type, timeout, error)) {
            if (isTimeout(error)) {
                ++diagTimeouts_;
                if (diagTimeouts_ <= 4 || diagTimeouts_ % 10 == 0) {
                    VNC_DIAG_WARN(
                                "[VNC-DIAG] server message timeout count=%{public}llu firstMessage=%{public}d request=incremental",
                                static_cast<unsigned long long>(diagTimeouts_), firstMessage ? 1 : 0);
                }
                error.clear();
                if (!sendFramebufferUpdateRequest(true, error)) return false;
                continue;
            }
            VNC_DIAG_WARN("[VNC-DIAG] server message read failed error=%{public}s", error.c_str());
            return false;
        }
        firstMessage = false;
        ++diagServerMessages_;
        if (diagServerMessages_ <= 8 || diagServerMessages_ % 60 == 0) {
            VNC_DIAG_INFO(
                        "[VNC-DIAG] server message count=%{public}llu type=%{public}d",
                        static_cast<unsigned long long>(diagServerMessages_), static_cast<int>(type));
        }
        if (type == 0) {
            bool requestPipelined = false;
            if (!receiveFramebufferUpdate(requestPipelined, error)) return false;
            if (!requestPipelined && !sendFramebufferUpdateRequest(true, error)) return false;
        } else if (type == 2) {
            // Bell: no payload.
        } else if (type == 3) {
            if (!receiveServerCutText(error)) return false;
        } else {
            error = "unsupported VNC server message type";
            VNC_DIAG_WARN("[VNC-DIAG] unsupported server message type=%{public}d",
                        static_cast<int>(type));
            return false;
        }
    }
    return true;
}

bool VncRfbEngine::receiveFramebufferUpdate(bool& requestPipelined,
                                            std::string& error) {
    requestPipelined = false;
    uint8_t padding[1] = {0};
    uint16_t count = 0;
    // FBU 头部是小读取，跟随空闲超时；实际矩形负载仍受 ioTimeoutMs_ 保护。
    if (!readBytes(padding, sizeof(padding), idleTimeoutMs_, error) ||
        !readU16(count, idleTimeoutMs_, error)) return false;
    if (count > 4096) {
        error = "VNC update contains too many rectangles";
        return false;
    }
    ++diagFramebufferUpdates_;
    if (diagFramebufferUpdates_ <= 8 || diagFramebufferUpdates_ % 60 == 0 || count == 0) {
        VNC_DIAG_INFO(
                    "[VNC-DIAG] framebuffer update count=%{public}llu rectangles=%{public}u",
                    static_cast<unsigned long long>(diagFramebufferUpdates_), count);
    }
    bool dirty = false;
    bool fullFrame = false;
    int dirtyLeft = framebufferWidth_;
    int dirtyTop = framebufferHeight_;
    int dirtyRight = 0;
    int dirtyBottom = 0;
    int frameEncoding = -1;
    const auto markDirty = [&](int x, int y, int width, int height, bool full) -> void {
        if (full) {
            fullFrame = true;
            dirty = true;
            return;
        }
        if (fullFrame || width <= 0 || height <= 0) return;
        dirty = true;
        dirtyLeft = std::min(dirtyLeft, x);
        dirtyTop = std::min(dirtyTop, y);
        dirtyRight = std::max(dirtyRight, x + width);
        dirtyBottom = std::max(dirtyBottom, y + height);
    };
    for (uint16_t index = 0; index < count; ++index) {
        uint16_t x = 0, y = 0, width = 0, height = 0;
        int32_t encoding = 0;
        if (!readU16(x, ioTimeoutMs_, error) || !readU16(y, ioTimeoutMs_, error) ||
            !readU16(width, ioTimeoutMs_, error) || !readU16(height, ioTimeoutMs_, error) ||
            !readI32(encoding, ioTimeoutMs_, error)) return false;
        if (diagFramebufferUpdates_ <= 8 || diagFramebufferUpdates_ % 60 == 0) {
            VNC_DIAG_INFO(
                        "[VNC-DIAG] rectangle update=%{public}llu index=%{public}u x=%{public}u y=%{public}u width=%{public}u height=%{public}u encoding=%{public}d",
                        static_cast<unsigned long long>(diagFramebufferUpdates_), index,
                        x, y, width, height, encoding);
        }
        if (encoding == VncRfbProtocol::kRawEncoding) {
            if (!receiveRawRectangle(x, y, width, height, error)) return false;
            markDirty(x, y, width, height, false);
            if (frameEncoding != VncRfbProtocol::kZrleEncoding) {
                frameEncoding = VncRfbProtocol::kRawEncoding;
            }
        } else if (encoding == VncRfbProtocol::kCopyRectEncoding) {
            if (!receiveCopyRectangle(x, y, width, height, error)) return false;
            markDirty(x, y, width, height, false);
            if (frameEncoding < 0) {
                frameEncoding = VncRfbProtocol::kCopyRectEncoding;
            }
        } else if (encoding == VncRfbProtocol::kZrleEncoding) {
            if (!receiveZrleRectangle(x, y, width, height,
                                      count == 1 && index == 0,
                                      requestPipelined, error)) return false;
            markDirty(x, y, width, height, false);
            frameEncoding = VncRfbProtocol::kZrleEncoding;
        } else if (encoding == VncCursorProtocol::kEncoding) {
            if (!receiveCursorRectangle(x, y, width, height, error)) return false;
        } else if (encoding == VncRfbProtocol::kDesktopSizeEncoding) {
            if (!receiveDesktopSize(width, height, error)) return false;
            markDirty(0, 0, framebufferWidth_, framebufferHeight_, true);
        } else if (encoding == VncRfbProtocol::kLastRectEncoding) {
            break;
        } else {
            error = "VNC server selected an unsupported framebuffer encoding";
            return false;
        }
    }
    // RFC 6143 groups all rectangles belonging to one server update.  Decode
    // the complete group first and present once so a multi-rectangle Mac
    // refresh does not force one EGL swap per rectangle.
    if (dirty) {
        if (frameEncoding >= 0) {
            effectiveEncoding_ = frameEncoding;
        }
        if (fullFrame) {
            emitFrame(-1, -1, framebufferWidth_, framebufferHeight_);
        } else if (dirtyRight > dirtyLeft && dirtyBottom > dirtyTop) {
            emitFrame(dirtyLeft, dirtyTop, dirtyRight - dirtyLeft, dirtyBottom - dirtyTop);
        }
    }
    return true;
}

bool VncRfbEngine::receiveRawRectangle(int x, int y, int width, int height, std::string& error) {
    if (!validRectangle(x, y, width, height)) {
        error = "VNC Raw rectangle is outside the framebuffer";
        return false;
    }
    const size_t bytesPerPixel = serverPixelFormat_.bitsPerPixel / 8;
    size_t rawBytes = 0;
    size_t pixels = 0;
    if (!checkedPixelBytes(width, height, bytesPerPixel, rawBytes) ||
        !checkedPixelBytes(width, height, 1, pixels) || pixels > kMaxRectanglePixels) {
        error = "VNC Raw rectangle exceeds the safe limit";
        return false;
    }
    std::vector<uint8_t> raw(rawBytes);
    if (!readBytes(raw.data(), raw.size(), ioTimeoutMs_, error)) return false;
    for (int row = 0; row < height; ++row) {
        for (int column = 0; column < width; ++column) {
            const size_t source = (static_cast<size_t>(row) * width + column) * bytesPerPixel;
            const uint32_t pixel = decodePixel(raw.data() + source);
            const size_t destination = (static_cast<size_t>(y + row) * framebufferWidth_ + x + column) * 4;
            framebuffer_[destination] = static_cast<uint8_t>(pixel & 0xFF);
            framebuffer_[destination + 1] = static_cast<uint8_t>((pixel >> 8) & 0xFF);
            framebuffer_[destination + 2] = static_cast<uint8_t>((pixel >> 16) & 0xFF);
            framebuffer_[destination + 3] = 0xFF;
        }
    }
    return true;
}

bool VncRfbEngine::receiveCopyRectangle(int x, int y, int width, int height, std::string& error) {
    if (!validRectangle(x, y, width, height)) {
        error = "VNC CopyRect destination is outside the framebuffer";
        return false;
    }
    uint16_t sourceX = 0, sourceY = 0;
    if (!readU16(sourceX, ioTimeoutMs_, error) || !readU16(sourceY, ioTimeoutMs_, error) ||
        !validRectangle(sourceX, sourceY, width, height)) {
        error = "VNC CopyRect source is outside the framebuffer";
        return false;
    }
    size_t copyBytes = 0;
    if (!checkedPixelBytes(width, height, 4, copyBytes) || copyBytes > kMaxRectanglePixels * 4) {
        error = "VNC CopyRect exceeds the safe limit";
        return false;
    }
    std::vector<uint8_t> copy(copyBytes);
    for (int row = 0; row < height; ++row) {
        const size_t source = (static_cast<size_t>(sourceY + row) * framebufferWidth_ + sourceX) * 4;
        std::memcpy(copy.data() + static_cast<size_t>(row) * width * 4,
                    framebuffer_.data() + source, static_cast<size_t>(width) * 4);
    }
    for (int row = 0; row < height; ++row) {
        const size_t destination = (static_cast<size_t>(y + row) * framebufferWidth_ + x) * 4;
        std::memcpy(framebuffer_.data() + destination,
                    copy.data() + static_cast<size_t>(row) * width * 4,
                    static_cast<size_t>(width) * 4);
    }
    return true;
}

bool VncRfbEngine::receiveZrleRectangle(int x, int y, int width, int height,
                                        bool pipelineNextRequest,
                                        bool& requestPipelined,
                                        std::string& error) {
#if VNC_DIAGNOSTICS_ENABLED
    const uint64_t zrleStartMs = nowMs();
#endif
    if (!validRectangle(x, y, width, height)) {
        error = "VNC ZRLE rectangle is outside the framebuffer";
        return false;
    }
    size_t pixels = 0;
    if (!checkedPixelBytes(width, height, 1, pixels) || pixels > kMaxRectanglePixels) {
        error = "VNC ZRLE rectangle exceeds the safe pixel limit";
        return false;
    }
    uint32_t compressedLength = 0;
    if (!readU32(compressedLength, ioTimeoutMs_, error)) {
        return false;
    }
    size_t maxDecodedBytes = 0;
    if (!VncRfbProtocol::maxZrleDecodedBytes(
            width, height, serverPixelFormat_, maxDecodedBytes)) {
        error = "VNC ZRLE decompressed bound is invalid";
        return false;
    }
    const size_t rectangleCompressedLimit =
        std::min(kMaxZrleCompressedBytes, maxDecodedBytes + 64U * 1024U);
    if (compressedLength == 0 || compressedLength > rectangleCompressedLimit) {
        error = "VNC ZRLE compressed length exceeds the rectangle-safe limit";
        return false;
    }
    try {
        zrleCompressedBuffer_.resize(compressedLength);
    } catch (const std::bad_alloc&) {
        error = "VNC ZRLE compressed allocation failed";
        return false;
    }
    if (!readBytes(zrleCompressedBuffer_.data(), zrleCompressedBuffer_.size(),
                   ioTimeoutMs_, error)) {
        return false;
    }
#if VNC_DIAGNOSTICS_ENABLED
    const uint64_t zrleReadMs = nowMs();
#endif
    // The RFB request is demand-driven.  Once this single rectangle's complete
    // wire payload is buffered, ask the server for the next update before CPU
    // inflate/decode and synchronous EGL presentation.  The next capture and
    // network transfer can then overlap the current client-side frame work.
    if (pipelineNextRequest) {
        if (!sendFramebufferUpdateRequest(true, error)) {
            return false;
        }
        requestPipelined = true;
    }
    if (!zrleInflater_.inflateChunk(zrleCompressedBuffer_.data(),
                                    zrleCompressedBuffer_.size(),
                                    maxDecodedBytes, zrleDecodedBuffer_, error)) {
        return false;
    }
#if VNC_DIAGNOSTICS_ENABLED
    const uint64_t zrleInflateMs = nowMs();
#endif
    const size_t destinationOffset =
        (static_cast<size_t>(y) * static_cast<size_t>(framebufferWidth_) +
         static_cast<size_t>(x)) * 4U;
    if (!VncRfbProtocol::decodeZrleTilesToBgra(
            serverPixelFormat_, width, height,
            zrleDecodedBuffer_.data(), zrleDecodedBuffer_.size(),
            framebuffer_.data() + destinationOffset,
            framebuffer_.size() - destinationOffset,
            static_cast<size_t>(framebufferWidth_) * 4U, error)) {
        return false;
    }
#if VNC_DIAGNOSTICS_ENABLED
    const uint64_t zrleDecodeTilesMs = nowMs();
#endif
#if VNC_DIAGNOSTICS_ENABLED
    if (width * height > 100000) {
        VNC_DIAG_INFO(
                    "[VNC-DIAG] ZRLE timing rect=%{public}dx%{public}d compressed=%{public}u readMs=%{public}llu inflateMs=%{public}llu directTilesMs=%{public}llu pipelined=%{public}d totalMs=%{public}llu",
                    width, height, compressedLength,
                    static_cast<unsigned long long>(zrleReadMs - zrleStartMs),
                    static_cast<unsigned long long>(zrleInflateMs - zrleReadMs),
                    static_cast<unsigned long long>(zrleDecodeTilesMs - zrleInflateMs),
                    requestPipelined ? 1 : 0,
                    static_cast<unsigned long long>(nowMs() - zrleStartMs));
    }
#endif
    return true;
}

bool VncRfbEngine::receiveCursorRectangle(int hotX, int hotY, int width, int height,
                                          std::string& error) {
    size_t payloadBytes = 0;
    if (width == 0 && height == 0) {
        payloadBytes = 0;
    } else {
        if (width <= 0 || height <= 0 ||
            width > VncCursorProtocol::kMaxDimension ||
            height > VncCursorProtocol::kMaxDimension) {
            error = "VNC cursor dimensions exceed the safe limit";
            return false;
        }
        const size_t bytesPerPixel =
            static_cast<size_t>(serverPixelFormat_.bitsPerPixel / 8);
        size_t pixelBytes = 0;
        size_t maskBytes = 0;
        if (!checkedPixelBytes(width, height, bytesPerPixel, pixelBytes) ||
            !checkedPixelBytes((width + 7) / 8, height, 1, maskBytes) ||
            pixelBytes > std::numeric_limits<size_t>::max() - maskBytes) {
            error = "VNC cursor payload size overflows";
            return false;
        }
        payloadBytes = pixelBytes + maskBytes;
    }
    std::vector<uint8_t> payload(payloadBytes);
    if (payloadBytes > 0 &&
        !readBytes(payload.data(), payload.size(), ioTimeoutMs_, error)) {
        return false;
    }
    VncCursorProtocol::DecodedCursor cursor;
    if (!VncCursorProtocol::decodePayload(
            serverPixelFormat_, hotX, hotY, width, height,
            payloadBytes > 0 ? payload.data() : nullptr, payloadBytes,
            cursor, error)) {
        return false;
    }
    CursorCallback callback;
    {
        std::lock_guard<std::mutex> lock(callbackMutex_);
        callback = cursorCallback_;
    }
    if (callback) {
        callback(cursor);
    }
    return true;
}

bool VncRfbEngine::receiveDesktopSize(int width, int height, std::string& error) {
    if (!resizeFramebuffer(width, height, error)) return false;
    return true;
}

bool VncRfbEngine::receiveServerCutText(std::string& error) {
    uint8_t padding[3] = {0};
    uint32_t length = 0;
    if (!readBytes(padding, sizeof(padding), ioTimeoutMs_, error) ||
        !readU32(length, ioTimeoutMs_, error)) return false;
    if (length > kMaxClipboardBytes) {
        error = "VNC clipboard payload exceeds the safe limit";
        return false;
    }
    std::string text(length, '\0');
    if (length > 0 && !readBytes(reinterpret_cast<uint8_t*>(text.data()), text.size(), ioTimeoutMs_, error)) {
        return false;
    }
    if (config_.vncClipboardEnabled) {
        std::lock_guard<std::mutex> lock(clipboardMutex_);
        clipboardText_ = std::move(text);
        clipboardReady_.store(true, std::memory_order_release);
    }
    return true;
}

bool VncRfbEngine::readReason(std::string& reason, std::string& error) {
    uint32_t length = 0;
    if (!readU32(length, config_.vncAuthTimeoutMs, error)) return false;
    if (length > kMaxReasonBytes) {
        error = "VNC failure reason is too long";
        return false;
    }
    reason.assign(length, '\0');
    if (length > 0 && !readBytes(reinterpret_cast<uint8_t*>(reason.data()), reason.size(),
                                  config_.vncAuthTimeoutMs, error)) return false;
    return true;
}

bool VncRfbEngine::readU8(uint8_t& value, int timeoutMs, std::string& error) {
    return readBytes(&value, 1, timeoutMs, error);
}

bool VncRfbEngine::readU16(uint16_t& value, int timeoutMs, std::string& error) {
    uint8_t bytes[2] = {0};
    if (!readBytes(bytes, sizeof(bytes), timeoutMs, error)) return false;
    value = static_cast<uint16_t>((bytes[0] << 8) | bytes[1]);
    return true;
}

bool VncRfbEngine::readU32(uint32_t& value, int timeoutMs, std::string& error) {
    uint8_t bytes[4] = {0};
    if (!readBytes(bytes, sizeof(bytes), timeoutMs, error)) return false;
    value = (static_cast<uint32_t>(bytes[0]) << 24) |
            (static_cast<uint32_t>(bytes[1]) << 16) |
            (static_cast<uint32_t>(bytes[2]) << 8) | bytes[3];
    return true;
}

bool VncRfbEngine::readI32(int32_t& value, int timeoutMs, std::string& error) {
    uint32_t raw = 0;
    if (!readU32(raw, timeoutMs, error)) return false;
    value = static_cast<int32_t>(raw);
    return true;
}

bool VncRfbEngine::readBytes(uint8_t* data, size_t size, int timeoutMs, std::string& error) {
    return transport_.readExact(data, size, timeoutMs, error);
}

bool VncRfbEngine::writeBytes(const uint8_t* data, size_t size, std::string& error) {
    std::lock_guard<std::mutex> lock(writeMutex_);
    return transport_.writeAll(data, size, error);
}

bool VncRfbEngine::writeU16(uint16_t value, std::string& error) {
    const uint8_t bytes[2] = {static_cast<uint8_t>(value >> 8), static_cast<uint8_t>(value)};
    return writeBytes(bytes, sizeof(bytes), error);
}

bool VncRfbEngine::writeU32(uint32_t value, std::string& error) {
    const uint8_t bytes[4] = {static_cast<uint8_t>(value >> 24), static_cast<uint8_t>(value >> 16),
                              static_cast<uint8_t>(value >> 8), static_cast<uint8_t>(value)};
    return writeBytes(bytes, sizeof(bytes), error);
}

bool VncRfbEngine::writeI32(int32_t value, std::string& error) {
    return writeU32(static_cast<uint32_t>(value), error);
}

void VncRfbEngine::emitFrame(int dirtyX, int dirtyY, int dirtyWidth, int dirtyHeight) {
    VideoFrameCallback callback;
    {
        std::lock_guard<std::mutex> lock(callbackMutex_);
        callback = frameCallback_;
    }
    if (!callback || framebuffer_.empty()) {
        VNC_DIAG_WARN("[VNC-DIAG] frame emission skipped callback=%{public}d framebufferBytes=%{public}zu",
                    callback ? 1 : 0, framebuffer_.size());
        return;
    }
    VideoFrame frame;
    frame.data = framebuffer_.data();
    frame.size = framebuffer_.size();
    frame.width = framebufferWidth_;
    frame.height = framebufferHeight_;
    frame.codec = CodecType::RAW_BGRA;
    frame.timestamp = nowMs();
    frame.isKeyFrame = dirtyX < 0;
    frame.display = 0;
    frame.stride = framebufferWidth_ * 4;
    frame.dirtyX = dirtyX;
    frame.dirtyY = dirtyY;
    frame.dirtyWidth = dirtyWidth;
    frame.dirtyHeight = dirtyHeight;
    frame.colorDepth = effectiveColorDepth_;
    frame.sourceEncoding = effectiveEncoding_;
    ++diagFrames_;
    if (diagFrames_ <= 8 || diagFrames_ % 60 == 0) {
        VNC_DIAG_INFO(
                    "[VNC-DIAG] frame emitted count=%{public}llu size=%{public}zu framebuffer=%{public}dx%{public}d dirty=%{public}d,%{public}d %{public}dx%{public}d",
                    static_cast<unsigned long long>(diagFrames_), frame.size, frame.width, frame.height,
                    frame.dirtyX, frame.dirtyY, frame.dirtyWidth, frame.dirtyHeight);
    }
    callback(frame);
}

bool VncRfbEngine::validRectangle(int x, int y, int width, int height) const {
    if (x < 0 || y < 0 || width <= 0 || height <= 0) return false;
    if (x > framebufferWidth_ || y > framebufferHeight_) return false;
    return width <= framebufferWidth_ - x && height <= framebufferHeight_ - y;
}

bool VncRfbEngine::resizeFramebuffer(int width, int height, std::string& error) {
    size_t bytes = 0;
    if (width <= 0 || height <= 0 || width > kMaxFramebufferEdge || height > kMaxFramebufferEdge ||
        static_cast<size_t>(width) * static_cast<size_t>(height) > kMaxDesktopPixels ||
        !checkedPixelBytes(width, height, 4, bytes)) {
        error = "VNC DesktopSize exceeds the safe limit";
        return false;
    }
    try {
        framebuffer_.assign(bytes, 0);
    } catch (const std::bad_alloc&) {
        error = "VNC framebuffer allocation failed";
        return false;
    }
    framebufferWidth_ = width;
    framebufferHeight_ = height;
    return true;
}

uint32_t VncRfbEngine::decodePixel(const uint8_t* data) const {
    if (data == nullptr) return 0;
    const size_t bytes = serverPixelFormat_.bitsPerPixel / 8;
    uint32_t value = 0;
    if (serverPixelFormat_.bigEndian) {
        for (size_t index = 0; index < bytes; ++index) value = (value << 8) | data[index];
    } else {
        for (size_t index = 0; index < bytes; ++index) {
            value |= static_cast<uint32_t>(data[index]) << (index * 8);
        }
    }
    const uint32_t red = (value >> serverPixelFormat_.redShift) & serverPixelFormat_.redMax;
    const uint32_t green = (value >> serverPixelFormat_.greenShift) & serverPixelFormat_.greenMax;
    const uint32_t blue = (value >> serverPixelFormat_.blueShift) & serverPixelFormat_.blueMax;
    const uint32_t r = red * 255 / serverPixelFormat_.redMax;
    const uint32_t g = green * 255 / serverPixelFormat_.greenMax;
    const uint32_t b = blue * 255 / serverPixelFormat_.blueMax;
    return b | (g << 8) | (r << 16) | 0xFF000000;
}

void VncRfbEngine::sendKey(uint32_t keyCode, bool pressed) {
    if (config_.vncViewOnly || state() != ConnectionState::CONNECTED) return;
    const uint32_t keySym = keySymForHarmonyCode(keyCode);
    if (keySym == 0) return;
    const uint8_t packet[8] = {4, static_cast<uint8_t>(pressed ? 1 : 0), 0, 0,
                               static_cast<uint8_t>(keySym >> 24), static_cast<uint8_t>(keySym >> 16),
                               static_cast<uint8_t>(keySym >> 8), static_cast<uint8_t>(keySym)};
    std::string error;
    if (!writeBytes(packet, sizeof(packet), error)) {
        VNC_DIAG_WARN("[VNC-DIAG] RFB KeyEvent write failed: %{public}s", error.c_str());
    }
}

void VncRfbEngine::sendMouse(int x, int y, MouseButton button, bool pressed) {
    if (config_.vncViewOnly || state() != ConnectionState::CONNECTED) return;
    std::lock_guard<std::mutex> lock(inputMutex_);
    x = std::max(0, std::min(x, std::max(0, framebufferWidth_ - 1)));
    y = std::max(0, std::min(y, std::max(0, framebufferHeight_ - 1)));
    if (static_cast<int>(button) >= 0) {
        const int bit = static_cast<int>(button) == 0 ? 1 :
                        (static_cast<int>(button) == 1 ? 2 :
                         (static_cast<int>(button) == 2 ? 4 : 0));
        if (bit == 0) return;
        if (pressed) buttonMask_ |= bit;
        else buttonMask_ &= ~bit;
    }
    const uint8_t packet[6] = {5, static_cast<uint8_t>(buttonMask_),
                               static_cast<uint8_t>(x >> 8), static_cast<uint8_t>(x),
                               static_cast<uint8_t>(y >> 8), static_cast<uint8_t>(y)};
    std::string error;
    if (!writeBytes(packet, sizeof(packet), error)) {
        VNC_DIAG_WARN("[VNC-DIAG] RFB PointerEvent write failed: %{public}s", error.c_str());
    }
}

void VncRfbEngine::sendMouseWheel(int x, int y, int delta) {
    if (config_.vncViewOnly || state() != ConnectionState::CONNECTED || delta == 0) return;
    std::lock_guard<std::mutex> lock(inputMutex_);
    // Keep a logical wheel burst contiguous on the RFB stream and pay for one
    // socket/TLS write instead of up to 128 tiny writes.  This also prevents a
    // pipelined framebuffer request from landing between wheel down/up pairs.
    const std::vector<uint8_t> packets = VncRfbProtocol::buildPointerWheelBurst(
        buttonMask_, x, y, delta, framebufferWidth_, framebufferHeight_);
    std::string error;
    if (!packets.empty() && !writeBytes(packets.data(), packets.size(), error)) {
        VNC_DIAG_WARN("[VNC-DIAG] RFB wheel burst write failed: %{public}s", error.c_str());
    }
}

void VncRfbEngine::sendText(const std::string& text) {
    if (text.empty() || !VncRfbProtocol::canSendTextInput(
        config_.vncViewOnly, config_.vncClipboardEnabled,
        state() == ConnectionState::CONNECTED)) {
        return;
    }
    std::vector<uint8_t> packet;
    std::string error;
    if (!VncRfbProtocol::buildTextKeyEvents(text, packet, error)) {
        VNC_DIAG_WARN("[VNC-DIAG] text input rejected: %{public}s", error.c_str());
        return;
    }
    if (!packet.empty()) {
        writeBytes(packet.data(), packet.size(), error);
    }
}

void VncRfbEngine::sendClipboard(const uint8_t* data, uint32_t len) {
    if (data == nullptr || len == 0 || len > kMaxClipboardBytes ||
        config_.vncViewOnly || !config_.vncClipboardEnabled ||
        state() != ConnectionState::CONNECTED) return;
    std::vector<uint8_t> packet;
    packet.reserve(8 + len);
    packet.push_back(6); // ClientCutText
    packet.push_back(0);
    packet.push_back(0);
    packet.push_back(0);
    appendU32(packet, len);
    packet.insert(packet.end(), data, data + len);
    std::string error;
    writeBytes(packet.data(), packet.size(), error);
}

std::string VncRfbEngine::clipboardText() const {
    std::lock_guard<std::mutex> lock(clipboardMutex_);
    return clipboardText_;
}

bool VncRfbEngine::clipboardReady() const {
    return clipboardReady_.load(std::memory_order_acquire);
}

void VncRfbEngine::requestFrameRefresh() {
    if (state() != ConnectionState::CONNECTED) return;
    std::string error;
    sendFramebufferUpdateRequest(false, error);
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
bool VncRfbEngine::invokeFrameCallbackForTesting(const VideoFrame& frame) {
    if (frame.data == nullptr || frame.size == 0 || frame.width <= 0 ||
        frame.height <= 0) {
        return false;
    }
    framebuffer_.assign(frame.data, frame.data + frame.size);
    framebufferWidth_ = frame.width;
    framebufferHeight_ = frame.height;
    effectiveColorDepth_ = frame.colorDepth;
    effectiveEncoding_ = VncRfbProtocol::kRawEncoding;
    emitFrame(frame.dirtyX, frame.dirtyY, frame.dirtyWidth, frame.dirtyHeight);
    return true;
}

int VncRfbEngine::startWorkerForTesting(std::function<void()> callback) {
    if (!callback || worker_.joinable()) return -1;
    {
        std::lock_guard<std::mutex> lock(workerStateMutex_);
        workerDone_ = false;
    }
    try {
        worker_ = std::thread([this, callback = std::move(callback)]() mutable {
            struct TestWorkerDone {
                VncRfbEngine* engine;
                ~TestWorkerDone() {
                    {
                        std::lock_guard<std::mutex> lock(engine->workerStateMutex_);
                        engine->workerDone_ = true;
                    }
                    engine->workerStateCv_.notify_all();
                }
            } done {this};
            struct TestCallbackRelease {
                VncRfbEngine* engine;
                ~TestCallbackRelease() { engine->releaseCallbacks(); }
            } release {this};
            callback();
        });
    } catch (const std::exception&) {
        {
            std::lock_guard<std::mutex> lock(workerStateMutex_);
            workerDone_ = true;
        }
        workerStateCv_.notify_all();
        return -12;
    }
    return 0;
}

void VncRfbEngine::setStopObserverForTesting(std::function<void()> observer) {
    std::lock_guard<std::mutex> lock(callbackMutex_);
    stopObserver_ = std::move(observer);
}
#endif

uint32_t VncRfbEngine::keySymForHarmonyCode(uint32_t keyCode) {
    // HarmonyOS KeyCode values used by RemoteDesktop.ets. The mapper lives in
    // native VNC code so RDP scancodes and RustDesk private codes never leak
    // into the VNC protocol.
    if (keyCode >= 2000 && keyCode <= 2009) return '0' + (keyCode - 2000);
    if (keyCode >= 2017 && keyCode <= 2042) return 'a' + (keyCode - 2017);
    if (keyCode >= 2090 && keyCode <= 2101) return 0xFFBE + (keyCode - 2090);
    if (keyCode >= 2816 && keyCode <= 2827) return 0xFFCA + (keyCode - 2816);
    if (keyCode >= 2103 && keyCode <= 2112) return 0xFFB0 + (keyCode - 2103);
    switch (keyCode) {
        case 2045: return 0xFFE9; // Alt left
        case 2046: return 0xFFEA; // Alt right
        case 2047: return 0xFFE1; // Shift left
        case 2048: return 0xFFE2; // Shift right
        case 2049: return 0xFF09;
        case 2050: return 0x20;
        case 2054: return 0xFF0D;
        case 2055: return 0xFF08;
        case 2067: return 0xFF67;
        case 2068: return 0xFF55;
        case 2069: return 0xFF56;
        case 2070: return 0xFF1B;
        case 2071: return 0xFFFF;
        case 2072: return 0xFFE3;
        case 2073: return 0xFFE4;
        case 2074: return 0xFFE5;
        case 2075: return 0xFF14;
        case 2076: return 0xFFEB;
        case 2077: return 0xFFEC;
        case 2081: return 0xFF50;
        case 2082: return 0xFF57;
        case 2083: return 0xFF63;
        case 2102: return 0xFF7F;
        case 2079: return 0xFF61; // Print Screen / SysRq
        case 2080: return 0xFF13; // Pause / Break
        case 2113: return 0xFFAF; // Keypad divide
        case 2114: return 0xFFAA; // Keypad multiply
        case 2115: return 0xFFAD; // Keypad subtract
        case 2116: return 0xFFAB; // Keypad add
        case 2117: return 0xFFAE; // Keypad decimal
        case 2118: return 0xFFAC; // Keypad separator/comma
        case 2119: return 0xFF8D; // Keypad enter
        case 2120: return 0xFFBD; // Keypad equals
        case 2121: return 0xFF9D; // Keypad left parenthesis
        case 2122: return 0xFF9E; // Keypad right parenthesis
        case 2078: return 0;      // Fn is a local layer selector, not an RFB key
        case 2012: return 0xFF52;
        case 2013: return 0xFF54;
        case 2014: return 0xFF51;
        case 2015: return 0xFF53;
        case 2043: return ',';
        case 2044: return '.';
        case 2056: return '`';
        case 2057: return '-';
        case 2058: return '=';
        case 2059: return '[';
        case 2060: return ']';
        case 2061: return '\\';
        case 2062: return ';';
        case 2063: return '\'';
        case 2064: return '/';
        case 2065: return '@';
        case 2066: return '+';
        case 0x10039: return 0xFFE5;
        default: return keyCode <= 0x10FFFF ? keyCode : 0;
    }
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
void VncRfbEngine::emitStateForTesting(
    ConnectionState state, const std::string& message) {
    setState(state, message);
}

uint32_t VncRfbEngine::keySymForHarmonyCodeForTesting(uint32_t keyCode) {
    return keySymForHarmonyCode(keyCode);
}
#endif

uint8_t VncRfbEngine::reverseBits(uint8_t value) {
    value = static_cast<uint8_t>(((value & 0xF0) >> 4) | ((value & 0x0F) << 4));
    value = static_cast<uint8_t>(((value & 0xCC) >> 2) | ((value & 0x33) << 2));
    return static_cast<uint8_t>(((value & 0xAA) >> 1) | ((value & 0x55) << 1));
}

bool VncRfbEngine::isTimeout(const std::string& error) {
    return error.find("timed out") != std::string::npos ||
        error.find("E-VNC-CERT-TLS-TIMEOUT") != std::string::npos;
}

void VncRfbEngine::setState(ConnectionState state, const std::string& message) {
    state_.store(state, std::memory_order_release);
    StateCallback callback;
    {
        std::lock_guard<std::mutex> lock(callbackMutex_);
        callback = stateCallback_;
    }
    if (callback) callback(state, message);
}

void VncRfbEngine::clearSensitiveConfig() {
    secureClear(config_.password);
    secureClear(config_.privateKeyPem);
    secureClear(config_.privateKeyPassphrase);
    secureClear(config_.vncExpectedCertificateFingerprintSha256);
}
