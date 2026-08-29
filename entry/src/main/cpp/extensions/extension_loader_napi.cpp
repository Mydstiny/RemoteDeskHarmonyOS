/**
 * extension_loader_napi.cpp — 扩展加载器 NAPI 桥接
 *
 * 将 ExtensionSystem 暴露给 ArkTS 层。
 * ArkTS 通过此模块查询已注册的协议适配器、建立连接、发送输入。
 */

#include "extension_registry.h"
#include "protocol_adapter.h"
#include "session_teardown_executor.h"
#include "session_registry.h"
#include "key_sequence_dispatch.h"
#include "disconnect_request_registry.h"
#include "rdp/freerdp_adapter.h"
#include "rdp/rdp_auth_mode_policy.h"
#include "rdp/rdp_connection_identity_policy.h"
#include "ssh/ssh_adapter.h"
#include "ssh/ssh_terminal_resume_policy.h"
#include "ssh/ssh_key_tool.h"
#include "ssh/ssh_session_manager.h"
#include "ssh/ssh_pending_connect_registry.h"
#include "audio/input_handler.h"
#include "audio/audio_player.h"
#include "common/safe_log.h"
#include "common/endpoint_address_policy.h"
#include "render/hw_decoder.h"
#include "render/gl_renderer.h"
#include "render/video_perf_counters.h"
#include "render/shared_session_context.h"
#include "video/video_activity_state.h"
#include "rustdesk/rustdesk_bridge.h"
#include "rustdesk/rustdesk_multi_canvas_policy.h"
#include "vnc/vnc_adapter.h"
#include "vnc/vnc_certificate_probe.h"
#include "vnc/vnc_rfb_engine.h"
#include "vnc/vnc_rfb_protocol.h"
#include "vnc/vnc_transport.h"
#include <napi/native_api.h>
#include <hilog/log.h>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <algorithm>
#include <array>
#include <cctype>
#include <atomic>
#include <chrono>
#include <cstring>
#include <condition_variable>
#include <cmath>
#include <deque>
#include <exception>
#include <fstream>
#include <new>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <thread>
#include <vector>
#include <unistd.h>

#if defined(__MUSL__)
#include <network/netmanager/net_connection.h>
#endif

#ifdef RUSTDESK_USE_REAL_CORE
extern "C" {
    size_t rustdesk_last_error(char* buffer, size_t buffer_len);
    bool rustdesk_probe_presence(const RustDeskFfiConfig* cfg, RustDeskPresenceResult* result);
}
#endif

// 前向声明各协议的注册函数 (在各自 .cpp 中定义)
void registerFreeRdpAdapter();
void registerRustDeskBridge();
void registerSshAdapter();
void registerVncAdapter();

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0005
#define LOG_TAG "EXT_LOADER"

namespace ExtensionLoaderNapi {
    napi_value Init(napi_env env, napi_value exports);
}

static void PrepareAdapterForTeardown(
    const std::shared_ptr<ProtocolAdapter>& adapter,
    const DecoderSessionIdentity& owner);

// VncAdapter::disconnect() is deliberately bounded so a callback-originated
// stop cannot block the caller. A normal teardown executor must nevertheless
// keep the session non-reusable until any deferred worker has crossed its done
// fence; otherwise ArkTS can start a new connection while the old socket is
// still owned by the reaper.
static bool DisconnectAdapterAndDrainVnc(
    const std::shared_ptr<ProtocolAdapter>& adapter);

namespace {

constexpr int kRustDeskMaxDisplays = 16;

bool IsValidRustDeskDisplay(int display) {
    return display >= 0 && display < kRustDeskMaxDisplays;
}

void secureClearString(std::string& value) {
    if (!value.empty()) {
        volatile char* data = value.data();
        for (size_t index = 0; index < value.size(); ++index) {
            data[index] = '\0';
        }
    }
    value.clear();
}

struct SshSecretGuard {
    ConnectionConfig& config;

    ~SshSecretGuard() {
        secureClearString(config.password);
        secureClearString(config.privateKeyPem);
        secureClearString(config.privateKeyPassphrase);
        secureClearString(config.sshProxyPassword);
        secureClearString(config.sshProxyPrivateKeyPem);
        secureClearString(config.sshProxyPrivateKeyPassphrase);
        for (std::string& response : config.sshKeyboardInteractiveResponses) {
            secureClearString(response);
        }
        config.sshKeyboardInteractiveResponses.clear();
        for (std::string& response : config.sshProxyKeyboardInteractiveResponses) {
            secureClearString(response);
        }
        config.sshProxyKeyboardInteractiveResponses.clear();
        for (SshJumpHopHandoff& handoff : config.sshJumpHopHandoffs) {
            secureClearString(handoff.password);
            secureClearString(handoff.privateKeyPem);
            secureClearString(handoff.privateKeyPassphrase);
            for (std::string& response : handoff.keyboardInteractiveResponses) {
                secureClearString(response);
            }
            handoff.keyboardInteractiveResponses.clear();
        }
        config.sshJumpHopHandoffs.clear();
    }
};

} // namespace

// ============================================================
// 全局状态
// ============================================================

// 当前活跃连接
static std::shared_ptr<ProtocolAdapter> g_activeConnection = nullptr;
static std::mutex g_activeConnectionMutex;

static bool ActivateSessionContext(
    const std::shared_ptr<ProtocolAdapter>& adapter,
    const DecoderSessionIdentity& owner) {
    if (!Render::ActivateSharedSessionSinks(owner)) {
        return false;
    }
    std::lock_guard<std::mutex> lock(g_activeConnectionMutex);
    g_activeConnection = adapter;
    InputHandler::instance().setActiveAdapter(adapter);
    return true;
}

static bool DeactivateSessionContextIfActive(
    const std::shared_ptr<ProtocolAdapter>& adapter,
    const DecoderSessionIdentity& owner) {
    if (!Render::DeactivateSharedSessionSinks(owner)) {
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(g_activeConnectionMutex);
        InputHandler::instance().setActiveAdapter(nullptr);
        if (g_activeConnection == adapter) {
            g_activeConnection = nullptr;
        }
    }
    return true;
}

static void DeactivateAllSessionContexts() {
    Render::DeactivateAllSharedSessionSinks();
    {
        std::lock_guard<std::mutex> lock(g_activeConnectionMutex);
        g_activeConnection = nullptr;
        InputHandler::instance().setActiveAdapter(nullptr);
    }
}

static std::shared_ptr<ProtocolAdapter> GetActiveSessionAdapter() {
    std::lock_guard<std::mutex> lock(g_activeConnectionMutex);
    return g_activeConnection;
}

struct SessionDiagnosticsCounters {
    std::atomic<uint64_t> ingressFrames {0};
    std::atomic<uint64_t> videoCallbacks {0};
    std::atomic<uint64_t> ingressBytes {0};
    std::atomic<uint64_t> keyframes {0};
    std::atomic<uint64_t> presentedFrames {0};
    std::atomic<uint64_t> presentationRejected {0};
    std::atomic<uint64_t> decodeOk {0};
    std::atomic<uint64_t> decodeErrors {0};
    std::atomic<uint64_t> decodeRetNotReady {0};
    std::atomic<uint64_t> decodeRetBadCodec {0};
    std::atomic<uint64_t> decodeRetMismatch {0};
    std::atomic<uint64_t> decodeRetOther {0};
    std::atomic<uint64_t> inactiveDisplayFrames {0};
    std::atomic<uint64_t> audioFrames {0};
    std::atomic<int> lastCodec {-1};
    std::atomic<int> lastWidth {0};
    std::atomic<int> lastHeight {0};
    std::atomic<uint64_t> lastFrameAtMs {0};
    std::atomic<uint64_t> lastPresentedAtMs {0};
    std::atomic<int> lastDirtyX {-1};
    std::atomic<int> lastDirtyY {-1};
    std::atomic<int> lastDirtyWidth {0};
    std::atomic<int> lastDirtyHeight {0};
    std::atomic<int> effectiveColorDepth {0};
    std::atomic<int> sourceEncoding {-1};
    std::atomic<uint64_t> inputEventsSent {0};
    std::atomic<uint64_t> inputEventsDropped {0};
    mutable std::mutex timingMutex;
    std::deque<int64_t> decodeSamplesUs;
    mutable std::mutex rateMutex;
    uint64_t lastRateAtMs = 0;
    uint64_t lastRateFrames = 0;
    uint64_t lastRateBytes = 0;
    uint64_t lastRateDecodeOk = 0;
    double receivedFps = 0.0;
    double decodedFps = 0.0;
    double bitrateKbps = 0.0;
    bool rateSampleAvailable = false;

    void reset() {
        ingressFrames.store(0, std::memory_order_release);
        videoCallbacks.store(0, std::memory_order_release);
        ingressBytes.store(0, std::memory_order_release);
        keyframes.store(0, std::memory_order_release);
        presentedFrames.store(0, std::memory_order_release);
        presentationRejected.store(0, std::memory_order_release);
        decodeOk.store(0, std::memory_order_release);
        decodeErrors.store(0, std::memory_order_release);
        decodeRetNotReady.store(0, std::memory_order_release);
        decodeRetBadCodec.store(0, std::memory_order_release);
        decodeRetMismatch.store(0, std::memory_order_release);
        decodeRetOther.store(0, std::memory_order_release);
        inactiveDisplayFrames.store(0, std::memory_order_release);
        audioFrames.store(0, std::memory_order_release);
        lastCodec.store(-1, std::memory_order_release);
        lastWidth.store(0, std::memory_order_release);
        lastHeight.store(0, std::memory_order_release);
        lastFrameAtMs.store(0, std::memory_order_release);
        lastPresentedAtMs.store(0, std::memory_order_release);
        lastDirtyX.store(-1, std::memory_order_release);
        lastDirtyY.store(-1, std::memory_order_release);
        lastDirtyWidth.store(0, std::memory_order_release);
        lastDirtyHeight.store(0, std::memory_order_release);
        effectiveColorDepth.store(0, std::memory_order_release);
        sourceEncoding.store(-1, std::memory_order_release);
        inputEventsSent.store(0, std::memory_order_release);
        inputEventsDropped.store(0, std::memory_order_release);
        std::lock_guard<std::mutex> lock(timingMutex);
        decodeSamplesUs.clear();
        std::lock_guard<std::mutex> rateLock(rateMutex);
        lastRateAtMs = 0;
        lastRateFrames = 0;
        lastRateBytes = 0;
        lastRateDecodeOk = 0;
        receivedFps = 0.0;
        decodedFps = 0.0;
        bitrateKbps = 0.0;
        rateSampleAvailable = false;
    }

    void addDecodeSample(int64_t elapsedUs) {
        std::lock_guard<std::mutex> lock(timingMutex);
        if (decodeSamplesUs.size() >= 128) {
            decodeSamplesUs.pop_front();
        }
        decodeSamplesUs.push_back(elapsedUs);
    }

    void timingSnapshot(int64_t& p50, int64_t& p95, int64_t& max) const {
        std::vector<int64_t> values;
        {
            std::lock_guard<std::mutex> lock(timingMutex);
            values.assign(decodeSamplesUs.begin(), decodeSamplesUs.end());
        }
        if (values.empty()) {
            p50 = 0;
            p95 = 0;
            max = 0;
            return;
        }
        std::sort(values.begin(), values.end());
        const size_t p50Index = (values.size() - 1) * 50 / 100;
        const size_t p95Index = (values.size() - 1) * 95 / 100;
        p50 = values[p50Index];
        p95 = values[p95Index];
        max = values.back();
    }

    void updateRates(uint64_t nowMs) {
        const uint64_t frames = ingressFrames.load(std::memory_order_acquire);
        const uint64_t bytes = ingressBytes.load(std::memory_order_acquire);
        const uint64_t decoded = decodeOk.load(std::memory_order_acquire);
        std::lock_guard<std::mutex> lock(rateMutex);
        if (lastRateAtMs > 0 && nowMs > lastRateAtMs) {
            const double seconds = static_cast<double>(nowMs - lastRateAtMs) / 1000.0;
            receivedFps = static_cast<double>(frames - lastRateFrames) / seconds;
            decodedFps = static_cast<double>(decoded - lastRateDecodeOk) / seconds;
            bitrateKbps = static_cast<double>(bytes - lastRateBytes) * 8.0 / seconds / 1000.0;
            rateSampleAvailable = true;
        }
        lastRateAtMs = nowMs;
        lastRateFrames = frames;
        lastRateBytes = bytes;
        lastRateDecodeOk = decoded;
    }

    void rateSnapshot(double& ingressFps, double& decodedFramesPerSecond, double& kbps,
                      bool& sampleAvailable) const {
        std::lock_guard<std::mutex> lock(rateMutex);
        ingressFps = receivedFps;
        decodedFramesPerSecond = decodedFps;
        kbps = bitrateKbps;
        sampleAvailable = rateSampleAvailable;
    }
};

constexpr size_t kMaxPendingRustDeskFrameBytes = 32 * 1024 * 1024;

struct PendingRustDeskFrame {
    VideoFrame frame;
    std::vector<uint8_t> bytes;
};

enum class RustDeskMultiCanvasPipelineStatus : int {
    Starting = 1,
    Presenting = 2,
    ReconfigureRequired = 3,
    Failed = 4,
    Paused = 5,
};

struct RustDeskMultiCanvasPipeline {
    // A frame callback can retain this pipeline after it has been removed
    // from the session map. Serialize handle use with teardown so no decode
    // or telemetry query can race exact-owner decoder/renderer destruction.
    mutable std::mutex lifecycleMutex;
    int display = -1;
    int sourceWidth = 0;
    int sourceHeight = 0;
    int codec = -1;
    int surfaceWidth = 0;
    int surfaceHeight = 0;
    std::string surfaceId;
    int64_t rendererHandle = 0;
    int64_t decoderHandle = 0;
    uint64_t rendererGeneration = 0;
    uint64_t decoderGeneration = 0;
    std::atomic<int> status {
        static_cast<int>(RustDeskMultiCanvasPipelineStatus::Starting)};
    std::atomic<int> observedWidth {0};
    std::atomic<int> observedHeight {0};
    std::atomic<int> observedCodec {-1};
    std::atomic<int> lastDecodeResult {0};
    std::atomic<uint64_t> receivedFrames {0};
    std::atomic<uint64_t> acceptedFrames {0};
    std::atomic<uint64_t> droppedFrames {0};
    std::atomic<uint64_t> lastRefreshRequestAtMs {0};
};

// 连接会话上下文
struct SessionContext {
    enum class Lifecycle : uint8_t {
        Active = 0,
        Disconnecting,
        Complete,
        Failed,
    };

    std::shared_ptr<ProtocolAdapter> adapter;
    std::string protocolName;
    mutable std::mutex adapterMutex;
    // One logical key transaction owns this lane from its first down through
    // its final up. Teardown claims the same lane before changing lifecycle,
    // so a chord is either fully queued on the active adapter or rejected.
    mutable std::mutex keyDispatchMutex;
    // Serializes SSH data-callback publication with the teardown lifecycle
    // claim. A callback registration must either publish before teardown owns
    // the session (and be reclaimed by it) or be rejected after the claim.
    mutable std::mutex callbackRegistrationMutex;
    // The numeric session id is retained for the public N-API surface; the
    // generation and owner token are the identities used by callback and
    // decoder telemetry gates. All video counters/controllers die with this
    // object.
    uint64_t sessionId = 0;
    std::atomic<uint64_t> generation {0};
    uint64_t ownerToken = 0;
    // Immutable after registry publication. Independent SSH windows use
    // explicit session-id APIs and therefore do not acquire the process-wide
    // decoder/input sink owner when their page callback is rebound.
    bool sharedSinkForeground = true;
    std::string lastStateMessage;
    std::mutex messageMutex;
    std::atomic<Lifecycle> lifecycle {Lifecycle::Active};
    std::atomic<uint64_t> teardownRequestId {0};
    mutable std::mutex teardownPublicationMutex;
    std::condition_variable teardownPublicationCv;
    bool teardownRequestPublished = false;
    SessionDiagnosticsCounters diagnostics;
    Render::VideoPerfCounters videoPerf;
    Render::VideoPressureController videoPressure;
    mutable std::mutex pressureSnapshotMutex;
    Render::VideoPerfSnapshot lastPressureSnapshot;
    Render::VideoPressureDecision lastPressureDecision;
    uint64_t lastDecoderGeneration = 0;
    uint64_t lastDisplayGeneration = 0;
    uint64_t lastDropCounterGeneration = 0;
    mutable std::mutex pendingRustDeskFrameMutex;
    std::unique_ptr<PendingRustDeskFrame> pendingRustDeskFrame;
    mutable std::mutex rustDeskMultiCanvasMutex;
    std::map<int, std::shared_ptr<RustDeskMultiCanvasPipeline>>
        rustDeskMultiCanvasPipelines;
    std::string vncConnectionPath = "unknown";
    std::string vncRequestedColorDepth = "auto";

    DecoderSessionIdentity identity() const {
        return DecoderSessionIdentity {
            sessionId, generation.load(std::memory_order_acquire), ownerToken};
    }
};

static std::shared_ptr<RustDeskBridge> GetRustDeskAdapter(
    const std::shared_ptr<SessionContext>& session) {
    if (!session || session->protocolName != "rustdesk") {
        return nullptr;
    }
    std::lock_guard<std::mutex> lock(session->adapterMutex);
    return std::dynamic_pointer_cast<RustDeskBridge>(session->adapter);
}

static void DestroyRustDeskMultiCanvasPipeline(
    const DecoderSessionIdentity& owner,
    const std::shared_ptr<RustDeskMultiCanvasPipeline>& pipeline) {
    if (!pipeline) {
        return;
    }
    std::lock_guard<std::mutex> lifecycleLock(pipeline->lifecycleMutex);
    pipeline->status.store(
        static_cast<int>(RustDeskMultiCanvasPipelineStatus::Paused),
        std::memory_order_release);
    if (pipeline->decoderHandle > 0) {
        DecoderNapi::DestroyDecoderHandle(pipeline->decoderHandle, owner);
        pipeline->decoderHandle = 0;
    }
    if (pipeline->rendererHandle > 0) {
        RendererNapi::DestroyRendererHandle(pipeline->rendererHandle, owner);
        pipeline->rendererHandle = 0;
    }
}

static void DestroyRustDeskMultiCanvasPipelines(
    const std::shared_ptr<SessionContext>& session) {
    if (!session) {
        return;
    }
    std::vector<std::shared_ptr<RustDeskMultiCanvasPipeline>> pipelines;
    {
        std::lock_guard<std::mutex> lock(session->rustDeskMultiCanvasMutex);
        for (auto& entry : session->rustDeskMultiCanvasPipelines) {
            pipelines.push_back(std::move(entry.second));
        }
        session->rustDeskMultiCanvasPipelines.clear();
    }
    const DecoderSessionIdentity owner = session->identity();
    for (const auto& pipeline : pipelines) {
        DestroyRustDeskMultiCanvasPipeline(owner, pipeline);
    }
}

static bool RefreshRustDeskMultiCanvasCaptureSet(
    const std::shared_ptr<SessionContext>& session) {
    const std::shared_ptr<RustDeskBridge> bridge = GetRustDeskAdapter(session);
    if (!bridge) {
        return false;
    }
    const RustDeskDisplayCapabilities capabilities = bridge->getDisplayCapabilities();
    if (!capabilities.supported || capabilities.currentDisplay < 0) {
        return false;
    }
    std::vector<int> requested;
    {
        std::lock_guard<std::mutex> lock(session->rustDeskMultiCanvasMutex);
        for (const auto& entry : session->rustDeskMultiCanvasPipelines) {
            requested.push_back(entry.first);
        }
    }
    std::vector<RustDeskMultiCanvasDisplayBudgetInput> catalog;
    catalog.reserve(capabilities.displays.size());
    for (const RustDeskDisplayInfo& display : capabilities.displays) {
        catalog.push_back({
            display.display,
            display.width > 0 ? display.width : display.originalWidth,
            display.height > 0 ? display.height : display.originalHeight,
            display.online,
        });
    }
    const RustDeskMultiCanvasBudgetDecision decision =
        RustDeskSelectMultiCanvasDisplays(
            capabilities.currentDisplay, requested, catalog);
    return decision.accepted && bridge->captureDisplays(decision.displays);
}

static void SubmitRustDeskMultiCanvasFrame(
    const std::shared_ptr<SessionContext>& session, const VideoFrame& frame) {
    if (!session || session->protocolName != "rustdesk" || frame.display < 0) {
        return;
    }
    std::shared_ptr<RustDeskMultiCanvasPipeline> pipeline;
    {
        std::lock_guard<std::mutex> lock(session->rustDeskMultiCanvasMutex);
        const auto found = session->rustDeskMultiCanvasPipelines.find(frame.display);
        if (found != session->rustDeskMultiCanvasPipelines.end()) {
            pipeline = found->second;
        }
    }
    if (!pipeline) {
        return;
    }
    std::unique_lock<std::mutex> lifecycleLock(pipeline->lifecycleMutex);
    if (pipeline->decoderHandle <= 0) {
        return;
    }
    pipeline->receivedFrames.fetch_add(1, std::memory_order_relaxed);
    pipeline->observedWidth.store(frame.width, std::memory_order_release);
    pipeline->observedHeight.store(frame.height, std::memory_order_release);
    pipeline->observedCodec.store(static_cast<int>(frame.codec),
                                  std::memory_order_release);
    const int result = DecoderNapi::DecodeOwnedAuxNative(
        pipeline->decoderHandle, session->identity(), frame.display, frame);
    pipeline->lastDecodeResult.store(result, std::memory_order_release);
    if (result == 0) {
        pipeline->acceptedFrames.fetch_add(1, std::memory_order_relaxed);
        pipeline->status.store(
            static_cast<int>(RustDeskMultiCanvasPipelineStatus::Presenting),
            std::memory_order_release);
    } else {
        pipeline->droppedFrames.fetch_add(1, std::memory_order_relaxed);
        if (result == DecoderNapi::kDecodeAuxReconfigureRequired) {
            pipeline->status.store(
                static_cast<int>(RustDeskMultiCanvasPipelineStatus::ReconfigureRequired),
                std::memory_order_release);
        } else if (result != DecoderNapi::kDecodeAuxBackpressure &&
                   result != DecoderNapi::kDecodeHardwareKeyframeRequired) {
            pipeline->status.store(
                static_cast<int>(RustDeskMultiCanvasPipelineStatus::Failed),
                std::memory_order_release);
        }
    }
    const bool referenceChainDrop =
        result == DecoderNapi::kDecodeAuxBackpressure ||
        result == DecoderNapi::kDecodeHardwareKeyframeRequired;
    bool requestDisplayRefresh = false;
    if (referenceChainDrop) {
        constexpr uint64_t kAuxRefreshCoalesceMs = 1000;
        const uint64_t nowMs = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count());
        uint64_t previous = pipeline->lastRefreshRequestAtMs.load(
            std::memory_order_acquire);
        while ((previous == 0 || nowMs - previous >= kAuxRefreshCoalesceMs) &&
               !pipeline->lastRefreshRequestAtMs.compare_exchange_weak(
                   previous, nowMs, std::memory_order_acq_rel,
                   std::memory_order_acquire)) {
        }
        requestDisplayRefresh = previous == 0 ||
            nowMs - previous >= kAuxRefreshCoalesceMs;
    }
    lifecycleLock.unlock();
    if (requestDisplayRefresh) {
        const std::shared_ptr<RustDeskBridge> bridge = GetRustDeskAdapter(session);
        if (bridge) {
            (void)bridge->refreshVideoDisplay(frame.display);
        }
    }
}

static bool IsSessionCallbackActive(const std::shared_ptr<SessionContext>& session) {
    return session &&
        session->lifecycle.load(std::memory_order_acquire) ==
            SessionContext::Lifecycle::Active &&
        Render::SharedSessionSinkOwnerLease().accepts(session->identity()) &&
        DecoderNapi::IsActiveSessionOwner(session->identity());
}

static void RememberPendingRustDeskKeyFrame(
    const std::shared_ptr<SessionContext>& session, const VideoFrame& frame) {
    if (!session || session->protocolName != "rustdesk" || !frame.isKeyFrame ||
        frame.data == nullptr || frame.size == 0 || frame.size > kMaxPendingRustDeskFrameBytes) {
        return;
    }
    auto pending = std::make_unique<PendingRustDeskFrame>();
    pending->bytes.assign(frame.data, frame.data + frame.size);
    pending->frame = frame;
    pending->frame.data = pending->bytes.data();
    {
        std::lock_guard<std::mutex> lock(session->pendingRustDeskFrameMutex);
        // Keep the newest keyframe. A delta frame cannot make a cold decoder
        // usable, while replacing a newer keyframe with an older one can make
        // replay fail after a slow renderer bind.
        if (session->pendingRustDeskFrame != nullptr &&
            session->pendingRustDeskFrame->frame.timestamp > pending->frame.timestamp) {
            return;
        }
        session->pendingRustDeskFrame = std::move(pending);
    }
    OH_LOG_INFO(LOG_APP,
                "[ExtLoader] retained RustDesk keyframe until video pipeline bind size=%{public}zu",
                frame.size);
}

static void RequeuePendingRustDeskFrame(
    const std::shared_ptr<SessionContext>& session,
    std::unique_ptr<PendingRustDeskFrame> pending) {
    if (!session || !pending) {
        return;
    }
    std::lock_guard<std::mutex> lock(session->pendingRustDeskFrameMutex);
    if (!session->pendingRustDeskFrame) {
        session->pendingRustDeskFrame = std::move(pending);
    }
}

static bool ReplayPendingRustDeskFrame(const std::shared_ptr<SessionContext>& session) {
    if (!session || session->protocolName != "rustdesk") {
        return false;
    }
    std::unique_ptr<PendingRustDeskFrame> pending;
    {
        std::lock_guard<std::mutex> lock(session->pendingRustDeskFrameMutex);
        if (!session->pendingRustDeskFrame) {
            return true;
        }
        pending = std::move(session->pendingRustDeskFrame);
    }
    if (!IsSessionCallbackActive(session)) {
        RequeuePendingRustDeskFrame(session, std::move(pending));
        return false;
    }
    pending->frame.data = pending->bytes.data();
    const int ret = DecoderNapi::DecodeActiveNative(session->identity(), pending->frame);
    if (ret == 0) {
        session->diagnostics.decodeOk.fetch_add(1, std::memory_order_relaxed);
        OH_LOG_INFO(LOG_APP,
                    "[ExtLoader] replayed retained RustDesk keyframe session=%{public}llu",
                    static_cast<unsigned long long>(session->sessionId));
        return true;
    }
    if (ret < 0 || ret == DecoderNapi::kDecodeInactiveSession) {
        session->diagnostics.decodeErrors.fetch_add(1, std::memory_order_relaxed);
        RequeuePendingRustDeskFrame(session, std::move(pending));
    }
    OH_LOG_WARN(LOG_APP,
                "[ExtLoader] retained RustDesk keyframe replay deferred ret=%{public}d session=%{public}llu",
                ret, static_cast<unsigned long long>(session->sessionId));
    return false;
}

static bool ReportVideoPressureForSession(
    const std::shared_ptr<SessionContext>& session, int level) {
    if (!session || session->lifecycle.load(std::memory_order_acquire) !=
            SessionContext::Lifecycle::Active) {
        return false;
    }
    std::shared_ptr<ProtocolAdapter> adapter;
    {
        std::lock_guard<std::mutex> lock(session->adapterMutex);
        adapter = session->adapter;
    }
    if (!adapter) {
        return false;
    }
    if (auto* rustdesk = dynamic_cast<RustDeskBridge*>(adapter.get())) {
        return rustdesk->reportVideoPressureForSession(
            session->sessionId, session->generation.load(std::memory_order_acquire),
            session->ownerToken, level);
    }
    auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(session->identity());
    if (!ownerLease) {
        return false;
    }
    if (!IsSessionCallbackActive(session)) {
        return false;
    }
    adapter->reportVideoPressure(level);
    return true;
}

static bool RequestFrameRefreshForSession(
    const std::shared_ptr<SessionContext>& session, const char* reason) {
    if (!IsSessionCallbackActive(session)) {
        return false;
    }
    std::shared_ptr<ProtocolAdapter> adapter;
    {
        std::lock_guard<std::mutex> lock(session->adapterMutex);
        adapter = session->adapter;
    }
    if (!adapter || !IsSessionCallbackActive(session)) {
        return false;
    }
    adapter->requestFrameRefresh();
    OH_LOG_WARN(LOG_APP,
        "[ExtLoader] requested frame refresh session=%{public}llu generation=%{public}llu reason=%{public}s",
        static_cast<unsigned long long>(session->sessionId),
        static_cast<unsigned long long>(session->generation.load(
            std::memory_order_acquire)),
        reason ? reason : "unspecified");
    return true;
}

static SessionRegistry<SessionContext> g_sessionRegistry;
static DisconnectRequestRegistry g_disconnectRequests;
static SessionTeardown::Executor g_teardownExecutor;
static uint64_t g_disconnectAllRequestId = 0;
static std::atomic<int> g_nextSessionId {1};
static std::atomic<uint64_t> g_nextSessionGeneration {1};
static std::atomic<uint64_t> g_nextSessionOwnerToken {1};
// SSH connects are independently owned async sessions.  Keep the registry
// for compatibility with the old single-id query, but never use it as an
// admission gate or as the identity of the current page.
static SshPendingConnectRegistry g_pendingSshConnects;
static SshSessionManager g_sshSessionManager;
static SshNativeFacade g_sshNativeFacade(g_sshSessionManager);

static void AddPendingSshConnect(int sessionId, uint64_t generation) {
    (void)g_pendingSshConnects.add(SshPendingConnectIdentity {sessionId, generation});
}

static void RemovePendingSshConnect(int sessionId, uint64_t generation) {
    (void)g_pendingSshConnects.remove(SshPendingConnectIdentity {sessionId, generation});
}

static int GetPendingSshConnectIdSnapshot() {
    return g_pendingSshConnects.firstSessionId();
}

static std::vector<int> GetPendingSshConnectIdsSnapshot() {
    const std::vector<SshPendingConnectIdentity> identities = g_pendingSshConnects.snapshot();
    std::vector<int> result;
    result.reserve(identities.size());
    for (const SshPendingConnectIdentity& identity : identities) {
        result.push_back(identity.sessionId);
    }
    return result;
}
static std::atomic<uint64_t> g_nextVncCertificateProbeRequestId {1};
static std::mutex g_vncCertificateProbeMutex;
struct VncCertificateProbeEnvironmentState {
    std::mutex mutex;
    bool closing = false;
    size_t activeWorks = 0;
    napi_async_cleanup_hook_handle cleanupHandle = nullptr;
    bool cleanupHookRegistered = false;
    bool cleanupHookRemoved = false;
};
struct VncCertificateProbeRegistration {
    std::shared_ptr<std::atomic_bool> cancelled;
    std::shared_ptr<VncCertificateProbeEnvironmentState> environmentState;
    napi_env env = nullptr;
    napi_async_work work = nullptr;
};
static std::map<uint64_t, VncCertificateProbeRegistration> g_vncCertificateProbeTokens;
static std::map<napi_env, std::shared_ptr<VncCertificateProbeEnvironmentState>>
    g_vncCertificateProbeEnvironments;
static std::atomic<uint64_t> g_napiWheelSendCount {0};
static std::atomic<uint64_t> g_napiFileSendCount {0};
static std::atomic<uint64_t> g_napiKeySendCount {0};
static std::atomic<uint64_t> g_napiMouseSendCount {0};

static bool DispatchRustDeskNetworkSession(
    const std::shared_ptr<SessionContext>& session, int32_t sessionId,
    uint64_t sessionGeneration, bool available, uint64_t networkGeneration) {
    if (!session || sessionId <= 0 || sessionGeneration == 0 ||
        networkGeneration == 0) {
        return false;
    }
    if (session->protocolName != "rustdesk" ||
        session->lifecycle.load(std::memory_order_acquire) !=
            SessionContext::Lifecycle::Active ||
        session->generation.load(std::memory_order_acquire) != sessionGeneration) {
        return false;
    }
    std::shared_ptr<ProtocolAdapter> adapter;
    {
        std::lock_guard<std::mutex> lock(session->adapterMutex);
        adapter = session->adapter;
    }
    if (!adapter) {
        return false;
    }
    const DecoderSessionIdentity owner = session->identity();
    auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!ownerLease) {
        return false;
    }
    if (session->generation.load(std::memory_order_acquire) != sessionGeneration ||
        session->lifecycle.load(std::memory_order_acquire) !=
            SessionContext::Lifecycle::Active) {
        return false;
    }
    auto* rustdesk = dynamic_cast<RustDeskBridge*>(adapter.get());
    if (!rustdesk) {
        return false;
    }
    // This is the only handoff into continuity. ArkTS/NAPI and the OHOS
    // observer both call this validator; neither owns retry scheduling.
    rustdesk->onNetworkChanged(available, networkGeneration);
    return true;
}

static bool DispatchRustDeskNetworkEvent(
    int32_t sessionId, uint64_t sessionGeneration, bool available,
    uint64_t networkGeneration) {
    if (sessionId <= 0 || sessionGeneration == 0 || networkGeneration == 0) {
        return false;
    }
    std::shared_ptr<SessionContext> session;
    const auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end()) {
        session = it->second;
    }
    if (!session) {
        return false;
    }
    return DispatchRustDeskNetworkSession(
        session, sessionId, sessionGeneration, available, networkGeneration);
}

#if defined(__MUSL__)
static std::mutex g_nativeNetworkObserverMutex;
static uint32_t g_nativeNetworkObserverId = 0;
static int32_t g_nativeNetworkObserverSessionId = 0;
static uint64_t g_nativeNetworkObserverSessionGeneration = 0;
static std::shared_ptr<SessionContext> g_nativeNetworkObserverSession;
static std::atomic<uint64_t> g_nativeNetworkGeneration {1};

static void DispatchNativeNetworkAvailability(bool available) {
    int32_t sessionId = 0;
    uint64_t sessionGeneration = 0;
    std::shared_ptr<SessionContext> session;
    {
        std::lock_guard<std::mutex> lock(g_nativeNetworkObserverMutex);
        sessionId = g_nativeNetworkObserverSessionId;
        sessionGeneration = g_nativeNetworkObserverSessionGeneration;
        session = g_nativeNetworkObserverSession;
    }
    const uint64_t networkGeneration =
        g_nativeNetworkGeneration.fetch_add(1, std::memory_order_acq_rel) + 1;
    if (sessionId != 0 && sessionGeneration != 0) {
        (void)DispatchRustDeskNetworkSession(
            session, sessionId, sessionGeneration, available, networkGeneration);
    }
    const size_t sshCount = g_sshNativeFacade.notifyNetworkAvailability(
        available, networkGeneration);
    if (sshCount > 0) {
        OH_LOG_INFO(LOG_APP,
            "[ExtLoader] SSH network availability=%{public}s sessions=%{public}zu generation=%{public}llu",
            available ? "available" : "lost", sshCount,
            static_cast<unsigned long long>(networkGeneration));
    }
}

static void OnNativeNetworkAvailable(NetConn_NetHandle* /*netHandle*/) {
    DispatchNativeNetworkAvailability(true);
}

static void OnNativeNetworkLost(NetConn_NetHandle* /*netHandle*/) {
    DispatchNativeNetworkAvailability(false);
}

static void OnNativeNetworkUnavailable() {
    DispatchNativeNetworkAvailability(false);
}

static NetConn_NetConnCallback kNativeNetworkCallbacks {
    OnNativeNetworkAvailable,
    nullptr,
    nullptr,
    OnNativeNetworkLost,
    OnNativeNetworkUnavailable,
    nullptr,
};

static bool EnsureNativeNetworkObserver() {
    {
        std::lock_guard<std::mutex> lock(g_nativeNetworkObserverMutex);
        if (g_nativeNetworkObserverId != 0) {
            return true;
        }
    }
    // Do not call the system registration API while holding our state lock:
    // some platform implementations can deliver an initial availability
    // callback synchronously during registration.
    uint32_t callbackId = 0;
    const int32_t result = OH_NetConn_RegisterDefaultNetConnCallback(
        &kNativeNetworkCallbacks, &callbackId);
    if (result != 0) {
        OH_LOG_WARN(LOG_APP,
            "[ExtLoader] native network observer registration failed result=%{public}d",
            result);
        return false;
    }
    bool keepRegistration = false;
    {
        std::lock_guard<std::mutex> lock(g_nativeNetworkObserverMutex);
        if (g_nativeNetworkObserverId == 0) {
            g_nativeNetworkObserverId = callbackId;
            keepRegistration = true;
        }
    }
    if (!keepRegistration) {
        OH_NetConn_UnregisterNetConnCallback(callbackId);
    }
    return true;
}

static void UpdateNativeNetworkObserver(
    const std::shared_ptr<SessionContext>& session) {
    if (!session) {
        return;
    }
    if (!EnsureNativeNetworkObserver() || session->protocolName != "rustdesk") {
        return;
    }
    const int32_t sessionId = static_cast<int32_t>(session->sessionId);
    const uint64_t sessionGeneration =
        session->generation.load(std::memory_order_acquire);
    if (sessionId <= 0 || sessionGeneration == 0) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_nativeNetworkObserverMutex);
    g_nativeNetworkObserverSessionId = sessionId;
    g_nativeNetworkObserverSessionGeneration = sessionGeneration;
    g_nativeNetworkObserverSession = session;
}

static void ClearNativeNetworkObserver(
    int32_t sessionId, uint64_t sessionGeneration) {
    uint32_t callbackId = 0;
    {
        std::lock_guard<std::mutex> lock(g_nativeNetworkObserverMutex);
        if (g_nativeNetworkObserverSessionId == sessionId &&
            g_nativeNetworkObserverSessionGeneration == sessionGeneration) {
            g_nativeNetworkObserverSessionId = 0;
            g_nativeNetworkObserverSessionGeneration = 0;
            g_nativeNetworkObserverSession.reset();
        }
        // SSH sessions are managed separately from the single RustDesk
        // observer target. Keep the platform registration while either side
        // still has a live consumer, and release it only after the last one.
        if (g_nativeNetworkObserverId != 0 &&
            g_nativeNetworkObserverSessionId == 0 &&
            g_sshNativeFacade.snapshots().empty()) {
            callbackId = g_nativeNetworkObserverId;
            g_nativeNetworkObserverId = 0;
        }
    }
    if (callbackId != 0) {
        OH_NetConn_UnregisterNetConnCallback(callbackId);
    }
}
#else
static void UpdateNativeNetworkObserver(
    const std::shared_ptr<SessionContext>& /*session*/) {}
static void ClearNativeNetworkObserver(
    int32_t /*sessionId*/, uint64_t /*sessionGeneration*/) {}
#endif

// SSH 推送回调的 TSFN 映射 (sessionId → registration). 由 setOnDataCallback /
// disconnect 维护。registration 先停止生产者，再释放 TSFN，避免 reader 线程
// 在 N-API handle 已释放后仍调用 napi_call_threadsafe_function。
struct SshDataTsfnRegistration {
    static constexpr size_t kMaxPendingChunks = 512;
    static constexpr size_t kMaxPendingBytes = 8 * 1024 * 1024;

    napi_threadsafe_function tsfn = nullptr;
    int32_t sessionId = 0;
    std::atomic<bool> accepting {true};
    // Only an authenticated independent-window handoff preserves output that
    // was already queued for the source page. Explicit callback removal and
    // session teardown intentionally discard it.
    std::atomic<bool> redeliverOnStop {false};
    std::mutex pendingMutex;
    std::condition_variable pendingCondition;
    std::deque<std::vector<uint8_t>*> pending;
    size_t pendingBytes = 0;
    std::thread pumpThread;
    // Keep the adapter alive until the callback is explicitly detached. This
    // makes orphan-registration cleanup reliable even after the session map
    // has already erased its owner.
    std::shared_ptr<SshAdapter> adapter;

    ~SshDataTsfnRegistration() {
        accepting.store(false, std::memory_order_release);
        pendingCondition.notify_all();
        if (pumpThread.joinable()) {
            if (pumpThread.get_id() == std::this_thread::get_id()) {
                pumpThread.detach();
            } else {
                pumpThread.join();
            }
        }
        std::lock_guard<std::mutex> lock(pendingMutex);
        while (!pending.empty()) {
            delete pending.front();
            pending.pop_front();
        }
        pendingBytes = 0;
    }
};

// The TSFN owns this holder until every already-queued JS callback has
// finished. Keeping the registration alive lets a callback that loses its
// page during an independent-window handoff return the exact bytes to the
// adapter instead of invoking a stale ArkTS closure or dropping the prompt.
struct SshDataTsfnContext {
    std::shared_ptr<SshDataTsfnRegistration> registration;
};

static std::map<int, std::shared_ptr<SshDataTsfnRegistration>> g_dataTsfnMap;
static std::mutex g_dataTsfnMutex;

static void StopSshDataRegistrationInstance(
    const std::shared_ptr<SshDataTsfnRegistration>& registration,
    bool redeliverOnStop = false);

// Used by the TSFN pump when N-API is closing and the normal page disconnect
// path is no longer available. Detach the adapter first so the callback lambda
// cannot keep the registration alive through adapter -> callback -> registration.
static void DetachSshDataRegistrationOnClose(
    const std::shared_ptr<SshDataTsfnRegistration>& registration) {
    if (!registration) {
        return;
    }
    registration->accepting.store(false, std::memory_order_release);
    registration->pendingCondition.notify_all();
    const std::shared_ptr<SshAdapter> adapter = registration->adapter;
    if (adapter) {
        adapter->setOnDataCallback(nullptr);
    }
    std::lock_guard<std::mutex> lock(g_dataTsfnMutex);
    auto it = g_dataTsfnMap.find(registration->sessionId);
    if (it != g_dataTsfnMap.end() && it->second == registration) {
        g_dataTsfnMap.erase(it);
    }
}

static std::shared_ptr<SshDataTsfnRegistration> TakeSshDataRegistration(int32_t sessionId) {
    std::lock_guard<std::mutex> lock(g_dataTsfnMutex);
    auto it = g_dataTsfnMap.find(sessionId);
    if (it == g_dataTsfnMap.end()) {
        return nullptr;
    }
    std::shared_ptr<SshDataTsfnRegistration> registration = it->second;
    g_dataTsfnMap.erase(it);
    return registration;
}

static void StopSshDataRegistration(
    int32_t sessionId, const std::shared_ptr<SshAdapter>& adapter) {
    std::shared_ptr<SshDataTsfnRegistration> registration =
        TakeSshDataRegistration(sessionId);
    if (registration) {
        StopSshDataRegistrationInstance(registration);
    }
    std::shared_ptr<SshAdapter> effectiveAdapter = adapter;
    if (!effectiveAdapter && registration) {
        effectiveAdapter = registration->adapter;
    }
    if (effectiveAdapter) {
        effectiveAdapter->setOnDataCallback(nullptr);
    }
    if (registration && registration->tsfn != nullptr) {
        napi_release_threadsafe_function(registration->tsfn, napi_tsfn_release);
    }
}

// Remove only the JS consumer. A detached SSH session keeps its owner reactor
// and socket alive so a later page can attach a fresh callback and resume input.
static void DetachSshDataRegistration(
    int32_t sessionId, const std::shared_ptr<SshAdapter>& adapter) {
    std::shared_ptr<SshDataTsfnRegistration> registration =
        TakeSshDataRegistration(sessionId);
    std::shared_ptr<SshAdapter> effectiveAdapter = adapter;
    if (!effectiveAdapter && registration) {
        effectiveAdapter = registration->adapter;
    }
    // First sever the native producer under the adapter's delivery lock.
    // Bytes already accepted by the old registration remain in its pending
    // or TSFN queues; StopSshDataRegistrationInstance returns those bytes to
    // the adapter FIFO while no stale callback can consume them.
    if (effectiveAdapter) {
        effectiveAdapter->detachOnDataCallback();
    }
    if (registration) {
        StopSshDataRegistrationInstance(registration, true);
    }
    if (registration && registration->tsfn != nullptr) {
        napi_release_threadsafe_function(registration->tsfn, napi_tsfn_release);
    }
}

// ============================================================
// 内部辅助函数
// ============================================================

/** 确保所有协议适配器已注册 (懒加载) */
static void EnsureExtensionsLoaded() {
    static bool loaded = false;
    if (!loaded) {
        OH_LOG_INFO(LOG_APP, "[ExtLoader] 懒加载扩展系统...");

        // 注册所有协议适配器
        registerFreeRdpAdapter();
        registerRustDeskBridge();
        registerSshAdapter();
        registerVncAdapter();

        loaded = true;
        OH_LOG_INFO(LOG_APP, "[ExtLoader] 扩展系统加载完成");
    }
}

constexpr size_t kMaxGenericNapiStringLength = 4U * 1024U * 1024U;

static bool ReadBoundedNapiStringValue(
    napi_env env, napi_value value, size_t maxLength, std::string& output) {
    output.clear();
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_string) {
        return false;
    }
    size_t len = 0;
    napi_status status = napi_get_value_string_utf8(env, value, nullptr, 0, &len);
    if (status != napi_ok || len > maxLength) {
        return false;
    }
    try {
        std::vector<char> buffer(len + 1, '\0');
        size_t copied = 0;
        status = napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &copied);
        if (status != napi_ok || copied > maxLength) {
            return false;
        }
        output.assign(buffer.data(), copied);
        return true;
    } catch (...) {
        output.clear();
        return false;
    }
}

static std::string GetNapiString(napi_env env, napi_value value) {
    std::string output;
    (void)ReadBoundedNapiStringValue(
        env, value, kMaxGenericNapiStringLength, output);
    return output;
}

static bool ReadStrictNapiInt32Value(
    napi_env env, napi_value value, int32_t& output) {
    napi_valuetype type = napi_undefined;
    double numeric = 0.0;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_number ||
        napi_get_value_double(env, value, &numeric) != napi_ok ||
        !std::isfinite(numeric) || std::trunc(numeric) != numeric ||
        numeric < static_cast<double>(std::numeric_limits<int32_t>::min()) ||
        numeric > static_cast<double>(std::numeric_limits<int32_t>::max())) {
        return false;
    }
    output = static_cast<int32_t>(numeric);
    return true;
}

static bool ReadStrictNapiInt64Value(
    napi_env env, napi_value value, int64_t& output) {
    constexpr double kMaxSafeInteger = 9007199254740991.0;
    napi_valuetype type = napi_undefined;
    double numeric = 0.0;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_number ||
        napi_get_value_double(env, value, &numeric) != napi_ok ||
        !std::isfinite(numeric) || std::trunc(numeric) != numeric ||
        numeric < -kMaxSafeInteger || numeric > kMaxSafeInteger) {
        return false;
    }
    output = static_cast<int64_t>(numeric);
    return true;
}

static void ParseBoundedSshResponseArray(napi_env env, napi_value object,
                                         const char* property,
                                         std::vector<std::string>& output) {
    if (object == nullptr || property == nullptr) { return; }
    napi_value value;
    bool isArray = false;
    if (napi_get_named_property(env, object, property, &value) != napi_ok ||
        napi_is_array(env, value, &isArray) != napi_ok || !isArray) {
        return;
    }
    uint32_t count = 0;
    if (napi_get_array_length(env, value, &count) != napi_ok) { return; }
    count = std::min<uint32_t>(count, 32);
    for (uint32_t index = 0; index < count; ++index) {
        napi_value item;
        if (napi_get_element(env, value, index, &item) != napi_ok) { continue; }
        napi_valuetype type = napi_undefined;
        if (napi_typeof(env, item, &type) != napi_ok || type != napi_string) { continue; }
        std::string response;
        if (!ReadBoundedNapiStringValue(env, item, 4096, response)) { continue; }
        output.push_back(std::move(response));
    }
}

static bool ReadOptionalNapiString(napi_env env, napi_value object, const char* key,
                                   std::string& output, size_t maxLength) {
    napi_value value;
    if (napi_get_named_property(env, object, key, &value) != napi_ok) { return true; }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type == napi_undefined ||
        type == napi_null) { return true; }
    if (type != napi_string) { return false; }
    return ReadBoundedNapiStringValue(env, value, maxLength, output);
}

static bool ReadOptionalNapiInt(napi_env env, napi_value object, const char* key,
                                int& output, bool* present = nullptr) {
    bool propertyPresent = false;
    if (napi_has_named_property(env, object, key, &propertyPresent) != napi_ok) {
        return false;
    }
    if (!propertyPresent) { return true; }
    napi_value value;
    if (napi_get_named_property(env, object, key, &value) != napi_ok) { return false; }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok) { return false; }
    if (type == napi_undefined || type == napi_null) { return true; }
    if (type != napi_number) { return false; }
    int32_t parsed = 0;
    if (!ReadStrictNapiInt32Value(env, value, parsed)) { return false; }
    output = parsed;
    if (present != nullptr) { *present = true; }
    return true;
}

static bool NormalizePersistedEndpoint(std::string& host, int port) {
    if (port <= 0 || port > 65535) { return false; }
    const auto parsed = remotedesk::endpoint::ParseFields(
        host, static_cast<std::uint16_t>(port), remotedesk::endpoint::ParseMode::Persisted);
    if (!parsed.ok || !parsed.endpoint.scope().empty()) { return false; }
    host = remotedesk::endpoint::TransportHost(parsed.endpoint);
    return true;
}

static bool NormalizeServerIdentity(std::string& name) {
    if (name.empty()) { return true; }
    const auto parsed = remotedesk::endpoint::ParseServerIdentity(name);
    if (!parsed.ok || parsed.identity.kind() == remotedesk::endpoint::ServerIdentityKind::None) {
        return false;
    }
    name = parsed.identity.canonicalName();
    return true;
}

static bool SshSessionLocaleIsSupported(const std::string& locale) {
    return locale.empty() || locale == "C.UTF-8" || locale == "zh_CN.UTF-8" ||
        locale == "zh_TW.UTF-8" || locale == "en_US.UTF-8";
}

static bool ParseSshJumpHopHandoffs(napi_env env, napi_value object,
                                    ConnectionConfig& config) {
    napi_value value;
    if (napi_get_named_property(env, object, "sshJumpHopHandoffs", &value) != napi_ok) {
        return true;
    }
    bool isArray = false;
    if (napi_is_array(env, value, &isArray) != napi_ok || !isArray) { return false; }
    uint32_t count = 0;
    if (napi_get_array_length(env, value, &count) != napi_ok ||
        count > kSshMaxJumpHops) { return false; }
    config.sshJumpHopHandoffs.clear();
    config.sshJumpHopHandoffs.reserve(count);
    for (uint32_t index = 0; index < count; ++index) {
        napi_value item;
        if (napi_get_element(env, value, index, &item) != napi_ok) { return false; }
        napi_valuetype type = napi_undefined;
        if (napi_typeof(env, item, &type) != napi_ok || type != napi_object) { return false; }
        SshJumpHopHandoff handoff;
        if (!ReadOptionalNapiString(env, item, "password", handoff.password, 4096) ||
            !ReadOptionalNapiString(env, item, "privateKeyPem", handoff.privateKeyPem, 64 * 1024) ||
            !ReadOptionalNapiString(env, item, "privateKeyPassphrase",
                                    handoff.privateKeyPassphrase, 4096)) {
            return false;
        }
        ParseBoundedSshResponseArray(env, item, "keyboardInteractiveResponses",
                                     handoff.keyboardInteractiveResponses);
        config.sshJumpHopHandoffs.push_back(std::move(handoff));
    }
    return true;
}

static bool ParseSshRoute(napi_env env, napi_value object, ConnectionConfig& config) {
    napi_value routeValue;
    if (napi_get_named_property(env, object, "sshRoute", &routeValue) != napi_ok) {
        return true;
    }
    napi_valuetype routeType = napi_undefined;
    if (napi_typeof(env, routeValue, &routeType) != napi_ok || routeType != napi_object) {
        return false;
    }

    SshRoute route;
    int schemaVersion = 1;
    // Keep an omitted endpoint port distinguishable until FinalizeSshRoute()
    // can apply the normalized SSH config port (including non-22 ports).
    int endpointPort = 0;
    int connectTimeoutMs = 10000;
    std::string type;
    if (!ReadOptionalNapiInt(env, routeValue, "schemaVersion", schemaVersion) ||
        !ReadOptionalNapiString(env, routeValue, "type", type, 32) ||
        !ReadOptionalNapiString(env, routeValue, "endpointHost", route.endpointHost, 255) ||
        !ReadOptionalNapiInt(env, routeValue, "endpointPort", endpointPort) ||
        !ReadOptionalNapiString(env, routeValue, "controlId", route.controlId, 256) ||
        !ReadOptionalNapiInt(env, routeValue, "connectTimeoutMs", connectTimeoutMs) ||
        type.empty() || !sshRouteTypeIsKnown(type)) {
        return false;
    }
    route.schemaVersion = static_cast<uint32_t>(std::max(0, schemaVersion));
    route.kind = sshRouteKindFromType(type);
    route.endpointPort = endpointPort > 0 ? endpointPort : config.port;
    route.connectTimeoutMs = static_cast<uint32_t>(std::max(0, connectTimeoutMs));
    if (!route.endpointHost.empty() &&
        !NormalizePersistedEndpoint(route.endpointHost, route.endpointPort)) {
        return false;
    }

    napi_value hopsValue;
    if (napi_get_named_property(env, routeValue, "hops", &hopsValue) == napi_ok) {
        bool isArray = false;
        uint32_t count = 0;
        if (napi_is_array(env, hopsValue, &isArray) != napi_ok || !isArray ||
            napi_get_array_length(env, hopsValue, &count) != napi_ok ||
            count > kSshMaxJumpHops) {
            return false;
        }
        route.hops.reserve(count);
        for (uint32_t index = 0; index < count; ++index) {
            napi_value item;
            if (napi_get_element(env, hopsValue, index, &item) != napi_ok) { return false; }
            napi_valuetype itemType = napi_undefined;
            if (napi_typeof(env, item, &itemType) != napi_ok || itemType != napi_object) {
                return false;
            }
            SshJumpHop hop;
            int port = 22;
            int hopTimeoutMs = 10000;
            if (!ReadOptionalNapiString(env, item, "host", hop.host, 255) ||
                !ReadOptionalNapiInt(env, item, "port", port) ||
                !ReadOptionalNapiString(env, item, "username", hop.username, 256) ||
                !ReadOptionalNapiString(env, item, "authMethod", hop.authMethod, 32) ||
                !ReadOptionalNapiString(env, item, "expectedHostKeyRawBase64",
                                        hop.expectedHostKeyRawBase64, 64 * 1024) ||
                !ReadOptionalNapiString(env, item, "expectedHostKeyFingerprintSha256",
                                        hop.expectedHostKeyFingerprintSha256, 512) ||
                !ReadOptionalNapiInt(env, item, "connectTimeoutMs", hopTimeoutMs)) {
                return false;
            }
            hop.port = port;
            hop.connectTimeoutMs = static_cast<uint32_t>(std::max(0, hopTimeoutMs));
            if (!NormalizePersistedEndpoint(hop.host, hop.port)) { return false; }
            route.hops.push_back(std::move(hop));
        }
    }
    if (!sshRouteHopsValid(route)) { return false; }
    config.sshRoute = std::move(route);
    config.sshRouteExplicit = true;
    return ParseSshJumpHopHandoffs(env, object, config);
}

static const char* SshRouteTypeName(SshRouteKind kind) {
    switch (kind) {
        case SshRouteKind::HttpConnect: return "http_connect";
        case SshRouteKind::Socks5: return "socks5";
        case SshRouteKind::FrpTcp: return "frp_tcp";
        case SshRouteKind::SshJump: return "ssh_jump";
        case SshRouteKind::FrpVisitor: return "frp_visitor";
        case SshRouteKind::FrpStcp: return "frp_stcp";
        case SshRouteKind::FrpSudp: return "frp_sudp";
        case SshRouteKind::FrpXtcp: return "frp_xtcp";
        case SshRouteKind::Direct: return "direct";
    }
    return "direct";
}

static bool FinalizeSshRoute(ConnectionConfig& config) {
    if (config.sshHostKeyPromptEnabled &&
        (config.sshTrustHostId.empty() || config.sshTrustHostId.size() > 128)) {
        return false;
    }
    const std::string configuredType = config.sshProxyType.empty()
        ? "direct" : config.sshProxyType;
    if (!sshRouteTypeIsKnown(configuredType)) { return false; }

    if (!config.sshRouteExplicit) {
        config.sshRoute.schemaVersion = 1;
        config.sshRoute.kind = sshRouteKindFromType(configuredType);
        config.sshRoute.endpointHost = config.host;
        config.sshRoute.endpointPort = config.port;
        config.sshRoute.connectTimeoutMs = 10000;
        if (config.sshRoute.kind == SshRouteKind::SshJump) {
            SshJumpHop hop;
            hop.host = config.sshProxyHost;
            hop.port = config.sshProxyPort;
            hop.username = config.sshProxyUsername;
            hop.authMethod = config.sshProxyAuthMethod.empty()
                ? "password" : config.sshProxyAuthMethod;
            hop.expectedHostKeyRawBase64 = config.sshJumpHostKeyRawBase64;
            hop.expectedHostKeyFingerprintSha256 = config.sshJumpHostKeyFingerprintSha256;
            config.sshRoute.hops.push_back(std::move(hop));
            SshJumpHopHandoff handoff;
            handoff.password = config.sshProxyPassword;
            handoff.privateKeyPem = config.sshProxyPrivateKeyPem;
            handoff.privateKeyPassphrase = config.sshProxyPrivateKeyPassphrase;
            handoff.keyboardInteractiveResponses = config.sshProxyKeyboardInteractiveResponses;
            config.sshJumpHopHandoffs.push_back(std::move(handoff));
        }
    } else {
        if (config.sshRoute.endpointHost.empty()) {
            config.sshRoute.endpointHost = config.host;
        } else if (config.sshRoute.endpointHost != config.host) {
            return false;
        }
        if (config.sshRoute.endpointPort <= 0) {
            config.sshRoute.endpointPort = config.port;
        } else if (config.sshRoute.endpointPort != config.port) {
            return false;
        }
        config.sshProxyType = SshRouteTypeName(config.sshRoute.kind);
        if (config.sshRoute.kind == SshRouteKind::SshJump &&
            config.sshJumpHopHandoffs.empty() && config.sshRoute.hops.size() == 1) {
            SshJumpHopHandoff handoff;
            handoff.password = config.sshProxyPassword;
            handoff.privateKeyPem = config.sshProxyPrivateKeyPem;
            handoff.privateKeyPassphrase = config.sshProxyPrivateKeyPassphrase;
            handoff.keyboardInteractiveResponses = config.sshProxyKeyboardInteractiveResponses;
            config.sshJumpHopHandoffs.push_back(std::move(handoff));
        }
    }

    if (!sshRouteHopsValid(config.sshRoute) ||
        config.sshJumpHopHandoffs.size() > config.sshRoute.hops.size()) {
        return false;
    }
    if (config.sshRoute.kind != SshRouteKind::SshJump &&
        !config.sshJumpHopHandoffs.empty()) {
        return false;
    }
    return true;
}

static bool ReadStrictBoundedSshResponseArray(
    napi_env env, napi_value object, const char* property,
    std::vector<std::string>& output) {
    bool present = false;
    if (napi_has_named_property(env, object, property, &present) != napi_ok) {
        return false;
    }
    if (!present) { return true; }
    napi_value value;
    if (napi_get_named_property(env, object, property, &value) != napi_ok) {
        return false;
    }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok) { return false; }
    if (type == napi_undefined || type == napi_null) { return true; }
    bool isArray = false;
    if (napi_is_array(env, value, &isArray) != napi_ok || !isArray) {
        return false;
    }
    uint32_t count = 0;
    if (napi_get_array_length(env, value, &count) != napi_ok || count > 32) {
        return false;
    }
    for (uint32_t index = 0; index < count; ++index) {
        napi_value item;
        if (napi_get_element(env, value, index, &item) != napi_ok) { return false; }
        std::string response;
        if (!ReadBoundedNapiStringValue(env, item, 4096, response)) { return false; }
        output.push_back(std::move(response));
    }
    return true;
}

static bool ReadSshProxyOptions(
    napi_env env, napi_value value, SshProxyOptions& proxy) {
    proxy = SshProxyOptions {};
    if (value == nullptr) { return true; }

    napi_valuetype proxyType = napi_undefined;
    if (napi_typeof(env, value, &proxyType) != napi_ok) { return false; }
    if (proxyType == napi_undefined || proxyType == napi_null) { return true; }
    bool isArray = false;
    if (proxyType != napi_object ||
        napi_is_array(env, value, &isArray) != napi_ok || isArray) {
        return false;
    }

    bool portPresent = false;
    if (!ReadOptionalNapiString(env, value, "type", proxy.type, 32) ||
        !ReadOptionalNapiString(env, value, "host", proxy.host,
                                remotedesk::endpoint::kMaxInputLength) ||
        !ReadOptionalNapiInt(env, value, "port", proxy.port, &portPresent) ||
        !ReadOptionalNapiString(env, value, "username", proxy.username, 1024) ||
        !ReadOptionalNapiString(env, value, "password", proxy.password, 65536) ||
        !ReadOptionalNapiString(env, value, "privateKeyPem", proxy.privateKeyPem,
                                kMaxGenericNapiStringLength) ||
        !ReadOptionalNapiString(env, value, "privateKeyPassphrase",
                                proxy.privateKeyPassphrase, 65536) ||
        !ReadOptionalNapiString(env, value, "authMethod", proxy.authMethod, 32) ||
        !ReadOptionalNapiString(env, value, "expectedHostKeyRawBase64",
                                proxy.expectedHostKeyRawBase64, 65536) ||
        !ReadOptionalNapiString(env, value, "expectedHostKeyFingerprintSha256",
                                proxy.expectedHostKeyFingerprintSha256, 256) ||
        !ReadStrictBoundedSshResponseArray(
            env, value, "keyboardInteractiveResponses",
            proxy.keyboardInteractiveResponses)) {
        return false;
    }

    if (proxy.type.empty()) { proxy.type = "direct"; }
    if (!sshRouteTypeIsKnown(proxy.type) ||
        (!proxy.authMethod.empty() && proxy.authMethod != "password" &&
         proxy.authMethod != "publickey" && proxy.authMethod != "kbd-interactive" &&
         proxy.authMethod != "keyboard-interactive")) {
        return false;
    }
    if (sshRouteTypeNeedsProxyEndpoint(proxy.type)) {
        if (!portPresent || !NormalizePersistedEndpoint(proxy.host, proxy.port)) {
            return false;
        }
    }
    return true;
}

static void ClearSshProxyOptions(SshProxyOptions& proxy) {
    secureClearString(proxy.password);
    secureClearString(proxy.privateKeyPem);
    secureClearString(proxy.privateKeyPassphrase);
    for (std::string& response : proxy.keyboardInteractiveResponses) {
        secureClearString(response);
    }
    proxy.keyboardInteractiveResponses.clear();
}

/**
 * 根据协议名称查找适配器
 */
static std::shared_ptr<ProtocolAdapter> FindAdapter(const std::string& protocolName) {
    EnsureExtensionsLoaded();
    return ExtensionSystem::instance().protocols.getByName("protocol", protocolName);
}

/**
 * SSH session adapter factory.
 *
 * The extension registry stores one prototype per protocol for discovery and
 * preflight. SSH protocol state is session-owned, so a real SSH connection
 * must receive a fresh SshAdapter instance. Other protocols keep their
 * existing factory/ownership path unchanged.
 */
static std::shared_ptr<ProtocolAdapter> CreateAdapterForSession(
    const std::string& protocolName) {
    EnsureExtensionsLoaded();
    if (protocolName == "ssh") {
        return std::make_shared<SshAdapter>();
    }
    return ExtensionSystem::instance().protocols.getByName("protocol", protocolName);
}

static void SetObjectString(napi_env env, napi_value object, const char* key,
                            const std::string& value) {
    napi_value item;
    napi_create_string_utf8(env, value.c_str(), NAPI_AUTO_LENGTH, &item);
    napi_set_named_property(env, object, key, item);
}

static void SetObjectInt32(napi_env env, napi_value object, const char* key, int32_t value) {
    napi_value item;
    napi_create_int32(env, value, &item);
    napi_set_named_property(env, object, key, item);
}

static void SetObjectInt64(napi_env env, napi_value object, const char* key, int64_t value) {
    napi_value item;
    napi_create_int64(env, value, &item);
    napi_set_named_property(env, object, key, item);
}

static void SetObjectDouble(napi_env env, napi_value object, const char* key, double value) {
    napi_value item;
    napi_create_double(env, value, &item);
    napi_set_named_property(env, object, key, item);
}

static void SetObjectBool(napi_env env, napi_value object, const char* key, bool value) {
    napi_value item;
    napi_get_boolean(env, value, &item);
    napi_set_named_property(env, object, key, item);
}

struct SshForwardingSessionAccess {
    std::shared_ptr<SessionContext> session;
    std::shared_ptr<SshAdapter> adapter;
    uint64_t generation = 0;
};

// Forwarding is a session-owned capability. Keep this gate in one place so
// every NAPI operation rejects a reused id, a non-SSH adapter, and teardown
// callbacks before touching the adapter-owned manager.
static SshForwardingResult ResolveSshForwardingSession(
    int32_t sessionId, uint64_t expectedGeneration,
    SshForwardingSessionAccess& out) {
    if (sessionId <= 0) {
        return SshForwardingResult::NotFound;
    }
    if (expectedGeneration == 0) {
        return SshForwardingResult::MissingGeneration;
    }
    const auto it = g_sessionRegistry.find(sessionId);
    if (it == g_sessionRegistry.end() || !it->second) {
        return SshForwardingResult::NotFound;
    }
    const std::shared_ptr<SessionContext>& session = it->second;
    if (session->lifecycle.load(std::memory_order_acquire) !=
        SessionContext::Lifecycle::Active) {
        return SshForwardingResult::InvalidState;
    }
    const uint64_t currentGeneration =
        session->generation.load(std::memory_order_acquire);
    if (currentGeneration == 0) {
        return SshForwardingResult::MissingGeneration;
    }
    if (currentGeneration != expectedGeneration) {
        return SshForwardingResult::StaleSession;
    }
    if (!g_sshNativeFacade.accepts(SshSessionHandle {
            static_cast<uint64_t>(sessionId), "shell", expectedGeneration})) {
        return SshForwardingResult::StaleSession;
    }
    if (session->protocolName != "ssh" || !session->adapter) {
        return SshForwardingResult::InvalidState;
    }
    const std::shared_ptr<SshAdapter> adapter =
        std::dynamic_pointer_cast<SshAdapter>(session->adapter);
    if (!adapter) {
        return SshForwardingResult::InvalidState;
    }
    out.session = session;
    out.adapter = adapter;
    out.generation = currentGeneration;
    return SshForwardingResult::Ok;
}

static bool ReadNapiNamedString(
    napi_env env, napi_value object, const char* name,
    std::string& out, bool required,
    size_t maxLength = kMaxGenericNapiStringLength) {
    napi_value value;
    if (napi_get_named_property(env, object, name, &value) != napi_ok) {
        return !required;
    }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok) {
        return false;
    }
    if (type == napi_undefined || type == napi_null) {
        return !required;
    }
    if (type != napi_string) {
        return false;
    }
    return ReadBoundedNapiStringValue(env, value, maxLength, out);
}

static bool ReadNapiNamedInt32(
    napi_env env, napi_value object, const char* name,
    int32_t& out, bool required) {
    napi_value value;
    if (napi_get_named_property(env, object, name, &value) != napi_ok) {
        return !required;
    }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok) {
        return false;
    }
    if (type == napi_undefined || type == napi_null) {
        return !required;
    }
    if (type != napi_number || !ReadStrictNapiInt32Value(env, value, out)) {
        return false;
    }
    return true;
}

static bool ReadNapiNamedBool(
    napi_env env, napi_value object, const char* name,
    bool& out, bool required) {
    napi_value value;
    if (napi_get_named_property(env, object, name, &value) != napi_ok) {
        return !required;
    }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok) {
        return false;
    }
    if (type == napi_undefined || type == napi_null) {
        return !required;
    }
    if (type != napi_boolean || napi_get_value_bool(env, value, &out) != napi_ok) {
        return false;
    }
    return true;
}

static bool ReadNapiNamedInt64(napi_env env, napi_value object, const char* name,
                               int64_t& out, bool required);

static bool ReadSshForwardingConfig(
    napi_env env, napi_value value, SshForwardingConfig& config) {
    napi_valuetype type = napi_undefined;
    bool isArray = false;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_object ||
        napi_is_array(env, value, &isArray) != napi_ok || isArray) {
        return false;
    }

    int32_t mode = static_cast<int32_t>(config.mode);
    int32_t bindPort = config.bindPort;
    int32_t targetPort = config.targetPort;
    int32_t maxConnections = static_cast<int32_t>(config.maxConnections);
    int32_t schemaVersion = static_cast<int32_t>(config.schemaVersion);
    int32_t minBindPort = static_cast<int32_t>(config.minBindPort);
    int32_t maxBindPort = static_cast<int32_t>(config.maxBindPort);
    int64_t maxBytes = static_cast<int64_t>(config.maxBytes);
    int64_t expiresAtMs = static_cast<int64_t>(config.expiresAtMs);
    if (!ReadNapiNamedString(env, value, "id", config.id, true, 256) ||
        !ReadNapiNamedString(env, value, "bindHost", config.bindHost, false,
                             remotedesk::endpoint::kMaxInputLength) ||
        !ReadNapiNamedString(env, value, "targetHost", config.targetHost, false,
                             remotedesk::endpoint::kMaxInputLength) ||
        !ReadNapiNamedInt32(env, value, "mode", mode, false) ||
        !ReadNapiNamedInt32(env, value, "bindPort", bindPort, false) ||
        !ReadNapiNamedInt32(env, value, "targetPort", targetPort, false) ||
        !ReadNapiNamedInt32(env, value, "maxConnections", maxConnections, false) ||
        !ReadNapiNamedInt32(env, value, "schemaVersion", schemaVersion, false) ||
        !ReadNapiNamedInt32(env, value, "minBindPort", minBindPort, false) ||
        !ReadNapiNamedInt32(env, value, "maxBindPort", maxBindPort, false) ||
        !ReadNapiNamedInt64(env, value, "maxBytes", maxBytes, false) ||
        !ReadNapiNamedInt64(env, value, "expiresAtMs", expiresAtMs, false) ||
        !ReadNapiNamedBool(env, value, "enabled", config.enabled, false) ||
        !ReadNapiNamedBool(env, value, "allowPublicBind", config.allowPublicBind, false) ||
        minBindPort < 0 || minBindPort > 65535 || maxBindPort < 0 || maxBindPort > 65535 ||
        maxBytes < 0 || expiresAtMs < 0) {
        return false;
    }
    config.mode = static_cast<SshForwardingMode>(mode);
    config.bindPort = bindPort;
    config.targetPort = targetPort;
    config.maxConnections = maxConnections < 0 ? 0 : static_cast<uint32_t>(maxConnections);
    config.schemaVersion = schemaVersion <= 0 ? 1 : static_cast<uint32_t>(schemaVersion);
    config.minBindPort = minBindPort <= 0 ? 1 : static_cast<uint16_t>(minBindPort);
    config.maxBindPort = maxBindPort <= 0 ? 65535 : static_cast<uint16_t>(maxBindPort);
    config.maxBytes = static_cast<uint64_t>(maxBytes);
    config.expiresAtMs = static_cast<uint64_t>(expiresAtMs);
    return true;
}

static napi_value CreateSshForwardingSnapshotValue(
    napi_env env, const SshForwardingSnapshot& snapshot) {
    napi_value result;
    napi_create_object(env, &result);
    SetObjectInt32(env, result, "schemaVersion",
                   static_cast<int32_t>(snapshot.config.schemaVersion));
    SetObjectString(env, result, "id", snapshot.config.id);
    SetObjectInt32(env, result, "mode", static_cast<int32_t>(snapshot.config.mode));
    SetObjectString(env, result, "bindHost", snapshot.config.bindHost);
    SetObjectInt32(env, result, "bindPort", snapshot.config.bindPort);
    SetObjectString(env, result, "targetHost", snapshot.config.targetHost);
    SetObjectInt32(env, result, "targetPort", snapshot.config.targetPort);
    SetObjectInt64(env, result, "maxConnections",
                   static_cast<int64_t>(snapshot.config.maxConnections));
    SetObjectInt64(env, result, "maxBytes", static_cast<int64_t>(snapshot.config.maxBytes));
    SetObjectBool(env, result, "enabled", snapshot.config.enabled);
    SetObjectBool(env, result, "allowPublicBind", snapshot.config.allowPublicBind);
    SetObjectInt32(env, result, "minBindPort", snapshot.config.minBindPort);
    SetObjectInt32(env, result, "maxBindPort", snapshot.config.maxBindPort);
    SetObjectInt64(env, result, "ownerSessionId",
                   static_cast<int64_t>(snapshot.config.ownerSessionId));
    SetObjectString(env, result, "ownerChannelId", snapshot.config.ownerChannelId);
    SetObjectInt64(env, result, "ownerGeneration",
                   static_cast<int64_t>(snapshot.config.ownerGeneration));
    SetObjectInt32(env, result, "state", static_cast<int32_t>(snapshot.state));
    SetObjectInt64(env, result, "sessionGeneration",
                   static_cast<int64_t>(snapshot.sessionGeneration));
    SetObjectInt64(env, result, "activeConnections",
                   static_cast<int64_t>(snapshot.activeConnections));
    SetObjectInt32(env, result, "lastError", snapshot.lastError);
    SetObjectInt64(env, result, "transferredBytes",
                   static_cast<int64_t>(snapshot.transferredBytes));
    SetObjectInt64(env, result, "expiresAtMs",
                   static_cast<int64_t>(snapshot.expiresAtMs));
    return result;
}

static napi_value CreateSshForwardingSnapshotsValue(
    napi_env env, int32_t sessionId, SshForwardingResult errorCode,
    uint64_t generation, const std::vector<SshForwardingSnapshot>& snapshots) {
    napi_value result;
    napi_create_object(env, &result);
    SetObjectInt32(env, result, "errorCode", static_cast<int32_t>(errorCode));
    SetObjectInt32(env, result, "sessionId", sessionId);
    SetObjectInt64(env, result, "sessionGeneration", static_cast<int64_t>(generation));
    napi_value array;
    napi_create_array_with_length(env, snapshots.size(), &array);
    for (size_t index = 0; index < snapshots.size(); ++index) {
        napi_value item = CreateSshForwardingSnapshotValue(env, snapshots[index]);
        napi_set_element(env, array, static_cast<uint32_t>(index), item);
    }
    napi_set_named_property(env, result, "snapshots", array);
    return result;
}

static napi_value CreateSshForwardingResultValue(
    napi_env env, SshForwardingResult resultCode) {
    napi_value result;
    napi_create_int32(env, static_cast<int32_t>(resultCode), &result);
    return result;
}

static napi_value CreateSshAuthPromptValue(
    napi_env env, const SshAuthPromptRequest& request) {
    napi_value result;
    napi_create_object(env, &result);
    SetObjectInt32(env, result, "schemaVersion", static_cast<int32_t>(request.schemaVersion));
    SetObjectInt64(env, result, "requestId", static_cast<int64_t>(request.requestId));
    SetObjectInt64(env, result, "sessionId", static_cast<int64_t>(request.sessionId));
    SetObjectInt64(env, result, "generation", static_cast<int64_t>(request.generation));
    SetObjectString(env, result, "targetHost", request.targetHost);
    SetObjectString(env, result, "hop", request.hop);
    SetObjectInt32(env, result, "round", static_cast<int32_t>(request.round));
    SetObjectString(env, result, "name", request.name);
    SetObjectString(env, result, "instruction", request.instruction);
    SetObjectInt64(env, result, "expiresAtMs", static_cast<int64_t>(request.expiresAtMs));
    SetObjectString(env, result, "kind", request.kind);
    SetObjectString(env, result, "trustHostId", request.trustHostId);
    SetObjectString(env, result, "endpointHost", request.endpointHost);
    SetObjectInt32(env, result, "endpointPort", request.endpointPort);
    SetObjectInt32(env, result, "hostKeyHopIndex", request.hostKeyHopIndex);
    SetObjectString(env, result, "hostKeyAlgorithm", request.hostKeyAlgorithm);
    SetObjectString(env, result, "hostKeyFingerprintSha256", request.hostKeyFingerprintSha256);
    SetObjectString(env, result, "hostKeyRawBase64", request.hostKeyRawBase64);
    SetObjectString(env, result, "expectedHostKeyFingerprintSha256",
                    request.expectedHostKeyFingerprintSha256);
    SetObjectBool(env, result, "hostKeyChanged", request.hostKeyChanged);
    napi_value prompts;
    napi_create_array_with_length(env, request.prompts.size(), &prompts);
    for (size_t index = 0; index < request.prompts.size(); ++index) {
        napi_value prompt;
        napi_create_object(env, &prompt);
        SetObjectString(env, prompt, "text", request.prompts[index].text);
        SetObjectBool(env, prompt, "echo", request.prompts[index].echo);
        napi_set_element(env, prompts, static_cast<uint32_t>(index), prompt);
    }
    napi_set_named_property(env, result, "prompts", prompts);
    return result;
}

static napi_value CreateSshSessionSnapshotValue(
    napi_env env, const SshSessionSnapshot& snapshot, int errorCode = 0) {
    napi_value result;
    napi_create_object(env, &result);
    SetObjectInt32(env, result, "schemaVersion", static_cast<int32_t>(snapshot.schemaVersion));
    SetObjectInt32(env, result, "errorCode", errorCode);
    SetObjectInt64(env, result, "sessionId", static_cast<int64_t>(snapshot.sessionId));
    SetObjectInt64(env, result, "generation", static_cast<int64_t>(snapshot.generation));
    SetObjectString(env, result, "channelId", snapshot.channelId);
    SetObjectInt32(env, result, "state", static_cast<int32_t>(snapshot.state));
    SetObjectString(env, result, "stateName", sshSessionLifecycleStateName(snapshot.state));
    SetObjectInt64(env, result, "eventSequence", static_cast<int64_t>(snapshot.eventSequence));
    SetObjectString(env, result, "host", snapshot.host);
    SetObjectInt32(env, result, "port", snapshot.port);
    SetObjectBool(env, result, "backgroundLimited", snapshot.backgroundLimited);
    SetObjectString(env, result, "lastEventType", snapshot.lastEventType);
    return result;
}

static napi_value CreateSshEventEnvelopeValue(
    napi_env env, const SshEventEnvelope& event) {
    napi_value result;
    napi_create_object(env, &result);
    SetObjectInt32(env, result, "schemaVersion", static_cast<int32_t>(event.schemaVersion));
    SetObjectInt64(env, result, "sessionId", static_cast<int64_t>(event.sessionId));
    SetObjectInt64(env, result, "generation", static_cast<int64_t>(event.generation));
    SetObjectString(env, result, "channelId", event.channelId);
    SetObjectString(env, result, "taskId", event.taskId);
    SetObjectString(env, result, "requestId", event.requestId);
    SetObjectInt64(env, result, "sequence", static_cast<int64_t>(event.sequence));
    SetObjectInt64(env, result, "timestampMs", static_cast<int64_t>(event.timestampMs));
    SetObjectInt32(env, result, "priority", static_cast<int32_t>(event.priority));
    SetObjectString(env, result, "type", event.type);
    SetObjectString(env, result, "payloadJson", event.payloadJson);
    return result;
}

static napi_value CreateSshSessionEventsValue(
    napi_env env, int32_t sessionId, const std::string& channelId,
    uint64_t generation, uint64_t afterSequence,
    SshSessionManagerResult errorCode,
    const std::vector<SshEventEnvelope>& events) {
    napi_value result;
    napi_create_object(env, &result);
    SetObjectInt32(env, result, "schemaVersion", 1);
    SetObjectInt32(env, result, "errorCode", static_cast<int32_t>(errorCode));
    SetObjectInt32(env, result, "sessionId", sessionId);
    SetObjectString(env, result, "channelId", channelId);
    SetObjectInt64(env, result, "generation", static_cast<int64_t>(generation));
    SetObjectInt64(env, result, "afterSequence", static_cast<int64_t>(afterSequence));
    napi_value array;
    napi_create_array_with_length(env, events.size(), &array);
    for (size_t index = 0; index < events.size(); ++index) {
        napi_value item = CreateSshEventEnvelopeValue(env, events[index]);
        napi_set_element(env, array, static_cast<uint32_t>(index), item);
    }
    napi_set_named_property(env, result, "events", array);
    return result;
}

static napi_value CreateRdpCertificateInfoValue(napi_env env, const RdpCertificateInfo& cert) {
    napi_value result;
    napi_create_object(env, &result);
    SetObjectBool(env, result, "ok", cert.ok);
    SetObjectString(env, result, "host", cert.host);
    SetObjectInt32(env, result, "port", cert.port);
    SetObjectString(env, result, "serverName", cert.serverName);
    SetObjectString(env, result, "commonName", cert.commonName);
    SetObjectString(env, result, "subject", cert.subject);
    SetObjectString(env, result, "issuer", cert.issuer);
    SetObjectString(env, result, "fingerprintSha256", cert.fingerprintSha256);
    SetObjectInt64(env, result, "notBeforeMs", cert.notBeforeMs);
    SetObjectInt64(env, result, "notAfterMs", cert.notAfterMs);
    SetObjectString(env, result, "preflightStatus", cert.preflightStatus);
    SetObjectInt32(env, result, "flags", cert.flags);
    SetObjectBool(env, result, "rootTrusted", cert.rootTrusted);
    SetObjectBool(env, result, "hostMismatch", cert.hostMismatch);
    SetObjectInt32(env, result, "errorCode", cert.errorCode);
    SetObjectString(env, result, "errorMessage", cert.errorMessage);
    napi_value riskFlags;
    napi_create_array_with_length(env, cert.riskFlags.size(), &riskFlags);
    for (size_t index = 0; index < cert.riskFlags.size(); ++index) {
        napi_value flag;
        napi_create_string_utf8(env, cert.riskFlags[index].c_str(), NAPI_AUTO_LENGTH, &flag);
        napi_set_element(env, riskFlags, static_cast<uint32_t>(index), flag);
    }
    napi_set_named_property(env, result, "riskFlags", riskFlags);
    return result;
}

static napi_value CreateRdpCertificateRecordValue(
    napi_env env, const RdpCertificateRecord& cert) {
    napi_value result;
    napi_create_object(env, &result);
    SetObjectBool(env, result, "present", cert.present);
    SetObjectBool(env, result, "rootTrusted", cert.rootTrusted);
    SetObjectBool(env, result, "hostMismatch", cert.hostMismatch);
    SetObjectInt32(env, result, "flags", cert.flags);
    SetObjectString(env, result, "host", cert.host);
    SetObjectInt32(env, result, "port", cert.port);
    SetObjectString(env, result, "stage", cert.stage);
    SetObjectString(env, result, "serverName", cert.serverName);
    SetObjectString(env, result, "commonName", cert.commonName);
    SetObjectString(env, result, "subject", cert.subject);
    SetObjectString(env, result, "issuer", cert.issuer);
    SetObjectString(env, result, "fingerprintSha256", cert.fingerprintSha256);
    SetObjectInt64(env, result, "notBeforeMs", cert.notBeforeMs);
    SetObjectInt64(env, result, "notAfterMs", cert.notAfterMs);
    napi_value riskFlags;
    napi_create_array_with_length(env, cert.riskFlags.size(), &riskFlags);
    for (size_t index = 0; index < cert.riskFlags.size(); ++index) {
        napi_value flag;
        napi_create_string_utf8(env, cert.riskFlags[index].c_str(), NAPI_AUTO_LENGTH, &flag);
        napi_set_element(env, riskFlags, static_cast<uint32_t>(index), flag);
    }
    napi_set_named_property(env, result, "riskFlags", riskFlags);
    return result;
}

static napi_value CreateRdpPreflightResultValue(
    napi_env env, const RdpPreflightResult& preflight) {
    napi_value result;
    napi_create_object(env, &result);
    SetObjectBool(env, result, "ok", preflight.ok);
    SetObjectString(env, result, "preflightStatus", preflight.preflightStatus);
    SetObjectString(env, result, "endpointMode",
                    RdpGatewayPolicy::endpointModeName(preflight.endpointMode));
    SetObjectString(env, result, "routeIdentity", preflight.routeIdentity);
    SetObjectInt64(env, result, "generation", static_cast<int64_t>(preflight.generation));
    SetObjectString(env, result, "requestId", preflight.requestId);
    SetObjectString(env, result, "stage", preflight.stage);
    SetObjectString(env, result, "errorCode", preflight.errorCode);
    SetObjectString(env, result, "errorMessage", preflight.errorMessage);
    SetObjectString(env, result, "gatewayTransportRequested",
                    preflight.gatewayTransportRequested);
    SetObjectString(env, result, "gatewayTransportNegotiated",
                    preflight.gatewayTransportNegotiated);
    SetObjectString(env, result, "gatewayTransportSelected", preflight.gatewayTransportSelected);
    SetObjectBool(env, result, "requiresGatewayAuth", preflight.requiresGatewayAuth);
    SetObjectBool(env, result, "requiresUserDecision", preflight.requiresUserDecision);
    auto setRiskArray = [&](const char* key, const std::vector<std::string>& flags) {
        napi_value array;
        napi_create_array_with_length(env, flags.size(), &array);
        for (size_t index = 0; index < flags.size(); ++index) {
            napi_value flag;
            napi_create_string_utf8(env, flags[index].c_str(), NAPI_AUTO_LENGTH, &flag);
            napi_set_element(env, array, static_cast<uint32_t>(index), flag);
        }
        napi_set_named_property(env, result, key, array);
    };
    setRiskArray("riskFlags", preflight.riskFlags);
    setRiskArray("gatewayRiskFlags", preflight.gatewayRiskFlags);
    setRiskArray("targetRiskFlags", preflight.targetRiskFlags);
    napi_value gatewayCertificate = CreateRdpCertificateRecordValue(
        env, preflight.gatewayCertificate);
    napi_value targetCertificate = CreateRdpCertificateRecordValue(
        env, preflight.targetCertificate);
    napi_set_named_property(env, result, "gatewayCertificate", gatewayCertificate);
    napi_set_named_property(env, result, "targetCertificate", targetCertificate);
    return result;
}

static bool ReadNapiNamedInt64(
    napi_env env, napi_value object, const char* name,
    int64_t& out, bool required) {
    napi_value value;
    if (napi_get_named_property(env, object, name, &value) != napi_ok) {
        return !required;
    }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok) {
        return false;
    }
    if (type == napi_undefined || type == napi_null) {
        return !required;
    }
    return type == napi_number && ReadStrictNapiInt64Value(env, value, out);
}

static bool ReadRdpPreflightRequest(
    napi_env env, napi_value value, RdpPreflightRequest& request,
    std::string& errorMessage) {
    napi_valuetype type = napi_undefined;
    bool isArray = false;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_object ||
        napi_is_array(env, value, &isArray) != napi_ok || isArray) {
        errorMessage = "RDP preflight request must be an object";
        return false;
    }

    napi_value routeValue = value;
    napi_value nestedRoute;
    if (napi_get_named_property(env, value, "route", &nestedRoute) == napi_ok &&
        napi_typeof(env, nestedRoute, &type) == napi_ok && type == napi_object &&
        napi_is_array(env, nestedRoute, &isArray) == napi_ok && !isArray) {
        routeValue = nestedRoute;
    }

    int32_t targetPort = 3389;
    int32_t gatewayPort = 443;
    std::string endpointMode;
    std::string gatewayTransport;
    if (!ReadNapiNamedString(env, routeValue, "targetHost",
                             request.route.targetHost, true,
                             remotedesk::endpoint::kMaxInputLength) ||
        !ReadNapiNamedInt32(env, routeValue, "targetPort", targetPort, false) ||
        !ReadNapiNamedString(env, routeValue, "targetServerName",
                             request.route.targetServerName, false,
                             remotedesk::endpoint::kMaxInputLength) ||
        !ReadNapiNamedString(env, routeValue, "endpointMode", endpointMode, false, 64) ||
        !ReadNapiNamedString(env, routeValue, "gatewayHost",
                             request.route.gatewayHost, false,
                             remotedesk::endpoint::kMaxInputLength) ||
        !ReadNapiNamedInt32(env, routeValue, "gatewayPort", gatewayPort, false) ||
        !ReadNapiNamedString(env, routeValue, "gatewayServerName",
                             request.route.gatewayServerName, false,
                             remotedesk::endpoint::kMaxInputLength) ||
        !ReadNapiNamedString(env, routeValue, "gatewayTransport",
                             gatewayTransport, false, 64)) {
        errorMessage = "RDP preflight route contains an invalid field";
        return false;
    }

    // Preserve the legacy handoff rule only at this explicit boundary. Once
    // parsed, the adapter sees a concrete route and cannot guess from a port.
    if (endpointMode.empty()) {
        endpointMode = request.route.gatewayHost.empty() ? "direct_rdp" :
            "microsoft_rd_gateway";
    }
    if (!RdpGatewayPolicy::parseEndpointMode(endpointMode, request.route.endpointMode)) {
        errorMessage = "RDP preflight endpointMode is unknown";
        return false;
    }
    if (gatewayTransport.empty()) {
        gatewayTransport = "auto";
    }
    if (!RdpGatewayPolicy::parseGatewayTransport(
            gatewayTransport, request.route.gatewayTransport)) {
        errorMessage = "RDP preflight gatewayTransport is unknown";
        return false;
    }
    request.route.targetPort = targetPort;
    request.route.gatewayPort = gatewayPort;
    if (!NormalizePersistedEndpoint(request.route.targetHost, targetPort) ||
        (!request.route.gatewayHost.empty() &&
         !NormalizePersistedEndpoint(request.route.gatewayHost, gatewayPort))) {
        errorMessage = "RDP preflight endpoint is invalid or uses unsupported scope";
        return false;
    }
    if (request.route.targetServerName.empty()) {
        request.route.targetServerName = request.route.targetHost;
    }
    if (request.route.gatewayServerName.empty()) {
        request.route.gatewayServerName = request.route.gatewayHost;
    }
    if (!NormalizeServerIdentity(request.route.targetServerName) ||
        (!request.route.gatewayServerName.empty() &&
         !NormalizeServerIdentity(request.route.gatewayServerName))) {
        errorMessage = "RDP preflight server identity is invalid";
        return false;
    }

    if (!ReadNapiNamedString(env, value, "username", request.username, false) ||
        !ReadNapiNamedString(env, value, "password", request.password, false) ||
        !ReadNapiNamedString(env, value, "domain", request.domain, false) ||
        !ReadNapiNamedBool(env, value, "targetRestrictedAdmin",
                           request.targetRestrictedAdmin, false) ||
        !ReadNapiNamedString(env, value, "expectedTargetFingerprintSha256",
                             request.expectedTargetFingerprintSha256, false) ||
        !ReadNapiNamedString(env, value, "expectedGatewayFingerprintSha256",
                             request.expectedGatewayFingerprintSha256, false) ||
        !ReadNapiNamedBool(env, value, "targetAllowUntrustedRoot",
                           request.targetAllowUntrustedRoot, false) ||
        !ReadNapiNamedBool(env, value, "targetAllowHostMismatch",
                           request.targetAllowHostMismatch, false) ||
        !ReadNapiNamedBool(env, value, "targetAllowTimeAnomaly",
                           request.targetAllowTimeAnomaly, false) ||
        !ReadNapiNamedBool(env, value, "gatewayAllowUntrustedRoot",
                           request.gatewayAllowUntrustedRoot, false) ||
        !ReadNapiNamedBool(env, value, "gatewayAllowHostMismatch",
                           request.gatewayAllowHostMismatch, false) ||
        !ReadNapiNamedBool(env, value, "gatewayAllowTimeAnomaly",
                           request.gatewayAllowTimeAnomaly, false) ||
        !ReadNapiNamedString(env, value, "requestId", request.requestId, false)) {
        errorMessage = "RDP preflight trust fields are invalid";
        return false;
    }
    int64_t generation = 0;
    if (!ReadNapiNamedInt64(env, value, "generation", generation, false) || generation < 0) {
        errorMessage = "RDP preflight generation is invalid";
        return false;
    }
    request.generation = static_cast<uint64_t>(generation);
    return true;
}

static napi_value CreateVncCertificateInfoValue(napi_env env, const VncCertificateInfo& cert) {
    napi_value result;
    napi_create_object(env, &result);
    SetObjectBool(env, result, "ok", cert.ok);
    SetObjectString(env, result, "host", cert.host);
    SetObjectInt32(env, result, "port", cert.port);
    SetObjectString(env, result, "serverName", cert.serverName);
    SetObjectString(env, result, "fingerprintSha256", cert.fingerprintSha256);
    SetObjectString(env, result, "commonName", cert.commonName);
    SetObjectString(env, result, "subject", cert.subject);
    SetObjectString(env, result, "issuer", cert.issuer);
    SetObjectInt64(env, result, "notBeforeMs", cert.notBeforeMs);
    SetObjectInt64(env, result, "notAfterMs", cert.notAfterMs);
    SetObjectBool(env, result, "rootTrusted", cert.rootTrusted);
    SetObjectBool(env, result, "hostMismatch", cert.hostMismatch);
    SetObjectString(env, result, "tlsVersion", cert.tlsVersion);
    SetObjectString(env, result, "cipherCategory", cert.cipherCategory);
    SetObjectInt32(env, result, "errorCode", cert.errorCode);
    SetObjectString(env, result, "errorMessageCategory", cert.errorMessageCategory);
    SetObjectString(env, result, "errorMessage", cert.errorMessage);
    return result;
}

struct VncGatewayDeepHealthResult {
    VncGatewayDeepHealthResult() = default;
    VncGatewayDeepHealthResult(std::string stageValue, std::string codeValue,
                               std::string messageValue, bool ready)
        : stage(std::move(stageValue)), code(std::move(codeValue)),
          message(std::move(messageValue)), protocolReady(ready) {}
    std::string stage = "FAILED";
    std::string code = "E-VNC-GATEWAY-DEEP";
    std::string message = "VNC Gateway 深度检查失败";
    bool protocolReady = false;
    std::string certificateFingerprintSha256;
    std::string ownerType;
    std::string ownerId;
    std::string userId;
    std::string storeIdentityFingerprint;
    std::string endpointBindingFingerprint;
    int64_t accountGeneration = 0;
};

static napi_value CreateVncGatewayDeepHealthValue(
    napi_env env, const VncGatewayDeepHealthResult& result) {
    napi_value value;
    napi_create_object(env, &value);
    SetObjectString(env, value, "stage", result.stage);
    SetObjectString(env, value, "code", result.code);
    SetObjectString(env, value, "message", result.message);
    SetObjectBool(env, value, "protocolReady", result.protocolReady);
    SetObjectString(env, value, "certificateFingerprintSha256", result.certificateFingerprintSha256);
    SetObjectString(env, value, "ownerType", result.ownerType);
    SetObjectString(env, value, "ownerId", result.ownerId);
    SetObjectString(env, value, "userId", result.userId);
    SetObjectString(env, value, "storeIdentityFingerprint", result.storeIdentityFingerprint);
    SetObjectString(env, value, "endpointBindingFingerprint", result.endpointBindingFingerprint);
    SetObjectInt64(env, value, "accountGeneration", result.accountGeneration);
    return value;
}

static std::shared_ptr<VncCertificateProbeEnvironmentState>
GetVncCertificateProbeEnvironmentState(napi_env env) {
    std::lock_guard<std::mutex> lock(g_vncCertificateProbeMutex);
    auto it = g_vncCertificateProbeEnvironments.find(env);
    if (it != g_vncCertificateProbeEnvironments.end()) {
        return it->second;
    }
    auto state = std::make_shared<VncCertificateProbeEnvironmentState>();
    g_vncCertificateProbeEnvironments.emplace(env, state);
    return state;
}

// g_vncCertificateProbeMutex must be held by the caller. If the final work
// completes during environment teardown, the caller removes the async
// cleanup hook after releasing the registry lock.
static void RemoveVncCertificateProbeTokenLocked(
    uint64_t requestId, napi_async_cleanup_hook_handle& cleanupHandleToRemove) {
    cleanupHandleToRemove = nullptr;
    std::shared_ptr<VncCertificateProbeEnvironmentState> state;
    napi_env env = nullptr;
    auto it = g_vncCertificateProbeTokens.find(requestId);
    if (it == g_vncCertificateProbeTokens.end()) {
        return;
    }
    state = it->second.environmentState;
    env = it->second.env;
    g_vncCertificateProbeTokens.erase(it);
    if (state != nullptr) {
        std::lock_guard<std::mutex> stateLock(state->mutex);
        if (state->activeWorks > 0) {
            --state->activeWorks;
        }
        if (state->closing && state->activeWorks == 0) {
            if (state->cleanupHookRegistered && !state->cleanupHookRemoved &&
                state->cleanupHandle != nullptr) {
                state->cleanupHookRemoved = true;
                cleanupHandleToRemove = state->cleanupHandle;
            }
            auto environment = g_vncCertificateProbeEnvironments.find(env);
            if (environment != g_vncCertificateProbeEnvironments.end() &&
                environment->second == state) {
                g_vncCertificateProbeEnvironments.erase(environment);
            }
        }
    }
}

static void RemoveVncCertificateProbeToken(uint64_t requestId) {
    napi_async_cleanup_hook_handle cleanupHandle = nullptr;
    {
        std::lock_guard<std::mutex> registryLock(g_vncCertificateProbeMutex);
        RemoveVncCertificateProbeTokenLocked(requestId, cleanupHandle);
    }
    if (cleanupHandle != nullptr) {
        (void)napi_remove_async_cleanup_hook(cleanupHandle);
    }
}

static void CancelVncCertificateProbesForEnvironment(
    napi_async_cleanup_hook_handle handle, void* rawState) {
    napi_async_cleanup_hook_handle cleanupHandle = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_vncCertificateProbeMutex);
        std::shared_ptr<VncCertificateProbeEnvironmentState> state;
        for (const auto& entry : g_vncCertificateProbeEnvironments) {
            if (entry.second.get() == rawState) {
                state = entry.second;
                break;
            }
        }
        if (state == nullptr) {
            // The state may already have been retired by the final completion
            // callback. The runtime still expects this hook handle to close.
            cleanupHandle = handle;
        } else {
            bool activeZero = false;
            {
                std::lock_guard<std::mutex> stateLock(state->mutex);
                state->closing = true;
                state->cleanupHandle = handle;
                state->cleanupHookRegistered = true;
                activeZero = state->activeWorks == 0;
                if (activeZero && !state->cleanupHookRemoved) {
                    state->cleanupHookRemoved = true;
                    cleanupHandle = handle;
                }
            }
            for (const auto& entry : g_vncCertificateProbeTokens) {
                if (entry.second.environmentState != state) {
                    continue;
                }
                if (entry.second.cancelled) {
                    entry.second.cancelled->store(true, std::memory_order_release);
                }
            }
            if (activeZero) {
                for (auto environment = g_vncCertificateProbeEnvironments.begin();
                     environment != g_vncCertificateProbeEnvironments.end();) {
                    if (environment->second == state) {
                        environment = g_vncCertificateProbeEnvironments.erase(environment);
                    } else {
                        ++environment;
                    }
                }
            }
        }
    }
    if (cleanupHandle != nullptr) {
        (void)napi_remove_async_cleanup_hook(cleanupHandle);
    }
}

// ============================================================
// NAPI 导出函数 (ArkTS 可见)
// ============================================================

/**
 * NAPI: listProtocols(): Array<{name: string, port: number, version: string}>
 *
 * 列出所有已注册的远程协议适配器
 */
napi_value NapiListProtocols(napi_env env, napi_callback_info /*info*/) {
    EnsureExtensionsLoaded();

    auto adapters = ExtensionSystem::instance().protocols.get("protocol");
    auto names = ExtensionSystem::instance().protocols.listNames("protocol");

    napi_value result;
    napi_create_array_with_length(env, names.size(), &result);

    for (size_t i = 0; i < names.size(); ++i) {
        auto adapter = ExtensionSystem::instance().protocols.getByName(
            "protocol", names[i]);

        napi_value item;
        napi_create_object(env, &item);

        // name
        napi_value nameVal;
        napi_create_string_utf8(env, names[i].c_str(), NAPI_AUTO_LENGTH, &nameVal);
        napi_set_named_property(env, item, "name", nameVal);

        // displayName (格式化显示名)
        std::string displayName;
        if (names[i] == "rdp") displayName = "RDP (远程桌面协议)";
        else if (names[i] == "rustdesk") displayName = "RustDesk (跨平台远程)";
        else displayName = names[i];
        napi_value dispVal;
        napi_create_string_utf8(env, displayName.c_str(), NAPI_AUTO_LENGTH, &dispVal);
        napi_set_named_property(env, item, "displayName", dispVal);

        // port
        int port = 3389;
        if (adapter) port = adapter->defaultPort();
        napi_value portVal;
        napi_create_int32(env, port, &portVal);
        napi_set_named_property(env, item, "port", portVal);

        // version
        std::string version = "1.0.0";
        if (adapter) version = adapter->protocolVersion();
        napi_value verVal;
        napi_create_string_utf8(env, version.c_str(), NAPI_AUTO_LENGTH, &verVal);
        napi_set_named_property(env, item, "version", verVal);

        napi_set_element(env, result, i, item);
    }

    OH_LOG_INFO(LOG_APP, "[ExtLoader] listProtocols: %{public}zu 个协议", names.size());
    return result;
}

/**
 * NAPI: probeRdpCertificate(host: string, port: number, serverName: string): RdpCertificateInfo
 */
napi_value NapiProbeRdpCertificate(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string host;
    int32_t port = 3389;
    std::string serverName;
    const bool validHost = argc > 0 && ReadBoundedNapiStringValue(
        env, args[0], remotedesk::endpoint::kMaxInputLength, host);
    const bool validPort = argc <= 1 || ReadStrictNapiInt32Value(env, args[1], port);
    const bool validServerName = argc <= 2 || ReadBoundedNapiStringValue(
        env, args[2], remotedesk::endpoint::kMaxInputLength, serverName);
    if (!validHost || !validPort || !validServerName ||
        !NormalizePersistedEndpoint(host, port) ||
        (!serverName.empty() && !NormalizeServerIdentity(serverName))) {
        napi_throw_type_error(env, nullptr, "RDP certificate endpoint is invalid or unsupported");
        return nullptr;
    }

    auto adapter = FindAdapter("rdp");
    RdpCertificateInfo cert;
    if (adapter) {
        cert = adapter->probeRdpCertificate(host, port, serverName);
    } else {
        cert.host = host;
        cert.port = port;
        cert.errorCode = -1;
        cert.errorMessage = "RDP adapter is not available";
    }

    return CreateRdpCertificateInfoValue(env, cert);
}

struct RdpCertificateProbeAsyncData {
    std::string host;
    int32_t port = 3389;
    std::string serverName;
    std::shared_ptr<ProtocolAdapter> adapter;
    RdpCertificateInfo result;
    std::string errorMessage;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
    bool workerFailed = false;
};

static void ExecuteRdpCertificateProbeAsync(napi_env /*env*/, void* rawData) {
    auto* data = static_cast<RdpCertificateProbeAsyncData*>(rawData);
    if (data == nullptr || !data->adapter) {
        if (data != nullptr) {
            data->result.host = data->host;
            data->result.port = data->port;
            data->result.errorCode = -1;
            data->result.errorMessage = "RDP adapter is not available";
        }
        return;
    }

    try {
        // execute 回调只访问 C++ 数据；禁止在此线程调用任何 NAPI API。
        data->result = data->adapter->probeRdpCertificate(data->host, data->port, data->serverName);
    } catch (const std::exception& ex) {
        data->workerFailed = true;
        data->errorMessage = std::string("RDP certificate probe failed: ") + ex.what();
    } catch (...) {
        data->workerFailed = true;
        data->errorMessage = "RDP certificate probe failed: unknown native exception";
    }
}

static void CompleteRdpCertificateProbeAsync(napi_env env, napi_status status, void* rawData) {
    auto* data = static_cast<RdpCertificateProbeAsyncData*>(rawData);
    if (data == nullptr) {
        return;
    }

    if (status != napi_ok || data->workerFailed) {
        napi_value error;
        const std::string message = data->errorMessage.empty()
            ? "RDP certificate probe async work failed"
            : data->errorMessage;
        napi_create_string_utf8(env, message.c_str(), NAPI_AUTO_LENGTH, &error);
        napi_reject_deferred(env, data->deferred, error);
        OH_LOG_ERROR(LOG_APP, "[RDP-CERT-ASYNC] complete failed status=%{public}d", status);
    } else {
        napi_value result = CreateRdpCertificateInfoValue(env, data->result);
        napi_resolve_deferred(env, data->deferred, result);
        OH_LOG_INFO(LOG_APP, "[RDP-CERT-ASYNC] complete host=%{public}s", data->host.c_str());
    }

    napi_delete_async_work(env, data->work);
    delete data;
}

/**
 * NAPI: probeRdpCertificateAsync(host: string, port: number, serverName: string): Promise<RdpCertificateInfo>
 *
 * DNS/TCP/TLS 探测在 N-API worker 线程执行，避免阻塞 ArkTS/UI 线程。
 */
napi_value NapiProbeRdpCertificateAsync(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    auto* data = new (std::nothrow) RdpCertificateProbeAsyncData();
    if (data == nullptr) {
        napi_throw_error(env, nullptr, "RDP certificate async allocation failed");
        return nullptr;
    }

    const bool validHost = argc > 0 && ReadBoundedNapiStringValue(
        env, args[0], remotedesk::endpoint::kMaxInputLength, data->host);
    const bool validPort = argc <= 1 ||
        ReadStrictNapiInt32Value(env, args[1], data->port);
    const bool validServerName = argc <= 2 || ReadBoundedNapiStringValue(
        env, args[2], remotedesk::endpoint::kMaxInputLength, data->serverName);
    if (!validHost || !validPort || !validServerName ||
        !NormalizePersistedEndpoint(data->host, data->port) ||
        (!data->serverName.empty() && !NormalizeServerIdentity(data->serverName))) {
        delete data;
        napi_throw_error(env, nullptr, "RDP certificate endpoint is invalid or unsupported");
        return nullptr;
    }
    data->adapter = FindAdapter("rdp");

    napi_value promise;
    napi_status status = napi_create_promise(env, &data->deferred, &promise);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "RDP certificate async promise creation failed");
        return nullptr;
    }

    napi_value resourceName;
    status = napi_create_string_utf8(env, "RdpCertificateProbeAsync", NAPI_AUTO_LENGTH, &resourceName);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "RDP certificate async resource creation failed");
        return nullptr;
    }

    status = napi_create_async_work(env, resourceName, resourceName,
        ExecuteRdpCertificateProbeAsync, CompleteRdpCertificateProbeAsync, data, &data->work);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "RDP certificate async work creation failed");
        return nullptr;
    }

    OH_LOG_INFO(LOG_APP, "[RDP-CERT-ASYNC] queued host=%{public}s port=%{public}d",
        data->host.c_str(), data->port);
    status = napi_queue_async_work(env, data->work);
    if (status != napi_ok) {
        napi_delete_async_work(env, data->work);
        delete data;
        napi_throw_error(env, nullptr, "RDP certificate async work queue failed");
        return nullptr;
    }

    return promise;
}

struct RdpPreflightRouteProbeAsyncData {
    RdpPreflightRequest request;
    std::shared_ptr<ProtocolAdapter> adapter;
    RdpPreflightResult result;
    std::string errorMessage;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
    bool workerFailed = false;
};

static void ExecuteRdpPreflightRouteProbeAsync(napi_env /*env*/, void* rawData) {
    auto* data = static_cast<RdpPreflightRouteProbeAsyncData*>(rawData);
    if (!data) {
        return;
    }
    try {
        if (!data->adapter) {
            data->result.endpointMode = data->request.route.endpointMode;
            data->result.routeIdentity = RdpGatewayPolicy::routeIdentity(data->request.route);
            data->result.generation = data->request.generation;
            data->result.requestId = data->request.requestId;
            data->result.stage = "endpoint";
            data->result.errorCode = "E-RDP-ADAPTER";
            data->result.errorMessage = "RDP adapter is not available";
            RdpGatewayPolicy::initializeGatewayTransportResult(
                data->result, data->request.route.gatewayTransport);
            return;
        }
        data->result = data->adapter->probeRdpCertificateRoute(data->request);
    } catch (const std::exception& ex) {
        data->workerFailed = true;
        data->errorMessage = std::string("RDP route preflight failed: ") + ex.what();
    } catch (...) {
        data->workerFailed = true;
        data->errorMessage = "RDP route preflight failed: unknown native exception";
    }
}

static void CompleteRdpPreflightRouteProbeAsync(
    napi_env env, napi_status status, void* rawData) {
    auto* data = static_cast<RdpPreflightRouteProbeAsyncData*>(rawData);
    if (!data) {
        return;
    }
    if (status != napi_ok || data->workerFailed) {
        napi_value error;
        const std::string message = data->errorMessage.empty()
            ? "RDP route preflight async work failed" : data->errorMessage;
        napi_create_string_utf8(env, message.c_str(), NAPI_AUTO_LENGTH, &error);
        napi_reject_deferred(env, data->deferred, error);
        OH_LOG_ERROR(LOG_APP,
                     "[RDP-PREFLIGHT-ASYNC] complete failed status=%{public}d", status);
    } else {
        napi_value result = CreateRdpPreflightResultValue(env, data->result);
        napi_resolve_deferred(env, data->deferred, result);
        OH_LOG_INFO(LOG_APP,
                    "[RDP-PREFLIGHT-ASYNC] complete stage=%{public}s ok=%{public}s",
                    data->result.stage.c_str(), data->result.ok ? "true" : "false");
    }
    napi_delete_async_work(env, data->work);
    delete data;
}

/**
 * NAPI: probeRdpCertificateRouteAsync(request): Promise<RdpPreflightResult>
 *
 * The request carries the complete route. Gateway callers must not use the
 * legacy three-argument direct-RDP probe.
 */
napi_value NapiProbeRdpCertificateRouteAsync(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, "E-RDP-PREFLIGHT-REQUEST",
                              "RDP route preflight request is required");
        return nullptr;
    }

    auto* data = new (std::nothrow) RdpPreflightRouteProbeAsyncData();
    if (!data) {
        napi_throw_error(env, nullptr, "RDP route preflight async allocation failed");
        return nullptr;
    }
    std::string parseError;
    if (!ReadRdpPreflightRequest(env, args[0], data->request, parseError)) {
        delete data;
        napi_throw_type_error(env, "E-RDP-PREFLIGHT-REQUEST", parseError.c_str());
        return nullptr;
    }
    data->adapter = FindAdapter("rdp");

    napi_value promise;
    napi_status status = napi_create_promise(env, &data->deferred, &promise);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "RDP route preflight promise creation failed");
        return nullptr;
    }
    napi_value resourceName;
    status = napi_create_string_utf8(env, "RdpPreflightRouteProbeAsync",
                                     NAPI_AUTO_LENGTH, &resourceName);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "RDP route preflight resource creation failed");
        return nullptr;
    }
    status = napi_create_async_work(env, resourceName, resourceName,
        ExecuteRdpPreflightRouteProbeAsync, CompleteRdpPreflightRouteProbeAsync,
        data, &data->work);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "RDP route preflight work creation failed");
        return nullptr;
    }
    status = napi_queue_async_work(env, data->work);
    if (status != napi_ok) {
        napi_delete_async_work(env, data->work);
        delete data;
        napi_throw_error(env, nullptr, "RDP route preflight work queue failed");
        return nullptr;
    }
    return promise;
}

struct RustDeskPresenceProbeAsyncData {
    std::string host;
    int32_t port = 21116;
    std::string serverKey;
    std::string peerId;
    std::string token;
    bool direct = false;
    int32_t keyMode = 1;
    RustDeskPresenceResult result;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

static void ExecuteRustDeskPresenceProbeAsync(napi_env /*env*/, void* rawData) {
    auto* data = static_cast<RustDeskPresenceProbeAsyncData*>(rawData);
    if (data == nullptr) {
        return;
    }
    RustDeskFfiConfig config = {};
    config.host = data->host.c_str();
    config.port = data->port;
    config.key = data->serverKey.c_str();
    config.username = data->peerId.c_str();
    config.token = data->token.c_str();
    config.direct_connection = data->direct;
    config.key_mode = data->keyMode;
#ifdef RUSTDESK_USE_REAL_CORE
    if (!rustdesk_probe_presence(&config, &data->result)) {
        data->result.state = 0;
        data->result.latencyMs = -1;
        data->result.errorCode = 5;
    }
#else
    data->result.state = 0;
    data->result.latencyMs = -1;
    data->result.errorCode = 5;
#endif
}

static napi_value CreateRustDeskPresenceResultValue(
    napi_env env, const RustDeskPresenceResult& value) {
    napi_value result;
    napi_create_object(env, &result);
    SetObjectInt32(env, result, "state", value.state);
    SetObjectInt32(env, result, "latencyMs", value.latencyMs);
    SetObjectInt32(env, result, "errorCode", value.errorCode);
    return result;
}

static void CompleteRustDeskPresenceProbeAsync(
    napi_env env, napi_status /*status*/, void* rawData) {
    auto* data = static_cast<RustDeskPresenceProbeAsyncData*>(rawData);
    if (data == nullptr) {
        return;
    }
    napi_value result = CreateRustDeskPresenceResultValue(env, data->result);
    napi_resolve_deferred(env, data->deferred, result);
    napi_delete_async_work(env, data->work);
    delete data;
}

/** NAPI: probeRustDeskPresenceAsync(host, port, key, peerId, token, direct, keyMode) */
napi_value NapiProbeRustDeskPresenceAsync(napi_env env, napi_callback_info info) {
    size_t argc = 7;
    napi_value args[7] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto* data = new (std::nothrow) RustDeskPresenceProbeAsyncData();
    if (data == nullptr) {
        napi_throw_error(env, nullptr, "RustDesk presence probe allocation failed");
        return nullptr;
    }
    const bool validHost = argc > 0 && ReadBoundedNapiStringValue(
        env, args[0], remotedesk::endpoint::kMaxInputLength, data->host);
    const bool validPort = argc <= 1 ||
        ReadStrictNapiInt32Value(env, args[1], data->port);
    const bool validKey = argc <= 2 ||
        ReadBoundedNapiStringValue(env, args[2], 4096, data->serverKey);
    const bool validPeerId = argc <= 3 ||
        ReadBoundedNapiStringValue(env, args[3], 512, data->peerId);
    const bool validToken = argc <= 4 ||
        ReadBoundedNapiStringValue(env, args[4], 64 * 1024, data->token);
    const bool validDirect = argc <= 5 ||
        napi_get_value_bool(env, args[5], &data->direct) == napi_ok;
    const bool validKeyMode = argc <= 6 ||
        ReadStrictNapiInt32Value(env, args[6], data->keyMode);
    if (!validHost || !validPort || !validKey || !validPeerId || !validToken ||
        !validDirect || !validKeyMode ||
        !NormalizePersistedEndpoint(data->host, data->port)) {
        delete data;
        napi_throw_error(env, nullptr,
                         "RustDesk presence endpoint is invalid or unsupported");
        return nullptr;
    }

    napi_value promise;
    napi_status status = napi_create_promise(env, &data->deferred, &promise);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "RustDesk presence probe promise creation failed");
        return nullptr;
    }
    napi_value resource;
    status = napi_create_string_utf8(env, "RustDeskPresenceProbeAsync", NAPI_AUTO_LENGTH, &resource);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "RustDesk presence probe resource creation failed");
        return nullptr;
    }
    status = napi_create_async_work(env, resource, resource,
        ExecuteRustDeskPresenceProbeAsync, CompleteRustDeskPresenceProbeAsync,
        data, &data->work);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "RustDesk presence probe async work creation failed");
        return nullptr;
    }
    status = napi_queue_async_work(env, data->work);
    if (status != napi_ok) {
        napi_delete_async_work(env, data->work);
        delete data;
        napi_throw_error(env, nullptr, "RustDesk presence probe async work queue failed");
        return nullptr;
    }
    return promise;
}

struct VncCertificateProbeAsyncData {
    uint64_t requestId = 0;
    VncCertificateProbeConfig config;
    VncCertificateInfo result;
    std::shared_ptr<VncCertificateProbeEnvironmentState> environmentState;
    std::string errorMessage;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
    bool workerFailed = false;
};

static void ExecuteVncCertificateProbeAsync(napi_env /*env*/, void* rawData) {
    auto* data = static_cast<VncCertificateProbeAsyncData*>(rawData);
    if (data == nullptr) {
        return;
    }
    try {
        data->result = probeVncCertificate(data->config);
    } catch (const std::exception& ex) {
        data->workerFailed = true;
        data->errorMessage = ex.what();
    } catch (...) {
        data->workerFailed = true;
        data->errorMessage = "unknown native exception";
    }
}

static void CompleteVncCertificateProbeAsync(napi_env env, napi_status status, void* rawData) {
    auto* data = static_cast<VncCertificateProbeAsyncData*>(rawData);
    if (data == nullptr) {
        return;
    }
    if (status == napi_cancelled ||
        (data->config.cancelled && data->config.cancelled->load(std::memory_order_acquire))) {
        data->result.ok = false;
        data->result.errorCode = static_cast<int>(VncCertificateProbeErrorCode::Cancelled);
        data->result.errorMessageCategory = vncCertificateProbeErrorCategory(data->result.errorCode);
        data->result.errorMessage = vncCertificateProbeErrorMessage(data->result.errorCode);
    } else if (status != napi_ok || data->workerFailed) {
        data->result.ok = false;
        data->result.errorCode = static_cast<int>(VncCertificateProbeErrorCode::MetadataFailed);
        data->result.errorMessageCategory = vncCertificateProbeErrorCategory(data->result.errorCode);
        data->result.errorMessage = vncCertificateProbeErrorMessage(data->result.errorCode);
        OH_LOG_ERROR(LOG_APP, "[VNC-CERT-ASYNC] category=%{public}s status=%{public}d",
                     data->result.errorMessageCategory.c_str(), status);
    }
    bool closing = true;
    if (data->environmentState != nullptr) {
        // Serialize the closing decision with the cleanup hook. Once closing
        // is observed, no N-API value or Promise operation may touch env.
        std::unique_lock<std::mutex> lock(data->environmentState->mutex);
        closing = data->environmentState->closing;
        if (!closing && env != nullptr && data->deferred != nullptr) {
            napi_value result = CreateVncCertificateInfoValue(env, data->result);
            napi_resolve_deferred(env, data->deferred, result);
        }
    }
    // The completion callback owns the async-work handle until it is deleted.
    // Keep activeWorks > 0 across this call so the environment cleanup hook
    // cannot destroy env between the Promise operation and handle deletion.
    napi_async_cleanup_hook_handle cleanupHandle = nullptr;
    {
        // Keep handle deletion and registry removal under the same lock used
        // by cleanup cancellation. A cleanup hook can never cancel/delete a
        // handle after this callback has removed it from the registry.
        std::lock_guard<std::mutex> registryLock(g_vncCertificateProbeMutex);
        if (env != nullptr && data->work != nullptr) {
            napi_delete_async_work(env, data->work);
        }
        RemoveVncCertificateProbeTokenLocked(data->requestId, cleanupHandle);
    }
    if (cleanupHandle != nullptr) {
        (void)napi_remove_async_cleanup_hook(cleanupHandle);
    }
    delete data;
}

struct VncGatewayDeepAsyncData {
    uint64_t requestId = 0;
    VncTransportConfig config;
    std::shared_ptr<std::atomic_bool> cancelled;
    VncGatewayDeepHealthResult result;
    std::shared_ptr<VncCertificateProbeEnvironmentState> environmentState;
    bool workerFailed = false;
    std::string ownerType;
    std::string ownerId;
    std::string userId;
    std::string storeIdentityFingerprint;
    std::string endpointBindingFingerprint;
    int64_t accountGeneration = 0;
    bool enabled = false;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

static void CopyVncGatewayDeepBinding(VncGatewayDeepHealthResult& result,
                                      const VncGatewayDeepAsyncData& data) {
    result.ownerType = data.ownerType;
    result.ownerId = data.ownerId;
    result.userId = data.userId;
    result.storeIdentityFingerprint = data.storeIdentityFingerprint;
    result.endpointBindingFingerprint = data.endpointBindingFingerprint;
    result.accountGeneration = data.accountGeneration;
}

static std::string ExtractVncCertificateFingerprint(const std::string& error) {
    const char* markers[] = {"VNC_TRUST_REQUIRED:", "VNC_CERT_CHANGED:"};
    for (const char* marker : markers) {
        const size_t start = error.find(marker);
        if (start == std::string::npos) { continue; }
        const size_t valueStart = start + std::strlen(marker);
        const std::string value = error.substr(valueStart, 64);
        if (vncCertificateFingerprintIsCanonical(value)) { return value; }
    }
    return "";
}

static std::string ExtractVncCertificateErrorCode(const std::string& error) {
    const std::string prefix = "E-VNC-CERT-";
    const size_t start = error.find(prefix);
    if (start == std::string::npos) { return ""; }
    const size_t end = error.find_first_of("; \r\n", start);
    const std::string code = error.substr(start,
        end == std::string::npos ? std::string::npos : end - start);
    if (code.size() <= prefix.size() || code.size() > 96) { return ""; }
    for (size_t i = prefix.size(); i < code.size(); ++i) {
        const unsigned char c = static_cast<unsigned char>(code[i]);
        if (!(std::isdigit(c) || (c >= 'A' && c <= 'Z') || c == '-')) { return ""; }
    }
    return code;
}

static void ExecuteVncGatewayDeepAsync(napi_env /*env*/, void* rawData) {
    auto* data = static_cast<VncGatewayDeepAsyncData*>(rawData);
    if (data == nullptr) {
        return;
    }
    try {
        CopyVncGatewayDeepBinding(data->result, *data);
        if (!data->enabled || data->ownerType != "gateway" || data->ownerId.empty() ||
            data->userId.empty() ||
            !vncCertificateFingerprintIsCanonical(data->storeIdentityFingerprint) ||
            !vncCertificateFingerprintIsCanonical(data->endpointBindingFingerprint) ||
            data->accountGeneration <= 0) {
            data->result = {"FAILED", "E-VNC-GATEWAY-BINDING", "Gateway 绑定已失效", false};
            CopyVncGatewayDeepBinding(data->result, *data);
            return;
        }
        if (data->config.transport != "ultravnc_repeater") {
            data->result = {"FAILED", "E-VNC-GATEWAY-TRANSPORT",
                            "当前仅支持 UltraVNC Repeater mode12", false};
            return;
        }
        if (data->config.repeaterMode != "mode12") {
            data->result = {"FAILED", "E-VNC-REPEATER-MODE2-ROLE",
                            "mode2 是服务端监听角色，不能作为 Viewer 深度测试", false};
            return;
        }
        std::array<uint8_t, VncRfbProtocol::kUltraVncRepeaterFieldBytes> targetField {};
        std::string validationError;
        if (!VncRfbProtocol::buildRepeaterTargetField(
                data->config.repeaterTarget, targetField, validationError)) {
            data->result = {"FAILED", "E-VNC-REPEATER-TARGET",
                            "深度测试 target 无效", false};
            return;
        }
        VncTransport transport;
        std::string error;
        if (!transport.connect(data->config, error)) {
            CopyVncGatewayDeepBinding(data->result, *data);
            data->result.certificateFingerprintSha256 = ExtractVncCertificateFingerprint(error);
            if (error.find("E-VNC-CERT-CANCELLED") != std::string::npos) {
                data->result = {"FAILED", "E-VNC-CERT-CANCELLED", "Gateway 深度检查已取消", false};
            } else if (error.find("E-VNC-CERT-TRUST-REQUIRED") != std::string::npos) {
                data->result = {"TLS_CERT_CONFIRMATION_REQUIRED", "E-VNC-CERT-TRUST-REQUIRED",
                                "TLS Gateway 需要先完成证书确认", false};
            } else if (error.find("E-VNC-CERT-CHANGED") != std::string::npos) {
                data->result = {"FAILED", "E-VNC-CERT-CHANGED",
                                "TLS Gateway 证书与已确认指纹不匹配", false};
            } else {
                const std::string code = ExtractVncCertificateErrorCode(error);
                if (!code.empty()) {
                    data->result = {"FAILED", code,
                                    "TLS Gateway 证书校验失败", false};
                } else if (error.find("banner") != std::string::npos) {
                    data->result = {"FAILED", "E-VNC-REPEATER-BANNER",
                                    "Repeater banner 无效或读取不完整", false};
                } else {
                    data->result = {"FAILED", "E-VNC-GATEWAY-DEEP", "Gateway 深度检查失败", false};
                }
            }
            CopyVncGatewayDeepBinding(data->result, *data);
            data->result.certificateFingerprintSha256 = ExtractVncCertificateFingerprint(error);
            transport.close();
            return;
        }
        std::array<uint8_t, VncRfbProtocol::kProtocolVersionBytes> banner {};
        if (!transport.readExact(banner.data(), banner.size(), data->config.connectTimeoutMs, error)) {
            const std::string certificateCode = ExtractVncCertificateErrorCode(error);
            const bool cancelled = certificateCode == "E-VNC-CERT-CANCELLED";
            data->result = {"FAILED", certificateCode.empty() ? "E-VNC-RFB-BANNER" : certificateCode,
                            cancelled ? "Gateway 深度检查已取消" :
                            (certificateCode.empty() ? "RFB banner 无效或读取超时" : "TLS Gateway 证书校验失败"), false};
            transport.close();
            return;
        }
        if (!VncRfbProtocol::protocolBannerIsSupported(banner.data(), banner.size())) {
            data->result = {"FAILED", "E-VNC-RFB-BANNER", "RFB banner 无效", false};
            transport.close();
            return;
        }
        data->result = {"RFB_BANNER_READY", "", "VNC 协议链路已验证", true};
        CopyVncGatewayDeepBinding(data->result, *data);
        transport.close();
    } catch (...) {
        data->workerFailed = true;
        data->result = {"FAILED", "E-VNC-GATEWAY-DEEP", "Gateway 深度检查失败", false};
        CopyVncGatewayDeepBinding(data->result, *data);
    }
}

static void CompleteVncGatewayDeepAsync(napi_env env, napi_status status, void* rawData) {
    auto* data = static_cast<VncGatewayDeepAsyncData*>(rawData);
    if (data == nullptr) {
        return;
    }
    if (status == napi_cancelled ||
        (data->cancelled && data->cancelled->load(std::memory_order_acquire))) {
        data->result = {"FAILED", "E-VNC-CERT-CANCELLED", "Gateway 深度检查已取消", false};
    } else if (status != napi_ok || data->workerFailed) {
        data->result = {"FAILED", "E-VNC-GATEWAY-DEEP", "Gateway 深度检查失败", false};
    }
    CopyVncGatewayDeepBinding(data->result, *data);
    bool closing = true;
    if (data->environmentState != nullptr) {
        std::unique_lock<std::mutex> lock(data->environmentState->mutex);
        closing = data->environmentState->closing;
        if (!closing && env != nullptr && data->deferred != nullptr) {
            napi_resolve_deferred(env, data->deferred,
                                  CreateVncGatewayDeepHealthValue(env, data->result));
        }
    }
    napi_async_cleanup_hook_handle cleanupHandle = nullptr;
    {
        std::lock_guard<std::mutex> registryLock(g_vncCertificateProbeMutex);
        if (env != nullptr && data->work != nullptr) {
            napi_delete_async_work(env, data->work);
        }
        RemoveVncCertificateProbeTokenLocked(data->requestId, cleanupHandle);
    }
    if (cleanupHandle != nullptr) {
        (void)napi_remove_async_cleanup_hook(cleanupHandle);
    }
    delete data;
}

/** NAPI: probeVncGatewayDeepAsync(host, port, transport, mode, target, tls, pin, timeoutMs,
 * ownerType, ownerId, userId, storeFingerprint, endpointBinding, accountGeneration, enabled). */
napi_value NapiProbeVncGatewayDeepAsync(napi_env env, napi_callback_info info) {
    size_t argc = 15;
    napi_value args[15];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto* data = new (std::nothrow) VncGatewayDeepAsyncData();
    if (data == nullptr) {
        napi_throw_error(env, nullptr, "VNC Gateway deep async allocation failed");
        return nullptr;
    }
    bool validInput = argc > 0 && ReadBoundedNapiStringValue(
        env, args[0], remotedesk::endpoint::kMaxInputLength, data->config.host);
    validInput = validInput && (argc <= 1 ||
        ReadStrictNapiInt32Value(env, args[1], data->config.port));
    validInput = validInput && (argc <= 2 ||
        ReadBoundedNapiStringValue(env, args[2], 64, data->config.transport));
    validInput = validInput && (argc <= 3 ||
        ReadBoundedNapiStringValue(env, args[3], 64, data->config.repeaterMode));
    validInput = validInput && (argc <= 4 || ReadBoundedNapiStringValue(
        env, args[4], 4096, data->config.repeaterTarget));
    validInput = validInput && (argc <= 5 ||
        napi_get_value_bool(env, args[5], &data->config.tls) == napi_ok);
    validInput = validInput && (argc <= 6 || ReadBoundedNapiStringValue(
        env, args[6], 256, data->config.expectedCertificateFingerprintSha256));
    validInput = validInput && (argc <= 7 ||
        ReadStrictNapiInt32Value(env, args[7], data->config.connectTimeoutMs));
    validInput = validInput && (argc <= 8 ||
        ReadBoundedNapiStringValue(env, args[8], 128, data->ownerType));
    validInput = validInput && (argc <= 9 ||
        ReadBoundedNapiStringValue(env, args[9], 512, data->ownerId));
    validInput = validInput && (argc <= 10 ||
        ReadBoundedNapiStringValue(env, args[10], 512, data->userId));
    validInput = validInput && (argc <= 11 || ReadBoundedNapiStringValue(
        env, args[11], 256, data->storeIdentityFingerprint));
    validInput = validInput && (argc <= 12 || ReadBoundedNapiStringValue(
        env, args[12], 256, data->endpointBindingFingerprint));
    validInput = validInput && (argc <= 13 ||
        napi_get_value_int64(env, args[13], &data->accountGeneration) == napi_ok);
    validInput = validInput && (argc <= 14 ||
        napi_get_value_bool(env, args[14], &data->enabled) == napi_ok);
    if (!validInput ||
        !NormalizePersistedEndpoint(data->config.host, data->config.port)) {
        delete data;
        napi_throw_error(env, nullptr, "VNC Gateway endpoint is invalid or unsupported");
        return nullptr;
    }
    data->config.serverName = data->config.host;
    data->cancelled = std::make_shared<std::atomic_bool>(false);
    data->config.cancelled = data->cancelled;
    data->environmentState = GetVncCertificateProbeEnvironmentState(env);
    data->requestId = g_nextVncCertificateProbeRequestId.fetch_add(1, std::memory_order_relaxed);
    if (data->requestId == 0) {
        data->requestId = g_nextVncCertificateProbeRequestId.fetch_add(1, std::memory_order_relaxed);
    }
    napi_value promise;
    napi_status status = napi_create_promise(env, &data->deferred, &promise);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "VNC Gateway deep promise creation failed");
        return nullptr;
    }
    napi_value requestIdValue;
    napi_create_int64(env, static_cast<int64_t>(data->requestId), &requestIdValue);
    napi_set_named_property(env, promise, "requestId", requestIdValue);
    napi_value resourceName;
    status = napi_create_string_utf8(env, "VncGatewayDeepAsync", NAPI_AUTO_LENGTH, &resourceName);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "VNC Gateway deep resource creation failed");
        return nullptr;
    }
    {
        std::unique_lock<std::mutex> registryLock(g_vncCertificateProbeMutex);
        std::unique_lock<std::mutex> stateLock(data->environmentState->mutex);
        if (data->environmentState->closing || !data->environmentState->cleanupHookRegistered) {
            stateLock.unlock();
            registryLock.unlock();
            delete data;
            napi_throw_error(env, nullptr, "VNC Gateway environment is closing");
            return nullptr;
        }
        ++data->environmentState->activeWorks;
        g_vncCertificateProbeTokens[data->requestId] =
            VncCertificateProbeRegistration {data->cancelled, data->environmentState, env, nullptr};
        stateLock.unlock();
        status = napi_create_async_work(env, resourceName, resourceName,
                                        ExecuteVncGatewayDeepAsync, CompleteVncGatewayDeepAsync,
                                        data, &data->work);
        if (status != napi_ok) {
            g_vncCertificateProbeTokens.erase(data->requestId);
            std::lock_guard<std::mutex> rollbackState(data->environmentState->mutex);
            --data->environmentState->activeWorks;
            registryLock.unlock();
            delete data;
            napi_throw_error(env, nullptr, "VNC Gateway deep work creation failed");
            return nullptr;
        }
        auto registration = g_vncCertificateProbeTokens.find(data->requestId);
        if (registration == g_vncCertificateProbeTokens.end()) {
            napi_delete_async_work(env, data->work);
            std::lock_guard<std::mutex> rollbackState(data->environmentState->mutex);
            --data->environmentState->activeWorks;
            registryLock.unlock();
            delete data;
            napi_throw_error(env, nullptr, "VNC Gateway deep admission failed");
            return nullptr;
        }
        registration->second.work = data->work;
        status = napi_queue_async_work(env, data->work);
        if (status != napi_ok) {
            napi_delete_async_work(env, data->work);
            g_vncCertificateProbeTokens.erase(registration);
            std::lock_guard<std::mutex> rollbackState(data->environmentState->mutex);
            --data->environmentState->activeWorks;
            registryLock.unlock();
            delete data;
            napi_throw_error(env, nullptr, "VNC Gateway deep work queue failed");
            return nullptr;
        }
    }
    return promise;
}

/**
 * NAPI: probeVncCertificateAsync(host, port, serverName, timeoutMs): Promise<VncCertificateInfo>
 *
 * The returned Promise carries a numeric requestId property so callers can
 * cancel the worker through cancelVncCertificateProbe without exposing a
 * native pointer or a mutable shared object to ArkTS.
 */
napi_value NapiProbeVncCertificateAsync(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    auto* data = new (std::nothrow) VncCertificateProbeAsyncData();
    if (data == nullptr) {
        napi_throw_error(env, nullptr, "VNC certificate async allocation failed");
        return nullptr;
    }
    const bool validHost = argc > 0 && ReadBoundedNapiStringValue(
        env, args[0], remotedesk::endpoint::kMaxInputLength, data->config.host);
    const bool validPort = argc <= 1 ||
        ReadStrictNapiInt32Value(env, args[1], data->config.port);
    const bool validServerName = argc <= 2 || ReadBoundedNapiStringValue(
        env, args[2], remotedesk::endpoint::kMaxInputLength, data->config.serverName);
    const bool validTimeout = argc <= 3 ||
        ReadStrictNapiInt32Value(env, args[3], data->config.timeoutMs);
    if (!validHost || !validPort || !validServerName || !validTimeout ||
        !NormalizePersistedEndpoint(data->config.host, data->config.port) ||
        (!data->config.serverName.empty() &&
         !NormalizeServerIdentity(data->config.serverName))) {
        delete data;
        napi_throw_error(env, nullptr, "VNC certificate endpoint is invalid or unsupported");
        return nullptr;
    }
    data->requestId = g_nextVncCertificateProbeRequestId.fetch_add(1, std::memory_order_relaxed);
    if (data->requestId == 0) {
        data->requestId = g_nextVncCertificateProbeRequestId.fetch_add(1, std::memory_order_relaxed);
    }
    data->config.cancelled = std::make_shared<std::atomic_bool>(false);
    data->environmentState = GetVncCertificateProbeEnvironmentState(env);

    napi_value promise;
    napi_status status = napi_create_promise(env, &data->deferred, &promise);
    if (status != napi_ok) {
        RemoveVncCertificateProbeToken(data->requestId);
        delete data;
        napi_throw_error(env, nullptr, "VNC certificate promise creation failed");
        return nullptr;
    }
    napi_value requestIdValue;
    napi_create_int64(env, static_cast<int64_t>(data->requestId), &requestIdValue);
    napi_set_named_property(env, promise, "requestId", requestIdValue);

    napi_value resourceName;
    status = napi_create_string_utf8(env, "VncCertificateProbeAsync", NAPI_AUTO_LENGTH, &resourceName);
    if (status != napi_ok) {
        RemoveVncCertificateProbeToken(data->requestId);
        delete data;
        napi_throw_error(env, nullptr, "VNC certificate resource creation failed");
        return nullptr;
    }
    const uint64_t requestId = data->requestId;
    const std::string logHost = data->config.host;
    const int logPort = data->config.port;
    {
        // Admission, token publication, work creation and queueing share one
        // registry lock. Cleanup therefore cannot observe an admitted request
        // before it has a real async-work handle to cancel.
        std::unique_lock<std::mutex> registryLock(g_vncCertificateProbeMutex);
        std::unique_lock<std::mutex> stateLock(data->environmentState->mutex);
        if (data->environmentState->closing ||
            !data->environmentState->cleanupHookRegistered) {
            stateLock.unlock();
            registryLock.unlock();
            delete data;
            napi_throw_error(env, nullptr, "VNC certificate environment is closing");
            return nullptr;
        }
        ++data->environmentState->activeWorks;
        g_vncCertificateProbeTokens[data->requestId] =
            VncCertificateProbeRegistration {data->config.cancelled, data->environmentState,
                                              env, nullptr};
        stateLock.unlock();

        status = napi_create_async_work(env, resourceName, resourceName,
            ExecuteVncCertificateProbeAsync, CompleteVncCertificateProbeAsync, data,
            &data->work);
        if (status != napi_ok) {
            g_vncCertificateProbeTokens.erase(data->requestId);
            std::lock_guard<std::mutex> rollbackState(data->environmentState->mutex);
            --data->environmentState->activeWorks;
            registryLock.unlock();
            delete data;
            napi_throw_error(env, nullptr, "VNC certificate async work creation failed");
            return nullptr;
        }
        auto registration = g_vncCertificateProbeTokens.find(data->requestId);
        if (registration == g_vncCertificateProbeTokens.end()) {
            napi_delete_async_work(env, data->work);
            std::lock_guard<std::mutex> rollbackState(data->environmentState->mutex);
            --data->environmentState->activeWorks;
            registryLock.unlock();
            delete data;
            napi_throw_error(env, nullptr, "VNC certificate async admission failed");
            return nullptr;
        }
        registration->second.work = data->work;
        status = napi_queue_async_work(env, data->work);
        if (status != napi_ok) {
            napi_delete_async_work(env, data->work);
            g_vncCertificateProbeTokens.erase(registration);
            std::lock_guard<std::mutex> rollbackState(data->environmentState->mutex);
            --data->environmentState->activeWorks;
            registryLock.unlock();
            delete data;
            napi_throw_error(env, nullptr, "VNC certificate async work queue failed");
            return nullptr;
        }
    }
    OH_LOG_INFO(LOG_APP, "[VNC-CERT-ASYNC] queued requestId=%{public}llu host=%{public}s port=%{public}d",
                static_cast<unsigned long long>(requestId),
                SafeLog::MaskHost(logHost).c_str(), logPort);
    return promise;
}

napi_value NapiCancelVncCertificateProbe(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t requestId = 0;
    if (argc > 0) {
        napi_get_value_int64(env, args[0], &requestId);
    }
    bool cancelled = false;
    if (requestId > 0) {
        std::lock_guard<std::mutex> lock(g_vncCertificateProbeMutex);
        auto it = g_vncCertificateProbeTokens.find(static_cast<uint64_t>(requestId));
        if (it != g_vncCertificateProbeTokens.end() && it->second.cancelled) {
            it->second.cancelled->store(true, std::memory_order_release);
            cancelled = true;
        }
    }
    napi_value result;
    napi_get_boolean(env, cancelled, &result);
    return result;
}

/**
 * NAPI: getRdpRenderStats(sessionId: number): RdpRenderStats
 */
napi_value NapiGetRdpRenderStats(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &sessionId);
    }

    RdpRenderStats stats;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter) {
        stats = it->second->adapter->getRdpRenderStats();
    }

    napi_value result;
    napi_create_object(env, &result);
    SetObjectInt32(env, result, "paintCount", stats.paintCount);
    SetObjectInt32(env, result, "renderedPaintCount", stats.renderedPaintCount);
    SetObjectInt64(env, result, "firstPaintMs", stats.firstPaintMs);
    SetObjectInt64(env, result, "lastPaintMs", stats.lastPaintMs);
    SetObjectInt64(env, result, "lastRemoteUpdateAgeMs", stats.lastRemoteUpdateAgeMs);
    SetObjectInt64(env, result, "eventLoopAgeMs", stats.eventLoopAgeMs);
    SetObjectInt64(env, result, "eventLoopBlockMaxUs", stats.eventLoopBlockMaxUs);
    SetObjectInt64(env, result, "lastInputPostAgeMs", stats.lastInputPostAgeMs);
    SetObjectInt64(env, result, "eventLoopTicks",
                   static_cast<int64_t>(stats.eventLoopTicks));
    SetObjectInt64(env, result, "networkCheckCount",
                   static_cast<int64_t>(stats.networkCheckCount));
    SetObjectInt64(env, result, "networkCheckFailures",
                   static_cast<int64_t>(stats.networkCheckFailures));
    SetObjectInt64(env, result, "inputPostFailures",
                   static_cast<int64_t>(stats.inputPostFailures));
    SetObjectInt32(env, result, "lastRenderResult", stats.lastRenderResult);
    SetObjectInt32(env, result, "skippedPaintCount", stats.skippedPaintCount);
    SetObjectInt32(env, result, "slowRenderCount", stats.slowRenderCount);
    SetObjectInt64(env, result, "minRenderIntervalUs", stats.minRenderIntervalUs);
    SetObjectInt64(env, result, "lastRenderCostUs", stats.lastRenderCostUs);
    SetObjectInt64(env, result, "lastRenderBytes", static_cast<int64_t>(stats.lastRenderBytes));
    SetObjectInt64(env, result, "pumpSubmitted", static_cast<int64_t>(stats.pumpSubmitted));
    SetObjectInt64(env, result, "pumpRendered", static_cast<int64_t>(stats.pumpRendered));
    SetObjectInt64(env, result, "pumpReplaced", static_cast<int64_t>(stats.pumpReplaced));
    SetObjectInt64(env, result, "pumpRejected", static_cast<int64_t>(stats.pumpRejected));
    SetObjectInt64(env, result, "invalidEvents", static_cast<int64_t>(stats.invalidEvents));
    SetObjectInt64(env, result, "invalidPixels", static_cast<int64_t>(stats.invalidPixels));
    SetObjectInt64(env, result, "copiedBytes", static_cast<int64_t>(stats.copiedBytes));
    SetObjectInt64(env, result, "presentationRejected",
                   static_cast<int64_t>(stats.presentationRejected));
    SetObjectInt64(env, result, "surfaceDetachedRejections",
                   static_cast<int64_t>(stats.surfaceDetachedRejections));
    SetObjectInt64(env, result, "generationRejections",
                   static_cast<int64_t>(stats.generationRejections));
    SetObjectInt64(env, result, "presentationWindowSamples",
                   static_cast<int64_t>(stats.presentationWindowSamples));
    SetObjectInt64(env, result, "callbackP50Us", stats.callbackP50Us);
    SetObjectInt64(env, result, "callbackP95Us", stats.callbackP95Us);
    SetObjectInt64(env, result, "callbackMaxUs", stats.callbackMaxUs);
    SetObjectInt64(env, result, "copyP50Us", stats.copyP50Us);
    SetObjectInt64(env, result, "copyP95Us", stats.copyP95Us);
    SetObjectInt64(env, result, "copyMaxUs", stats.copyMaxUs);
    SetObjectInt64(env, result, "queueP50Us", stats.queueP50Us);
    SetObjectInt64(env, result, "queueP95Us", stats.queueP95Us);
    SetObjectInt64(env, result, "queueMaxUs", stats.queueMaxUs);
    SetObjectInt64(env, result, "uploadP50Us", stats.uploadP50Us);
    SetObjectInt64(env, result, "uploadP95Us", stats.uploadP95Us);
    SetObjectInt64(env, result, "uploadMaxUs", stats.uploadMaxUs);
    SetObjectInt64(env, result, "drawP50Us", stats.drawP50Us);
    SetObjectInt64(env, result, "drawP95Us", stats.drawP95Us);
    SetObjectInt64(env, result, "drawMaxUs", stats.drawMaxUs);
    SetObjectInt64(env, result, "swapP50Us", stats.swapP50Us);
    SetObjectInt64(env, result, "swapP95Us", stats.swapP95Us);
    SetObjectInt64(env, result, "swapMaxUs", stats.swapMaxUs);
    SetObjectInt64(env, result, "workerP50Us", stats.workerP50Us);
    SetObjectInt64(env, result, "workerP95Us", stats.workerP95Us);
    SetObjectInt64(env, result, "workerMaxUs", stats.workerMaxUs);
    SetObjectInt32(env, result, "glUploadGateDecision", stats.glUploadGateDecision);
    SetObjectInt64(env, result, "glUploadEvaluatedSamples",
                   static_cast<int64_t>(stats.glUploadEvaluatedSamples));
    SetObjectInt64(env, result, "glUploadSwapP95Us", stats.glUploadSwapP95Us);
    SetObjectInt32(env, result, "glUploadSharePermille", stats.glUploadSharePermille);
    SetObjectInt32(env, result, "desktopWidth", stats.desktopWidth);
    SetObjectInt32(env, result, "desktopHeight", stats.desktopHeight);
    SetObjectInt64(env, result, "graphicsEpoch", static_cast<int64_t>(stats.graphicsEpoch));
    SetObjectInt64(env, result, "desktopResizeCount",
                   static_cast<int64_t>(stats.desktopResizeCount));
    SetObjectInt64(env, result, "desktopResizeFailures",
                   static_cast<int64_t>(stats.desktopResizeFailures));
    SetObjectBool(env, result, "gfxChannelConnected", stats.gfxChannelConnected);
    SetObjectBool(env, result, "displayControlReady", stats.displayControlReady);
    SetObjectBool(env, result, "displayControlDisabled", stats.displayControlDisabled);
    SetObjectInt32(env, result, "displayRequestedWidth", stats.displayRequestedWidth);
    SetObjectInt32(env, result, "displayRequestedHeight", stats.displayRequestedHeight);
    SetObjectInt32(env, result, "displayEffectiveWidth", stats.displayEffectiveWidth);
    SetObjectInt32(env, result, "displayEffectiveHeight", stats.displayEffectiveHeight);
    SetObjectInt32(env, result, "displayScaleFactor", stats.displayScaleFactor);
    SetObjectInt64(env, result, "displayRequestCount",
                   static_cast<int64_t>(stats.displayRequestCount));
    SetObjectInt64(env, result, "displayFailureCount",
                   static_cast<int64_t>(stats.displayFailureCount));
    SetObjectString(env, result, "displayLastResult", stats.displayLastResult);
    SetObjectInt32(env, result, "inputQueueDepth", stats.inputQueueDepth);
    SetObjectInt32(env, result, "inputQueueMax", stats.inputQueueMax);
    SetObjectInt64(env, result, "inputTextUnits", stats.inputTextUnits);
    SetObjectInt64(env, result, "inputDroppedMouseMoves", stats.inputDroppedMouseMoves);
    SetObjectInt64(env, result, "inputNonDisposableOverflow", stats.inputNonDisposableOverflow);
    SetObjectString(env, result, "graphicsMode", stats.graphicsMode);
    return result;
}

/** NAPI: requestRdpDisplayLayout(sessionId, request): RdpDisplayLayoutResult */
napi_value NapiRequestRdpDisplayLayout(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &sessionId);
    }
    RdpDisplayLayoutRequest request;
    if (argc > 1) {
        const auto getInt = [&](const char* key, int& out) {
            napi_value value;
            if (napi_get_named_property(env, args[1], key, &value) == napi_ok) {
                napi_get_value_int32(env, value, &out);
            }
        };
        getInt("width", request.width);
        getInt("height", request.height);
        getInt("physicalWidthMm", request.physicalWidthMm);
        getInt("physicalHeightMm", request.physicalHeightMm);
        getInt("orientation", request.orientation);
        getInt("desktopScaleFactor", request.desktopScaleFactor);
        getInt("deviceScaleFactor", request.deviceScaleFactor);
    }

    RdpDisplayLayoutResult layoutResult {
        false, "not_found", "RDP session was not found"
    };
    const auto lookup = g_sessionRegistry.find(sessionId);
    const std::shared_ptr<SessionContext> session =
        lookup == g_sessionRegistry.end() ? nullptr : lookup->second;
    if (session && session->protocolName == "rdp") {
        std::shared_ptr<ProtocolAdapter> protocolAdapter;
        if (session->lifecycle.load(std::memory_order_acquire) ==
            SessionContext::Lifecycle::Active) {
            std::lock_guard<std::mutex> adapterLock(session->adapterMutex);
            protocolAdapter = session->adapter;
        }
        auto adapter = std::dynamic_pointer_cast<FreeRdpAdapter>(protocolAdapter);
        layoutResult = adapter
            ? adapter->requestDisplayLayout(request)
            : RdpDisplayLayoutResult {false, "not_active", "RDP session is not active"};
    }
    napi_value result;
    napi_create_object(env, &result);
    SetObjectBool(env, result, "accepted", layoutResult.accepted);
    SetObjectString(env, result, "code", layoutResult.code);
    SetObjectString(env, result, "message", layoutResult.message);
    return result;
}

/** NAPI: cancelRdpDisplayLayout(sessionId): boolean */
napi_value NapiCancelRdpDisplayLayout(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &sessionId);
    }
    bool cancelled = false;
    const auto lookup = g_sessionRegistry.find(sessionId);
    const std::shared_ptr<SessionContext> session =
        lookup == g_sessionRegistry.end() ? nullptr : lookup->second;
    if (session && session->protocolName == "rdp" &&
        session->lifecycle.load(std::memory_order_acquire) ==
            SessionContext::Lifecycle::Active) {
        std::shared_ptr<ProtocolAdapter> protocolAdapter;
        {
            std::lock_guard<std::mutex> adapterLock(session->adapterMutex);
            protocolAdapter = session->adapter;
        }
        auto adapter = std::dynamic_pointer_cast<FreeRdpAdapter>(protocolAdapter);
        cancelled = adapter && adapter->cancelDisplayLayout();
    }
    napi_value result;
    napi_get_boolean(env, cancelled, &result);
    return result;
}

/** NAPI: generic desktop-session diagnostics; the RustDesk name remains an alias. */
napi_value NapiGetSessionDiagnostics(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &sessionId);
    }

    RustDeskDiagnosticsStats nativeStats;
    std::shared_ptr<SessionContext> session;
    SessionDiagnosticsCounters* counters = nullptr;
    bool sessionActive = false;
    bool vncSession = false;
    bool rdpSession = false;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second) {
        session = it->second;
        counters = &session->diagnostics;
        if (it->second->protocolName == "rustdesk") {
            sessionActive = session->lifecycle.load(std::memory_order_acquire) ==
                SessionContext::Lifecycle::Active;
            const std::shared_ptr<RustDeskBridge> bridge = GetRustDeskAdapter(session);
            if (bridge) {
                nativeStats = bridge->getDiagnostics();
            }
        }
        if (it->second->protocolName == "vnc" && it->second->adapter) {
            sessionActive = session->lifecycle.load(std::memory_order_acquire) ==
                SessionContext::Lifecycle::Active;
            vncSession = true;
            nativeStats.supported = true;
            nativeStats.sessionId = static_cast<uint64_t>(sessionId);
            nativeStats.codec = static_cast<int>(CodecType::RAW_BGRA);
            nativeStats.connectionPath = it->second->vncConnectionPath == "direct" ? 1 : 0;
            nativeStats.videoMessages = counters->ingressFrames.load(std::memory_order_acquire);
            nativeStats.receivedFrames = counters->ingressFrames.load(std::memory_order_acquire);
            nativeStats.receivedBytes = counters->ingressBytes.load(std::memory_order_acquire);
            nativeStats.keyframes = counters->keyframes.load(std::memory_order_acquire);
            nativeStats.presentedFrames = counters->presentedFrames.load(std::memory_order_acquire);
            nativeStats.lastFrameAtMs = counters->lastFrameAtMs.load(std::memory_order_acquire);
            nativeStats.width = counters->lastWidth.load(std::memory_order_acquire);
            nativeStats.height = counters->lastHeight.load(std::memory_order_acquire);
        }
        if (it->second->protocolName == "rdp" && it->second->adapter) {
            sessionActive = session->lifecycle.load(std::memory_order_acquire) ==
                SessionContext::Lifecycle::Active;
            rdpSession = true;
            nativeStats.supported = true;
            nativeStats.sessionId = static_cast<uint64_t>(sessionId);
            nativeStats.codec = static_cast<int>(CodecType::RAW_BGRA);
            nativeStats.videoMessages = counters->ingressFrames.load(std::memory_order_acquire);
            nativeStats.receivedFrames = counters->ingressFrames.load(std::memory_order_acquire);
            nativeStats.receivedBytes = counters->ingressBytes.load(std::memory_order_acquire);
            nativeStats.presentedFrames = counters->presentedFrames.load(std::memory_order_acquire);
            nativeStats.lastFrameAtMs = counters->lastFrameAtMs.load(std::memory_order_acquire);
            nativeStats.width = counters->lastWidth.load(std::memory_order_acquire);
            nativeStats.height = counters->lastHeight.load(std::memory_order_acquire);
        }
    }

    const uint64_t nowMs = static_cast<uint64_t>(std::chrono::duration_cast<
        std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
    Render::VideoPerfSnapshot pressureSnapshot;
    Render::VideoPressureDecision pressureDecision;
    bool pressureReportReady = false;
    if (session) {
        std::lock_guard<std::mutex> pressureLock(session->pressureSnapshotMutex);
        pressureDecision = session->videoPressure.tick(std::chrono::steady_clock::now());
        pressureSnapshot = session->lastPressureSnapshot;
        if (pressureDecision.changed && IsSessionCallbackActive(session)) {
            session->lastPressureDecision = pressureDecision;
            pressureReportReady = true;
        }
    }
    if (pressureReportReady) {
        ReportVideoPressureForSession(session, static_cast<int>(pressureDecision.level));
    }
    const DecoderSessionIdentity expectedOwner = session ? session->identity() :
        DecoderSessionIdentity {};
    DecoderTelemetrySnapshot decoder = DecoderNapi::GetActiveTelemetry(expectedOwner);
    const bool ownsActivePresentation = session &&
        DecoderNapi::IsActiveSessionOwner(expectedOwner);
    const RdpPresentationMetricsSnapshot renderer = ownsActivePresentation ?
        RendererNapi::GetActivePresentationStats(expectedOwner) : RdpPresentationMetricsSnapshot {};
    int64_t decodeP50Us = 0;
    int64_t decodeP95Us = 0;
    int64_t decodeMaxUs = 0;
    if (counters) {
        counters->updateRates(nowMs);
        counters->timingSnapshot(decodeP50Us, decodeP95Us, decodeMaxUs);
    }
    double receivedFps = 0.0;
    double displayFps = 0.0;
    double decodedFps = 0.0;
    double bitrateKbps = 0.0;
    bool receivedRateAvailable = false;
    if (counters) {
        counters->rateSnapshot(receivedFps, decodedFps, bitrateKbps, receivedRateAvailable);
    }
    // Decode completion is not presentation. Only report display FPS once a
    // completed renderer interval supplies both frame count and duration.
    const bool presentedRateAvailable = renderer.windowComplete &&
        renderer.windowDurationUs > 0 && renderer.presentedFrames > 0;
    if (presentedRateAvailable) {
        displayFps = static_cast<double>(renderer.windowSamples) * 1000000.0 /
            static_cast<double>(renderer.windowDurationUs);
    }
    const uint64_t observedFrames = counters ?
        counters->ingressFrames.load(std::memory_order_acquire) : nativeStats.receivedFrames;
    const uint64_t observedLastFrameAtMs = counters ?
        counters->lastFrameAtMs.load(std::memory_order_acquire) : nativeStats.lastFrameAtMs;
    const bool videoSeen = observedFrames > 0;
    const int64_t lastFrameAgeMs = observedLastFrameAtMs > 0 && nowMs >= observedLastFrameAtMs ?
        static_cast<int64_t>(nowMs - observedLastFrameAtMs) : -1;
    const uint64_t observedLastPresentedAtMs = counters ?
        counters->lastPresentedAtMs.load(std::memory_order_acquire) : 0;
    const int64_t lastPresentedFrameAgeMs =
        observedLastPresentedAtMs > 0 && nowMs >= observedLastPresentedAtMs ?
        static_cast<int64_t>(nowMs - observedLastPresentedAtMs) : -1;

    napi_value result;
    napi_create_object(env, &result);
    SetObjectBool(env, result, "supported", nativeStats.supported);
    SetObjectBool(env, result, "sessionActive", sessionActive);
    SetObjectBool(env, result, "protocolSnapshotAvailable", nativeStats.supported || vncSession);
    SetObjectBool(env, result, "videoSeen", videoSeen);
    SetObjectBool(env, result, "receivedRateAvailable", receivedRateAvailable);
    SetObjectBool(env, result, "presentedRateAvailable", presentedRateAvailable);
    SetObjectBool(env, result, "decodeRateAvailable", receivedRateAvailable);
    SetObjectBool(env, result, "remoteInputPermissionKnown", nativeStats.remoteInputPermissionKnown);
    SetObjectBool(env, result, "remoteInputAllowed", nativeStats.remoteInputAllowed);
    SetObjectBool(env, result, "remoteClipboardPermissionKnown",
        nativeStats.remoteClipboardPermissionKnown);
    SetObjectBool(env, result, "remoteClipboardAllowed", nativeStats.remoteClipboardAllowed);
    SetObjectBool(env, result, "remoteFilePermissionKnown", nativeStats.remoteFilePermissionKnown);
    SetObjectBool(env, result, "remoteFileAllowed", nativeStats.remoteFileAllowed);
    SetObjectInt32(env, result, "sessionId", sessionId);
    SetObjectInt32(env, result, "latencyMs", nativeStats.latencyMs);
    SetObjectInt32(env, result, "targetBitrateKbps", nativeStats.targetBitrateKbps);
    SetObjectInt32(env, result, "requestedImageQuality", nativeStats.requestedImageQuality);
    SetObjectInt32(env, result, "effectiveImageQuality", nativeStats.effectiveImageQuality);
    SetObjectInt32(env, result, "sentImageQuality", nativeStats.sentImageQuality);
    SetObjectInt32(env, result, "qualityProfile", nativeStats.qualityProfile);
    SetObjectInt32(env, result, "qualityFps", nativeStats.qualityFps);
    SetObjectInt64(env, result, "qualityRequestedGeneration",
                   static_cast<int64_t>(nativeStats.qualityRequestedGeneration));
    SetObjectInt64(env, result, "qualityAppliedGeneration",
                   static_cast<int64_t>(nativeStats.qualityAppliedGeneration));
    SetObjectInt32(env, result, "qualityUpdateStatus", nativeStats.qualityUpdateStatus);
    SetObjectInt64(env, result, "videoMessages", static_cast<int64_t>(
        vncSession && counters ? counters->ingressFrames.load(std::memory_order_acquire) :
        nativeStats.videoMessages));
    SetObjectInt64(env, result, "receivedFrames", static_cast<int64_t>(
        counters ? counters->ingressFrames.load(std::memory_order_acquire) : nativeStats.receivedFrames));
    SetObjectInt64(env, result, "keyframes", static_cast<int64_t>(
        counters ? counters->keyframes.load(std::memory_order_acquire) : nativeStats.keyframes));
    SetObjectInt64(env, result, "receivedBytes", static_cast<int64_t>(
        counters ? counters->ingressBytes.load(std::memory_order_acquire) : nativeStats.receivedBytes));
    SetObjectInt64(env, result, "audioFrames", static_cast<int64_t>(nativeStats.audioFrames));
    SetObjectInt64(env, result, "cadenceGaps", static_cast<int64_t>(nativeStats.cadenceGaps));
    SetObjectInt64(env, result, "maxCadenceGapMs", static_cast<int64_t>(nativeStats.maxCadenceGapMs));
    SetObjectInt64(env, result, "testDelayCount", static_cast<int64_t>(nativeStats.testDelayCount));
    SetObjectDouble(env, result, "receivedFps", receivedFps);
    SetObjectDouble(env, result, "displayFps", displayFps);
    SetObjectDouble(env, result, "decodeFps", decodedFps);
    SetObjectDouble(env, result, "bitrateKbps", bitrateKbps);
    SetObjectInt32(env, result, "codec", counters ?
        counters->lastCodec.load(std::memory_order_acquire) : nativeStats.codec);
    SetObjectInt32(env, result, "width", counters ?
        counters->lastWidth.load(std::memory_order_acquire) : nativeStats.width);
    SetObjectInt32(env, result, "height", counters ?
        counters->lastHeight.load(std::memory_order_acquire) : nativeStats.height);
    SetObjectString(env, result, "connectionPath", vncSession && it != g_sessionRegistry.end() ?
        it->second->vncConnectionPath :
        (nativeStats.connectionPath == 1 ? "direct" : (nativeStats.supported ? "relay" : "unknown")));
    SetObjectString(env, result, "peerPlatform",
        session && session->protocolName == "rustdesk" ? nativeStats.peerPlatform : "unknown");
    SetObjectBool(env, result, "desktopSurfaceCompatibility",
        decoder.desktopSurfaceCompatibility);
    SetObjectString(env, result, "nativeImagePresentation",
        Render::NativeImagePresentationModeName(decoder.presentationMode));
    SetObjectString(env, result, "producerTransform",
        Render::NativeImageTransformClassName(decoder.producerTransformClass));
    SetObjectInt64(env, result, "lastFrameAtMs", static_cast<int64_t>(
        counters ? counters->lastFrameAtMs.load(std::memory_order_acquire) : nativeStats.lastFrameAtMs));
    SetObjectInt64(env, result, "lastFrameAgeMs", lastFrameAgeMs);
    SetObjectInt64(env, result, "lastPresentedAtMs",
        static_cast<int64_t>(observedLastPresentedAtMs));
    SetObjectInt64(env, result, "lastPresentedFrameAgeMs", lastPresentedFrameAgeMs);
    SetObjectInt64(env, result, "decodeOk", static_cast<int64_t>(
        counters ? counters->decodeOk.load(std::memory_order_acquire) : 0));
    SetObjectInt64(env, result, "decodeErrors", static_cast<int64_t>(
        counters ? counters->decodeErrors.load(std::memory_order_acquire) : 0));
    SetObjectInt64(env, result, "decodeP50Us", decodeP50Us);
    SetObjectInt64(env, result, "decodeP95Us", decodeP95Us);
    SetObjectInt64(env, result, "decodeMaxUs", decodeMaxUs);
    SetObjectInt64(env, result, "presentedFrames", static_cast<int64_t>(
        vncSession && counters ? counters->presentedFrames.load(std::memory_order_acquire) :
        renderer.presentedFrames));
    SetObjectInt64(env, result, "presentationRejected", static_cast<int64_t>(
        counters ? counters->presentationRejected.load(std::memory_order_acquire) : 0));
    SetObjectInt32(env, result, "lastDirtyX",
        counters ? counters->lastDirtyX.load(std::memory_order_acquire) : -1);
    SetObjectInt32(env, result, "lastDirtyY",
        counters ? counters->lastDirtyY.load(std::memory_order_acquire) : -1);
    SetObjectInt32(env, result, "lastDirtyWidth",
        counters ? counters->lastDirtyWidth.load(std::memory_order_acquire) : 0);
    SetObjectInt32(env, result, "lastDirtyHeight",
        counters ? counters->lastDirtyHeight.load(std::memory_order_acquire) : 0);
    SetObjectString(env, result, "requestedColorDepth", vncSession && it != g_sessionRegistry.end() ?
        it->second->vncRequestedColorDepth : "");
    SetObjectInt32(env, result, "effectiveColorDepth",
        counters ? counters->effectiveColorDepth.load(std::memory_order_acquire) : 0);
    SetObjectInt64(env, result, "inputEventsSent", static_cast<int64_t>(
        counters ? counters->inputEventsSent.load(std::memory_order_acquire) : 0));
    SetObjectInt64(env, result, "inputEventsDropped", static_cast<int64_t>(
        counters ? counters->inputEventsDropped.load(std::memory_order_acquire) : 0));
    SetObjectInt64(env, result, "presentationWindowSamples",
                   static_cast<int64_t>(renderer.windowSamples));
    SetObjectInt64(env, result, "presentationWindowMs", renderer.windowDurationUs / 1000);
    SetObjectInt64(env, result, "renderP50Us", renderer.workerUs.p50);
    SetObjectInt64(env, result, "renderP95Us", renderer.workerUs.p95);
    SetObjectInt64(env, result, "renderMaxUs", renderer.workerUs.max);
    SetObjectInt64(env, result, "queueDepth", static_cast<int64_t>(decoder.queueDepth));
    SetObjectInt64(env, result, "queueMax", static_cast<int64_t>(decoder.queueMax));
    SetObjectInt64(env, result, "decoderGeneration",
                   static_cast<int64_t>(decoder.decoderGeneration));
    SetObjectInt64(env, result, "displayGeneration",
                   static_cast<int64_t>(decoder.displayGeneration));
    SetObjectInt64(env, result, "dropCounterGeneration",
                   static_cast<int64_t>(decoder.dropCounterGeneration));
    SetObjectInt32(env, result, "pressureLevel",
                   session ? static_cast<int32_t>(session->videoPressure.level()) : 0);
    SetObjectBool(env, result, "pressureTimedOut",
                  session ? session->videoPressure.timedOut() : false);
    SetObjectInt64(env, result, "pressureDelta",
                   static_cast<int64_t>(pressureSnapshot.decodeDrops));
    SetObjectInt64(env, result, "pressureInputDropsDelta",
                   static_cast<int64_t>(pressureSnapshot.inputDropsDelta));
    SetObjectInt64(env, result, "pressureWaitKeyframeDropsDelta",
                   static_cast<int64_t>(pressureSnapshot.waitKeyframeDropsDelta));
    SetObjectInt64(env, result, "pressureDecodeErrors",
                   static_cast<int64_t>(pressureSnapshot.decodeErrors));
    SetObjectInt64(env, result, "decodeRetNotReady", static_cast<int64_t>(
        counters ? counters->decodeRetNotReady.load(std::memory_order_acquire) : 0));
    SetObjectInt64(env, result, "decodeRetBadCodec", static_cast<int64_t>(
        counters ? counters->decodeRetBadCodec.load(std::memory_order_acquire) : 0));
    SetObjectInt64(env, result, "decodeRetMismatch", static_cast<int64_t>(
        counters ? counters->decodeRetMismatch.load(std::memory_order_acquire) : 0));
    SetObjectInt64(env, result, "decodeRetOther", static_cast<int64_t>(
        counters ? counters->decodeRetOther.load(std::memory_order_acquire) : 0));
    SetObjectInt64(env, result, "droppedFrames", static_cast<int64_t>(decoder.droppedFrames));
    const int sourceEncoding = counters ?
        counters->sourceEncoding.load(std::memory_order_acquire) : -1;
    const std::string vncBackend = sourceEncoding == VncRfbProtocol::kZrleEncoding ? "ZRLE" :
        (sourceEncoding == VncRfbProtocol::kCopyRectEncoding ? "CopyRect" :
         (sourceEncoding == VncRfbProtocol::kRawEncoding ? "RAW" : "等待服务器"));
    SetObjectString(env, result, "decoderBackend", vncSession ? vncBackend :
        (rdpSession ? "gdi" :
         (decoder.valid && decoder.ready ? (decoder.software ? "software" : "hardware") : "unknown")));
    return result;
}

napi_value NapiReplayPendingRustDeskFrame(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &sessionId);
    }
    bool ok = false;
    const auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second) {
        ok = ReplayPendingRustDeskFrame(it->second);
    }
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

static bool ReadProcCpuTicks(uint64_t& processTicks, uint64_t& totalTicks) {
    std::ifstream processFile("/proc/self/stat");
    std::string processLine;
    if (!processFile || !std::getline(processFile, processLine)) {
        return false;
    }
    const size_t commEnd = processLine.rfind(')');
    if (commEnd == std::string::npos || commEnd + 2 >= processLine.size()) {
        return false;
    }
    std::istringstream processFields(processLine.substr(commEnd + 2));
    std::string state;
    processFields >> state;
    std::vector<uint64_t> fields;
    uint64_t value = 0;
    while (processFields >> value) {
        fields.push_back(value);
    }
    // fields[0] is field 4 (ppid), utime is field 14 and stime field 15.
    if (fields.size() <= 12) {
        return false;
    }
    processTicks = fields[10] + fields[11];

    std::ifstream systemFile("/proc/stat");
    std::string cpuLine;
    if (!systemFile || !std::getline(systemFile, cpuLine)) {
        return false;
    }
    std::istringstream cpuFields(cpuLine);
    std::string cpuName;
    cpuFields >> cpuName;
    totalTicks = 0;
    while (cpuFields >> value) {
        totalTicks += value;
    }
    return cpuName == "cpu" && totalTicks > 0;
}

static uint64_t ReadResidentMemoryBytes() {
    std::ifstream statusFile("/proc/self/status");
    std::string line;
    while (statusFile && std::getline(statusFile, line)) {
        if (line.rfind("VmRSS:", 0) != 0) {
            continue;
        }
        std::istringstream fields(line.substr(6));
        uint64_t kilobytes = 0;
        fields >> kilobytes;
        return kilobytes * 1024ULL;
    }
    return 0;
}

struct LocalResourceSampleState {
    bool hasBaseline = false;
    uint64_t previousProcessTicks = 0;
    uint64_t previousTotalTicks = 0;
    uint64_t sampledAtMs = 0;
    bool supported = false;
    bool cpuAvailable = false;
    double cpuPercent = -1.0;
    uint64_t memoryBytes = 0;
    bool memoryAvailable = false;
};

static napi_value MakeLocalResourceStatsValue(napi_env env,
                                               const LocalResourceSampleState& state) {
    napi_value result;
    napi_create_object(env, &result);
    SetObjectBool(env, result, "supported", state.supported);
    SetObjectBool(env, result, "cpuAvailable", state.cpuAvailable);
    SetObjectDouble(env, result, "cpuPercent", state.cpuAvailable ? state.cpuPercent : -1.0);
    SetObjectInt64(env, result, "memoryBytes", static_cast<int64_t>(state.memoryBytes));
    SetObjectBool(env, result, "memoryAvailable", state.memoryAvailable);
    SetObjectBool(env, result, "gpuAvailable", false);
    SetObjectDouble(env, result, "gpuPercent", -1.0);
    SetObjectInt64(env, result, "sampledAtMs", static_cast<int64_t>(state.sampledAtMs));
    return result;
}

/** NAPI: getLocalResourceStats(includePro): local process CPU/RSS; GPU is best-effort. */
napi_value NapiGetLocalResourceStats(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    bool includePro = true;
    if (argc > 0) {
        napi_get_value_bool(env, args[0], &includePro);
    }

    static std::mutex sampleMutex;
    static LocalResourceSampleState state;
    if (!includePro) {
        std::lock_guard<std::mutex> lock(sampleMutex);
        // Turning Pro off also discards the CPU baseline. Re-enabling Pro
        // must start with an unavailable first sample instead of reporting a
        // stale interval measured while the HUD was hidden.
        state = LocalResourceSampleState();
        return MakeLocalResourceStatsValue(env, state);
    }

    const uint64_t nowMs = static_cast<uint64_t>(std::chrono::duration_cast<
        std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
    uint64_t processTicks = 0;
    uint64_t totalTicks = 0;
    const bool procSupported = ReadProcCpuTicks(processTicks, totalTicks);

    std::lock_guard<std::mutex> lock(sampleMutex);
    if (state.sampledAtMs > 0 && nowMs >= state.sampledAtMs &&
        nowMs - state.sampledAtMs < 1000) {
        return MakeLocalResourceStatsValue(env, state);
    }

    const uint64_t memoryBytes = ReadResidentMemoryBytes();
    const bool memoryAvailable = memoryBytes > 0;
    if (procSupported) {
        if (state.hasBaseline && totalTicks > state.previousTotalTicks &&
            processTicks >= state.previousProcessTicks) {
            const uint64_t processDelta = processTicks - state.previousProcessTicks;
            const uint64_t totalDelta = totalTicks - state.previousTotalTicks;
            const long cpuCount = sysconf(_SC_NPROCESSORS_ONLN);
            state.cpuPercent = totalDelta > 0 ? static_cast<double>(processDelta) * 100.0 /
                static_cast<double>(totalDelta) * static_cast<double>(cpuCount > 0 ? cpuCount : 1) : -1.0;
            state.cpuAvailable = totalDelta > 0;
        } else {
            state.cpuPercent = -1.0;
            state.cpuAvailable = false;
        }
        state.previousProcessTicks = processTicks;
        state.previousTotalTicks = totalTicks;
        state.hasBaseline = true;
    } else {
        state.cpuPercent = -1.0;
        state.cpuAvailable = false;
    }
    state.memoryBytes = memoryBytes;
    state.memoryAvailable = memoryAvailable;
    state.supported = procSupported || memoryAvailable;
    state.sampledAtMs = nowMs;
    return MakeLocalResourceStatsValue(env, state);
}

napi_value NapiGetSessionTransferStatus(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    if (argc > 0) { napi_get_value_int32(env, args[0], &sessionId); }
    SessionTransferStatus status;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter) {
        status = it->second->adapter->getSessionTransferStatus();
    }
    napi_value result;
    napi_create_object(env, &result);
    SetObjectBool(env, result, "rdpDriveMounted", status.rdpDriveMounted);
    SetObjectInt32(env, result, "rustdeskTransferState", static_cast<int32_t>(status.rustdeskTransfer));
    SetObjectInt64(env, result, "transferId", static_cast<int64_t>(status.transferId));
    SetObjectInt64(env, result, "transferredBytes", static_cast<int64_t>(status.transferredBytes));
    SetObjectInt64(env, result, "totalBytes", static_cast<int64_t>(status.totalBytes));
    SetObjectString(env, result, "diagnosticCode", status.diagnosticCode);
    return result;
}

/**
 * NAPI: setRdpBackgroundVideoPrewarm(sessionId: number, enabled: boolean, intervalMs: number): boolean
 */
napi_value NapiSetRdpBackgroundVideoPrewarm(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    bool enabled = false;
    int32_t intervalMs = 0;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &sessionId);
    }
    if (argc > 1) {
        napi_get_value_bool(env, args[1], &enabled);
    }
    if (argc > 2) {
        napi_get_value_int32(env, args[2], &intervalMs);
    }

    bool ok = false;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second && it->second->adapter &&
        it->second->protocolName == "rdp") {
        auto* adapter = dynamic_cast<FreeRdpAdapter*>(it->second->adapter.get());
        if (adapter) {
            ok = adapter->setBackgroundVideoPrewarm(
                enabled, intervalMs > 0 ? static_cast<uint32_t>(intervalMs) : 0);
        }
    }

    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

/**
 * NAPI: presentRdpCachedFrame(sessionId: number): boolean
 */
napi_value NapiPresentRdpCachedFrame(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &sessionId);
    }

    bool ok = false;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second && it->second->adapter &&
        it->second->protocolName == "rdp") {
        auto* adapter = dynamic_cast<FreeRdpAdapter*>(it->second->adapter.get());
        if (adapter) {
            ok = adapter->presentCachedBackgroundFrame();
        }
    }

    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

/**
 * NAPI: connect(config: object): number
 *
 * config 字段: protocol, host, port, username, password, domain, width, height, codec,
 * rdpAuthMode, rdpRestrictedAdminSecretSource, rdpRestrictedAdminHash
 * 返回会话 ID (>0=成功, -1=协议未找到, -2=连接失败)
 */
napi_value NapiConnect(napi_env env, napi_callback_info info) {
    try {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_valuetype configType = napi_undefined;
    if (argc < 1 || napi_typeof(env, args[0], &configType) != napi_ok ||
        configType != napi_object) {
        napi_value errVal;
        napi_create_int32(env, -2, &errVal);
        return errVal;
    }

    // 解析 config 对象
    ConnectionConfig cfg;
    SshSecretGuard sshSecretGuard { cfg };
    bool invalidConfigField = false;

    auto getString = [&](const char* key, std::string& out,
                         size_t maxLength = kMaxGenericNapiStringLength) {
        bool present = false;
        if (napi_has_named_property(env, args[0], key, &present) != napi_ok) {
            invalidConfigField = true;
            return;
        }
        if (!present) { return; }
        napi_value val;
        if (napi_get_named_property(env, args[0], key, &val) == napi_ok) {
            napi_valuetype type = napi_undefined;
            if (napi_typeof(env, val, &type) != napi_ok) {
                invalidConfigField = true;
                return;
            }
            if (type == napi_undefined) { return; }
            if (type != napi_string) {
                invalidConfigField = true;
                return;
            }
            if (!ReadBoundedNapiStringValue(env, val, maxLength, out)) {
                invalidConfigField = true;
            }
        } else {
            invalidConfigField = true;
        }
    };
    auto getInt = [&](const char* key, int& out, bool* present = nullptr) {
        bool propertyPresent = false;
        if (napi_has_named_property(env, args[0], key, &propertyPresent) != napi_ok) {
            invalidConfigField = true;
            return;
        }
        if (!propertyPresent) { return; }
        napi_value val;
        if (napi_get_named_property(env, args[0], key, &val) == napi_ok) {
            napi_valuetype type = napi_undefined;
            if (napi_typeof(env, val, &type) != napi_ok) {
                invalidConfigField = true;
                return;
            }
            if (type == napi_undefined) { return; }
            int32_t parsed = 0;
            if (type != napi_number ||
                !ReadStrictNapiInt32Value(env, val, parsed)) {
                invalidConfigField = true;
                return;
            }
            out = parsed;
            if (present != nullptr) { *present = true; }
        } else {
            invalidConfigField = true;
        }
    };
    auto getBool = [&](const char* key, bool& out) {
        bool present = false;
        if (napi_has_named_property(env, args[0], key, &present) != napi_ok) {
            invalidConfigField = true;
            return;
        }
        if (!present) { return; }
        napi_value val;
        if (napi_get_named_property(env, args[0], key, &val) == napi_ok) {
            napi_valuetype type = napi_undefined;
            if (napi_typeof(env, val, &type) != napi_ok) {
                invalidConfigField = true;
                return;
            }
            if (type == napi_undefined) { return; }
            if (type != napi_boolean ||
                napi_get_value_bool(env, val, &out) != napi_ok) {
                invalidConfigField = true;
            }
        } else {
            invalidConfigField = true;
        }
    };

    std::string protocolName;
    getString("protocol", protocolName, 32);
    getString("host", cfg.host, remotedesk::endpoint::kMaxInputLength);
    bool hasPort = false;
    getInt("port", cfg.port, &hasPort);
    getString("username", cfg.username);
    getString("password", cfg.password);
    getString("domain", cfg.domain);
    getInt("width", cfg.width);
    getInt("height", cfg.height);
    std::string codecName;
    getString("codec", codecName);
    std::transform(codecName.begin(), codecName.end(), codecName.begin(),
        [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
    if (codecName == "H265") cfg.codec = CodecType::H265;
    else if (codecName == "VP8") cfg.codec = CodecType::VP8;
    else if (codecName == "VP9") cfg.codec = CodecType::VP9;
    else if (codecName == "AV1") cfg.codec = CodecType::AV1;
    else if (codecName == "H264") cfg.codec = CodecType::H264;
    else if (protocolName == "rustdesk") cfg.codec = CodecType::AUTO;
    else cfg.codec = CodecType::H264;

    // 🆕 新增字段解析
    getString("customHostname", cfg.customHostname,
              remotedesk::endpoint::kMaxInputLength);
    getString("targetServerName", cfg.targetServerName,
              remotedesk::endpoint::kMaxInputLength);
    getString("clientHostname", cfg.clientHostname, 253);
    getString("gatewayHost", cfg.gatewayHost,
              remotedesk::endpoint::kMaxInputLength);
    bool hasGatewayPort = false;
    getInt("gatewayPort", cfg.gatewayPort, &hasGatewayPort);
    getString("rdpEndpointMode", cfg.rdpEndpointMode, 64);
    getString("rdpGatewayTransport", cfg.rdpGatewayTransport, 64);
    getString("rdpGatewayServerName", cfg.rdpGatewayServerName,
              remotedesk::endpoint::kMaxInputLength);
    getInt("monitorCount", cfg.monitorCount);
    getBool("multiMonitor", cfg.multiMonitor);
    getInt("colorDepth", cfg.colorDepth);
    getInt("rdpDesktopScaleFactor", cfg.rdpDesktopScaleFactor);
    getInt("rdpDeviceScaleFactor", cfg.rdpDeviceScaleFactor);
    getInt("rdpDesktopPhysicalWidthMm", cfg.rdpDesktopPhysicalWidthMm);
    getInt("rdpDesktopPhysicalHeightMm", cfg.rdpDesktopPhysicalHeightMm);
    getInt("rdpDesktopOrientation", cfg.rdpDesktopOrientation);
    if (cfg.rdpDesktopScaleFactor != 100 && cfg.rdpDesktopScaleFactor != 140 &&
        cfg.rdpDesktopScaleFactor != 180) {
        cfg.rdpDesktopScaleFactor = 100;
    }
    if (cfg.rdpDeviceScaleFactor != 100 && cfg.rdpDeviceScaleFactor != 140 &&
        cfg.rdpDeviceScaleFactor != 180) {
        cfg.rdpDeviceScaleFactor = cfg.rdpDesktopScaleFactor;
    }
    if (cfg.rdpDesktopPhysicalWidthMm < 10 || cfg.rdpDesktopPhysicalWidthMm > 10000) {
        cfg.rdpDesktopPhysicalWidthMm = 0;
    }
    if (cfg.rdpDesktopPhysicalHeightMm < 10 || cfg.rdpDesktopPhysicalHeightMm > 10000) {
        cfg.rdpDesktopPhysicalHeightMm = 0;
    }
    if (cfg.rdpDesktopOrientation != 0 && cfg.rdpDesktopOrientation != 90 &&
        cfg.rdpDesktopOrientation != 180 && cfg.rdpDesktopOrientation != 270) {
        cfg.rdpDesktopOrientation = 0;
    }
    getInt("rdpAuthIdentityMode", cfg.rdpAuthIdentityMode);
    std::string rdpAuthModeName;
    std::string rdpRestrictedAdminSecretSourceName;
    getString("rdpAuthMode", rdpAuthModeName);
    getString("rdpRestrictedAdminSecretSource", rdpRestrictedAdminSecretSourceName);
    if (protocolName == "rdp") {
        std::string rawRdpRestrictedAdminHash;
        getString("rdpRestrictedAdminHash", rawRdpRestrictedAdminHash);
        RdpAuthenticationPolicy rdpAuth = ParseRdpAuthenticationPolicy(
            rdpAuthModeName, rdpRestrictedAdminSecretSourceName, rawRdpRestrictedAdminHash);
        secureClearString(rawRdpRestrictedAdminHash);
        if (!rdpAuth.valid) {
            secureClearString(rdpAuth.normalizedNtlmHash);
            OH_LOG_ERROR(LOG_APP, "[ExtLoader] invalid RDP authentication configuration");
            napi_value errVal;
            napi_create_int32(env, -50, &errVal);
            return errVal;
        }
        if (rdpAuth.mode == RdpAuthenticationPolicyMode::Password) {
            cfg.rdpAuthMode = RdpAuthenticationMode::Password;
        } else if (rdpAuth.mode == RdpAuthenticationPolicyMode::BlankPassword) {
            cfg.rdpAuthMode = RdpAuthenticationMode::BlankPassword;
        } else {
            cfg.rdpAuthMode = RdpAuthenticationMode::RestrictedAdmin;
        }
        cfg.rdpRestrictedAdminSecretSource = RdpRestrictedAdminSecretSource::NtlmHash;
        if (cfg.rdpAuthMode == RdpAuthenticationMode::RestrictedAdmin) {
            cfg.password.clear();
            cfg.rdpRestrictedAdminHash = rdpAuth.normalizedNtlmHash;
        } else {
            cfg.rdpRestrictedAdminHash.clear();
            if (cfg.rdpAuthMode == RdpAuthenticationMode::BlankPassword) {
                cfg.password.clear();
            }
        }
        secureClearString(rdpAuth.normalizedNtlmHash);
    }

    // 🆕 SSH 认证字段
    getString("authMethod", cfg.authMethod);
    getString("privateKeyPem", cfg.privateKeyPem);
    getString("privateKeyPassphrase", cfg.privateKeyPassphrase);
    getString("expectedHostKeyRawBase64", cfg.expectedHostKeyRawBase64);
    getString("expectedHostKeyFingerprintSha256", cfg.expectedHostKeyFingerprintSha256);
    getBool("sshHostKeyPromptEnabled", cfg.sshHostKeyPromptEnabled);
    getString("sshTrustHostId", cfg.sshTrustHostId);
    getString("sshJumpHostKeyRawBase64", cfg.sshJumpHostKeyRawBase64);
    getString("sshJumpHostKeyFingerprintSha256", cfg.sshJumpHostKeyFingerprintSha256);
    if (protocolName == "ssh") {
        getString("sshLocale", cfg.sshLocale);
        if (!SshSessionLocaleIsSupported(cfg.sshLocale)) {
            OH_LOG_ERROR(LOG_APP, "[ExtLoader] unsupported SSH session locale");
            napi_value errVal;
            napi_create_int32(env, ERR_SSH_PROXY_INVALID, &errVal);
            return errVal;
        }
        getString("sshProxyType", cfg.sshProxyType);
        getString("sshProxyHost", cfg.sshProxyHost,
                  remotedesk::endpoint::kMaxInputLength);
        getInt("sshProxyPort", cfg.sshProxyPort);
    getString("sshProxyUsername", cfg.sshProxyUsername);
    getString("sshProxyPassword", cfg.sshProxyPassword);
    getString("sshProxyAuthMethod", cfg.sshProxyAuthMethod);
        getString("sshProxyPrivateKeyPem", cfg.sshProxyPrivateKeyPem);
        getString("sshProxyPrivateKeyPassphrase", cfg.sshProxyPrivateKeyPassphrase);
        // The old SSH UI wrote proxy data into the generic RDP gateway fields.
        // Preserve the values only to reject them explicitly; never silently
        // fall back to a direct connection.
        if (cfg.sshProxyHost.empty() && !cfg.gatewayHost.empty()) {
            cfg.sshProxyHost = cfg.gatewayHost;
            cfg.sshProxyPort = cfg.gatewayPort;
            if (cfg.sshProxyType.empty()) { cfg.sshProxyType = "legacy_gateway"; }
        }
        napi_value responseValue;
        bool isArray = false;
        if (napi_get_named_property(env, args[0], "keyboardInteractiveResponses",
                                    &responseValue) == napi_ok &&
            napi_is_array(env, responseValue, &isArray) == napi_ok && isArray) {
            uint32_t responseCount = 0;
            if (napi_get_array_length(env, responseValue, &responseCount) == napi_ok) {
                // A bounded response list prevents a malformed config from
                // allocating unbounded secret material in the native bridge.
                responseCount = std::min<uint32_t>(responseCount, 32);
                for (uint32_t index = 0; index < responseCount; ++index) {
                    napi_value responseItem;
                    if (napi_get_element(env, responseValue, index, &responseItem) != napi_ok) {
                        continue;
                    }
                    napi_valuetype responseType = napi_undefined;
                    if (napi_typeof(env, responseItem, &responseType) != napi_ok ||
                        responseType != napi_string) {
                        continue;
                    }
                    std::string response;
                    if (!ReadBoundedNapiStringValue(
                            env, responseItem, 4096, response)) { continue; }
                    cfg.sshKeyboardInteractiveResponses.push_back(std::move(response));
                }
            }
        }
        ParseBoundedSshResponseArray(env, args[0],
                                     "sshProxyKeyboardInteractiveResponses",
                                     cfg.sshProxyKeyboardInteractiveResponses);
    }
    if (cfg.authMethod.empty()) cfg.authMethod = "password";
    // RustDesk 扩展配置
    getInt("rdImageQuality", cfg.rdImageQuality);
    getBool("rdDirectIp", cfg.rdDirectIp);
    getString("rdConnectionStrategy", cfg.rdConnectionStrategy);
    bool hasRdDirectPort = false;
    getInt("rdDirectPort", cfg.rdDirectPort, &hasRdDirectPort);
    getBool("rdLanDiscovery", cfg.rdLanDiscovery);
    getBool("rdPrivacyMode", cfg.rdPrivacyMode);
    getBool("rdAudioEnabled", cfg.rdAudioEnabled);
    getBool("rdClipboardEnabled", cfg.rdClipboardEnabled);
    getString("rdDriveName", cfg.rdDriveName);
    getString("rdDrivePath", cfg.rdDrivePath);
    getString("expectedRdpCertificateFingerprintSha256", cfg.expectedRdpCertificateFingerprintSha256);
    getString("expectedRdpGatewayCertificateFingerprintSha256",
              cfg.expectedRdpGatewayCertificateFingerprintSha256);
    getBool("rdpAllowUntrustedRoot", cfg.rdpAllowUntrustedRoot);
    getBool("rdpAllowHostMismatch", cfg.rdpAllowHostMismatch);
    getBool("rdpCertificateAllowUnpinnedOnce", cfg.rdpCertificateAllowUnpinnedOnce);
    getBool("rdpAllowStandardSecurityOnce", cfg.rdpAllowStandardSecurityOnce);
    getBool("rdpTlsWithoutNla", cfg.rdpTlsWithoutNla);
    getBool("rdpCertificateAllowTimeAnomalyOnce", cfg.rdpCertificateAllowTimeAnomalyOnce);
    getBool("rdpGatewayAllowUntrustedRoot", cfg.rdpGatewayAllowUntrustedRoot);
    getBool("rdpGatewayAllowHostMismatch", cfg.rdpGatewayAllowHostMismatch);
    getBool("rdpGatewayCertificateAllowUnpinnedOnce",
            cfg.rdpGatewayCertificateAllowUnpinnedOnce);
    getBool("rdpGatewayCertificateAllowTimeAnomalyOnce",
            cfg.rdpGatewayCertificateAllowTimeAnomalyOnce);
    getInt("rdPasswordMode", cfg.rdPasswordMode);
    getInt("rdAuthMode", cfg.rdAuthMode);
    getInt("rdPasswordLength", cfg.rdPasswordLength);
    getString("rdRelayId", cfg.rdRelayId);
    getString("rdAccountId", cfg.rdAccountId);
    getString("rdServerKey", cfg.rdServerKey);
    getInt("rdServerKeyMode", cfg.rdServerKeyMode);
    bool hasRdRelayPort = false;
    getInt("rdRelayPort", cfg.rdRelayPort, &hasRdRelayPort);
    getString("rdAccessToken", cfg.rdAccessToken);

    // VNC-only connection contract. These values are assembled from the
    // isolated VNC data domain and are ignored by the other adapters.
    getString("vncTransport", cfg.vncTransport);
    getString("vncGatewayHost", cfg.vncGatewayHost,
              remotedesk::endpoint::kMaxInputLength);
    bool hasVncGatewayPort = false;
    getInt("vncGatewayPort", cfg.vncGatewayPort, &hasVncGatewayPort);
    getString("vncServerName", cfg.vncServerName,
              remotedesk::endpoint::kMaxInputLength);
    getString("vncGatewayPath", cfg.vncGatewayPath);
    getString("vncRepeaterMode", cfg.vncRepeaterMode);
    getString("vncRepeaterTarget", cfg.vncRepeaterTarget);
    getBool("vncTls", cfg.vncTls);
    getBool("vncViewOnly", cfg.vncViewOnly);
    getBool("vncClipboardEnabled", cfg.vncClipboardEnabled);
    getString("vncSecurityPolicy", cfg.vncSecurityPolicy);
    getInt("vncConnectTimeoutMs", cfg.vncConnectTimeoutMs);
    getInt("vncAuthTimeoutMs", cfg.vncAuthTimeoutMs);
    getInt("vncFirstFrameTimeoutMs", cfg.vncFirstFrameTimeoutMs);
    getString("vncImageQualityPreset", cfg.vncImageQualityPreset);
    getString("vncPreferredEncoding", cfg.vncPreferredEncoding);
    getString("vncColorDepth", cfg.vncColorDepth);
    getInt("vncFrameRateLimit", cfg.vncFrameRateLimit);
    getString("vncExpectedCertificateFingerprintSha256", cfg.vncExpectedCertificateFingerprintSha256);

    if (cfg.rdConnectionStrategy.empty()) {
        cfg.rdConnectionStrategy = cfg.rdDirectIp ? "direct_ip" : "force_relay";
    } else if (cfg.rdConnectionStrategy == "direct_ip") {
        cfg.rdDirectIp = true;
    } else if (cfg.rdConnectionStrategy == "force_relay" ||
               cfg.rdConnectionStrategy == "auto") {
        cfg.rdDirectIp = false;
    } else {
        // Preserve an explicit invalid sentinel so native rejects the request
        // instead of silently changing a future/typoed strategy to relay.
        cfg.rdConnectionStrategy = "invalid";
        cfg.rdDirectIp = false;
    }
    if ((hasGatewayPort && (cfg.gatewayPort <= 0 || cfg.gatewayPort > 65535)) ||
        (hasRdDirectPort && (cfg.rdDirectPort <= 0 || cfg.rdDirectPort > 65535)) ||
        (hasRdRelayPort && (cfg.rdRelayPort <= 0 || cfg.rdRelayPort > 65535)) ||
        (hasVncGatewayPort &&
         (cfg.vncGatewayPort <= 0 || cfg.vncGatewayPort > 65535))) {
        invalidConfigField = true;
    }
    if (!hasRdDirectPort) cfg.rdDirectPort = 21118;
    if (!hasPort) {
        // RustDesk 的通用端口字段在直连模式代表 peer TCP 端口；
        // 非直连模式才代表 ID/rendezvous 端口，不能落回 RDP 3389。
        if (protocolName == "ssh") {
            cfg.port = 22;
        } else if (protocolName == "rustdesk") {
            cfg.port = cfg.rdDirectIp ? cfg.rdDirectPort : 21116;
        } else if (protocolName == "vnc") {
            cfg.port = 5900;
        } else {
            cfg.port = 3389;
        }
    }
    if (cfg.width == 0) cfg.width = 1920;
    if (cfg.height == 0) cfg.height = 1080;
    if (!hasGatewayPort) cfg.gatewayPort = 443;
    if (cfg.colorDepth == 0) cfg.colorDepth = 32;
    if (cfg.rdImageQuality < 0 || cfg.rdImageQuality > 2) cfg.rdImageQuality = 1;
    if (cfg.rdPasswordMode != 1) cfg.rdPasswordMode = 0;
    if (cfg.rdAuthMode != 1) cfg.rdAuthMode = 0;
    if (cfg.rdPasswordLength != 8 && cfg.rdPasswordLength != 10) cfg.rdPasswordLength = 6;
    if (cfg.rdServerKeyMode != 1 && cfg.rdServerKeyMode != 2) cfg.rdServerKeyMode = 0;
    if (!hasRdRelayPort) cfg.rdRelayPort = 21117;
    if (cfg.vncTransport.empty()) cfg.vncTransport = "direct_tcp";
    if (cfg.vncGatewayPath.empty()) cfg.vncGatewayPath = "/vnc";
    // An omitted mode gets the only viewer mode we currently support. An
    // explicitly unknown mode is preserved so policy/Native reject it
    // instead of silently changing the requested repeater role.
    if (cfg.vncRepeaterMode.empty()) cfg.vncRepeaterMode = "mode12";
    if (!hasVncGatewayPort) cfg.vncGatewayPort = 5901;
    if (cfg.vncConnectTimeoutMs <= 0 || cfg.vncConnectTimeoutMs > 120000) cfg.vncConnectTimeoutMs = 10000;
    if (cfg.vncAuthTimeoutMs <= 0 || cfg.vncAuthTimeoutMs > 120000) cfg.vncAuthTimeoutMs = 15000;
    if (cfg.vncFirstFrameTimeoutMs <= 0 || cfg.vncFirstFrameTimeoutMs > 120000) cfg.vncFirstFrameTimeoutMs = 15000;
    if (cfg.vncImageQualityPreset != "speed" && cfg.vncImageQualityPreset != "quality") {
        cfg.vncImageQualityPreset = "balanced";
    }
    if (cfg.vncPreferredEncoding != "raw" && cfg.vncPreferredEncoding != "zrle") {
        cfg.vncPreferredEncoding = "auto";
    }
    if (cfg.vncColorDepth != "32" && cfg.vncColorDepth != "16" && cfg.vncColorDepth != "8") {
        cfg.vncColorDepth = "auto";
    }
    if (cfg.vncFrameRateLimit != 0 && cfg.vncFrameRateLimit != 15 &&
        cfg.vncFrameRateLimit != 60) cfg.vncFrameRateLimit = 30;
    if (cfg.vncSecurityPolicy != "secure_only" && cfg.vncSecurityPolicy != "trusted_network" &&
        cfg.vncSecurityPolicy != "allow_plaintext") cfg.vncSecurityPolicy = "secure_only";

    if (invalidConfigField) {
        OH_LOG_ERROR(LOG_APP, "[ExtLoader] invalid NAPI connection config field type");
        napi_value errVal;
        napi_create_int32(env, protocolName == "ssh" ? ERR_SSH_PROXY_INVALID : -2, &errVal);
        return errVal;
    }

    if (protocolName == "rdp") {
        if (cfg.targetServerName.empty()) {
            cfg.targetServerName = cfg.customHostname;
        } else if (!cfg.customHostname.empty() &&
                   cfg.customHostname != cfg.targetServerName) {
            OH_LOG_ERROR(LOG_APP, "[ExtLoader] conflicting legacy and explicit RDP target identity");
            napi_value errVal;
            napi_create_int32(env, -2, &errVal);
            return errVal;
        }
    }

    bool endpointValid = true;
    if (protocolName == "rdp" || protocolName == "ssh" || protocolName == "rustdesk") {
        endpointValid = NormalizePersistedEndpoint(cfg.host, cfg.port);
    } else if (protocolName == "vnc") {
        if (cfg.vncTransport == "direct_tcp") {
            endpointValid = NormalizePersistedEndpoint(cfg.host, cfg.port);
        } else {
            endpointValid = NormalizePersistedEndpoint(cfg.vncGatewayHost, cfg.vncGatewayPort);
        }
    }
    if (endpointValid && protocolName == "rdp" && !cfg.gatewayHost.empty()) {
        endpointValid = NormalizePersistedEndpoint(cfg.gatewayHost, cfg.gatewayPort);
    }
    if (endpointValid && protocolName == "ssh" && !cfg.sshProxyHost.empty() &&
        cfg.sshProxyType != "legacy_gateway") {
        endpointValid = NormalizePersistedEndpoint(cfg.sshProxyHost, cfg.sshProxyPort);
    }
    if (endpointValid && protocolName == "rdp") {
        endpointValid = NormalizeServerIdentity(cfg.targetServerName) &&
            NormalizeServerIdentity(cfg.rdpGatewayServerName) &&
            RdpConnectionIdentityPolicy::clientHostnameIsValid(cfg.clientHostname);
        if (endpointValid) {
            cfg.customHostname = cfg.targetServerName;
        }
    }
    if (endpointValid && protocolName == "vnc") {
        endpointValid = NormalizeServerIdentity(cfg.vncServerName);
    }
    if (!endpointValid) {
        OH_LOG_ERROR(LOG_APP, "[ExtLoader] invalid or unsupported scoped endpoint");
        napi_value errVal;
        napi_create_int32(env, protocolName == "ssh" ? ERR_SSH_PROXY_INVALID : -2, &errVal);
        return errVal;
    }

    if (protocolName == "ssh") {
        if (!ParseSshRoute(env, args[0], cfg)) {
            OH_LOG_ERROR(LOG_APP, "[ExtLoader] invalid SSH route handoff");
            napi_value errVal;
            napi_create_int32(env, ERR_SSH_PROXY_INVALID, &errVal);
            return errVal;
        }
        if (!FinalizeSshRoute(cfg)) {
            OH_LOG_ERROR(LOG_APP, "[ExtLoader] SSH route validation failed");
            napi_value errVal;
            napi_create_int32(env, ERR_SSH_PROXY_INVALID, &errVal);
            return errVal;
        }
    }

    const std::string logHost = SafeLog::MaskHost(cfg.host);
    const std::string logGatewayHost = cfg.gatewayHost.empty() ? "无" : SafeLog::MaskHost(cfg.gatewayHost);
    const std::string logCustomHostname = cfg.targetServerName.empty() ?
        "未设置" : SafeLog::MaskHost(cfg.targetServerName);

    OH_LOG_INFO(LOG_APP, "[ExtLoader] 连接请求: %{public}s → %{public}s:%{public}d"
                " (分辨率:%{public}dx%{public}d, 多显:%{public}s, 网关:%{public}s:%{public}d, 主机名:%{public}s, 编码:%{public}s)",
                protocolName.c_str(), logHost.c_str(), cfg.port,
                cfg.width, cfg.height,
                cfg.multiMonitor ? "是" : "否",
                logGatewayHost.c_str(), cfg.gatewayPort,
                logCustomHostname.c_str(), codecName.c_str());

    if (protocolName == "rustdesk") {
        const std::string relayLog = cfg.rdRelayId.empty() ? "未设置" : SafeLog::HashForLog(cfg.rdRelayId);
        const std::string accountLog = cfg.rdAccountId.empty() ? "未设置" : SafeLog::MaskUser(cfg.rdAccountId);
        const char* serverKeyMode = cfg.rdServerKeyMode == 2 ? "shared" :
            (cfg.rdServerKeyMode == 1 ? "public" : "auto");
        OH_LOG_INFO(LOG_APP, "[ExtLoader] RustDesk配置: quality=%{public}d strategy=%{public}s directPort=%{public}d lan=%{public}s privacy=%{public}s audio=%{public}s pwdMode=%{public}d authMode=%{public}d pwdLen=%{public}d relayId=%{public}s account=%{public}s serverKeyMode=%{public}s relayFallbackPort=%{public}d proToken=%{public}s",
                    cfg.rdImageQuality, cfg.rdConnectionStrategy.c_str(), cfg.rdDirectPort,
                    cfg.rdLanDiscovery ? "on" : "off", cfg.rdPrivacyMode ? "on" : "off",
                    cfg.rdAudioEnabled ? "on" : "off",
                    cfg.rdPasswordMode, cfg.rdAuthMode, cfg.rdPasswordLength,
                    relayLog.c_str(), accountLog.c_str(), serverKeyMode, cfg.rdRelayPort,
                    cfg.rdAccessToken.empty() ? "absent" : "present");
    } else if (protocolName == "rdp") {
        const std::string drivePathLog = cfg.rdDrivePath.empty() ? "off" : SafeLog::HashForLog(cfg.rdDrivePath);
        const char* authMode = cfg.rdpAuthMode == RdpAuthenticationMode::RestrictedAdmin ? "restricted_admin" :
            (cfg.rdpAuthMode == RdpAuthenticationMode::BlankPassword ? "blank_password" : "password");
        const char* restrictedSource = "ntlm_hash";
        OH_LOG_INFO(LOG_APP,
            "[ExtLoader] RDP配置: desktop=%{public}dx%{public}d colorDepth=%{public}d audio=%{public}s clipboard=%{public}s driveName=%{public}s drivePathId=%{public}s authIdentityMode=%{public}d authMode=%{public}s restrictedSource=%{public}s hashLen=%{public}zu",
            cfg.width,
            cfg.height,
            cfg.colorDepth,
            cfg.rdAudioEnabled ? "on" : "off",
            cfg.rdClipboardEnabled ? "on" : "off",
            cfg.rdDriveName.empty() ? "RemoteDesktop" : cfg.rdDriveName.c_str(),
            drivePathLog.c_str(),
            cfg.rdpAuthIdentityMode,
            authMode,
            restrictedSource,
            cfg.rdpRestrictedAdminHash.length());
    }

    // 查找协议适配器
    auto adapter = CreateAdapterForSession(protocolName);
    if (!adapter) {
        OH_LOG_ERROR(LOG_APP, "[ExtLoader] 协议未找到: %{public}s", protocolName.c_str());
        napi_value errVal;
        napi_create_int32(env, -1, &errVal);
        return errVal;
    }

    // 创建会话
    auto session = std::shared_ptr<SessionContext>(new SessionContext());
    session->adapter = adapter;
    session->protocolName = protocolName;
    if (protocolName == "vnc") {
        session->vncConnectionPath =
            cfg.vncTransport == "ultravnc_repeater" ? "repeater" : "direct";
        session->vncRequestedColorDepth = cfg.vncColorDepth;
    }

    int sessionId = g_nextSessionId++;
    session->sessionId = static_cast<uint64_t>(sessionId);
    session->generation = g_nextSessionGeneration.fetch_add(1, std::memory_order_acq_rel);
    session->ownerToken = g_nextSessionOwnerToken.fetch_add(1, std::memory_order_acq_rel);
    adapter->setSessionIdentity(static_cast<uint64_t>(sessionId));
    if (auto* ssh = dynamic_cast<SshAdapter*>(adapter.get())) {
        ssh->setSessionGeneration(session->generation.load(std::memory_order_acquire));
    }
    if (auto* rustdesk = dynamic_cast<RustDeskBridge*>(adapter.get())) {
        session->generation = rustdesk->sessionGeneration();
        rustdesk->setSessionOwnerToken(session->ownerToken);
    }
    if (auto* rdp = dynamic_cast<FreeRdpAdapter*>(adapter.get())) {
        rdp->setSessionOwner(session->identity());
    }
    if (auto* vnc = dynamic_cast<VncAdapter*>(adapter.get())) {
        vnc->setSessionOwner(session->identity());
    }
    g_disconnectAllRequestId = 0;
    if (g_disconnectRequests.size() > 256) {
        const auto requests = g_disconnectRequests.snapshot();
        for (const auto& request : requests) {
            const SessionTeardown::State state = g_teardownExecutor.state(request.second);
            if (state == SessionTeardown::State::Complete ||
                state == SessionTeardown::State::Failed ||
                state == SessionTeardown::State::Unknown) {
                g_disconnectRequests.eraseIf(request.first, request.second);
            }
        }
    }
    g_sessionRegistry.insertOrAssign(sessionId, session);
    if (protocolName == "ssh") {
        const SshSessionHandle handle {
            static_cast<uint64_t>(sessionId), "shell",
            session->generation.load(std::memory_order_acquire)};
        const auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(adapter);
        const std::weak_ptr<SshAdapter> weakSshAdapter = sshAdapter;
        if (g_sshNativeFacade.registerSession(handle, cfg.host, cfg.port, sshAdapter,
            [weakSshAdapter](bool available, uint64_t networkGeneration) {
                const std::shared_ptr<SshAdapter> adapter = weakSshAdapter.lock();
                if (adapter) {
                    adapter->onNetworkChanged(available, networkGeneration);
                }
            }) != SshSessionManagerResult::Ok) {
            g_sessionRegistry.eraseIf(sessionId, session);
            napi_value errVal;
            napi_create_int32(env, ERR_SSH_SESSION_INIT, &errVal);
            return errVal;
        }
    }
    const bool deferSshActivation = protocolName == "ssh";
    if (!deferSshActivation) {
        // R0: existing desktop protocols keep their established activation
        // order for compatibility. SSH commits the same context only after
        // its synchronous connect succeeds below.
        if (!ActivateSessionContext(adapter, session->identity())) {
            // Activation is the admission boundary for decoder/audio/input
            // sinks.  Do not start a protocol worker when that transaction
            // could not publish a complete owner; otherwise the adapter can
            // connect successfully with no visible consumer and later
            // callbacks can be admitted against the previous session.
            session->lifecycle.store(SessionContext::Lifecycle::Failed,
                                     std::memory_order_release);
            PrepareAdapterForTeardown(adapter, session->identity());
            try {
                (void)DisconnectAdapterAndDrainVnc(adapter);
            } catch (...) {
                OH_LOG_ERROR(LOG_APP,
                    "[ExtLoader] adapter disconnect after activation failure threw");
            }
            g_sessionRegistry.eraseIf(sessionId, session);
            (void)DeactivateSessionContextIfActive(adapter, session->identity());
            napi_value errVal;
            napi_create_int32(env, -2, &errVal);
            return errVal;
        }
    }

    const std::weak_ptr<SessionContext> weakSession = session;
    const std::weak_ptr<ProtocolAdapter> weakAdapter = adapter;
    if (auto* rustdesk = dynamic_cast<RustDeskBridge*>(adapter.get())) {
        rustdesk->setContinuityGenerationCallback(
            [weakSession, weakAdapter](uint64_t reconnectSessionId,
                                       uint64_t reconnectGeneration,
                                       uint64_t reconnectOwnerToken) {
                const std::shared_ptr<SessionContext> session = weakSession.lock();
                const std::shared_ptr<ProtocolAdapter> adapter = weakAdapter.lock();
                if (!session || !adapter ||
                    session->lifecycle.load(std::memory_order_acquire) !=
                        SessionContext::Lifecycle::Active ||
                    session->sessionId != reconnectSessionId ||
                    session->ownerToken != reconnectOwnerToken) {
                    return false;
                }
                const uint64_t previousGeneration =
                    session->generation.load(std::memory_order_acquire);
                if (reconnectGeneration == previousGeneration) {
                    // Transport continuity keeps the native owner stable, but
                    // a prior surface/decoder transition may have cleared the
                    // active pipeline handle. Repair only a still-live pair;
                    // a destroyed renderer remains a foreground lifecycle job.
                    const DecoderSessionIdentity stableOwner = session->identity();
                    auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(
                        stableOwner);
                    if (!ownerLease || !DecoderNapi::IsActiveSessionOwner(stableOwner)) {
                        return false;
                    }
                    const bool videoRebound = DecoderNapi::RebindActiveVideoPipeline(
                        stableOwner);
                    if (videoRebound) {
                        adapter->requestFrameRefresh();
                    }
                    OH_LOG_INFO(LOG_APP,
                        "[ExtLoader] RustDesk continuity reused owner session=%{public}llu generation=%{public}llu videoRebound=%{public}s",
                        static_cast<unsigned long long>(reconnectSessionId),
                        static_cast<unsigned long long>(reconnectGeneration),
                        videoRebound ? "true" : "false");
                    return true;
                }
                session->generation.store(reconnectGeneration, std::memory_order_release);
                const bool activated = ActivateSessionContext(
                    adapter, session->identity());
                if (!activated) {
                    session->generation.store(previousGeneration, std::memory_order_release);
                    (void)ActivateSessionContext(adapter, session->identity());
                    return false;
                }
                OH_LOG_INFO(LOG_APP,
                    "[ExtLoader] RustDesk continuity generation committed session=%{public}llu generation=%{public}llu",
                    static_cast<unsigned long long>(reconnectSessionId),
                    static_cast<unsigned long long>(reconnectGeneration));
                return true;
            });
    }
    adapter->setConnectionStateCallback([weakSession](ConnectionState state, const std::string& message) {
        const std::shared_ptr<SessionContext> session = weakSession.lock();
        if (!session || session->lifecycle.load(std::memory_order_acquire) !=
            SessionContext::Lifecycle::Active) { return; }
        std::lock_guard<std::mutex> lock(session->messageMutex);
        session->lastStateMessage = message;
        const std::string logMessage = session->protocolName == "vnc" ?
            vncRedactCertificateMessageForLog(message) : message;
        OH_LOG_INFO(LOG_APP, "[ExtLoader] 状态变更: protocol=%{public}s state=%{public}d msg=%{public}s",
                    session->protocolName.c_str(), static_cast<int>(state), logMessage.c_str());
    });
    if (protocolName == "ssh") {
        const std::shared_ptr<SshAdapter> sshAdapter =
            std::dynamic_pointer_cast<SshAdapter>(adapter);
        if (sshAdapter) {
            sshAdapter->setSshLifecycleStateCallback(
                [weakSession](SshSessionLifecycleState state,
                              const std::string& eventType) {
                    const std::shared_ptr<SessionContext> session = weakSession.lock();
                    if (!session || session->lifecycle.load(std::memory_order_acquire) !=
                        SessionContext::Lifecycle::Active) {
                        return;
                    }
                    const SshSessionHandle handle {
                        session->sessionId, "shell",
                        session->generation.load(std::memory_order_acquire)};
                    (void)g_sshNativeFacade.transition(handle, state, eventType, "{}");
                });
        }
    }

    if (auto* rustdesk = dynamic_cast<RustDeskBridge*>(adapter.get())) {
        rustdesk->setDisplayStateCallback([weakSession](int display) {
            const std::shared_ptr<SessionContext> session = weakSession.lock();
            if (!IsSessionCallbackActive(session)) {
                return;
            }
            // RustDesk invokes this before its stream thread starts. The
            // decoder therefore knows the peer's current display before any
            // interleaved display frame can arrive.
            if (DecoderNapi::SetActiveDisplay(session->identity(), display)) {
                DecoderNapi::RequestActiveDecoderRecovery(session->identity());
            }
        });
    }

    if (auto* rdp = dynamic_cast<FreeRdpAdapter*>(adapter.get())) {
        rdp->setVideoTelemetryCallback([weakSession](
            int width, int height, size_t bytes, bool submitted) {
            const std::shared_ptr<SessionContext> session = weakSession.lock();
            if (!IsSessionCallbackActive(session)) {
                return;
            }
            const uint64_t nowMs = static_cast<uint64_t>(std::chrono::duration_cast<
                std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
            session->diagnostics.videoCallbacks.fetch_add(1, std::memory_order_relaxed);
            session->diagnostics.ingressFrames.fetch_add(1, std::memory_order_relaxed);
            session->diagnostics.ingressBytes.fetch_add(static_cast<uint64_t>(bytes),
                                                        std::memory_order_relaxed);
            session->diagnostics.lastCodec.store(static_cast<int>(CodecType::RAW_BGRA),
                                                 std::memory_order_relaxed);
            session->diagnostics.lastWidth.store(width, std::memory_order_relaxed);
            session->diagnostics.lastHeight.store(height, std::memory_order_relaxed);
            session->diagnostics.lastFrameAtMs.store(nowMs, std::memory_order_release);
            if (submitted) {
                session->diagnostics.presentedFrames.fetch_add(1, std::memory_order_relaxed);
                session->diagnostics.decodeOk.fetch_add(1, std::memory_order_relaxed);
                session->diagnostics.lastPresentedAtMs.store(nowMs, std::memory_order_release);
            } else {
                session->diagnostics.presentationRejected.fetch_add(1, std::memory_order_relaxed);
            }

            const auto now = std::chrono::steady_clock::now();
            Render::VideoPressureDecision pressureDecision;
            bool pressureWindowReady = false;
            {
                std::lock_guard<std::mutex> pressureLock(session->pressureSnapshotMutex);
                session->videoPerf.recordIngressFrame("rdp", width, height, bytes, true);
                // RDP GDI has no encoded decoder drop counters. A successful
                // callback is the decode-equivalent healthy sample for this
                // SessionContext window; the counter generation is the
                // session generation, not a process-global adapter counter.
                session->videoPerf.recordDecodeResult(
                    submitted ? 0 : -1, 0, 0, 0,
                    session->generation.load(std::memory_order_acquire));
                if (session->videoPressure.windowDue(now)) {
                    const Render::VideoPerfSnapshot window =
                        session->videoPerf.snapshotAndReset();
                    pressureDecision = session->videoPressure.observeAt(window, now);
                    session->lastPressureSnapshot = window;
                    session->lastPressureDecision = pressureDecision;
                    pressureWindowReady = pressureDecision.windowComplete;
                }
            }
            if (pressureWindowReady && IsSessionCallbackActive(session)) {
                ReportVideoPressureForSession(
                    session, static_cast<int>(pressureDecision.level));
            }
        });
    }

    adapter->setVideoCallback([weakSession](const VideoFrame& frame) {
        const std::shared_ptr<SessionContext> session = weakSession.lock();
        if (!IsSessionCallbackActive(session)) {
            return;
        }
        // VNC produces a complete raw BGRA framebuffer. It is deliberately
        // presented through the generation-safe raw renderer and never enters
        // the shared H.264/VPx decoder pipeline.
        if (session->protocolName == "vnc" && frame.codec == CodecType::RAW_BGRA) {
            const size_t required = frame.stride > 0 && frame.height > 0 ?
                static_cast<size_t>(frame.stride) * static_cast<size_t>(frame.height) : 0;
            if (frame.width <= 0 || frame.height <= 0 || frame.stride <= 0 || frame.size < required) {
                OH_LOG_WARN(LOG_APP,
                            "[ExtLoader][VNC-DIAG] reject invalid raw frame width=%{public}d height=%{public}d stride=%{public}d size=%{public}zu required=%{public}zu",
                            frame.width, frame.height, frame.stride, frame.size, required);
                return;
            }
            const uint64_t frameNumber = session->diagnostics.ingressFrames.fetch_add(
                1, std::memory_order_relaxed) + 1;
            session->diagnostics.ingressBytes.fetch_add(static_cast<uint64_t>(frame.size),
                                                        std::memory_order_relaxed);
            if (frame.isKeyFrame) {
                session->diagnostics.keyframes.fetch_add(1, std::memory_order_relaxed);
            }
            session->diagnostics.lastCodec.store(static_cast<int>(frame.codec), std::memory_order_relaxed);
            session->diagnostics.lastWidth.store(frame.width, std::memory_order_relaxed);
            session->diagnostics.lastHeight.store(frame.height, std::memory_order_relaxed);
            session->diagnostics.lastDirtyX.store(frame.dirtyX, std::memory_order_relaxed);
            session->diagnostics.lastDirtyY.store(frame.dirtyY, std::memory_order_relaxed);
            session->diagnostics.lastDirtyWidth.store(frame.dirtyWidth, std::memory_order_relaxed);
            session->diagnostics.lastDirtyHeight.store(frame.dirtyHeight, std::memory_order_relaxed);
            session->diagnostics.effectiveColorDepth.store(frame.colorDepth, std::memory_order_relaxed);
            session->diagnostics.sourceEncoding.store(
                frame.sourceEncoding, std::memory_order_relaxed);
            session->diagnostics.lastFrameAtMs.store(static_cast<uint64_t>(
                std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count()),
                std::memory_order_release);
            // VNC is a raw framebuffer path, but it still counts as active
            // remote video for the background media/PIP registration layer.
            recordRemoteVideoFrame(frame.size, frame.width, frame.height);
            RendererNapi::SetActiveSourceSize(session->identity(), frame.width, frame.height);
            const RdpPresentationTarget target =
                RendererNapi::GetActivePresentationTarget(session->identity());
            if (!target.ready()) {
                session->diagnostics.presentationRejected.fetch_add(1, std::memory_order_relaxed);
                OH_LOG_WARN(LOG_APP,
                            "[ExtLoader][VNC-DIAG] raw frame target not ready width=%{public}d height=%{public}d size=%{public}zu generation=%{public}llu rejection=%{public}d",
                            frame.width, frame.height, frame.size,
                            static_cast<unsigned long long>(target.generation),
                            static_cast<int>(target.rejection));
                return;
            }
            RdpPresentMetrics present;
            if (frame.dirtyX >= 0 && frame.dirtyY >= 0 && frame.dirtyWidth > 0 && frame.dirtyHeight > 0) {
                present = RendererNapi::PresentRawBgraRectActive(
                    session->identity(), frame.data, frame.size, frame.width, frame.height, frame.stride,
                    frame.dirtyX, frame.dirtyY, frame.dirtyWidth, frame.dirtyHeight,
                    target.generation);
            } else {
                present = RendererNapi::PresentRawBgraActive(
                    session->identity(), frame.data, frame.size, frame.width, frame.height, frame.stride,
                    target.generation);
            }
            if (present.presented()) {
                session->diagnostics.presentedFrames.fetch_add(1, std::memory_order_relaxed);
                session->diagnostics.decodeOk.fetch_add(1, std::memory_order_relaxed);
                session->diagnostics.lastPresentedAtMs.store(static_cast<uint64_t>(
                    std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now().time_since_epoch()).count()),
                    std::memory_order_release);
            } else {
                session->diagnostics.presentationRejected.fetch_add(1, std::memory_order_relaxed);
            }
            Render::VideoPressureDecision pressureDecision;
            bool pressureWindowReady = false;
            const auto pressureNow = std::chrono::steady_clock::now();
            {
                std::lock_guard<std::mutex> pressureLock(session->pressureSnapshotMutex);
                session->videoPerf.recordIngressFrame(
                    "vnc", frame.width, frame.height, frame.size, true);
                session->videoPerf.recordDecodeResult(
                    present.presented() ? 0 : -1, 0, 0, 0,
                    session->generation.load(std::memory_order_acquire));
                if (session->videoPressure.windowDue(pressureNow)) {
                    const Render::VideoPerfSnapshot window =
                        session->videoPerf.snapshotAndReset();
                    pressureDecision = session->videoPressure.observeAt(window, pressureNow);
                    session->lastPressureSnapshot = window;
                    session->lastPressureDecision = pressureDecision;
                    pressureWindowReady = pressureDecision.windowComplete;
                }
            }
            if (pressureWindowReady && IsSessionCallbackActive(session)) {
                ReportVideoPressureForSession(
                    session, static_cast<int>(pressureDecision.level));
            }
            if (frameNumber <= 8 || frameNumber % 60 == 0 || !present.presented()) {
                OH_LOG_INFO(LOG_APP,
                            "[ExtLoader][VNC-DIAG] raw frame presented count=%{public}llu size=%{public}zu framebuffer=%{public}dx%{public}d dirty=%{public}d,%{public}d %{public}dx%{public}d generation=%{public}llu result=%{public}d uploadUs=%{public}lld drawUs=%{public}lld swapUs=%{public}lld",
                            static_cast<unsigned long long>(frameNumber), frame.size, frame.width, frame.height,
                            frame.dirtyX, frame.dirtyY, frame.dirtyWidth, frame.dirtyHeight,
                            static_cast<unsigned long long>(target.generation),
                            static_cast<int>(present.result),
                            static_cast<long long>(present.uploadUs),
                            static_cast<long long>(present.drawUs),
                            static_cast<long long>(present.swapUs));
            }
            return;
        }
        const uint64_t callbackCount = session->diagnostics.videoCallbacks.fetch_add(
            1, std::memory_order_relaxed) + 1;
        // A preview pipeline owns a distinct decoder/NativeImage/renderer.
        // Submit before the single-canvas active-display gate so an auxiliary
        // display can render without ever entering the interactive pipeline.
        SubmitRustDeskMultiCanvasFrame(session, frame);
        if (!DecoderNapi::IsActiveDisplayFrame(session->identity(), frame)) {
            const uint64_t dropped = session->diagnostics.inactiveDisplayFrames.fetch_add(
                1, std::memory_order_relaxed) + 1;
            if (dropped <= 8 || dropped % 300 == 0) {
                OH_LOG_INFO(LOG_APP,
                    "[ExtLoader] drop inactive RustDesk display before render session=%{public}llu generation=%{public}llu display=%{public}d total=%{public}llu",
                    static_cast<unsigned long long>(session->sessionId),
                    static_cast<unsigned long long>(session->generation.load(
                        std::memory_order_acquire)),
                    frame.display,
                    static_cast<unsigned long long>(dropped));
            }
            return;
        }
        if (frame.width > 0 && frame.height > 0) {
            RendererNapi::SetActiveSourceSize(session->identity(), frame.width, frame.height);
        }
        const uint64_t frameCount = session->diagnostics.ingressFrames.fetch_add(
            1, std::memory_order_relaxed) + 1;
        session->diagnostics.ingressBytes.fetch_add(static_cast<uint64_t>(frame.size),
                                                    std::memory_order_relaxed);
        if (frame.isKeyFrame) {
            session->diagnostics.keyframes.fetch_add(1, std::memory_order_relaxed);
        }
        session->diagnostics.lastCodec.store(static_cast<int>(frame.codec), std::memory_order_relaxed);
        session->diagnostics.lastWidth.store(frame.width, std::memory_order_relaxed);
        session->diagnostics.lastHeight.store(frame.height, std::memory_order_relaxed);
        session->diagnostics.lastFrameAtMs.store(static_cast<uint64_t>(std::chrono::duration_cast<
            std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count()),
            std::memory_order_release);
        recordRemoteVideoFrame(frame.size, frame.width, frame.height);
        session->videoPerf.recordIngressFrame("rustdesk", frame.width, frame.height,
                                              frame.size, frame.isKeyFrame);
        const auto decodeStartedAt = std::chrono::steady_clock::now();
        int ret = DecoderNapi::DecodeActiveNative(session->identity(), frame);
        const int64_t decodeElapsedUs = std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - decodeStartedAt).count();
        if (ret < 0 || ret == DecoderNapi::kDecodeInactiveSession) {
            // connect() starts the RustDesk stream worker before ArkTS can
            // create/bind the shared decoder. Retain a keyframe across that
            // short owner-pipeline gap so the first visible frame is not
            // dependent on a later remote refresh.
            RememberPendingRustDeskKeyFrame(session, frame);
        }
        if (ret == DecoderNapi::kDecodeInactiveDisplay ||
            ret == DecoderNapi::kDecodeInactiveSession) {
            return;
        }
        const bool latencyRecoveryDrop =
            ret == DecoderNapi::kDecodeSoftwareFrameDropped ||
            ret == DecoderNapi::kDecodeSoftwareKeyframeRequired ||
            ret == DecoderNapi::kDecodeHardwareKeyframeRequired;
        if (ret == DecoderNapi::kDecodeSoftwareKeyframeRequired) {
            const bool requested = RequestFrameRefreshForSession(
                session, "software_decode_queue_overflow");
            OH_LOG_WARN(LOG_APP,
                "[ExtLoader] software decoder keyframe recovery session=%{public}llu requested=%{public}s",
                static_cast<unsigned long long>(session->sessionId),
                requested ? "yes" : "no");
        }
        if (ret == DecoderNapi::kDecodeHardwareKeyframeRequired) {
            const bool requested = RequestFrameRefreshForSession(
                session, "hardware_decode_queue_overflow");
            OH_LOG_WARN(LOG_APP,
                "[ExtLoader] hardware decoder keyframe recovery session=%{public}llu requested=%{public}s",
                static_cast<unsigned long long>(session->sessionId),
                requested ? "yes" : "no");
        }
        session->diagnostics.addDecodeSample(decodeElapsedUs);
        if (ret == 0) {
            session->diagnostics.decodeOk.fetch_add(1, std::memory_order_relaxed);
        } else if (!latencyRecoveryDrop) {
            session->diagnostics.decodeErrors.fetch_add(1, std::memory_order_relaxed);
        }
        switch (ret) {
            case -1: session->diagnostics.decodeRetNotReady.fetch_add(1, std::memory_order_relaxed); break;
            case -2: session->diagnostics.decodeRetBadCodec.fetch_add(1, std::memory_order_relaxed); break;
            case -3: session->diagnostics.decodeRetMismatch.fetch_add(1, std::memory_order_relaxed); break;
            default:
                if (ret < 0) {
                    session->diagnostics.decodeRetOther.fetch_add(1, std::memory_order_relaxed);
                }
                break;
        }

        // Decoder queue/drop values are cumulative, so feed the real sample
        // into this session's delta counter only when the generation check
        // succeeds. An inactive session must not reset another session's
        // drop baseline to zero.
        const DecoderTelemetrySnapshot decoderTelemetry =
            DecoderNapi::GetActiveTelemetry(session->identity());
        if (decoderTelemetry.valid) {
            bool resetTelemetry = false;
            Render::VideoPressureDecision pressureDecision;
            Render::VideoPerfSnapshot pressureWindow;
            bool pressureWindowReady = false;
            const auto now = std::chrono::steady_clock::now();
            {
                std::lock_guard<std::mutex> pressureLock(session->pressureSnapshotMutex);
                if (session->lastDecoderGeneration != decoderTelemetry.decoderGeneration ||
                    session->lastDisplayGeneration != decoderTelemetry.displayGeneration ||
                    session->lastDropCounterGeneration != decoderTelemetry.dropCounterGeneration) {
                    session->videoPerf.reset();
                    session->videoPressure.reset();
                    session->lastPressureSnapshot = Render::VideoPerfSnapshot {};
                    session->lastPressureDecision = Render::VideoPressureDecision {};
                    session->lastDecoderGeneration = decoderTelemetry.decoderGeneration;
                    session->lastDisplayGeneration = decoderTelemetry.displayGeneration;
                    session->lastDropCounterGeneration = decoderTelemetry.dropCounterGeneration;
                    resetTelemetry = true;
                }
                session->videoPerf.recordDecodeResult(
                    ret,
                    decoderTelemetry.queueDepth,
                    decoderTelemetry.inputDroppedFrames,
                    decoderTelemetry.waitKeyframeDrops,
                    decoderTelemetry.dropCounterGeneration);
                if (session->videoPressure.windowDue(now)) {
                    pressureWindow = session->videoPerf.snapshotAndReset();
                    // Full-resolution VP9 arrives in short TCP bursts on macOS.
                    // Requiring five consecutive overloaded windows misses a
                    // queue spike that reaches 17 frames and clears in the next
                    // second. Escalate that software-only path immediately;
                    // recovery remains debounced by the controller and Rust's
                    // VP9 recovery hold. Hardware codecs keep the default gate.
                    const bool immediateVp9SoftwarePressure =
                        decoderTelemetry.software && frame.codec == CodecType::VP9;
                    pressureDecision = session->videoPressure.observeAt(
                        pressureWindow, now, immediateVp9SoftwarePressure);
                    session->lastPressureSnapshot = pressureWindow;
                    session->lastPressureDecision = pressureDecision;
                    pressureWindowReady = pressureDecision.windowComplete;
                }
            }
            if (pressureWindowReady && IsSessionCallbackActive(session)) {
                // Native/session telemetry is the sole hysteresis owner. Rust
                // only applies this reported level to stream options.
                ReportVideoPressureForSession(
                    session, static_cast<int>(pressureDecision.level));
                OH_LOG_INFO(LOG_APP,
                    "[ExtLoader] video pressure window session=%{public}llu generation=%{public}llu callback#%{public}llu frames=%{public}llu decoderGeneration=%{public}llu displayGeneration=%{public}llu queueMax=%{public}zu dropsDelta=%{public}llu dropsTotal=%{public}llu decodeOk=%{public}llu decodeErrors=%{public}llu codecLatency=%{public}lldms codecLatencyMax=%{public}lldms lowLatency=%{public}s pressure=%{public}s timedOut=%{public}s bytes=%{public}llu reset=%{public}s",
                    static_cast<unsigned long long>(session->sessionId),
                    static_cast<unsigned long long>(session->generation.load(
                        std::memory_order_acquire)),
                    static_cast<unsigned long long>(callbackCount),
                    static_cast<unsigned long long>(frameCount),
                    static_cast<unsigned long long>(decoderTelemetry.decoderGeneration),
                    static_cast<unsigned long long>(decoderTelemetry.displayGeneration),
                    pressureWindow.decodeQueueMax,
                    static_cast<unsigned long long>(pressureWindow.decodeDrops),
                    static_cast<unsigned long long>(pressureWindow.decodeDropsTotal),
                    static_cast<unsigned long long>(pressureWindow.decodeOk),
                    static_cast<unsigned long long>(pressureWindow.decodeErrors),
                    static_cast<long long>(decoderTelemetry.codecLatencyMs),
                    static_cast<long long>(decoderTelemetry.codecLatencyMaxMs),
                    decoderTelemetry.lowLatencyEnabled ? "yes" : "no",
                    Render::videoPressureName(pressureDecision.level),
                    pressureDecision.timedOut ? "yes" : "no",
                    static_cast<unsigned long long>(pressureWindow.bytesTotal),
                    resetTelemetry ? "yes" : "no");
            }
        }
        if (frameCount <= 3 || (ret != 0 && !latencyRecoveryDrop)) {
            OH_LOG_INFO(LOG_APP,
                "[ExtLoader] video callback session=%{public}llu generation=%{public}llu callback#%{public}llu frame#%{public}llu codec=%{public}d frame=%{public}dx%{public}d size=%{public}zu key=%{public}s decodeRet=%{public}d queue=%{public}zu dropsTotal=%{public}llu hist[ok=%{public}llu nrdy=%{public}llu bad=%{public}llu mism=%{public}llu other=%{public}llu]",
                static_cast<unsigned long long>(session->sessionId),
                static_cast<unsigned long long>(session->generation.load(
                    std::memory_order_acquire)),
                static_cast<unsigned long long>(callbackCount),
                static_cast<unsigned long long>(frameCount),
                static_cast<int>(frame.codec),
                frame.width,
                frame.height,
                frame.size,
                frame.isKeyFrame ? "yes" : "no",
                ret,
                decoderTelemetry.queueDepth,
                static_cast<unsigned long long>(decoderTelemetry.droppedFrames),
                static_cast<unsigned long long>(session->diagnostics.decodeOk.load(std::memory_order_relaxed)),
                static_cast<unsigned long long>(session->diagnostics.decodeRetNotReady.load(std::memory_order_relaxed)),
                static_cast<unsigned long long>(session->diagnostics.decodeRetBadCodec.load(std::memory_order_relaxed)),
                static_cast<unsigned long long>(session->diagnostics.decodeRetMismatch.load(std::memory_order_relaxed)),
                static_cast<unsigned long long>(session->diagnostics.decodeRetOther.load(std::memory_order_relaxed)));
        }
    });

    // R2/R5 预留: video/audio callback 派发点
    // adapter->setVideoCallback([decoderHandle](const VideoFrame& frame) {
    //     DecoderNapi::dispatchFrame(decoderHandle, frame);
    // });
    // adapter->setAudioCallback([audioHandle](const AudioData& data) {
    //     AudioPlayerNapi::dispatchAudio(audioHandle, data);
    // });

    if (cfg.rdAudioEnabled) {
        adapter->setAudioCallback([weakSession](const AudioData& data) {
            const std::shared_ptr<SessionContext> session = weakSession.lock();
            if (!IsSessionCallbackActive(session)) {
                return;
            }
            const uint64_t audioCount = session->diagnostics.audioFrames.fetch_add(
                1, std::memory_order_relaxed) + 1;
            int ret = AudioPlayerNapi::DispatchActiveNative(
                session->identity(), data.data, data.size, data.sampleRate, data.channels);
            if (audioCount <= 10 || audioCount % 100 == 0 || ret < 0) {
                OH_LOG_INFO(LOG_APP,
                    "[ExtLoader] audio callback #%{public}llu size=%{public}zu rate=%{public}d channels=%{public}d dispatchRet=%{public}d",
                    static_cast<unsigned long long>(audioCount),
                    data.size,
                    data.sampleRate,
                    data.channels,
                    ret);
            }
        });
    } else {
        adapter->setAudioCallback(nullptr);
        OH_LOG_INFO(LOG_APP, "[ExtLoader] audio callback disabled by session config");
    }

    // 建立连接 — 回调必须先注册，避免 FreeRDP 连接线程早于 rdpsnd/OHAudio 回调。
    int ret = adapter->connect(cfg);
    // FreeRdpAdapter owns the independent session copy after connect().  The
    // NAPI stack copy is no longer needed even when thread creation fails.
    secureClearString(cfg.rdpRestrictedAdminHash);
    if (ret != 0) {
        OH_LOG_ERROR(LOG_APP, "[ExtLoader] 连接失败: ret=%{public}d host=%{public}s:%{public}d auth=%{public}s",
            ret, logHost.c_str(), cfg.port, cfg.authMethod.c_str());
        PrepareAdapterForTeardown(adapter, session->identity());
        session->lifecycle.store(SessionContext::Lifecycle::Failed,
                                 std::memory_order_release);
        // connect() is allowed to have allocated protocol resources before
        // returning an error.  Teardown must therefore be protocol-agnostic;
        // restricting this to SSH left failed RDP/RustDesk/VNC attempts with
        // live sockets, workers, or callback registrations.
        try {
            (void)DisconnectAdapterAndDrainVnc(adapter);
        } catch (...) {
            OH_LOG_ERROR(LOG_APP,
                "[ExtLoader] adapter disconnect after connect failure threw");
        }
        g_sessionRegistry.eraseIf(sessionId, session);
        if (protocolName == "ssh") {
            (void)g_sshNativeFacade.closeSession(SshSessionHandle {
                session->sessionId, "shell",
                session->generation.load(std::memory_order_acquire)});
            ClearNativeNetworkObserver(
                sessionId, session->generation.load(std::memory_order_acquire));
        }
        (void)DeactivateSessionContextIfActive(adapter, session->identity());
        napi_value errVal;
        napi_create_int32(env, ret, &errVal);  // 传递真实错误码而非通用 -2
        return errVal;
    }

    if (protocolName == "rustdesk" || protocolName == "ssh") {
        // RustDesk keeps one exact observer target; SSH dispatches through the
        // session manager and only needs the registration alive.
        UpdateNativeNetworkObserver(session);
    }

    OH_LOG_INFO(LOG_APP, "[ExtLoader] 连接成功, sessionId=%{public}d", sessionId);
    if (deferSshActivation) {
        ActivateSessionContext(adapter, session->identity());
    }

    napi_value result;
    napi_create_int32(env, sessionId, &result);
    return result;
    } catch (const std::exception& ex) {
        OH_LOG_ERROR(LOG_APP, "[ExtLoader] connect admission exception: %{public}s", ex.what());
    } catch (...) {
        OH_LOG_ERROR(LOG_APP, "[ExtLoader] connect admission unknown native exception");
    }
    napi_value errVal;
    napi_create_int32(env, -2, &errVal);
    return errVal;
}

static void ClearSshConnectionSecrets(ConnectionConfig& config) {
    secureClearString(config.password);
    secureClearString(config.privateKeyPem);
    secureClearString(config.privateKeyPassphrase);
    secureClearString(config.sshProxyPassword);
    secureClearString(config.sshProxyPrivateKeyPem);
    secureClearString(config.sshProxyPrivateKeyPassphrase);
    for (std::string& response : config.sshKeyboardInteractiveResponses) {
        secureClearString(response);
    }
    config.sshKeyboardInteractiveResponses.clear();
    for (std::string& response : config.sshProxyKeyboardInteractiveResponses) {
        secureClearString(response);
    }
    config.sshProxyKeyboardInteractiveResponses.clear();
    for (SshJumpHopHandoff& handoff : config.sshJumpHopHandoffs) {
        secureClearString(handoff.password);
        secureClearString(handoff.privateKeyPem);
        secureClearString(handoff.privateKeyPassphrase);
        for (std::string& response : handoff.keyboardInteractiveResponses) {
            secureClearString(response);
        }
        handoff.keyboardInteractiveResponses.clear();
    }
    config.sshJumpHopHandoffs.clear();
}

static bool ParseSshConnectionConfig(napi_env env, napi_value value,
                                      ConnectionConfig& config) {
    napi_valuetype valueType = napi_undefined;
    if (value == nullptr || napi_typeof(env, value, &valueType) != napi_ok ||
        valueType != napi_object) {
        return false;
    }

    bool invalidConfigField = false;
    auto getString = [&](const char* key, std::string& out,
                         size_t maxLength = kMaxGenericNapiStringLength) {
        bool present = false;
        if (napi_has_named_property(env, value, key, &present) != napi_ok) {
            invalidConfigField = true;
            return;
        }
        if (!present) { return; }
        napi_value item;
        if (napi_get_named_property(env, value, key, &item) != napi_ok) {
            invalidConfigField = true;
            return;
        }
        napi_valuetype type = napi_undefined;
        if (napi_typeof(env, item, &type) != napi_ok) {
            invalidConfigField = true;
            return;
        }
        if (type == napi_undefined) { return; }
        if (type != napi_string ||
            !ReadBoundedNapiStringValue(env, item, maxLength, out)) {
            invalidConfigField = true;
        }
    };
    auto getInt = [&](const char* key, int& out, bool* present = nullptr) {
        bool propertyPresent = false;
        if (napi_has_named_property(env, value, key, &propertyPresent) != napi_ok) {
            invalidConfigField = true;
            return;
        }
        if (!propertyPresent) { return; }
        napi_value item;
        napi_valuetype type = napi_undefined;
        if (napi_get_named_property(env, value, key, &item) != napi_ok ||
            napi_typeof(env, item, &type) != napi_ok) {
            invalidConfigField = true;
            return;
        }
        if (type == napi_undefined) { return; }
        int32_t parsed = 0;
        if (type != napi_number || !ReadStrictNapiInt32Value(env, item, parsed)) {
            invalidConfigField = true;
            return;
        }
        out = parsed;
        if (present != nullptr) { *present = true; }
    };
    auto getBool = [&](const char* key, bool& out) {
        bool present = false;
        if (napi_has_named_property(env, value, key, &present) != napi_ok) {
            invalidConfigField = true;
            return;
        }
        if (!present) { return; }
        napi_value item;
        napi_valuetype type = napi_undefined;
        if (napi_get_named_property(env, value, key, &item) != napi_ok ||
            napi_typeof(env, item, &type) != napi_ok) {
            invalidConfigField = true;
            return;
        }
        if (type == napi_undefined) { return; }
        if (type != napi_boolean || napi_get_value_bool(env, item, &out) != napi_ok) {
            invalidConfigField = true;
        }
    };

    std::string protocol;
    getString("protocol", protocol, 32);
    if (protocol != "ssh") { return false; }
    getString("host", config.host, remotedesk::endpoint::kMaxInputLength);
    bool hasPort = false;
    getInt("port", config.port, &hasPort);
    getString("username", config.username);
    getString("password", config.password);
    getInt("width", config.width);
    getInt("height", config.height);
    getString("authMethod", config.authMethod);
    getString("privateKeyPem", config.privateKeyPem);
    getString("privateKeyPassphrase", config.privateKeyPassphrase);
    getString("sshLocale", config.sshLocale);
    if (!SshSessionLocaleIsSupported(config.sshLocale)) { return false; }
    getString("expectedHostKeyRawBase64", config.expectedHostKeyRawBase64);
    getString("expectedHostKeyFingerprintSha256", config.expectedHostKeyFingerprintSha256);
    getBool("sshHostKeyPromptEnabled", config.sshHostKeyPromptEnabled);
    getString("sshTrustHostId", config.sshTrustHostId);
    getString("sshJumpHostKeyRawBase64", config.sshJumpHostKeyRawBase64);
    getString("sshJumpHostKeyFingerprintSha256", config.sshJumpHostKeyFingerprintSha256);
    getString("sshProxyType", config.sshProxyType);
    getString("sshProxyHost", config.sshProxyHost,
              remotedesk::endpoint::kMaxInputLength);
    getInt("sshProxyPort", config.sshProxyPort);
    getString("sshProxyUsername", config.sshProxyUsername);
    getString("sshProxyPassword", config.sshProxyPassword);
    getString("sshProxyAuthMethod", config.sshProxyAuthMethod);
    getString("sshProxyPrivateKeyPem", config.sshProxyPrivateKeyPem);
    getString("sshProxyPrivateKeyPassphrase", config.sshProxyPrivateKeyPassphrase);
    // Keep the legacy generic gateway fail-closed behavior identical to the
    // synchronous connect path; never silently turn it into a direct socket.
    std::string gatewayHost;
    int gatewayPort = 0;
    getString("gatewayHost", gatewayHost,
              remotedesk::endpoint::kMaxInputLength);
    getInt("gatewayPort", gatewayPort);
    if (config.sshProxyHost.empty() && !gatewayHost.empty()) {
        config.sshProxyHost = gatewayHost;
        config.sshProxyPort = gatewayPort;
        if (config.sshProxyType.empty()) { config.sshProxyType = "legacy_gateway"; }
    }

    napi_value responseValue;
    bool isArray = false;
    if (napi_get_named_property(env, value, "keyboardInteractiveResponses",
                                &responseValue) == napi_ok &&
        napi_is_array(env, responseValue, &isArray) == napi_ok && isArray) {
        uint32_t responseCount = 0;
        if (napi_get_array_length(env, responseValue, &responseCount) == napi_ok) {
            responseCount = std::min<uint32_t>(responseCount, 32);
            for (uint32_t index = 0; index < responseCount; ++index) {
                napi_value item;
                if (napi_get_element(env, responseValue, index, &item) != napi_ok) { continue; }
                napi_valuetype itemType = napi_undefined;
                if (napi_typeof(env, item, &itemType) != napi_ok || itemType != napi_string) {
                    continue;
                }
                std::string response;
                if (!ReadBoundedNapiStringValue(env, item, 4096, response)) { continue; }
                config.sshKeyboardInteractiveResponses.push_back(std::move(response));
            }
        }
    }
    ParseBoundedSshResponseArray(env, value,
                                 "sshProxyKeyboardInteractiveResponses",
                                 config.sshProxyKeyboardInteractiveResponses);

    if (invalidConfigField) { return false; }
    if (config.host.empty() || config.username.empty()) { return false; }
    if (!hasPort) { config.port = 22; }
    if (!NormalizePersistedEndpoint(config.host, config.port)) { return false; }
    if (config.width <= 0) { config.width = 80; }
    if (config.height <= 0) { config.height = 24; }
    if (config.authMethod.empty()) { config.authMethod = "password"; }
    if (config.sshProxyType.empty()) {
        config.sshProxyType = config.sshProxyHost.empty() ? "direct" : "http_connect";
    }
    if (!config.sshProxyHost.empty() && config.sshProxyType != "legacy_gateway" &&
        !NormalizePersistedEndpoint(config.sshProxyHost, config.sshProxyPort)) {
        return false;
    }
    // Parse after the SSH port default is known. An explicit route without an
    // endpointPort must inherit config.port instead of the route struct's
    // historical 22 default.
    if (!ParseSshRoute(env, value, config)) { return false; }
    return FinalizeSshRoute(config);
}

struct SshConnectAsyncData {
    int sessionId = -1;
    uint64_t generation = 0;
    std::shared_ptr<SshAdapter> adapter;
    std::shared_ptr<SessionContext> session;
    ConnectionConfig config;
    int resultCode = ERR_SSH_SESSION_INIT;
    bool workerFailed = false;
    // Detached SFTP peer sessions must remain addressable through the session
    // registry without taking ownership of the process-wide input/decoder.
    bool foreground = true;
    std::string errorMessage;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;

    ~SshConnectAsyncData() {
        ClearSshConnectionSecrets(config);
    }
};

static void CleanupSshConnectFailure(SshConnectAsyncData& data) {
    if (data.session) {
        data.session->lifecycle.store(SessionContext::Lifecycle::Failed,
                                      std::memory_order_release);
    }
    g_sessionRegistry.eraseIf(data.sessionId, data.session);
    if (data.session) {
        (void)g_sshNativeFacade.closeSession(SshSessionHandle {
            data.session->sessionId, "shell",
            data.session->generation.load(std::memory_order_acquire)});
        ClearNativeNetworkObserver(
            data.sessionId, data.session->generation.load(std::memory_order_acquire));
    }
    if (data.session && data.foreground) {
        DeactivateSessionContextIfActive(data.adapter, data.session->identity());
    }
    if (data.adapter) {
        // Keep callback registration and adapter teardown in the same gate as
        // normal disconnect. A failed async connect can still race a late
        // setOnDataCallback(nullptr) from the page; calling the adapter
        // directly here would let reader stop/join overlap callback publish.
        if (data.session) {
            std::lock_guard<std::mutex> callbackRegistrationLock(
                data.session->callbackRegistrationMutex);
            StopSshDataRegistration(data.sessionId, data.adapter);
            PrepareAdapterForTeardown(data.adapter, data.session->identity());
        } else {
            PrepareAdapterForTeardown(data.adapter, DecoderSessionIdentity {});
        }
        data.adapter->disconnect();
    }
}

static bool RegisterSshConnectSession(SshConnectAsyncData& data) {
    try {
        data.adapter = std::make_shared<SshAdapter>();
    } catch (...) {
        data.adapter.reset();
        return false;
    }
    if (!data.adapter) { return false; }
    data.session = std::shared_ptr<SessionContext>(new (std::nothrow) SessionContext());
    if (!data.session) {
        data.adapter.reset();
        return false;
    }
    data.session->adapter = data.adapter;
    data.session->protocolName = "ssh";
    data.sessionId = g_nextSessionId++;
    data.session->sessionId = static_cast<uint64_t>(data.sessionId);
    data.session->generation = g_nextSessionGeneration.fetch_add(1, std::memory_order_acq_rel);
    data.generation = data.session->generation.load(std::memory_order_acquire);
    data.session->ownerToken = g_nextSessionOwnerToken.fetch_add(1, std::memory_order_acq_rel);
    data.session->sharedSinkForeground = data.foreground;
    data.adapter->setSessionIdentity(static_cast<uint64_t>(data.sessionId));
    data.adapter->setSessionGeneration(data.session->generation.load(std::memory_order_acquire));
    g_sessionRegistry.insertOrAssign(data.sessionId, data.session);
    const std::weak_ptr<SshAdapter> weakAdapter = data.adapter;
    if (g_sshNativeFacade.registerSession(SshSessionHandle {
            data.session->sessionId, "shell",
            data.session->generation.load(std::memory_order_acquire)},
            data.config.host, data.config.port, data.adapter,
            [weakAdapter](bool available, uint64_t networkGeneration) {
                const std::shared_ptr<SshAdapter> adapter = weakAdapter.lock();
                if (adapter) {
                    adapter->onNetworkChanged(available, networkGeneration);
                }
            }) != SshSessionManagerResult::Ok) {
        g_sessionRegistry.eraseIf(data.sessionId, data.session);
        data.adapter.reset();
        data.session.reset();
        return false;
    }

    const std::weak_ptr<SessionContext> weakSession = data.session;
    data.adapter->setConnectionStateCallback(
        [weakSession](ConnectionState state, const std::string& message) {
            const std::shared_ptr<SessionContext> session = weakSession.lock();
            if (!session) { return; }
            std::lock_guard<std::mutex> lock(session->messageMutex);
            session->lastStateMessage = message;
            OH_LOG_INFO(LOG_APP,
                "[ExtLoader] SSH async 状态变更 state=%{public}d msg=%{public}s",
                static_cast<int>(state), message.c_str());
        });
    const std::weak_ptr<SessionContext> lifecycleSession = data.session;
    data.adapter->setSshLifecycleStateCallback(
        [lifecycleSession](SshSessionLifecycleState state,
                           const std::string& eventType) {
            const std::shared_ptr<SessionContext> session = lifecycleSession.lock();
            if (!session || session->lifecycle.load(std::memory_order_acquire) !=
                SessionContext::Lifecycle::Active) {
                return;
            }
            const SshSessionHandle handle {
                session->sessionId, "shell",
                session->generation.load(std::memory_order_acquire)};
            (void)g_sshNativeFacade.transition(handle, state, eventType, "{}");
        });
    return true;
}

static void ExecuteSshConnectAsync(napi_env /*env*/, void* rawData) {
    auto* data = static_cast<SshConnectAsyncData*>(rawData);
    if (data == nullptr || !data->adapter) { return; }
    try {
        data->resultCode = data->adapter->connect(data->config);
    } catch (const std::exception& ex) {
        data->workerFailed = true;
        data->errorMessage = std::string("SSH async connect failed: ") + ex.what();
        data->resultCode = ERR_SSH_SESSION_INIT;
    } catch (...) {
        data->workerFailed = true;
        data->errorMessage = "SSH async connect failed: unknown native exception";
        data->resultCode = ERR_SSH_SESSION_INIT;
    }
}

static void CompleteSshConnectAsync(napi_env env, napi_status status, void* rawData) {
    auto* data = static_cast<SshConnectAsyncData*>(rawData);
    if (data == nullptr) { return; }
    const auto completionStartedAt = std::chrono::steady_clock::now();
    const auto elapsedMs = [&completionStartedAt]() -> long long {
        return std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - completionStartedAt).count();
    };
    OH_LOG_INFO(LOG_APP,
        "[ExtLoader] SSH async completion begin id=%{public}d elapsedMs=%{public}lld",
        data->sessionId, elapsedMs());
    RemovePendingSshConnect(data->sessionId, data->generation);
    const bool lifecycleActive = data->session &&
        data->session->lifecycle.load(std::memory_order_acquire) ==
        SessionContext::Lifecycle::Active;
    const bool failed = status != napi_ok || data->workerFailed ||
        data->resultCode != 0 || !lifecycleActive;
    if (failed) {
        if (data->adapter) { CleanupSshConnectFailure(*data); }
        const int failureCode = status != napi_ok || data->workerFailed ||
            !lifecycleActive || data->resultCode == 0
            ? ERR_SSH_SESSION_INIT : data->resultCode;
        napi_value result;
        napi_create_int32(env, failureCode, &result);
        napi_resolve_deferred(env, data->deferred, result);
    } else {
        // Do not switch the global decoder/input target until the worker has
        // completed DNS, proxy negotiation, KEX, host-key verification and
        // authentication successfully. A failed or cancelled pending SSH
        // connection must not disturb an already active protocol session.
        if (data->foreground &&
            !ActivateSessionContext(data->adapter, data->session->identity())) {
            // A successful SSH handshake is not enough to expose a session:
            // the shared sink owner must be committed first.  Reuse the same
            // failure path so no connected adapter is left registered without
            // a decoder/input destination.
            CleanupSshConnectFailure(*data);
            napi_value result;
            napi_create_int32(env, ERR_SSH_SESSION_INIT, &result);
            napi_resolve_deferred(env, data->deferred, result);
            napi_delete_async_work(env, data->work);
            delete data;
            return;
        }
        OH_LOG_INFO(LOG_APP,
            "[ExtLoader] SSH async completion owner=%{public}s id=%{public}d elapsedMs=%{public}lld",
            data->foreground ? "foreground" : "detached",
            data->sessionId, elapsedMs());
        UpdateNativeNetworkObserver(data->session);
        OH_LOG_INFO(LOG_APP,
            "[ExtLoader] SSH async completion observer done id=%{public}d elapsedMs=%{public}lld",
            data->sessionId, elapsedMs());
        napi_value result;
        napi_create_int32(env, data->sessionId, &result);
        napi_resolve_deferred(env, data->deferred, result);
        OH_LOG_INFO(LOG_APP,
            "[ExtLoader] SSH async completion resolved id=%{public}d elapsedMs=%{public}lld",
            data->sessionId, elapsedMs());
    }
    napi_delete_async_work(env, data->work);
    delete data;
}

/** NAPI: getPendingSshConnectId(): number */
napi_value NapiGetPendingSshConnectId(napi_env env, napi_callback_info /*info*/) {
    napi_value result;
    napi_create_int32(env, GetPendingSshConnectIdSnapshot(), &result);
    return result;
}

/** NAPI: getPendingSshConnectIds(): number[] */
napi_value NapiGetPendingSshConnectIds(napi_env env, napi_callback_info /*info*/) {
    napi_value result;
    napi_create_array(env, &result);
    const std::vector<int> pendingIds = GetPendingSshConnectIdsSnapshot();
    for (size_t index = 0; index < pendingIds.size(); ++index) {
        napi_value item;
        napi_create_int32(env, pendingIds[index], &item);
        napi_set_element(env, result, index, item);
    }
    return result;
}

/** NAPI: connectSshAsync(config: SessionConfig, foreground?: boolean): Promise<number> */
napi_value NapiConnectSshAsync(napi_env env, napi_callback_info info) {
    std::unique_ptr<SshConnectAsyncData> data;
    bool asyncWorkCreated = false;
    bool pendingAdded = false;
    try {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "SSH config is required");
        return nullptr;
    }
    ConnectionConfig config;
    SshSecretGuard secretGuard {config};
    if (!ParseSshConnectionConfig(env, args[0], config)) {
        napi_throw_type_error(env, nullptr, "invalid SSH connection config");
        return nullptr;
    }

    data.reset(new (std::nothrow) SshConnectAsyncData());
    if (!data) {
        napi_throw_error(env, nullptr, "SSH async connect allocation failed");
        return nullptr;
    }
    data->config = std::move(config);
    if (argc > 1 && args[1] != nullptr) {
        napi_valuetype foregroundType = napi_undefined;
        if (napi_typeof(env, args[1], &foregroundType) != napi_ok ||
            foregroundType != napi_boolean ||
            napi_get_value_bool(env, args[1], &data->foreground) != napi_ok) {
            napi_throw_type_error(env, nullptr, "foreground must be a boolean");
            return nullptr;
        }
    }
    if (!RegisterSshConnectSession(*data)) {
        napi_throw_error(env, nullptr, "SSH async session allocation failed");
        return nullptr;
    }

    napi_value promise;
    napi_status status = napi_create_promise(env, &data->deferred, &promise);
    if (status != napi_ok) {
        CleanupSshConnectFailure(*data);
        napi_throw_error(env, nullptr, "SSH async connect promise creation failed");
        return nullptr;
    }
    napi_value resource;
    status = napi_create_string_utf8(env, "SshConnectAsync", NAPI_AUTO_LENGTH, &resource);
    if (status != napi_ok) {
        CleanupSshConnectFailure(*data);
        napi_throw_error(env, nullptr, "SSH async connect resource creation failed");
        return nullptr;
    }
    status = napi_create_async_work(env, resource, resource,
        ExecuteSshConnectAsync, CompleteSshConnectAsync, data.get(), &data->work);
    if (status != napi_ok) {
        CleanupSshConnectFailure(*data);
        napi_throw_error(env, nullptr, "SSH async connect work creation failed");
        return nullptr;
    }
    asyncWorkCreated = true;
    AddPendingSshConnect(data->sessionId, data->generation);
    pendingAdded = true;
    // The Promise itself carries the reserved identity.  This avoids a race
    // where two callers read one process-global "pending" id after both
    // requests have been admitted.
    SetObjectInt32(env, promise, "sessionId", data->sessionId);
    SetObjectInt64(env, promise, "generation", static_cast<int64_t>(
        data->session->generation.load(std::memory_order_acquire)));
    status = napi_queue_async_work(env, data->work);
    if (status != napi_ok) {
        RemovePendingSshConnect(data->sessionId, data->generation);
        pendingAdded = false;
        napi_delete_async_work(env, data->work);
        asyncWorkCreated = false;
        CleanupSshConnectFailure(*data);
        napi_throw_error(env, nullptr, "SSH async connect work queue failed");
        return nullptr;
    }
    data.release();
    return promise;
    } catch (const std::exception& ex) {
        if (data) {
            if (pendingAdded) {
                RemovePendingSshConnect(data->sessionId, data->generation);
            }
            if (asyncWorkCreated && data->work != nullptr) {
                napi_delete_async_work(env, data->work);
            }
            if (data->adapter) {
                try { CleanupSshConnectFailure(*data); } catch (...) {}
            }
        }
        napi_throw_error(env, nullptr, ex.what());
        return nullptr;
    } catch (...) {
        if (data) {
            if (pendingAdded) {
                RemovePendingSshConnect(data->sessionId, data->generation);
            }
            if (asyncWorkCreated && data->work != nullptr) {
                napi_delete_async_work(env, data->work);
            }
            if (data->adapter) {
                try { CleanupSshConnectFailure(*data); } catch (...) {}
            }
        }
        napi_throw_error(env, nullptr, "SSH async connect native exception");
        return nullptr;
    }
}

struct TeardownNativeResources {
    int64_t rendererHandle = -1;
    int64_t decoderHandle = -1;
    int64_t audioHandle = -1;
    DecoderSessionIdentity owner;
    std::shared_ptr<AudioPlayer> activeAudioPlayer;
};

static int64_t GetOptionalHandle(napi_env env, size_t argc, napi_value* args, size_t index) {
    int64_t handle = -1;
    if (index < argc) {
        napi_get_value_int64(env, args[index], &handle);
    }
    return handle;
}

static void DeactivateNativeResources(TeardownNativeResources& resources) {
    if (resources.owner.valid()) {
        RendererNapi::DeactivateRenderer(resources.rendererHandle, resources.owner);
        DecoderNapi::DeactivateDecoder(resources.decoderHandle, resources.owner);
        resources.activeAudioPlayer = AudioPlayerNapi::TakeActiveNative(resources.owner);
    } else {
        OH_LOG_WARN(LOG_APP,
            "[ExtLoader][SHUTDOWN] reject unowned native teardown to protect active session");
    }
    // Video activity is legacy process-wide state. Only the still-active
    // owner may clear it; a stale S1 teardown must not blank S2's HUD state.
    if (resources.owner.valid() &&
        Render::SharedSessionSinkOwnerLease().accepts(resources.owner)) {
        resetRemoteVideoActivity();
    }
}

static void DestroyNativeResources(TeardownNativeResources resources) {
    OH_LOG_INFO(LOG_APP, "[ExtLoader][SHUTDOWN] phase=decoder-destroy-begin");
    if (resources.owner.valid()) {
        DecoderNapi::DestroyDecoderHandle(resources.decoderHandle, resources.owner);
    }
    OH_LOG_INFO(LOG_APP, "[ExtLoader][SHUTDOWN] phase=decoder-destroy-return");
    OH_LOG_INFO(LOG_APP, "[ExtLoader][SHUTDOWN] phase=renderer-destroy-begin");
    if (resources.owner.valid()) {
        RendererNapi::DestroyRendererHandle(resources.rendererHandle, resources.owner);
    }
    OH_LOG_INFO(LOG_APP, "[ExtLoader][SHUTDOWN] phase=renderer-destroy-return");
    OH_LOG_INFO(LOG_APP, "[ExtLoader][SHUTDOWN] phase=audio-destroy-begin");
    AudioPlayerNapi::DestroyDetachedNative(
        resources.audioHandle, std::move(resources.activeAudioPlayer), resources.owner);
    OH_LOG_INFO(LOG_APP, "[ExtLoader][SHUTDOWN] phase=audio-destroy-return");
}

static void PrepareAdapterForTeardown(
    const std::shared_ptr<ProtocolAdapter>& adapter,
    const DecoderSessionIdentity& owner) {
    if (!adapter || !owner.valid()) {
        return;
    }
    auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!ownerLease) {
        OH_LOG_INFO(LOG_APP,
            "[ExtLoader][SHUTDOWN] skip stale adapter callback clear session=%{public}llu generation=%{public}llu",
            static_cast<unsigned long long>(owner.sessionId),
            static_cast<unsigned long long>(owner.generation));
        return;
    }
    adapter->setConnectionStateCallback(nullptr);
    adapter->setVideoCallback(nullptr);
    adapter->setAudioCallback(nullptr);
    if (auto* ssh = dynamic_cast<SshAdapter*>(adapter.get())) {
        // Cancel before enqueueing the potentially blocking disconnect task;
        // this also covers an async SSH worker that has not started yet.
        ssh->rejectTerminalInput();
        ssh->requestConnectCancel();
    }
    if (auto* rustdesk = dynamic_cast<RustDeskBridge*>(adapter.get())) {
        rustdesk->setDisplayStateCallback(nullptr);
    }
}

static bool DisconnectAdapterAndDrainVnc(
    const std::shared_ptr<ProtocolAdapter>& adapter) {
    if (!adapter) {
        return true;
    }
    adapter->disconnect();
    if (dynamic_cast<VncAdapter*>(adapter.get()) == nullptr) {
        return true;
    }
    const bool drained = VncRfbEngine::drainDeferredJoinsWithin(
        std::chrono::seconds(10));
    if (!drained) {
        OH_LOG_ERROR(LOG_APP,
            "[ExtLoader][SHUTDOWN] VNC deferred worker did not reach done fence");
    }
    return drained;
}

static bool HasNativeResources(const TeardownNativeResources& resources) {
    return resources.rendererHandle > 0 || resources.decoderHandle > 0 ||
        resources.audioHandle > 0;
}

struct NativeDisconnectCoreResult {
    bool accepted = false;
    uint64_t requestId = 0;
    SessionTeardown::State immediateState = SessionTeardown::State::Unknown;
};

template <typename Task>
static SessionTeardown::State RunSynchronousTeardownTask(Task& task) noexcept {
    try {
        task();
        return SessionTeardown::State::Complete;
    } catch (...) {
        return SessionTeardown::State::Failed;
    }
}

static SessionTeardown::State TeardownStateForLifecycle(
    SessionContext::Lifecycle lifecycle) {
    if (lifecycle == SessionContext::Lifecycle::Complete) {
        return SessionTeardown::State::Complete;
    }
    if (lifecycle == SessionContext::Lifecycle::Failed) {
        return SessionTeardown::State::Failed;
    }
    return SessionTeardown::State::Unknown;
}

static NativeDisconnectCoreResult BeginSessionTeardown(
    int32_t sessionId, TeardownNativeResources resources,
    const DecoderSessionIdentity& expectedOwner = {}) {

    std::shared_ptr<SessionContext> session;
    const auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end()) {
        session = it->second;
    }
    // Exact callers carry the native generation and owner token captured when
    // their page/facade acquired the session.  Reject before touching TSFNs,
    // resources or lifecycle state when a numeric id has since been recycled.
    if (expectedOwner.valid() &&
        (!session || session->identity() != expectedOwner)) {
        return {};
    }
    if (sessionId > 0) {
        const uint64_t existing = g_disconnectRequests.find(sessionId);
        if (existing != 0) {
            return {true, existing, SessionTeardown::State::Unknown};
        }
    }
    if (!session) {
        // The registry may already have been erased by an earlier teardown.
        // No new registration can pass the lookup in that state, so reclaim
        // any remaining TSFN before handling resource-only teardown.
        StopSshDataRegistration(sessionId, nullptr);
        if (!HasNativeResources(resources)) {
            return {true, 0, SessionTeardown::State::Complete};
        }
        DeactivateNativeResources(resources);
        auto resourceTask = [resources = std::move(resources)]() mutable {
            DestroyNativeResources(std::move(resources));
        };
        const uint64_t resourceRequestId = g_teardownExecutor.enqueue(resourceTask);
        if (resourceRequestId == 0) {
            const SessionTeardown::State state =
                RunSynchronousTeardownTask(resourceTask);
            if (state == SessionTeardown::State::Failed) {
                OH_LOG_ERROR(LOG_APP,
                    "[ExtLoader][SHUTDOWN] synchronous resource teardown failed");
            }
            return {true, 0, state};
        }
        return {true, resourceRequestId, SessionTeardown::State::Unknown};
    }
    std::unique_lock<std::mutex> keyDispatchLock(session->keyDispatchMutex);
    std::shared_ptr<ProtocolAdapter> adapter;
    {
        std::lock_guard<std::mutex> lock(session->adapterMutex);
        adapter = session->adapter;
    }
    auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(adapter);
    std::unique_lock<std::mutex> callbackRegistrationLock(session->callbackRegistrationMutex);
    SessionContext::Lifecycle expected = SessionContext::Lifecycle::Active;
    if (!session->lifecycle.compare_exchange_strong(
            expected, SessionContext::Lifecycle::Disconnecting)) {
        keyDispatchLock.unlock();
        if (expected == SessionContext::Lifecycle::Disconnecting) {
            std::unique_lock<std::mutex> lock(session->teardownPublicationMutex);
            session->teardownPublicationCv.wait(lock, [&]() {
                return (session->teardownRequestPublished &&
                        session->teardownRequestId.load(std::memory_order_acquire) != 0) ||
                    session->lifecycle.load(std::memory_order_acquire) !=
                        SessionContext::Lifecycle::Disconnecting;
            });
        }
        const uint64_t requestId =
            session->teardownRequestId.load(std::memory_order_acquire);
        if (requestId != 0) {
            return {true, requestId, SessionTeardown::State::Unknown};
        }
        return {true, 0, TeardownStateForLifecycle(
            session->lifecycle.load(std::memory_order_acquire))};
    }

    // The lifecycle claim and TSFN removal share callbackRegistrationMutex.
    // A setOnDataCallback call that published before this claim is removed
    // here; a call after the claim is rejected before creating a TSFN.
    StopSshDataRegistration(sessionId, sshAdapter);
    callbackRegistrationLock.unlock();
    // Lifecycle is now Disconnecting. New key transactions fail their active
    // check, while the one that held this lane before us completed all ups.
    keyDispatchLock.unlock();

    if (session->protocolName == "rustdesk") {
        ClearNativeNetworkObserver(
            sessionId, session->generation.load(std::memory_order_acquire));
    }
    if (!resources.owner.valid()) {
        resources.owner = session->identity();
    }
    // Auxiliary pipelines are not part of the process-wide native resource
    // tuple. Destroy them while the exact session owner is still published.
    DestroyRustDeskMultiCanvasPipelines(session);
    PrepareAdapterForTeardown(adapter, session->identity());
    DeactivateNativeResources(resources);
    DeactivateSessionContextIfActive(adapter, session->identity());
    struct TeardownPublicationGate {
        std::mutex mutex;
        std::condition_variable cv;
        bool published = false;
    };
    auto publicationGate = std::make_shared<TeardownPublicationGate>();
    auto task = [sessionId, session, adapter, resources = std::move(resources),
                 publicationGate]() mutable {
        {
            std::unique_lock<std::mutex> lock(publicationGate->mutex);
            publicationGate->cv.wait(lock, [&]() { return publicationGate->published; });
        }
        const auto startedAt = std::chrono::steady_clock::now();
        OH_LOG_INFO(LOG_APP,
            "[ExtLoader][SHUTDOWN] sessionId=%{public}d phase=executor-start",
            sessionId);
        bool failed = false;
        try {
            if (adapter) {
                if (!DisconnectAdapterAndDrainVnc(adapter)) {
                    failed = true;
                }
            }
        } catch (...) {
            failed = true;
        }
        try {
            DestroyNativeResources(std::move(resources));
        } catch (...) {
            failed = true;
        }
        {
            std::lock_guard<std::mutex> lock(session->adapterMutex);
            session->adapter.reset();
        }
        session->lifecycle.store(
            failed ? SessionContext::Lifecycle::Failed : SessionContext::Lifecycle::Complete,
            std::memory_order_release);
        session->teardownPublicationCv.notify_all();
        const auto elapsedUs = std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - startedAt).count();
        OH_LOG_INFO(LOG_APP,
            "[ExtLoader][SHUTDOWN] sessionId=%{public}d phase=executor-return result=%{public}s elapsedUs=%{public}lld",
            sessionId, failed ? "failed" : "complete", static_cast<long long>(elapsedUs));
        if (failed) {
            throw std::runtime_error("session teardown failed");
        }
    };

    uint64_t requestId = g_teardownExecutor.enqueue(task);
    if (requestId == 0) {
        {
            std::lock_guard<std::mutex> lock(publicationGate->mutex);
            publicationGate->published = true;
        }
        publicationGate->cv.notify_all();
        {
            std::lock_guard<std::mutex> lock(session->teardownPublicationMutex);
            session->teardownRequestPublished = true;
        }
        session->teardownPublicationCv.notify_all();
        const SessionTeardown::State state = RunSynchronousTeardownTask(task);
        if (state == SessionTeardown::State::Failed) {
            OH_LOG_ERROR(LOG_APP,
                "[ExtLoader][SHUTDOWN] synchronous session teardown failed sessionId=%{public}d",
                sessionId);
        }
        g_sessionRegistry.eraseIf(sessionId, session);
        if (session->protocolName == "ssh") {
            (void)g_sshNativeFacade.closeSession(SshSessionHandle {
                session->sessionId, "shell",
                session->generation.load(std::memory_order_acquire)});
            ClearNativeNetworkObserver(
                sessionId, session->generation.load(std::memory_order_acquire));
        }
        return {true, 0, state};
    }
    session->teardownRequestId.store(requestId, std::memory_order_release);
    g_disconnectRequests.insertOrAssign(sessionId, requestId);
    {
        std::lock_guard<std::mutex> lock(session->teardownPublicationMutex);
        session->teardownRequestPublished = true;
    }
    {
        std::lock_guard<std::mutex> lock(publicationGate->mutex);
        publicationGate->published = true;
    }
    publicationGate->cv.notify_all();
    session->teardownPublicationCv.notify_all();
    g_sessionRegistry.eraseIf(sessionId, session);
    if (session->protocolName == "ssh") {
        (void)g_sshNativeFacade.closeSession(SshSessionHandle {
            session->sessionId, "shell",
            session->generation.load(std::memory_order_acquire)});
        ClearNativeNetworkObserver(
            sessionId, session->generation.load(std::memory_order_acquire));
    }
    return {true, requestId, SessionTeardown::State::Unknown};
}

// Shared production disconnect core.  NapiDisconnect supplies values parsed
// from napi arguments; the test-only carrier supplies the same native
// resource bundle after installing a real SessionRegistry entry.  Keeping the
// producer shutdown, owner snapshot, registry lookup, adapter teardown and
// idempotent request handling here prevents the carrier from becoming a
// second teardown implementation.
static NativeDisconnectCoreResult ExecuteNapiDisconnectCore(
    int32_t sessionId, TeardownNativeResources resources,
    const DecoderSessionIdentity& expectedOwner = {}) {
    if (!resources.owner.valid()) {
        if (const auto it = g_sessionRegistry.find(sessionId);
            it != g_sessionRegistry.end() && it->second) {
            resources.owner = it->second->identity();
        } else {
            resources.owner = Render::SharedSessionSinkOwnerLease().snapshot();
        }
    }
    return BeginSessionTeardown(
        sessionId, std::move(resources), expectedOwner);
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
class ReentrantRegistryTeardownAdapter final : public ProtocolAdapter {
public:
    explicit ReentrantRegistryTeardownAdapter(int32_t sessionId)
        : sessionId_(sessionId) {}

    std::string protocolName() override { return "registry-teardown-test"; }
    int defaultPort() override { return 0; }
    int connect(const ConnectionConfig&) override { return 0; }
    void disconnect() override {
        disconnectCount_.fetch_add(1, std::memory_order_acq_rel);
        TeardownNativeResources resources;
        resources.owner = owner_;
        reentrantRequest_.store(
            ExecuteNapiDisconnectCore(sessionId_, std::move(resources)).requestId,
            std::memory_order_release);
    }
    ConnectionState getState() override { return ConnectionState::DISCONNECTED; }
    void sendKey(uint32_t, bool) override {}
    void sendMouse(int, int, MouseButton, bool) override {}
    void sendMouseWheel(int, int, int) override {}
    void sendText(const std::string&) override {}
    bool supportsCodec(CodecType) override { return false; }
    std::vector<CodecType> supportedCodecs() override { return {}; }
    void setVideoCallback(VideoFrameCallback) override {}
    void setAudioCallback(AudioDataCallback) override {}
    void setConnectionStateCallback(ConnectionStateCallback) override {}

    void setOwner(const DecoderSessionIdentity& owner) { owner_ = owner; }
    uint32_t disconnectCount() const {
        return disconnectCount_.load(std::memory_order_acquire);
    }
    uint64_t reentrantRequest() const {
        return reentrantRequest_.load(std::memory_order_acquire);
    }

private:
    int32_t sessionId_ = 0;
    DecoderSessionIdentity owner_;
    std::atomic<uint32_t> disconnectCount_ {0};
    std::atomic<uint64_t> reentrantRequest_ {0};
};

// Test-only carrier entry: drive the same production registry lookup,
// BeginSessionTeardown, adapter teardown, and executor completion used by
// NapiDisconnect.  This is intentionally placed after the production helper
// rather than duplicating its steps in the carrier.  It is not exported by
// release NAPI/ABI builds.
extern "C" bool RdpTestProductionDisconnectRegistryRoundTrip(
    int sessionId, uint64_t requestId) {
    if (sessionId <= 0 || requestId == 0) {
        return false;
    }

    auto adapter = std::make_shared<ReentrantRegistryTeardownAdapter>(sessionId);
    const DecoderSessionIdentity owner {
        static_cast<uint64_t>(sessionId), 1, requestId};
    adapter->setOwner(owner);
    auto session = std::make_shared<SessionContext>();
    session->adapter = adapter;
    session->protocolName = adapter->protocolName();
    session->sessionId = owner.sessionId;
    session->generation.store(owner.generation, std::memory_order_release);
    session->ownerToken = owner.ownerToken;
    g_sessionRegistry.insertOrAssign(sessionId, session);
    if (!ActivateSessionContext(adapter, owner)) {
        g_sessionRegistry.eraseIf(sessionId, session);
        g_disconnectRequests.eraseIf(sessionId, requestId);
        return false;
    }

    TeardownNativeResources staleResources;
    const DecoderSessionIdentity staleOwner {
        owner.sessionId, owner.generation, owner.ownerToken + 1};
    staleResources.owner = staleOwner;
    const NativeDisconnectCoreResult stale = ExecuteNapiDisconnectCore(
        sessionId, std::move(staleResources), staleOwner);
    const auto retainedSession = g_sessionRegistry.find(sessionId);
    const bool staleRejectedWithoutMutation = !stale.accepted &&
        session->lifecycle.load(std::memory_order_acquire) ==
            SessionContext::Lifecycle::Active &&
        adapter->disconnectCount() == 0 &&
        retainedSession != g_sessionRegistry.end() &&
        retainedSession->second == session;

    TeardownNativeResources resources;
    resources.owner = owner;
    const NativeDisconnectCoreResult submission = ExecuteNapiDisconnectCore(
        sessionId, std::move(resources), owner);
    const uint64_t teardownRequest = submission.requestId;
    // The production helper, not the carrier, owns registry insertion.  A
    // pre-insert here would exercise only the duplicate-request fast path and
    // silently skip adapter->disconnect().
    const bool registryObserved = teardownRequest != 0 &&
        g_disconnectRequests.find(sessionId) == teardownRequest;
    const bool completed = teardownRequest == 0 ||
        g_teardownExecutor.waitFor(teardownRequest, std::chrono::seconds(2));
    const bool reentrantIdempotent = teardownRequest != 0 &&
        adapter->reentrantRequest() == teardownRequest;
    const auto lifecycle = session->lifecycle.load(std::memory_order_acquire);
    const bool terminal = lifecycle == SessionContext::Lifecycle::Complete ||
        lifecycle == SessionContext::Lifecycle::Failed;
    const bool requestCleared = teardownRequest == 0 ||
        g_disconnectRequests.eraseIf(sessionId, teardownRequest);
    const bool sessionRegistryCleared = g_sessionRegistry.find(sessionId) ==
        g_sessionRegistry.end();
    // Re-enter the same production core after completion.  It must be an
    // idempotent no-op rather than resurrecting the retired adapter or
    // touching a newly registered session with the same numeric id.
    TeardownNativeResources repeatResources;
    repeatResources.owner = owner;
    const NativeDisconnectCoreResult repeated = ExecuteNapiDisconnectCore(
        sessionId, std::move(repeatResources), owner);
    return staleRejectedWithoutMutation && submission.accepted &&
        registryObserved && completed &&
        reentrantIdempotent && terminal &&
        requestCleared && sessionRegistryCleared &&
        adapter->disconnectCount() == 1 && !repeated.accepted;
}

extern "C" int RdpTestSynchronousDisconnectReceiptState(bool fail) {
    auto task = [fail]() {
        if (fail) {
            throw std::runtime_error("expected synchronous teardown failure");
        }
    };
    return static_cast<int>(RunSynchronousTeardownTask(task));
}
#endif

/**
 * NAPI: beginDisconnect(sessionId, rendererHandle, decoderHandle, audioHandle): number
 */
napi_value NapiDisconnect(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = -1;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &sessionId);
    }
    const auto shutdownStartedAt = std::chrono::steady_clock::now();
    OH_LOG_INFO(LOG_APP, "[ExtLoader][SHUTDOWN] sessionId=%{public}d phase=napi-entry", sessionId);

    TeardownNativeResources resources;
    resources.rendererHandle = GetOptionalHandle(env, argc, args, 1);
    resources.decoderHandle = GetOptionalHandle(env, argc, args, 2);
    resources.audioHandle = GetOptionalHandle(env, argc, args, 3);
    const NativeDisconnectCoreResult submission = ExecuteNapiDisconnectCore(
        sessionId, std::move(resources));
    const uint64_t requestId = submission.requestId;

    const auto shutdownElapsedUs = std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now() - shutdownStartedAt).count();
    OH_LOG_INFO(LOG_APP,
        "[ExtLoader][SHUTDOWN] sessionId=%{public}d requestId=%{public}llu phase=napi-return elapsedUs=%{public}lld",
        sessionId, static_cast<unsigned long long>(requestId),
        static_cast<long long>(shutdownElapsedUs));

    napi_value result;
    napi_create_int64(env, static_cast<int64_t>(requestId), &result);
    return result;
}

static napi_value CreateNativeDisconnectReceiptValue(
    napi_env env, const NativeDisconnectCoreResult& submission) {
    napi_value result;
    napi_create_object(env, &result);
    SetObjectBool(env, result, "accepted", submission.accepted);
    SetObjectInt64(env, result, "requestId",
                   static_cast<int64_t>(submission.requestId));
    SetObjectInt32(env, result, "terminalState",
                   static_cast<int32_t>(submission.immediateState));
    return result;
}

/** Return the exact native owner needed for an atomic teardown CAS. */
napi_value NapiGetSessionOwnerIdentity(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = -1;
    if (argc < 1 ||
        napi_get_value_int32(env, args[0], &sessionId) != napi_ok ||
        sessionId <= 0) {
        napi_value empty;
        napi_get_null(env, &empty);
        return empty;
    }
    const auto it = g_sessionRegistry.find(sessionId);
    if (it == g_sessionRegistry.end() || !it->second ||
        it->second->lifecycle.load(std::memory_order_acquire) !=
            SessionContext::Lifecycle::Active) {
        napi_value empty;
        napi_get_null(env, &empty);
        return empty;
    }
    const DecoderSessionIdentity owner = it->second->identity();
    if (!owner.valid()) {
        napi_value empty;
        napi_get_null(env, &empty);
        return empty;
    }
    napi_value result;
    napi_create_object(env, &result);
    SetObjectInt64(env, result, "sessionId",
                   static_cast<int64_t>(owner.sessionId));
    SetObjectInt64(env, result, "generation",
                   static_cast<int64_t>(owner.generation));
    SetObjectInt64(env, result, "ownerToken",
                   static_cast<int64_t>(owner.ownerToken));
    return result;
}

/**
 * Exact disconnect entry.  A stale owner is rejected before any native
 * lifecycle, callback, resource or registry mutation.  Synchronous fallback
 * reports Complete(3) or Failed(4) instead of overloading requestId=0.
 */
napi_value NapiBeginDisconnectWithReceipt(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = -1;
    int64_t generation = 0;
    int64_t ownerToken = 0;
    if (argc < 6 ||
        napi_get_value_int32(env, args[0], &sessionId) != napi_ok ||
        napi_get_value_int64(env, args[1], &generation) != napi_ok ||
        napi_get_value_int64(env, args[2], &ownerToken) != napi_ok ||
        generation < 0 || ownerToken < 0 ||
        ((generation == 0 || ownerToken == 0) && sessionId > 0) ||
        ((generation != 0 || ownerToken != 0) && sessionId <= 0)) {
        return CreateNativeDisconnectReceiptValue(env, {});
    }
    TeardownNativeResources resources;
    resources.rendererHandle = GetOptionalHandle(env, argc, args, 3);
    resources.decoderHandle = GetOptionalHandle(env, argc, args, 4);
    resources.audioHandle = GetOptionalHandle(env, argc, args, 5);
    DecoderSessionIdentity expectedOwner;
    if (sessionId > 0) {
        expectedOwner = DecoderSessionIdentity {
            static_cast<uint64_t>(sessionId),
            static_cast<uint64_t>(generation),
            static_cast<uint64_t>(ownerToken)};
        resources.owner = expectedOwner;
    }
    return CreateNativeDisconnectReceiptValue(
        env, BeginSessionTeardown(
            sessionId, std::move(resources), expectedOwner));
}

/**
 * NAPI: disconnectAll(rendererHandle, decoderHandle, audioHandle): number
 *
 * Ability 退后台/销毁时兜底释放所有协议会话。RDP 如果只靠页面 aboutToDisappear,
 * 在系统手势回桌面或后台清理时可能来不及触发, Windows 侧会保留会话。
 */
napi_value NapiDisconnectAll(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const auto shutdownStartedAt = std::chrono::steady_clock::now();

    const SessionTeardown::State existingState =
        g_teardownExecutor.state(g_disconnectAllRequestId);
    if (g_disconnectAllRequestId > 0 &&
        (existingState == SessionTeardown::State::Queued ||
         existingState == SessionTeardown::State::Running)) {
        napi_value existingResult;
        napi_create_int64(env, static_cast<int64_t>(g_disconnectAllRequestId), &existingResult);
        return existingResult;
    }

    std::vector<std::pair<int, std::shared_ptr<SessionContext>>> sessions =
        g_sessionRegistry.snapshot();
    // Claim only sessions that are still Active. A concurrent per-session
    // disconnect owns any entry already in Disconnecting; including it in
    // this batch would call adapter->disconnect() twice and let the two
    // teardown tasks race over the same native handles.
    std::vector<std::pair<int, std::shared_ptr<SessionContext>>> teardownSessions;
    teardownSessions.reserve(sessions.size());
    for (const auto& item : sessions) {
        if (!item.second) {
            continue;
        }
        std::unique_lock<std::mutex> keyDispatchLock(item.second->keyDispatchMutex);
        std::shared_ptr<ProtocolAdapter> adapter;
        {
            std::lock_guard<std::mutex> lock(item.second->adapterMutex);
            adapter = item.second->adapter;
        }
        std::unique_lock<std::mutex> callbackRegistrationLock(
            item.second->callbackRegistrationMutex);
        SessionContext::Lifecycle expected = SessionContext::Lifecycle::Active;
        if (item.second->lifecycle.compare_exchange_strong(
                expected, SessionContext::Lifecycle::Disconnecting,
                std::memory_order_acq_rel, std::memory_order_acquire)) {
            const auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(adapter);
            StopSshDataRegistration(item.first, sshAdapter);
            teardownSessions.push_back(item);
        }
    }

    // A session absent from the registry cannot race a new registration. It
    // may still have a stale map entry from an interrupted earlier teardown;
    // reclaim only those orphan ids and leave Disconnecting owners untouched.
    std::vector<int32_t> orphanRegistrationIds;
    {
        std::lock_guard<std::mutex> lock(g_dataTsfnMutex);
        orphanRegistrationIds.reserve(g_dataTsfnMap.size());
        for (const auto& entry : g_dataTsfnMap) {
            if (g_sessionRegistry.find(entry.first) == g_sessionRegistry.end()) {
                orphanRegistrationIds.push_back(entry.first);
            }
        }
    }
    for (const int32_t orphanId : orphanRegistrationIds) {
        StopSshDataRegistration(orphanId, nullptr);
    }

    TeardownNativeResources resources;
    resources.rendererHandle = GetOptionalHandle(env, argc, args, 0);
    resources.decoderHandle = GetOptionalHandle(env, argc, args, 1);
    resources.audioHandle = GetOptionalHandle(env, argc, args, 2);
    resources.owner = Render::SharedSessionSinkOwnerLease().snapshot();
    // Stop protocol producers while the exact session owner is still
    // published.  DeactivateAllSessionContexts() closes the shared owner
    // gate; doing it first makes PrepareAdapterForTeardown() fail closed and
    // leaves late callbacks installed on the adapter until the executor runs.
    // That ordering was the source of the disconnectAll callback leak.
    for (const auto& item : teardownSessions) {
        if (!item.second) {
            continue;
        }
        const auto owner = item.second->identity();
        if (item.second->protocolName == "ssh") {
            // disconnectAll owns every Active session it successfully moved
            // to Disconnecting. Remove the matching generation from the SSH
            // manager before testing whether the shared platform observer is
            // still needed; erasing only g_sessionRegistry leaked manager
            // entries and eventually exhausted its bounded session table.
            (void)g_sshNativeFacade.closeSession(SshSessionHandle {
                item.second->sessionId, "shell", owner.generation});
            ClearNativeNetworkObserver(item.first, owner.generation);
        } else if (item.second->protocolName == "rustdesk") {
            // The native network observer retains the SessionContext.  Clear
            // it before removing the registry entry even when this batch is
            // racing a per-session disconnect; the generation check keeps a
            // newer observer registration untouched.
            ClearNativeNetworkObserver(
                item.first, owner.generation);
        }
        std::shared_ptr<ProtocolAdapter> adapter;
        {
            std::lock_guard<std::mutex> lock(item.second->adapterMutex);
            adapter = item.second->adapter;
        }
        DestroyRustDeskMultiCanvasPipelines(item.second);
        PrepareAdapterForTeardown(adapter, owner);
    }
    DeactivateNativeResources(resources);
    DeactivateAllSessionContexts();
    auto task = [teardownSessions, resources = std::move(resources)]() mutable {
        bool failed = false;
        for (const auto& item : teardownSessions) {
            const std::shared_ptr<SessionContext>& session = item.second;
            bool sessionFailed = false;
            std::shared_ptr<ProtocolAdapter> adapter;
            {
                std::lock_guard<std::mutex> lock(session->adapterMutex);
                adapter = session->adapter;
            }
            try {
                if (adapter) {
                    if (!DisconnectAdapterAndDrainVnc(adapter)) {
                        failed = true;
                        sessionFailed = true;
                    }
                }
            } catch (...) {
                failed = true;
                sessionFailed = true;
            }
            {
                std::lock_guard<std::mutex> lock(session->adapterMutex);
                if (session->adapter == adapter) {
                    session->adapter.reset();
                }
            }
            session->lifecycle.store(
                sessionFailed ? SessionContext::Lifecycle::Failed : SessionContext::Lifecycle::Complete,
                std::memory_order_release);
            session->teardownPublicationCv.notify_all();
        }
        try {
            DestroyNativeResources(std::move(resources));
        } catch (...) {
            failed = true;
        }
        if (failed) {
            throw std::runtime_error("disconnectAll teardown failed");
        }
    };

    const uint64_t requestId = g_teardownExecutor.enqueue(task);
    if (requestId == 0) {
        // Publish the terminal/fallback request before running the synchronous
        // task.  A concurrent single-session disconnect may already have
        // observed Lifecycle::Disconnecting and must never wait forever for a
        // publication that disconnectAll forgot to make.
        for (const auto& item : teardownSessions) {
            if (!item.second) {
                continue;
            }
            item.second->teardownRequestId.store(0, std::memory_order_release);
            {
                std::lock_guard<std::mutex> lock(item.second->teardownPublicationMutex);
                item.second->teardownRequestPublished = true;
            }
            item.second->teardownPublicationCv.notify_all();
        }
        try {
            task();
        } catch (...) {
            OH_LOG_ERROR(LOG_APP,
                "[ExtLoader][SHUTDOWN] synchronous disconnect-all teardown failed");
        }
    } else {
        g_disconnectAllRequestId = requestId;
        for (const auto& item : teardownSessions) {
            if (!item.second) {
                continue;
            }
            item.second->teardownRequestId.store(requestId, std::memory_order_release);
            g_disconnectRequests.insertOrAssign(item.first, requestId);
            {
                std::lock_guard<std::mutex> lock(item.second->teardownPublicationMutex);
                item.second->teardownRequestPublished = true;
            }
            item.second->teardownPublicationCv.notify_all();
        }
    }
    // Keep request publication and idempotence visible before dropping the
    // registry snapshots.  Subsequent disconnect calls hit
    // g_disconnectRequests instead of treating an in-flight disconnectAll as
    // a missing session.
    for (const auto& item : teardownSessions) {
        if (item.second) {
            g_sessionRegistry.eraseIf(item.first, item.second);
        }
    }

    const auto shutdownElapsedUs = std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now() - shutdownStartedAt).count();
    OH_LOG_INFO(LOG_APP,
        "[ExtLoader][SHUTDOWN] requestId=%{public}llu phase=disconnect-all-return sessions=%{public}zu elapsedUs=%{public}lld",
        static_cast<unsigned long long>(requestId), sessions.size(),
        static_cast<long long>(shutdownElapsedUs));

    napi_value result;
    napi_create_int64(env, static_cast<int64_t>(requestId), &result);
    return result;
}

napi_value NapiGetDisconnectState(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t requestId = 0;
    if (argc > 0) {
        napi_get_value_int64(env, args[0], &requestId);
    }
    napi_value result;
    napi_create_int32(env, static_cast<int32_t>(
        g_teardownExecutor.state(static_cast<uint64_t>(requestId))), &result);
    return result;
}

/**
 * NAPI: sendKey(sessionId: number, scancode: number, pressed: boolean): void
 */
napi_value NapiSendKey(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId, scancode;
    bool pressed;

    napi_get_value_int32(env, args[0], &sessionId);
    napi_get_value_int32(env, args[1], &scancode);
    napi_get_value_bool(env, args[2], &pressed);

    uint64_t index = ++g_napiKeySendCount;
    if (index <= 30 || index % 100 == 0) {
        OH_LOG_INFO(LOG_APP,
            "[ExtLoader] NapiSendKey #%{public}llu session=%{public}d sc=%{public}d pressed=%{public}s",
            static_cast<unsigned long long>(index),
            sessionId,
            scancode,
            pressed ? "yes" : "no");
    }

    const auto lookup = g_sessionRegistry.find(sessionId);
    const std::shared_ptr<SessionContext> session =
        lookup == g_sessionRegistry.end() ? nullptr : lookup->second;
    if (session) {
        std::lock_guard<std::mutex> keyLock(session->keyDispatchMutex);
        std::shared_ptr<ProtocolAdapter> adapter;
        if (session->lifecycle.load(std::memory_order_acquire) == SessionContext::Lifecycle::Active) {
            std::lock_guard<std::mutex> adapterLock(session->adapterMutex);
            adapter = session->adapter;
        }
        if (adapter) {
            if (session->protocolName == "vnc") {
                session->diagnostics.inputEventsSent.fetch_add(1, std::memory_order_relaxed);
            }
            adapter->sendKey(static_cast<uint32_t>(scancode), pressed);
        } else if (session->protocolName == "vnc") {
            session->diagnostics.inputEventsDropped.fetch_add(1, std::memory_order_relaxed);
        }
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static bool SubmitSessionKeyEvents(
    int32_t sessionId,
    const std::vector<RemoteKeyEvent>& events) {
    if (events.empty() || events.size() > 32U) {
        return false;
    }
    const auto lookup = g_sessionRegistry.find(sessionId);
    const std::shared_ptr<SessionContext> session =
        lookup == g_sessionRegistry.end() ? nullptr : lookup->second;
    if (!session) {
        return false;
    }
    std::lock_guard<std::mutex> keyLock(session->keyDispatchMutex);
    std::shared_ptr<ProtocolAdapter> adapter;
    if (session->lifecycle.load(std::memory_order_acquire) ==
        SessionContext::Lifecycle::Active) {
        std::lock_guard<std::mutex> adapterLock(session->adapterMutex);
        adapter = session->adapter;
    }
    if (!adapter) {
        if (session->protocolName == "vnc") {
            session->diagnostics.inputEventsDropped.fetch_add(
                events.size(), std::memory_order_relaxed);
        }
        return false;
    }
    const bool accepted = adapter->sendKeyEvents(events);
    if (session->protocolName == "vnc") {
        if (accepted) {
            session->diagnostics.inputEventsSent.fetch_add(
                events.size(), std::memory_order_relaxed);
        } else {
            session->diagnostics.inputEventsDropped.fetch_add(
                events.size(), std::memory_order_relaxed);
        }
    }
    return accepted;
}

/**
 * NAPI: sendKeySequence(sessionId: number, keyCodes: number[]): boolean
 *
 * Resolve the session once and submit the complete chord as one ordered NAPI
 * operation. Protocol adapters still own their native input queues; this
 * boundary prevents a reconnect or teardown from splitting a chord between
 * several JS-to-native calls.
 */
napi_value NapiSendKeySequence(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool accepted = false;
    int32_t sessionId = 0;
    bool isArray = false;
    uint32_t length = 0;
    if (argc >= 2 && napi_get_value_int32(env, args[0], &sessionId) == napi_ok &&
        napi_is_array(env, args[1], &isArray) == napi_ok && isArray &&
        napi_get_array_length(env, args[1], &length) == napi_ok &&
        length > 0 && length <= 16) {
        std::vector<uint32_t> keyCodes;
        keyCodes.reserve(length);
        bool valid = true;
        for (uint32_t index = 0; index < length; ++index) {
            napi_value value;
            int32_t keyCode = 0;
            if (napi_get_element(env, args[1], index, &value) != napi_ok ||
                napi_get_value_int32(env, value, &keyCode) != napi_ok || keyCode <= 0) {
                valid = false;
                break;
            }
            keyCodes.push_back(static_cast<uint32_t>(keyCode));
        }
        if (valid) {
            std::vector<RemoteKeyEvent> events;
            events.reserve(keyCodes.size() * 2U);
            DispatchKeySequence(keyCodes, [&events](uint32_t keyCode, bool pressed) {
                events.push_back({keyCode, pressed});
            });
            accepted = SubmitSessionKeyEvents(sessionId, events);
            if (accepted) {
                OH_LOG_INFO(LOG_APP,
                    "[ExtLoader] NapiSendKeySequence session=%{public}d keys=%{public}u",
                    sessionId, length);
            }
        }
    }
    napi_value result;
    napi_get_boolean(env, accepted, &result);
    return result;
}

/**
 * NAPI: sendKeyEvents(sessionId: number, keyCodes: number[], pressed: boolean[]): boolean
 */
napi_value NapiSendKeyEvents(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    bool accepted = false;
    int32_t sessionId = 0;
    bool keyArray = false;
    bool pressedArray = false;
    uint32_t keyLength = 0;
    uint32_t pressedLength = 0;
    if (argc >= 3 && napi_get_value_int32(env, args[0], &sessionId) == napi_ok &&
        napi_is_array(env, args[1], &keyArray) == napi_ok && keyArray &&
        napi_is_array(env, args[2], &pressedArray) == napi_ok && pressedArray &&
        napi_get_array_length(env, args[1], &keyLength) == napi_ok &&
        napi_get_array_length(env, args[2], &pressedLength) == napi_ok &&
        keyLength > 0 && keyLength <= 32 && keyLength == pressedLength) {
        std::vector<RemoteKeyEvent> events;
        events.reserve(keyLength);
        bool valid = true;
        for (uint32_t index = 0; index < keyLength; ++index) {
            napi_value keyValue;
            napi_value pressedValue;
            int32_t keyCode = 0;
            bool pressed = false;
            if (napi_get_element(env, args[1], index, &keyValue) != napi_ok ||
                napi_get_element(env, args[2], index, &pressedValue) != napi_ok ||
                napi_get_value_int32(env, keyValue, &keyCode) != napi_ok ||
                napi_get_value_bool(env, pressedValue, &pressed) != napi_ok || keyCode <= 0) {
                valid = false;
                break;
            }
            events.push_back({static_cast<uint32_t>(keyCode), pressed});
        }
        if (valid) {
            accepted = SubmitSessionKeyEvents(sessionId, events);
        }
    }
    napi_value result;
    napi_get_boolean(env, accepted, &result);
    return result;
}

/**
 * NAPI: sendMouse(sessionId: number, x: number, y: number, button: number, pressed: boolean): void
 */
napi_value NapiSendMouse(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId, x, y, button;
    bool pressed;

    napi_get_value_int32(env, args[0], &sessionId);
    napi_get_value_int32(env, args[1], &x);
    napi_get_value_int32(env, args[2], &y);
    napi_get_value_int32(env, args[3], &button);
    napi_get_value_bool(env, args[4], &pressed);

    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter) {
        if (it->second->protocolName == "vnc") {
            it->second->diagnostics.inputEventsSent.fetch_add(1, std::memory_order_relaxed);
        }
        uint64_t index = ++g_napiMouseSendCount;
        if (button >= 0 || index <= 20 || index % 120 == 0) {
            OH_LOG_INFO(LOG_APP,
                "[ExtLoader] NapiSendMouse #%{public}llu session=%{public}d x=%{public}d y=%{public}d button=%{public}d pressed=%{public}s",
                static_cast<unsigned long long>(index),
                sessionId,
                x,
                y,
                button,
                pressed ? "yes" : "no");
        }
        it->second->adapter->sendMouse(x, y, static_cast<MouseButton>(button), pressed);
    } else if (it != g_sessionRegistry.end() && it->second->protocolName == "vnc") {
        it->second->diagnostics.inputEventsDropped.fetch_add(1, std::memory_order_relaxed);
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * NAPI: sendMouseWheel(sessionId: number, x: number, y: number, delta: number): void
 */
napi_value NapiSendMouseWheel(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId, x, y, delta;
    napi_get_value_int32(env, args[0], &sessionId);
    napi_get_value_int32(env, args[1], &x);
    napi_get_value_int32(env, args[2], &y);
    napi_get_value_int32(env, args[3], &delta);

    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter) {
        if (it->second->protocolName == "vnc") {
            it->second->diagnostics.inputEventsSent.fetch_add(1, std::memory_order_relaxed);
        }
        uint64_t index = ++g_napiWheelSendCount;
        if (index <= 20 || index % 100 == 0) {
            OH_LOG_INFO(LOG_APP,
                "[ExtLoader] NapiSendMouseWheel #%{public}llu session=%{public}d x=%{public}d y=%{public}d delta=%{public}d",
                static_cast<unsigned long long>(index),
                sessionId,
                x,
                y,
                delta);
        }
        it->second->adapter->sendMouseWheel(x, y, delta);
    } else if (it != g_sessionRegistry.end() && it->second->protocolName == "vnc") {
        it->second->diagnostics.inputEventsDropped.fetch_add(1, std::memory_order_relaxed);
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/** NAPI: sendRustDeskTouchpadWheel(sessionId: number, x: number, y: number): boolean */
napi_value NapiSendRustDeskTouchpadWheel(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    int32_t x = 0;
    int32_t y = 0;
    if (argc >= 3) {
        napi_get_value_int32(env, args[0], &sessionId);
        napi_get_value_int32(env, args[1], &x);
        napi_get_value_int32(env, args[2], &y);
    }
    bool accepted = false;
    auto it = g_sessionRegistry.find(sessionId);
    const std::shared_ptr<SessionContext> session =
        it == g_sessionRegistry.end() ? nullptr : it->second;
    if (session) {
        const std::shared_ptr<RustDeskBridge> bridge = GetRustDeskAdapter(session);
        if (bridge) accepted = bridge->sendTouchpadWheel(x, y);
    }
    napi_value result;
    napi_get_boolean(env, accepted, &result);
    return result;
}

/** NAPI: setRustDeskImageQuality(sessionId, quality): boolean */
napi_value NapiSetRustDeskImageQuality(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    int32_t quality = -1;
    if (argc >= 2) {
        napi_get_value_int32(env, args[0], &sessionId);
        napi_get_value_int32(env, args[1], &quality);
    }
    bool accepted = false;
    auto it = g_sessionRegistry.find(sessionId);
    const std::shared_ptr<SessionContext> session =
        it == g_sessionRegistry.end() ? nullptr : it->second;
    if (quality >= 0 && quality <= 2 && IsSessionCallbackActive(session)) {
        const std::shared_ptr<RustDeskBridge> bridge = GetRustDeskAdapter(session);
        accepted = bridge != nullptr && bridge->setImageQuality(quality);
    }
    napi_value result;
    napi_get_boolean(env, accepted, &result);
    return result;
}

/** NAPI: getRustDeskDisplayCapabilities(sessionId): object */
napi_value NapiGetRustDeskDisplayCapabilities(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    if (argc > 0) napi_get_value_int32(env, args[0], &sessionId);

    RustDeskDisplayCapabilities capabilities;
    auto it = g_sessionRegistry.find(sessionId);
    const std::shared_ptr<SessionContext> session =
        it == g_sessionRegistry.end() ? nullptr : it->second;
    if (IsSessionCallbackActive(session)) {
        const std::shared_ptr<RustDeskBridge> bridge = GetRustDeskAdapter(session);
        if (bridge) capabilities = bridge->getDisplayCapabilities();
    }

    napi_value result;
    napi_create_object(env, &result);
    SetObjectBool(env, result, "supported", capabilities.supported);
    SetObjectInt32(env, result, "currentDisplay", capabilities.currentDisplay);
    SetObjectInt64(env, result, "switchGeneration",
                   static_cast<int64_t>(capabilities.switchGeneration));
    SetObjectInt64(env, result, "readySwitchGeneration",
                   static_cast<int64_t>(capabilities.readySwitchGeneration));
    SetObjectInt32(env, result, "pendingDisplay", capabilities.pendingDisplay);
    SetObjectInt32(env, result, "confirmedDisplay", capabilities.confirmedDisplay);
    SetObjectBool(env, result, "inputBlocked", capabilities.inputBlocked);
    bool multiCanvasPreviewActive = false;
    int multiCanvasPreviewDisplay = -1;
    if (session) {
        std::lock_guard<std::mutex> lock(session->rustDeskMultiCanvasMutex);
        if (!session->rustDeskMultiCanvasPipelines.empty()) {
            multiCanvasPreviewActive = true;
            multiCanvasPreviewDisplay =
                session->rustDeskMultiCanvasPipelines.begin()->first;
        }
    }
    const size_t onlineDisplayCount = static_cast<size_t>(std::count_if(
        capabilities.displays.begin(), capabilities.displays.end(),
        [](const RustDeskDisplayInfo& display) { return display.online; }));
    SetObjectBool(env, result, "multiCanvasPreviewSupported",
                  capabilities.supported && onlineDisplayCount > 1U);
    SetObjectInt32(env, result, "multiCanvasPreviewMaxDisplays",
                   static_cast<int32_t>(kRustDeskMultiCanvasMaxDisplays));
    SetObjectBool(env, result, "multiCanvasPreviewActive", multiCanvasPreviewActive);
    SetObjectInt32(env, result, "multiCanvasPreviewDisplay", multiCanvasPreviewDisplay);
    SetObjectInt32(env, result, "width", capabilities.width);
    SetObjectInt32(env, result, "height", capabilities.height);
    SetObjectInt32(env, result, "originalWidth", capabilities.originalWidth);
    SetObjectInt32(env, result, "originalHeight", capabilities.originalHeight);
    SetObjectInt32(env, result, "scaleMilli", capabilities.scaleMilli);
    SetObjectInt32(env, result, "geometryEpoch", static_cast<int32_t>(capabilities.geometryEpoch));
    napi_value resolutions;
    napi_create_array_with_length(env, capabilities.resolutions.size(), &resolutions);
    for (size_t index = 0; index < capabilities.resolutions.size(); ++index) {
        napi_value item;
        napi_create_object(env, &item);
        SetObjectInt32(env, item, "width", capabilities.resolutions[index].width);
        SetObjectInt32(env, item, "height", capabilities.resolutions[index].height);
        napi_set_element(env, resolutions, static_cast<uint32_t>(index), item);
    }
    napi_set_named_property(env, result, "resolutions", resolutions);

    napi_value displays;
    napi_create_array_with_length(env, capabilities.displays.size(), &displays);
    for (size_t index = 0; index < capabilities.displays.size(); ++index) {
        const RustDeskDisplayInfo& display = capabilities.displays[index];
        napi_value item;
        napi_create_object(env, &item);
        SetObjectInt32(env, item, "display", display.display);
        SetObjectInt32(env, item, "x", display.x);
        SetObjectInt32(env, item, "y", display.y);
        SetObjectInt32(env, item, "width", display.width);
        SetObjectInt32(env, item, "height", display.height);
        SetObjectInt32(env, item, "originalWidth", display.originalWidth);
        SetObjectInt32(env, item, "originalHeight", display.originalHeight);
        SetObjectInt32(env, item, "scaleMilli", display.scaleMilli);
        SetObjectBool(env, item, "online", display.online);
        SetObjectBool(env, item, "cursorEmbedded", display.cursorEmbedded);
        SetObjectString(env, item, "name", display.name);
        napi_value displayResolutions;
        napi_create_array_with_length(env, display.resolutions.size(), &displayResolutions);
        for (size_t resolutionIndex = 0; resolutionIndex < display.resolutions.size(); ++resolutionIndex) {
            napi_value resolution;
            napi_create_object(env, &resolution);
            SetObjectInt32(env, resolution, "width", display.resolutions[resolutionIndex].width);
            SetObjectInt32(env, resolution, "height", display.resolutions[resolutionIndex].height);
            napi_set_element(env, displayResolutions, static_cast<uint32_t>(resolutionIndex), resolution);
        }
        napi_set_named_property(env, item, "resolutions", displayResolutions);
        napi_set_element(env, displays, static_cast<uint32_t>(index), item);
    }
    napi_set_named_property(env, result, "displays", displays);
    return result;
}

static const char* RustDeskMultiCanvasStatusName(int status) {
    switch (static_cast<RustDeskMultiCanvasPipelineStatus>(status)) {
        case RustDeskMultiCanvasPipelineStatus::Starting: return "starting";
        case RustDeskMultiCanvasPipelineStatus::Presenting: return "presenting";
        case RustDeskMultiCanvasPipelineStatus::ReconfigureRequired: return "reconfigure_required";
        case RustDeskMultiCanvasPipelineStatus::Failed: return "failed";
        case RustDeskMultiCanvasPipelineStatus::Paused: return "paused";
        default: return "inactive";
    }
}

static napi_value CreateRustDeskMultiCanvasPipelineValue(
    napi_env env, const std::shared_ptr<SessionContext>& session,
    const std::shared_ptr<RustDeskMultiCanvasPipeline>& pipeline,
    const char* reason = "") {
    napi_value result;
    napi_create_object(env, &result);
    std::unique_lock<std::mutex> lifecycleLock;
    if (pipeline) {
        lifecycleLock = std::unique_lock<std::mutex>(pipeline->lifecycleMutex);
    }
    SetObjectBool(env, result, "supported", session != nullptr &&
        session->protocolName == "rustdesk");
    SetObjectBool(env, result, "active", pipeline != nullptr &&
        pipeline->decoderHandle > 0 && pipeline->rendererHandle > 0);
    SetObjectInt32(env, result, "display", pipeline ? pipeline->display : -1);
    const int status = pipeline ? pipeline->status.load(std::memory_order_acquire) : 0;
    SetObjectString(env, result, "status", RustDeskMultiCanvasStatusName(status));
    SetObjectString(env, result, "reason", reason == nullptr ? "" : reason);
    SetObjectString(env, result, "decoderBackend",
                    pipeline && pipeline->decoderHandle > 0 ? "hardware" : "paused");
    const int observedWidth = pipeline ?
        pipeline->observedWidth.load(std::memory_order_acquire) : 0;
    const int observedHeight = pipeline ?
        pipeline->observedHeight.load(std::memory_order_acquire) : 0;
    const int observedCodec = pipeline ?
        pipeline->observedCodec.load(std::memory_order_acquire) : -1;
    SetObjectInt32(env, result, "sourceWidth", observedWidth > 0 ? observedWidth :
                   (pipeline ? pipeline->sourceWidth : 0));
    SetObjectInt32(env, result, "sourceHeight", observedHeight > 0 ? observedHeight :
                   (pipeline ? pipeline->sourceHeight : 0));
    SetObjectInt32(env, result, "codec", observedCodec >= 0 ? observedCodec :
                   (pipeline ? pipeline->codec : -1));
    SetObjectInt32(env, result, "lastDecodeResult",
                   pipeline ? pipeline->lastDecodeResult.load(std::memory_order_acquire) : 0);
    SetObjectInt64(env, result, "receivedFrames", pipeline ?
        static_cast<int64_t>(pipeline->receivedFrames.load(std::memory_order_acquire)) : 0);
    SetObjectInt64(env, result, "acceptedFrames", pipeline ?
        static_cast<int64_t>(pipeline->acceptedFrames.load(std::memory_order_acquire)) : 0);
    SetObjectInt64(env, result, "droppedFrames", pipeline ?
        static_cast<int64_t>(pipeline->droppedFrames.load(std::memory_order_acquire)) : 0);
    DecoderPresentationTelemetrySnapshot telemetry;
    if (pipeline && session && pipeline->decoderHandle > 0) {
        telemetry = DecoderNapi::GetOwnedAuxPresentationTelemetry(
            pipeline->decoderHandle, session->identity());
    }
    SetObjectInt64(env, result, "presentedFrames",
                   static_cast<int64_t>(telemetry.rendererPresentedFrames));
    SetObjectInt64(env, result, "queueDepth",
                   static_cast<int64_t>(telemetry.queueDepth));
    SetObjectInt64(env, result, "inputDroppedFrames",
                   static_cast<int64_t>(telemetry.inputDroppedFrames));
    return result;
}

/**
 * NAPI: attachRustDeskMultiCanvasPreview(sessionId, display, surfaceId,
 *   surfaceWidth, surfaceHeight, sourceWidth, sourceHeight, codec): snapshot
 */
napi_value NapiAttachRustDeskMultiCanvasPreview(napi_env env, napi_callback_info info) {
    size_t argc = 8;
    napi_value args[8] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    int32_t display = -1;
    int32_t surfaceWidth = 0;
    int32_t surfaceHeight = 0;
    int32_t sourceWidth = 0;
    int32_t sourceHeight = 0;
    int32_t codec = -1;
    const std::string surfaceId = argc >= 3 ? GetNapiString(env, args[2]) : "";
    if (argc < 8 ||
        napi_get_value_int32(env, args[0], &sessionId) != napi_ok ||
        napi_get_value_int32(env, args[1], &display) != napi_ok ||
        napi_get_value_int32(env, args[3], &surfaceWidth) != napi_ok ||
        napi_get_value_int32(env, args[4], &surfaceHeight) != napi_ok ||
        napi_get_value_int32(env, args[5], &sourceWidth) != napi_ok ||
        napi_get_value_int32(env, args[6], &sourceHeight) != napi_ok ||
        napi_get_value_int32(env, args[7], &codec) != napi_ok) {
        return CreateRustDeskMultiCanvasPipelineValue(env, nullptr, nullptr,
                                                       "invalid_arguments");
    }
    auto it = g_sessionRegistry.find(sessionId);
    const std::shared_ptr<SessionContext> session =
        it == g_sessionRegistry.end() ? nullptr : it->second;
    const std::shared_ptr<RustDeskBridge> bridge = GetRustDeskAdapter(session);
    if (!session || !bridge || !IsSessionCallbackActive(session)) {
        return CreateRustDeskMultiCanvasPipelineValue(env, session, nullptr,
                                                       "inactive_session");
    }
    const RustDeskDisplayCapabilities capabilities = bridge->getDisplayCapabilities();
    const auto displayIt = std::find_if(
        capabilities.displays.begin(), capabilities.displays.end(),
        [display](const RustDeskDisplayInfo& item) {
            return item.display == display && item.online;
        });
    if (!capabilities.supported || displayIt == capabilities.displays.end() ||
        display == capabilities.currentDisplay || surfaceId.empty() ||
        surfaceWidth <= 0 || surfaceHeight <= 0 || sourceWidth <= 0 ||
        sourceHeight <= 0 || codec < static_cast<int>(CodecType::H264) ||
        codec > static_cast<int>(CodecType::AV1)) {
        return CreateRustDeskMultiCanvasPipelineValue(env, session, nullptr,
                                                       "unsupported_target");
    }
    const RustDeskMultiCanvasBudgetDecision budget =
        RustDeskSelectMultiCanvasDisplays(
            capabilities.currentDisplay, {display}, {{
                capabilities.currentDisplay, capabilities.width,
                capabilities.height, true}, {
                display, sourceWidth, sourceHeight, true}});
    if (!budget.accepted || budget.displays.size() != 2) {
        return CreateRustDeskMultiCanvasPipelineValue(env, session, nullptr,
                                                       "resource_budget_exceeded");
    }

    std::vector<std::shared_ptr<RustDeskMultiCanvasPipeline>> retired;
    {
        std::lock_guard<std::mutex> lock(session->rustDeskMultiCanvasMutex);
        for (auto& entry : session->rustDeskMultiCanvasPipelines) {
            retired.push_back(std::move(entry.second));
        }
        session->rustDeskMultiCanvasPipelines.clear();
    }
    for (const auto& oldPipeline : retired) {
        DestroyRustDeskMultiCanvasPipeline(session->identity(), oldPipeline);
    }

    const RendererNapi::OwnedRendererCreationResult renderer =
        RendererNapi::CreateOwnedAuxRenderer(
            surfaceId, surfaceWidth, surfaceHeight, session->identity());
    if (!renderer.ok) {
        (void)RefreshRustDeskMultiCanvasCaptureSet(session);
        return CreateRustDeskMultiCanvasPipelineValue(env, session, nullptr,
                                                       "renderer_unavailable");
    }
    const OwnedDecoderCreationResult decoder =
        DecoderNapi::CreateOwnedAuxHardwareDecoder(
            sourceWidth, sourceHeight, codec, display,
            renderer.rendererHandle, session->identity());
    if (!decoder.ok) {
        RendererNapi::DestroyRendererHandle(renderer.rendererHandle,
                                             session->identity());
        (void)RefreshRustDeskMultiCanvasCaptureSet(session);
        return CreateRustDeskMultiCanvasPipelineValue(env, session, nullptr,
                                                       "decoder_unavailable");
    }

    auto pipeline = std::make_shared<RustDeskMultiCanvasPipeline>();
    pipeline->display = display;
    pipeline->sourceWidth = sourceWidth;
    pipeline->sourceHeight = sourceHeight;
    pipeline->codec = codec;
    pipeline->surfaceWidth = surfaceWidth;
    pipeline->surfaceHeight = surfaceHeight;
    pipeline->surfaceId = surfaceId;
    pipeline->rendererHandle = renderer.rendererHandle;
    pipeline->rendererGeneration = renderer.rendererGeneration;
    pipeline->decoderHandle = decoder.decoderHandle;
    pipeline->decoderGeneration = decoder.decoderGeneration;
    {
        std::lock_guard<std::mutex> lock(session->rustDeskMultiCanvasMutex);
        session->rustDeskMultiCanvasPipelines.emplace(display, pipeline);
    }
    if (!RefreshRustDeskMultiCanvasCaptureSet(session)) {
        {
            std::lock_guard<std::mutex> lock(session->rustDeskMultiCanvasMutex);
            session->rustDeskMultiCanvasPipelines.erase(display);
        }
        DestroyRustDeskMultiCanvasPipeline(session->identity(), pipeline);
        return CreateRustDeskMultiCanvasPipelineValue(env, session, nullptr,
                                                       "capture_not_supported");
    }
    (void)bridge->refreshVideoDisplay(display);
    return CreateRustDeskMultiCanvasPipelineValue(env, session, pipeline);
}

/** NAPI: detachRustDeskMultiCanvasPreview(sessionId, display): boolean */
napi_value NapiDetachRustDeskMultiCanvasPreview(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    int32_t display = -1;
    if (argc >= 1) napi_get_value_int32(env, args[0], &sessionId);
    if (argc >= 2) napi_get_value_int32(env, args[1], &display);
    auto it = g_sessionRegistry.find(sessionId);
    const std::shared_ptr<SessionContext> session =
        it == g_sessionRegistry.end() ? nullptr : it->second;
    bool removed = false;
    if (session) {
        std::vector<std::shared_ptr<RustDeskMultiCanvasPipeline>> retired;
        {
            std::lock_guard<std::mutex> lock(session->rustDeskMultiCanvasMutex);
            if (display < 0) {
                for (auto& entry : session->rustDeskMultiCanvasPipelines) {
                    retired.push_back(std::move(entry.second));
                }
                session->rustDeskMultiCanvasPipelines.clear();
            } else {
                const auto found = session->rustDeskMultiCanvasPipelines.find(display);
                if (found != session->rustDeskMultiCanvasPipelines.end()) {
                    retired.push_back(std::move(found->second));
                    session->rustDeskMultiCanvasPipelines.erase(found);
                }
            }
        }
        removed = !retired.empty();
        for (const auto& pipeline : retired) {
            DestroyRustDeskMultiCanvasPipeline(session->identity(), pipeline);
        }
        (void)RefreshRustDeskMultiCanvasCaptureSet(session);
    }
    napi_value result;
    napi_get_boolean(env, removed, &result);
    return result;
}

/** NAPI: getRustDeskMultiCanvasPreview(sessionId, display): snapshot */
napi_value NapiGetRustDeskMultiCanvasPreview(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    int32_t display = -1;
    if (argc >= 1) napi_get_value_int32(env, args[0], &sessionId);
    if (argc >= 2) napi_get_value_int32(env, args[1], &display);
    auto it = g_sessionRegistry.find(sessionId);
    const std::shared_ptr<SessionContext> session =
        it == g_sessionRegistry.end() ? nullptr : it->second;
    std::shared_ptr<RustDeskMultiCanvasPipeline> pipeline;
    if (session) {
        std::lock_guard<std::mutex> lock(session->rustDeskMultiCanvasMutex);
        if (display >= 0) {
            const auto found = session->rustDeskMultiCanvasPipelines.find(display);
            if (found != session->rustDeskMultiCanvasPipelines.end()) pipeline = found->second;
        } else if (!session->rustDeskMultiCanvasPipelines.empty()) {
            pipeline = session->rustDeskMultiCanvasPipelines.begin()->second;
        }
    }
    return CreateRustDeskMultiCanvasPipelineValue(env, session, pipeline);
}

/** NAPI: beginRustDeskDisplaySwitch(sessionId, display): { accepted, generation } */
napi_value NapiBeginRustDeskDisplaySwitch(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    int32_t display = -1;
    if (argc >= 2) {
        napi_get_value_int32(env, args[0], &sessionId);
        napi_get_value_int32(env, args[1], &display);
    }

    RustDeskDisplaySwitchRequest request;
    auto it = g_sessionRegistry.find(sessionId);
    const std::shared_ptr<SessionContext> session =
        it == g_sessionRegistry.end() ? nullptr : it->second;
    if (IsValidRustDeskDisplay(display) && IsSessionCallbackActive(session)) {
        const std::shared_ptr<RustDeskBridge> bridge = GetRustDeskAdapter(session);
        if (bridge && IsSessionCallbackActive(session)) {
            request = bridge->beginDisplaySwitch(display);
        }
    }

    napi_value result;
    napi_create_object(env, &result);
    SetObjectBool(env, result, "accepted", request.accepted);
    SetObjectInt64(env, result, "generation", static_cast<int64_t>(request.generation));
    return result;
}

/** NAPI: switchRustDeskDisplay(sessionId, display): boolean */
napi_value NapiSwitchRustDeskDisplay(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    int32_t display = -1;
    if (argc >= 2) {
        napi_get_value_int32(env, args[0], &sessionId);
        napi_get_value_int32(env, args[1], &display);
    }

    bool accepted = false;
    auto it = g_sessionRegistry.find(sessionId);
    const std::shared_ptr<SessionContext> session =
        it == g_sessionRegistry.end() ? nullptr : it->second;
    if (IsValidRustDeskDisplay(display) && IsSessionCallbackActive(session)) {
        const std::shared_ptr<RustDeskBridge> bridge = GetRustDeskAdapter(session);
        if (bridge && IsSessionCallbackActive(session)) {
            accepted = bridge->switchDisplay(display);
            if (accepted) {
                OH_LOG_INFO(LOG_APP,
                            "[ExtLoader] RustDesk display switch accepted session=%{public}d display=%{public}d",
                            sessionId, display);
            }
        }
    }

    napi_value result;
    napi_get_boolean(env, accepted, &result);
    return result;
}

/** NAPI: changeRustDeskDisplayResolution(sessionId, display, width, height): boolean */
napi_value NapiChangeRustDeskDisplayResolution(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    int32_t display = 0;
    int32_t width = 0;
    int32_t height = 0;
    if (argc >= 4) {
        napi_get_value_int32(env, args[0], &sessionId);
        napi_get_value_int32(env, args[1], &display);
        napi_get_value_int32(env, args[2], &width);
        napi_get_value_int32(env, args[3], &height);
    }
    bool accepted = false;
    auto it = g_sessionRegistry.find(sessionId);
    const std::shared_ptr<SessionContext> session =
        it == g_sessionRegistry.end() ? nullptr : it->second;
    if (IsValidRustDeskDisplay(display) && IsSessionCallbackActive(session)) {
        const std::shared_ptr<RustDeskBridge> bridge = GetRustDeskAdapter(session);
        if (bridge && IsSessionCallbackActive(session)) {
            accepted = bridge->changeDisplayResolution(display, width, height);
        }
    }
    napi_value result;
    napi_get_boolean(env, accepted, &result);
    return result;
}

/** NAPI: sendRustDeskTouchScale(sessionId, scale): boolean */
napi_value NapiSendRustDeskTouchScale(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    int32_t scale = 0;
    if (argc >= 2) {
        napi_get_value_int32(env, args[0], &sessionId);
        napi_get_value_int32(env, args[1], &scale);
    }
    bool accepted = false;
    auto it = g_sessionRegistry.find(sessionId);
    const std::shared_ptr<SessionContext> session =
        it == g_sessionRegistry.end() ? nullptr : it->second;
    if (session) {
        const std::shared_ptr<RustDeskBridge> bridge = GetRustDeskAdapter(session);
        if (bridge) accepted = bridge->sendTouchScale(scale);
    }
    napi_value result;
    napi_get_boolean(env, accepted, &result);
    return result;
}

/** NAPI: sendRustDeskTouchPan(sessionId, phase, x, y): boolean */
napi_value NapiSendRustDeskTouchPan(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    int32_t phase = -1;
    int32_t x = 0;
    int32_t y = 0;
    if (argc >= 4) {
        napi_get_value_int32(env, args[0], &sessionId);
        napi_get_value_int32(env, args[1], &phase);
        napi_get_value_int32(env, args[2], &x);
        napi_get_value_int32(env, args[3], &y);
    }
    bool accepted = false;
    auto it = g_sessionRegistry.find(sessionId);
    const std::shared_ptr<SessionContext> session =
        it == g_sessionRegistry.end() ? nullptr : it->second;
    if (session) {
        const std::shared_ptr<RustDeskBridge> bridge = GetRustDeskAdapter(session);
        if (bridge) accepted = bridge->sendTouchPan(phase, x, y);
    }
    napi_value result;
    napi_get_boolean(env, accepted, &result);
    return result;
}

/**
 * NAPI: sendText(sessionId: number, text: string): void
 */
napi_value NapiSendText(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId;
    napi_get_value_int32(env, args[0], &sessionId);

    // Do not truncate terminal input at a fixed stack buffer. Paste and
    // bracketed-paste payloads are still bounded by an explicit native limit,
    // but valid UTF-8/control bytes up to that limit must reach the channel.
    std::string text = GetNapiString(env, args[1]);
    constexpr size_t kMaxSshInputBytes = 256 * 1024;
    if (text.size() > kMaxSshInputBytes) {
        OH_LOG_WARN(LOG_APP,
            "[ExtLoader] NapiSendText rejected oversized input session=%{public}d len=%{public}zu",
            sessionId, text.size());
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter) {
        if (it->second->protocolName == "vnc") {
            it->second->diagnostics.inputEventsSent.fetch_add(1, std::memory_order_relaxed);
        }
        it->second->adapter->sendText(text);
    } else {
        if (it != g_sessionRegistry.end() && it->second->protocolName == "vnc") {
            it->second->diagnostics.inputEventsDropped.fetch_add(1, std::memory_order_relaxed);
        }
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static const char* SshTerminalInputStatusName(SshTerminalInputStatus status) {
    switch (status) {
        case SshTerminalInputStatus::ACCEPTED: return "accepted";
        case SshTerminalInputStatus::QUEUE_FULL: return "queueFull";
        case SshTerminalInputStatus::SESSION_CLOSED: return "sessionClosed";
        case SshTerminalInputStatus::STALE_GENERATION: return "staleGeneration";
        case SshTerminalInputStatus::INVALID: return "invalid";
    }
    return "invalid";
}

/**
 * NAPI: enqueueSshTerminalInput(sessionId, text, expectedGeneration, control,
 *                              ordered, orderedEnd)
 *
 * The call only copies into the SSH adapter's bounded queue. It never enters
 * the libssh2 write loop on the ArkUI thread.
 */
napi_value NapiEnqueueSshTerminalInput(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    SshTerminalInputResult result;
    int32_t sessionId = 0;
    if (argc < 2 || napi_get_value_int32(env, args[0], &sessionId) != napi_ok) {
        result.status = SshTerminalInputStatus::INVALID;
    } else {
        std::string text = GetNapiString(env, args[1]);
        int64_t expectedGenerationValue = 0;
        if (argc > 2) {
            (void)napi_get_value_int64(env, args[2], &expectedGenerationValue);
        }
        bool control = false;
        if (argc > 3) {
            (void)napi_get_value_bool(env, args[3], &control);
        }
        bool ordered = false;
        if (argc > 4) {
            (void)napi_get_value_bool(env, args[4], &ordered);
        }
        bool orderedEnd = false;
        if (argc > 5) {
            (void)napi_get_value_bool(env, args[5], &orderedEnd);
        }
        const auto it = g_sessionRegistry.find(sessionId);
        const std::shared_ptr<SessionContext> session =
            it == g_sessionRegistry.end() ? nullptr : it->second;
        if (!session) {
            result.status = SshTerminalInputStatus::SESSION_CLOSED;
        } else if (session->lifecycle.load(std::memory_order_acquire) !=
                   SessionContext::Lifecycle::Active) {
            // BeginSessionTeardown marks Disconnecting before the executor
            // reaches adapter->disconnect(). Reject in this window so a late
            // key cannot enter a session that is already being closed.
            result.status = SshTerminalInputStatus::SESSION_CLOSED;
        } else {
            std::shared_ptr<ProtocolAdapter> adapter;
            {
                std::lock_guard<std::mutex> lock(session->adapterMutex);
                adapter = session->adapter;
            }
            auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(adapter);
            if (!sshAdapter) {
                result.status = SshTerminalInputStatus::INVALID;
            } else {
                result = sshAdapter->enqueueTerminalInput(
                    reinterpret_cast<const uint8_t*>(text.data()), text.size(), control,
                    expectedGenerationValue > 0 ?
                        static_cast<uint64_t>(expectedGenerationValue) : 0,
                    ordered, orderedEnd);
            }
        }
    }

    napi_value output;
    napi_create_object(env, &output);
    SetObjectBool(env, output, "accepted", result.accepted());
    SetObjectString(env, output, "status", SshTerminalInputStatusName(result.status));
    SetObjectInt64(env, output, "sequence", static_cast<int64_t>(result.sequence));
    SetObjectInt64(env, output, "generation", static_cast<int64_t>(result.generation));
    SetObjectInt64(env, output, "queueDepth", static_cast<int64_t>(result.queueDepth));
    SetObjectInt64(env, output, "queueBytes", static_cast<int64_t>(result.queueBytes));
    return output;
}

/**
 * NAPI: sendFile(sessionId: number, remotePath: string, data: ArrayBuffer): number
 * 返回 0 成功, -1 失败
 */
napi_value NapiSendFile(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &sessionId);
    }

    char remotePath[1024] = {0};
    if (argc > 1) {
        napi_get_value_string_utf8(env, args[1], remotePath, sizeof(remotePath), nullptr);
    }

    void* data = nullptr;
    size_t dataLen = 0;
    if (argc > 2) {
        napi_get_arraybuffer_info(env, args[2], &data, &dataLen);
    }

    auto it = g_sessionRegistry.find(sessionId);
    const std::string pathId = SafeLog::HashForLog(remotePath);
    if (it != g_sessionRegistry.end() && it->second->adapter) {
        uint64_t index = ++g_napiFileSendCount;
        OH_LOG_INFO(LOG_APP,
            "[ExtLoader] NapiSendFile #%{public}llu session=%{public}d pathId=%{public}s len=%{public}zu found=yes",
            static_cast<unsigned long long>(index),
            sessionId,
            pathId.c_str(),
            dataLen);
        int ret = it->second->adapter->sendFileData(
            remotePath,
            static_cast<const uint8_t*>(data),
            static_cast<uint32_t>(dataLen));
        OH_LOG_INFO(LOG_APP,
            "[ExtLoader] NapiSendFile result session=%{public}d ret=%{public}d",
            sessionId,
            ret);
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }

    OH_LOG_WARN(LOG_APP,
        "[ExtLoader] NapiSendFile session=%{public}d pathId=%{public}s len=%{public}zu found=no",
        sessionId,
        pathId.c_str(),
        dataLen);
    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

/**
 * NAPI: writeRemoteFileChunk(sessionId, remotePath, data, offset, truncate): number
 */
napi_value NapiWriteRemoteFileChunk(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &sessionId);
    }

    char remotePath[1024] = {0};
    if (argc > 1) {
        napi_get_value_string_utf8(env, args[1], remotePath, sizeof(remotePath), nullptr);
    }

    void* data = nullptr;
    size_t dataLen = 0;
    if (argc > 2) {
        napi_get_arraybuffer_info(env, args[2], &data, &dataLen);
    }

    double offsetDouble = 0;
    if (argc > 3) {
        napi_get_value_double(env, args[3], &offsetDouble);
    }

    bool truncate = false;
    if (argc > 4) {
        napi_get_value_bool(env, args[4], &truncate);
    }

    int ret = -1;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter) {
        ret = it->second->adapter->writeRemoteFileChunk(
            remotePath,
            static_cast<const uint8_t*>(data),
            static_cast<uint32_t>(dataLen),
            static_cast<uint64_t>(offsetDouble),
            truncate);
    }
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

/**
 * NAPI: listRemoteDir(sessionId: number, remotePath: string): Array<SftpFileEntry>
 */
napi_value NapiListRemoteDir(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &sessionId);
    }
    char remotePath[1024] = {0};
    if (argc > 1) {
        napi_get_value_string_utf8(env, args[1], remotePath, sizeof(remotePath), nullptr);
    }

    napi_value result;
    napi_create_array(env, &result);

    auto it = g_sessionRegistry.find(sessionId);
    if (it == g_sessionRegistry.end() || !it->second->adapter) {
        OH_LOG_WARN(LOG_APP, "[ExtLoader] listRemoteDir: session not found id=%{public}d", sessionId);
        return result;
    }

    std::vector<SftpFileEntry> entries;
    int ret = it->second->adapter->listRemoteDir(remotePath, entries);
    if (ret < 0) {
        const std::string pathId = SafeLog::HashForLog(remotePath);
        OH_LOG_WARN(LOG_APP, "[ExtLoader] listRemoteDir failed id=%{public}d pathId=%{public}s ret=%{public}d",
                    sessionId, pathId.c_str(), ret);
        return result;
    }

    for (size_t i = 0; i < entries.size(); i++) {
        napi_value item;
        napi_create_object(env, &item);

        napi_value val;
        napi_create_string_utf8(env, entries[i].name.c_str(), NAPI_AUTO_LENGTH, &val);
        napi_set_named_property(env, item, "name", val);
        napi_create_string_utf8(env, entries[i].path.c_str(), NAPI_AUTO_LENGTH, &val);
        napi_set_named_property(env, item, "path", val);
        napi_get_boolean(env, entries[i].isDirectory, &val);
        napi_set_named_property(env, item, "isDirectory", val);
        napi_get_boolean(env, entries[i].isSymbolicLink, &val);
        napi_set_named_property(env, item, "isSymbolicLink", val);
        napi_get_boolean(env, entries[i].isSpecialFile, &val);
        napi_set_named_property(env, item, "isSpecialFile", val);
        napi_create_double(env, static_cast<double>(entries[i].size), &val);
        napi_set_named_property(env, item, "size", val);
        napi_create_double(env, static_cast<double>(entries[i].mode), &val);
        napi_set_named_property(env, item, "mode", val);
        napi_create_double(env, static_cast<double>(entries[i].uid), &val);
        napi_set_named_property(env, item, "uid", val);
        napi_create_double(env, static_cast<double>(entries[i].gid), &val);
        napi_set_named_property(env, item, "gid", val);
        napi_create_double(env, static_cast<double>(entries[i].atime), &val);
        napi_set_named_property(env, item, "atime", val);
        napi_create_double(env, static_cast<double>(entries[i].mtime), &val);
        napi_set_named_property(env, item, "mtime", val);

        napi_set_element(env, result, static_cast<uint32_t>(i), item);
    }
    return result;
}

/**
 * NAPI: readRemoteFile(sessionId: number, remotePath: string): ArrayBuffer
 */
napi_value NapiReadRemoteFile(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &sessionId);
    }
    char remotePath[1024] = {0};
    if (argc > 1) {
        napi_get_value_string_utf8(env, args[1], remotePath, sizeof(remotePath), nullptr);
    }

    std::vector<uint8_t> bytes;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter) {
        int ret = it->second->adapter->readRemoteFile(remotePath, bytes);
        if (ret < 0) {
            const std::string pathId = SafeLog::HashForLog(remotePath);
            OH_LOG_WARN(LOG_APP, "[ExtLoader] readRemoteFile failed id=%{public}d pathId=%{public}s ret=%{public}d",
                        sessionId, pathId.c_str(), ret);
            bytes.clear();
        }
    }

    void* data = nullptr;
    napi_value result;
    napi_create_arraybuffer(env, bytes.size(), &data, &result);
    if (!bytes.empty() && data != nullptr) {
        memcpy(data, bytes.data(), bytes.size());
    }
    return result;
}

/**
 * NAPI: readRemoteFileChunk(sessionId: number, remotePath: string, offset: number, maxLen: number): ArrayBuffer
 */
napi_value NapiReadRemoteFileChunk(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &sessionId);
    }
    char remotePath[1024] = {0};
    if (argc > 1) {
        napi_get_value_string_utf8(env, args[1], remotePath, sizeof(remotePath), nullptr);
    }
    double offsetDouble = 0;
    if (argc > 2) {
        napi_get_value_double(env, args[2], &offsetDouble);
    }
    int32_t maxLen = 0;
    if (argc > 3) {
        napi_get_value_int32(env, args[3], &maxLen);
    }

    std::vector<uint8_t> bytes;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter && maxLen > 0) {
        int ret = it->second->adapter->readRemoteFileChunk(
            remotePath,
            static_cast<uint64_t>(offsetDouble),
            static_cast<uint32_t>(maxLen),
            bytes);
        if (ret < 0) {
            const std::string pathId = SafeLog::HashForLog(remotePath);
            OH_LOG_WARN(LOG_APP, "[ExtLoader] readRemoteFileChunk failed id=%{public}d pathId=%{public}s ret=%{public}d",
                        sessionId, pathId.c_str(), ret);
            bytes.clear();
        }
    }

    void* data = nullptr;
    napi_value result;
    napi_create_arraybuffer(env, bytes.size(), &data, &result);
    if (!bytes.empty() && data != nullptr) {
        memcpy(data, bytes.data(), bytes.size());
    }
    return result;
}

enum class SftpAsyncOperation {
    ListDirectory,
    ReadChunk,
    WriteChunk,
    RemoveFile,
    RemoveDirectory,
    MakeDirectory,
    RenamePath
};

struct SftpAsyncData {
    SftpAsyncOperation operation = SftpAsyncOperation::ListDirectory;
    int32_t sessionId = 0;
    uint64_t expectedGeneration = 0;
    uint64_t sessionGeneration = 0;
    std::shared_ptr<SessionContext> session;
    std::shared_ptr<ProtocolAdapter> adapter;
    std::string remotePath;
    std::string newRemotePath;
    std::vector<uint8_t> input;
    std::vector<uint8_t> output;
    std::vector<SftpFileEntry> entries;
    uint64_t offset = 0;
    uint32_t maxLen = 0;
    bool truncate = false;
    bool atomicRename = false;
    bool transportLost = false;
    int errorCode = ERR_SSH_SESSION_CLOSED;
    int bytesWritten = 0;
    bool workerFailed = false;
    std::string errorMessage;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

static void ExecuteSftpAsync(napi_env /*env*/, void* rawData) {
    auto* data = static_cast<SftpAsyncData*>(rawData);
    if (data == nullptr || !data->adapter) {
        return;
    }

    // Keep the request bound to the exact native session identity captured by
    // ArkTS. A detached/reconnected session can retain the same page task
    // while its transport and generation have already changed; that request
    // must fail closed before it enters libssh2.
    if (!data->session || data->session->lifecycle.load(std::memory_order_acquire) !=
            SessionContext::Lifecycle::Active ||
        (data->expectedGeneration > 0 &&
            data->session->generation.load(std::memory_order_acquire) !=
                data->expectedGeneration)) {
        data->errorCode = ERR_SSH_SESSION_STALE;
        OH_LOG_WARN(LOG_APP,
            "[ExtLoader] SFTP stale request rejected id=%{public}d expected=%{public}llu current=%{public}llu",
            data->sessionId,
            static_cast<unsigned long long>(data->expectedGeneration),
            data->session ? static_cast<unsigned long long>(
                data->session->generation.load(std::memory_order_acquire)) : 0ULL);
        return;
    }

    try {
        auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(data->adapter);
        if (!sshAdapter) {
            data->errorCode = ERR_SSH_SESSION_CLOSED;
            return;
        }
        const SftpOperationResult result = sshAdapter->executeSftpOperation(
            [data, sshAdapter]() -> int {
            switch (data->operation) {
                case SftpAsyncOperation::ListDirectory:
                    return sshAdapter->listRemoteDir(data->remotePath, data->entries);
                case SftpAsyncOperation::ReadChunk:
                    return sshAdapter->readRemoteFileChunk(
                        data->remotePath, data->offset, data->maxLen, data->output);
                case SftpAsyncOperation::WriteChunk:
                    data->bytesWritten = sshAdapter->writeRemoteFileChunk(
                        data->remotePath,
                        data->input.empty() ? nullptr : data->input.data(),
                        static_cast<uint32_t>(data->input.size()),
                        data->offset,
                        data->truncate);
                    return data->bytesWritten < 0 ? data->bytesWritten : 0;
                case SftpAsyncOperation::RemoveFile:
                    return sshAdapter->removeRemoteFile(data->remotePath);
                case SftpAsyncOperation::RemoveDirectory:
                    return sshAdapter->removeRemoteDir(data->remotePath);
                case SftpAsyncOperation::MakeDirectory:
                    return sshAdapter->makeRemoteDir(data->remotePath);
                case SftpAsyncOperation::RenamePath:
                    return data->atomicRename
                        ? sshAdapter->renameRemotePathAtomic(
                            data->remotePath, data->newRemotePath)
                        : sshAdapter->renameRemotePath(
                            data->remotePath, data->newRemotePath);
            }
            return static_cast<int>(ERR_SSH_SESSION_CLOSED);
        });
        data->errorCode = result.errorCode;
        data->transportLost = result.transportLost;
    } catch (const std::exception& ex) {
        data->workerFailed = true;
        data->errorMessage = std::string("SFTP async work failed: ") + ex.what();
    } catch (...) {
        data->workerFailed = true;
        data->errorMessage = "SFTP async work failed: unknown native exception";
    }
}

static void SetSftpEntryValue(napi_env env, napi_value item, const SftpFileEntry& entry) {
    napi_value value;
    napi_create_string_utf8(env, entry.name.c_str(), NAPI_AUTO_LENGTH, &value);
    napi_set_named_property(env, item, "name", value);
    napi_create_string_utf8(env, entry.path.c_str(), NAPI_AUTO_LENGTH, &value);
    napi_set_named_property(env, item, "path", value);
    napi_get_boolean(env, entry.isDirectory, &value);
    napi_set_named_property(env, item, "isDirectory", value);
    napi_get_boolean(env, entry.isSymbolicLink, &value);
    napi_set_named_property(env, item, "isSymbolicLink", value);
    napi_get_boolean(env, entry.isSpecialFile, &value);
    napi_set_named_property(env, item, "isSpecialFile", value);
    napi_create_double(env, static_cast<double>(entry.size), &value);
    napi_set_named_property(env, item, "size", value);
    napi_create_double(env, static_cast<double>(entry.mode), &value);
    napi_set_named_property(env, item, "mode", value);
    napi_create_double(env, static_cast<double>(entry.uid), &value);
    napi_set_named_property(env, item, "uid", value);
    napi_create_double(env, static_cast<double>(entry.gid), &value);
    napi_set_named_property(env, item, "gid", value);
    napi_create_double(env, static_cast<double>(entry.atime), &value);
    napi_set_named_property(env, item, "atime", value);
    napi_create_double(env, static_cast<double>(entry.mtime), &value);
    napi_set_named_property(env, item, "mtime", value);
}

static napi_value CreateSftpAsyncResult(napi_env env, const SftpAsyncData& data) {
    napi_value result;
    napi_create_object(env, &result);
    napi_value errorCode;
    napi_create_int32(env, data.errorCode, &errorCode);
    napi_set_named_property(env, result, "errorCode", errorCode);
    napi_value transportLost;
    napi_get_boolean(env, data.transportLost, &transportLost);
    napi_set_named_property(env, result, "transportLost", transportLost);

    if (data.operation == SftpAsyncOperation::ListDirectory) {
        napi_value entries;
        napi_create_array_with_length(env, data.entries.size(), &entries);
        for (size_t index = 0; index < data.entries.size(); ++index) {
            napi_value item;
            napi_create_object(env, &item);
            SetSftpEntryValue(env, item, data.entries[index]);
            napi_set_element(env, entries, static_cast<uint32_t>(index), item);
        }
        napi_set_named_property(env, result, "entries", entries);
    } else if (data.operation == SftpAsyncOperation::ReadChunk) {
        void* raw = nullptr;
        napi_value bytes;
        napi_create_arraybuffer(env, data.output.size(), &raw, &bytes);
        if (raw != nullptr && !data.output.empty()) {
            std::memcpy(raw, data.output.data(), data.output.size());
        }
        napi_set_named_property(env, result, "data", bytes);
    } else {
        napi_value bytesWritten;
        napi_create_int32(env, data.bytesWritten, &bytesWritten);
        napi_set_named_property(env, result, "bytesWritten", bytesWritten);
        if (data.operation == SftpAsyncOperation::WriteChunk) {
            napi_value durability;
            const char* durabilityName = data.errorCode == 0 ? "durable" :
                (data.errorCode == ERR_SSH_SFTP_DURABILITY_UNSUPPORTED ? "unsupported" : "failed");
            napi_create_string_utf8(env, durabilityName, NAPI_AUTO_LENGTH, &durability);
            napi_set_named_property(env, result, "durability", durability);
        }
        if (data.operation == SftpAsyncOperation::RenamePath) {
            napi_value atomic;
            napi_get_boolean(env, data.atomicRename && data.errorCode == 0, &atomic);
            napi_set_named_property(env, result, "atomic", atomic);
        }
    }
    return result;
}

static void CompleteSftpAsync(napi_env env, napi_status status, void* rawData) {
    auto* data = static_cast<SftpAsyncData*>(rawData);
    if (data == nullptr) {
        return;
    }
    if (status != napi_ok || data->workerFailed) {
        napi_value error;
        const std::string message = data->errorMessage.empty()
            ? "SFTP async work failed" : data->errorMessage;
        napi_create_string_utf8(env, message.c_str(), NAPI_AUTO_LENGTH, &error);
        napi_reject_deferred(env, data->deferred, error);
    } else {
        napi_value result = CreateSftpAsyncResult(env, *data);
        napi_resolve_deferred(env, data->deferred, result);
    }
    napi_delete_async_work(env, data->work);
    delete data;
}

static napi_value QueueSftpAsync(napi_env env, SftpAsyncData* data, const char* resourceName) {
    if (data == nullptr) {
        napi_throw_error(env, nullptr, "SFTP async allocation failed");
        return nullptr;
    }
    napi_value promise;
    napi_status status = napi_create_promise(env, &data->deferred, &promise);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "SFTP async promise creation failed");
        return nullptr;
    }
    napi_value resource;
    status = napi_create_string_utf8(env, resourceName, NAPI_AUTO_LENGTH, &resource);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "SFTP async resource creation failed");
        return nullptr;
    }
    status = napi_create_async_work(env, resource, resource,
        ExecuteSftpAsync, CompleteSftpAsync, data, &data->work);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "SFTP async work creation failed");
        return nullptr;
    }
    status = napi_queue_async_work(env, data->work);
    if (status != napi_ok) {
        napi_delete_async_work(env, data->work);
        delete data;
        napi_throw_error(env, nullptr, "SFTP async work queue failed");
        return nullptr;
    }
    return promise;
}

static std::shared_ptr<SessionContext> FindSshSessionContext(int32_t sessionId) {
    std::shared_ptr<SessionContext> session;
    const auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end()) {
        session = it->second;
    }
    return session;
}

static bool ParseOptionalSftpGeneration(napi_env env, napi_value value,
                                        uint64_t& generation) {
    generation = 0;
    if (value == nullptr) {
        return true;
    }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok ||
        type == napi_undefined || type == napi_null) {
        return true;
    }
    int64_t parsed = 0;
    if (type != napi_number || napi_get_value_int64(env, value, &parsed) != napi_ok ||
        parsed < 0) {
        return false;
    }
    generation = static_cast<uint64_t>(parsed);
    return true;
}

static bool BindSftpSession(SftpAsyncData& data, uint64_t expectedGeneration) {
    data.expectedGeneration = expectedGeneration;
    data.session = FindSshSessionContext(data.sessionId);
    if (!data.session || data.session->lifecycle.load(std::memory_order_acquire) !=
            SessionContext::Lifecycle::Active) {
        data.errorCode = ERR_SSH_SESSION_CLOSED;
        return false;
    }
    data.sessionGeneration = data.session->generation.load(std::memory_order_acquire);
    if (expectedGeneration > 0 && data.sessionGeneration != expectedGeneration) {
        data.errorCode = ERR_SSH_SESSION_STALE;
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(data.session->adapterMutex);
        data.adapter = data.session->adapter;
    }
    if (!data.adapter) {
        data.errorCode = ERR_SSH_SESSION_CLOSED;
        return false;
    }
    return true;
}

napi_value NapiListRemoteDirAsync(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto* data = new (std::nothrow) SftpAsyncData();
    if (data == nullptr) {
        napi_throw_error(env, nullptr, "SFTP list async allocation failed");
        return nullptr;
    }
    if (argc > 0) { napi_get_value_int32(env, args[0], &data->sessionId); }
    if (argc > 1) { data->remotePath = GetNapiString(env, args[1]); }
    uint64_t expectedGeneration = 0;
    if (argc > 2 && !ParseOptionalSftpGeneration(env, args[2], expectedGeneration)) {
        delete data;
        napi_throw_type_error(env, nullptr, "invalid SFTP session generation");
        return nullptr;
    }
    data->operation = SftpAsyncOperation::ListDirectory;
    (void)BindSftpSession(*data, expectedGeneration);
    return QueueSftpAsync(env, data, "SshListRemoteDirAsync");
}

napi_value NapiReadRemoteFileChunkAsync(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto* data = new (std::nothrow) SftpAsyncData();
    if (data == nullptr) {
        napi_throw_error(env, nullptr, "SFTP read async allocation failed");
        return nullptr;
    }
    if (argc > 0) { napi_get_value_int32(env, args[0], &data->sessionId); }
    if (argc > 1) { data->remotePath = GetNapiString(env, args[1]); }
    double offset = 0;
    int32_t maxLen = 0;
    if (argc > 2) { napi_get_value_double(env, args[2], &offset); }
    if (argc > 3) { napi_get_value_int32(env, args[3], &maxLen); }
    if (offset < 0 || maxLen <= 0 || maxLen > 8 * 1024 * 1024) {
        delete data;
        napi_throw_range_error(env, nullptr, "invalid SFTP read range");
        return nullptr;
    }
    uint64_t expectedGeneration = 0;
    if (argc > 4 && !ParseOptionalSftpGeneration(env, args[4], expectedGeneration)) {
        delete data;
        napi_throw_type_error(env, nullptr, "invalid SFTP session generation");
        return nullptr;
    }
    data->operation = SftpAsyncOperation::ReadChunk;
    data->offset = static_cast<uint64_t>(offset);
    data->maxLen = static_cast<uint32_t>(maxLen);
    (void)BindSftpSession(*data, expectedGeneration);
    return QueueSftpAsync(env, data, "SshReadRemoteFileChunkAsync");
}

napi_value NapiWriteRemoteFileChunkAsync(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto* data = new (std::nothrow) SftpAsyncData();
    if (data == nullptr) {
        napi_throw_error(env, nullptr, "SFTP write async allocation failed");
        return nullptr;
    }
    if (argc > 0) { napi_get_value_int32(env, args[0], &data->sessionId); }
    if (argc > 1) { data->remotePath = GetNapiString(env, args[1]); }
    bool isArrayBuffer = false;
    void* raw = nullptr;
    size_t dataLen = 0;
    if (argc <= 2 || napi_is_arraybuffer(env, args[2], &isArrayBuffer) != napi_ok ||
        !isArrayBuffer || napi_get_arraybuffer_info(env, args[2], &raw, &dataLen) != napi_ok ||
        dataLen > 16 * 1024 * 1024 || (dataLen > 0 && raw == nullptr)) {
        delete data;
        napi_throw_type_error(env, nullptr, "SFTP write data must be an ArrayBuffer <= 16 MiB");
        return nullptr;
    }
    if (dataLen > 0 && raw != nullptr) {
        data->input.assign(static_cast<const uint8_t*>(raw),
                           static_cast<const uint8_t*>(raw) + dataLen);
    }
    double offset = 0;
    if (argc > 3) { napi_get_value_double(env, args[3], &offset); }
    if (offset < 0) {
        delete data;
        napi_throw_range_error(env, nullptr, "invalid SFTP write offset");
        return nullptr;
    }
    if (argc > 4) { napi_get_value_bool(env, args[4], &data->truncate); }
    uint64_t expectedGeneration = 0;
    if (argc > 5 && !ParseOptionalSftpGeneration(env, args[5], expectedGeneration)) {
        delete data;
        napi_throw_type_error(env, nullptr, "invalid SFTP session generation");
        return nullptr;
    }
    data->operation = SftpAsyncOperation::WriteChunk;
    data->offset = static_cast<uint64_t>(offset);
    (void)BindSftpSession(*data, expectedGeneration);
    return QueueSftpAsync(env, data, "SshWriteRemoteFileChunkAsync");
}

static SftpAsyncData* CreateSftpPathAsyncData(
    napi_env env, napi_callback_info info, SftpAsyncOperation operation, size_t maxArgc) {
    size_t argc = maxArgc;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto* data = new (std::nothrow) SftpAsyncData();
    if (data == nullptr) {
        napi_throw_error(env, nullptr, "SFTP mutation async allocation failed");
        return nullptr;
    }
    if (argc > 0) { napi_get_value_int32(env, args[0], &data->sessionId); }
    if (argc > 1) { data->remotePath = GetNapiString(env, args[1]); }
    uint64_t expectedGeneration = 0;
    if (argc > 2 && !ParseOptionalSftpGeneration(env, args[2], expectedGeneration)) {
        delete data;
        napi_throw_type_error(env, nullptr, "invalid SFTP session generation");
        return nullptr;
    }
    data->operation = operation;
    (void)BindSftpSession(*data, expectedGeneration);
    return data;
}

napi_value NapiRemoveRemoteFileAsync(napi_env env, napi_callback_info info) {
    SftpAsyncData* data = CreateSftpPathAsyncData(
        env, info, SftpAsyncOperation::RemoveFile, 3);
    if (data == nullptr) {
        return nullptr;
    }
    return QueueSftpAsync(env, data, "SshRemoveRemoteFileAsync");
}

napi_value NapiRemoveRemoteDirAsync(napi_env env, napi_callback_info info) {
    SftpAsyncData* data = CreateSftpPathAsyncData(
        env, info, SftpAsyncOperation::RemoveDirectory, 3);
    if (data == nullptr) {
        return nullptr;
    }
    return QueueSftpAsync(env, data, "SshRemoveRemoteDirAsync");
}

napi_value NapiMakeRemoteDirAsync(napi_env env, napi_callback_info info) {
    SftpAsyncData* data = CreateSftpPathAsyncData(
        env, info, SftpAsyncOperation::MakeDirectory, 3);
    if (data == nullptr) {
        return nullptr;
    }
    return QueueSftpAsync(env, data, "SshMakeRemoteDirAsync");
}

napi_value NapiRenameRemotePathAsync(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto* data = new (std::nothrow) SftpAsyncData();
    if (data == nullptr) {
        napi_throw_error(env, nullptr, "SFTP rename async allocation failed");
        return nullptr;
    }
    if (argc > 0) { napi_get_value_int32(env, args[0], &data->sessionId); }
    if (argc > 1) { data->remotePath = GetNapiString(env, args[1]); }
    if (argc > 2) { data->newRemotePath = GetNapiString(env, args[2]); }
    if (argc > 3) { napi_get_value_bool(env, args[3], &data->atomicRename); }
    uint64_t expectedGeneration = 0;
    if (argc > 4 && !ParseOptionalSftpGeneration(env, args[4], expectedGeneration)) {
        delete data;
        napi_throw_type_error(env, nullptr, "invalid SFTP session generation");
        return nullptr;
    }
    if (data->remotePath.empty() || data->newRemotePath.empty()) {
        delete data;
        napi_throw_type_error(env, nullptr, "SFTP rename paths must not be empty");
        return nullptr;
    }
    data->operation = SftpAsyncOperation::RenamePath;
    (void)BindSftpSession(*data, expectedGeneration);
    return QueueSftpAsync(env, data, "SshRenameRemotePathAsync");
}

/**
 * NAPI: removeRemoteFile/removeRemoteDir/makeRemoteDir/renameRemotePath
 */
napi_value NapiRemoveRemoteFile(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    char remotePath[1024] = {0};
    if (argc > 0) napi_get_value_int32(env, args[0], &sessionId);
    if (argc > 1) napi_get_value_string_utf8(env, args[1], remotePath, sizeof(remotePath), nullptr);
    int ret = -1;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter) {
        ret = it->second->adapter->removeRemoteFile(remotePath);
    }
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

napi_value NapiRemoveRemoteDir(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    char remotePath[1024] = {0};
    if (argc > 0) napi_get_value_int32(env, args[0], &sessionId);
    if (argc > 1) napi_get_value_string_utf8(env, args[1], remotePath, sizeof(remotePath), nullptr);
    int ret = -1;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter) {
        ret = it->second->adapter->removeRemoteDir(remotePath);
    }
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

napi_value NapiMakeRemoteDir(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    char remotePath[1024] = {0};
    if (argc > 0) napi_get_value_int32(env, args[0], &sessionId);
    if (argc > 1) napi_get_value_string_utf8(env, args[1], remotePath, sizeof(remotePath), nullptr);
    int ret = -1;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter) {
        ret = it->second->adapter->makeRemoteDir(remotePath);
    }
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

napi_value NapiRenameRemotePath(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    char oldPath[1024] = {0};
    char newPath[1024] = {0};
    if (argc > 0) napi_get_value_int32(env, args[0], &sessionId);
    if (argc > 1) napi_get_value_string_utf8(env, args[1], oldPath, sizeof(oldPath), nullptr);
    if (argc > 2) napi_get_value_string_utf8(env, args[2], newPath, sizeof(newPath), nullptr);
    int ret = -1;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter) {
        ret = it->second->adapter->renameRemotePath(oldPath, newPath);
    }
    napi_value result;
    napi_create_int32(env, ret, &result);
    return result;
}

/**
 * NAPI: sendClipboard(sessionId: number, data: ArrayBuffer): void
 */
napi_value NapiSendClipboard(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &sessionId);
    }

    void* data = nullptr;
    size_t dataLen = 0;
    if (argc > 1) {
        napi_get_arraybuffer_info(env, args[1], &data, &dataLen);
    }

    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter) {
        it->second->adapter->sendClipboardData(
            static_cast<const uint8_t*>(data),
            static_cast<uint32_t>(dataLen));
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * NAPI: setSessionClipboardFiles(sessionId: number, paths: string[]): boolean
 * paths 必须是已复制到应用沙箱中的稳定绝对路径。
 */
napi_value NapiSetSessionClipboardFiles(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    bool accepted = false;
    bool isArray = false;
    if (argc == 2 && napi_get_value_int32(env, args[0], &sessionId) == napi_ok &&
        napi_is_array(env, args[1], &isArray) == napi_ok && isArray) {
        uint32_t length = 0;
        if (napi_get_array_length(env, args[1], &length) == napi_ok &&
            length > 0 && length <= 15) {
            std::vector<std::string> paths;
            paths.reserve(length);
            bool valid = true;
            for (uint32_t index = 0; index < length; ++index) {
                napi_value item;
                napi_valuetype type = napi_undefined;
                size_t byteLength = 0;
                if (napi_get_element(env, args[1], index, &item) != napi_ok ||
                    napi_typeof(env, item, &type) != napi_ok || type != napi_string ||
                    napi_get_value_string_utf8(env, item, nullptr, 0, &byteLength) != napi_ok ||
                    byteLength == 0 || byteLength > 4096) {
                    valid = false;
                    break;
                }
                std::vector<char> buffer(byteLength + 1, '\0');
                size_t written = 0;
                if (napi_get_value_string_utf8(env, item, buffer.data(), buffer.size(),
                                               &written) != napi_ok || written != byteLength) {
                    valid = false;
                    break;
                }
                paths.emplace_back(buffer.data(), written);
            }
            auto it = g_sessionRegistry.find(sessionId);
            if (valid && it != g_sessionRegistry.end() && it->second->adapter) {
                accepted = it->second->adapter->setClipboardFiles(paths);
            }
        }
    }

    napi_value result;
    napi_get_boolean(env, accepted, &result);
    return result;
}

napi_value NapiGetSessionClipboardText(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    if (argc > 0) napi_get_value_int32(env, args[0], &sessionId);
    std::string text;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter) text = it->second->adapter->getClipboardText();
    napi_value result;
    napi_create_string_utf8(env, text.c_str(), text.size(), &result);
    return result;
}

napi_value NapiIsSessionClipboardReady(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    if (argc > 0) napi_get_value_int32(env, args[0], &sessionId);
    bool ready = false;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter) ready = it->second->adapter->isClipboardReceiveReady();
    napi_value result;
    napi_get_boolean(env, ready, &result);
    return result;
}

/**
 * NAPI: setSessionClipboardEnabled(sessionId: number, enabled: boolean): boolean
 * 只切换当前会话的处理门禁；协议通道仍以连接握手结果为准。
 */
napi_value NapiSetSessionClipboardEnabled(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    bool enabled = false;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &sessionId);
    }
    if (argc > 1) {
        napi_get_value_bool(env, args[1], &enabled);
    }
    bool changed = false;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter) {
        changed = it->second->adapter->setSessionClipboardEnabled(enabled);
    }
    napi_value result;
    napi_get_boolean(env, changed, &result);
    return result;
}

/**
 * NAPI: getConnectionState(sessionId: number): number
 * 返回值: 0=DISCONNECTED, 1=CONNECTING, 2=CONNECTED, 3=RECONNECTING, 4=ERROR
 */
napi_value NapiGetConnectionState(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId;
    napi_get_value_int32(env, args[0], &sessionId);

    int state = 0;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter) {
        state = static_cast<int>(it->second->adapter->getState());
    }

    napi_value result;
    napi_create_int32(env, state, &result);
    return result;
}

static bool ReadSshAuthPromptResponse(
    napi_env env, napi_value object, SshAuthPromptResponse& response) {
    napi_valuetype type = napi_undefined;
    if (object == nullptr || napi_typeof(env, object, &type) != napi_ok ||
        type != napi_object) {
        return false;
    }
    napi_value value;
    int64_t number = 0;
    if (napi_get_named_property(env, object, "requestId", &value) != napi_ok ||
        napi_get_value_int64(env, value, &number) != napi_ok || number <= 0) {
        return false;
    }
    response.requestId = static_cast<uint64_t>(number);
    if (napi_get_named_property(env, object, "sessionId", &value) != napi_ok ||
        napi_get_value_int64(env, value, &number) != napi_ok || number <= 0) {
        return false;
    }
    response.sessionId = static_cast<uint64_t>(number);
    if (napi_get_named_property(env, object, "generation", &value) != napi_ok ||
        napi_get_value_int64(env, value, &number) != napi_ok || number <= 0) {
        return false;
    }
    response.generation = static_cast<uint64_t>(number);
    response.cancelled = false;
    if (napi_get_named_property(env, object, "cancelled", &value) == napi_ok) {
        (void)napi_get_value_bool(env, value, &response.cancelled);
    }
    response.responses.clear();
    ParseBoundedSshResponseArray(env, object, "responses", response.responses);
    return true;
}

napi_value NapiGetSshAuthPrompt(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    int64_t generation = 0;
    if (argc < 2 || napi_get_value_int32(env, args[0], &sessionId) != napi_ok ||
        napi_get_value_int64(env, args[1], &generation) != napi_ok ||
        sessionId <= 0 || generation <= 0) {
        napi_value result;
        napi_get_null(env, &result);
        return result;
    }
    SshForwardingSessionAccess access;
    if (ResolveSshForwardingSession(sessionId, static_cast<uint64_t>(generation), access) !=
            SshForwardingResult::Ok) {
        napi_value result;
        napi_get_null(env, &result);
        return result;
    }
    SshAuthPromptRequest request;
    if (!access.adapter->getAuthPrompt(request)) {
        napi_value result;
        napi_get_null(env, &result);
        return result;
    }
    return CreateSshAuthPromptValue(env, request);
}

napi_value NapiRespondSshAuthPrompt(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    SshAuthPromptResponse response;
    bool accepted = argc >= 1 && ReadSshAuthPromptResponse(env, args[0], response);
    if (accepted) {
        SshForwardingSessionAccess access;
        const SshForwardingResult result = ResolveSshForwardingSession(
            static_cast<int32_t>(response.sessionId), response.generation, access);
        accepted = result == SshForwardingResult::Ok &&
            access.adapter->respondAuthPrompt(response);
    }
    napi_value result;
    napi_get_boolean(env, accepted, &result);
    return result;
}

napi_value NapiCancelSshAuthPrompt(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    int64_t generation = 0;
    int64_t requestId = 0;
    const bool parsed = argc >= 3 &&
        napi_get_value_int32(env, args[0], &sessionId) == napi_ok &&
        napi_get_value_int64(env, args[1], &generation) == napi_ok &&
        napi_get_value_int64(env, args[2], &requestId) == napi_ok;
    bool accepted = false;
    if (parsed && sessionId > 0 && generation > 0 && requestId > 0) {
        SshForwardingSessionAccess access;
        if (ResolveSshForwardingSession(
                sessionId, static_cast<uint64_t>(generation), access) ==
            SshForwardingResult::Ok) {
            accepted = access.adapter->cancelAuthPrompt(
                static_cast<uint64_t>(requestId), static_cast<uint64_t>(generation));
        }
    }
    napi_value result;
    napi_get_boolean(env, accepted, &result);
    return result;
}

napi_value NapiGetSshSessionSnapshot(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    int64_t expectedGeneration = 0;
    if (argc > 0) {
        (void)napi_get_value_int32(env, args[0], &sessionId);
    }
    if (argc > 1) {
        (void)napi_get_value_int64(env, args[1], &expectedGeneration);
    }

    SshSessionSnapshot snapshot;
    int errorCode = expectedGeneration > 0
        ? static_cast<int>(SshForwardingResult::NotFound)
        : static_cast<int>(SshForwardingResult::MissingGeneration);
    const auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second && it->second->adapter) {
        auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(it->second->adapter);
        if (sshAdapter) {
            const uint64_t currentGeneration =
                it->second->generation.load(std::memory_order_acquire);
            if (expectedGeneration > 0 &&
                currentGeneration == static_cast<uint64_t>(expectedGeneration)) {
                errorCode = 0;
            } else if (expectedGeneration > 0) {
                errorCode = static_cast<int>(SshForwardingResult::StaleSession);
            }
            const SshSessionHandle handle {
                static_cast<uint64_t>(sessionId), "shell", currentGeneration};
            SshSessionManagerResult managerResult = SshSessionManagerResult::NotFound;
            if (!g_sshNativeFacade.snapshot(handle, snapshot, &managerResult)) {
                snapshot = sshAdapter->sessionSnapshot();
            }
        } else {
            errorCode = static_cast<int>(SshForwardingResult::InvalidState);
        }
    }
    return CreateSshSessionSnapshotValue(env, snapshot, errorCode);
}

napi_value NapiGetSshSessionEvents(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    int64_t generationValue = 0;
    int64_t afterSequenceValue = 0;
    std::string channelId;
    bool parsed = argc >= 3 &&
        napi_get_value_int32(env, args[0], &sessionId) == napi_ok &&
        napi_get_value_int64(env, args[2], &generationValue) == napi_ok;
    if (parsed && argc >= 4 && args[3] != nullptr) {
        napi_valuetype afterSequenceType = napi_undefined;
        if (napi_typeof(env, args[3], &afterSequenceType) != napi_ok) {
            parsed = false;
        } else if (afterSequenceType != napi_undefined && afterSequenceType != napi_null) {
            parsed = napi_get_value_int64(env, args[3], &afterSequenceValue) == napi_ok;
        }
    }
    if (argc >= 2 && args[1] != nullptr) {
        channelId = GetNapiString(env, args[1]);
    }

    SshSessionManagerResult resultCode = SshSessionManagerResult::InvalidIdentity;
    const uint64_t generation = generationValue > 0
        ? static_cast<uint64_t>(generationValue) : 0;
    const uint64_t afterSequence = afterSequenceValue >= 0
        ? static_cast<uint64_t>(afterSequenceValue) : 0;
    std::vector<SshEventEnvelope> events;
    if (parsed && sessionId > 0 && generation > 0 && afterSequenceValue >= 0 &&
        !channelId.empty()) {
        const SshSessionHandle handle {
            static_cast<uint64_t>(sessionId), channelId, generation};
        SshSessionSnapshot snapshot;
        if (g_sshNativeFacade.snapshot(handle, snapshot, &resultCode)) {
            events = g_sshNativeFacade.events(handle, afterSequence);
        }
    }
    return CreateSshSessionEventsValue(
        env, sessionId, channelId, generation, afterSequence, resultCode, events);
}

/**
 * NAPI forwarding bridge.
 *
 * Every operation takes the session generation captured from
 * getSshTerminalDiagnostics(). The adapter remains the single owner of the
 * forwarding manager; NAPI only validates the session and forwards the
 * lifecycle request.
 */
napi_value NapiConfigureSshForwarding(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    int64_t generationValue = 0;
    SshForwardingResult resultCode = SshForwardingResult::MissingGeneration;
    if (argc > 0) {
        (void)napi_get_value_int32(env, args[0], &sessionId);
    }
    if (argc > 1) {
        (void)napi_get_value_int64(env, args[1], &generationValue);
    }
    SshForwardingSessionAccess access;
    resultCode = ResolveSshForwardingSession(
        sessionId, generationValue > 0 ? static_cast<uint64_t>(generationValue) : 0,
        access);
    if (resultCode == SshForwardingResult::Ok) {
        SshForwardingConfig config;
        if (argc < 3 || !ReadSshForwardingConfig(env, args[2], config)) {
            resultCode = SshForwardingResult::InvalidId;
        } else {
            resultCode = access.adapter->configureForwarding(config);
        }
    }
    return CreateSshForwardingResultValue(env, resultCode);
}

napi_value NapiRemoveSshForwarding(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    int64_t generationValue = 0;
    if (argc > 0) {
        (void)napi_get_value_int32(env, args[0], &sessionId);
    }
    if (argc > 1) {
        (void)napi_get_value_int64(env, args[1], &generationValue);
    }
    const std::string id = argc > 2 ? GetNapiString(env, args[2]) : "";
    SshForwardingSessionAccess access;
    SshForwardingResult resultCode = ResolveSshForwardingSession(
        sessionId, generationValue > 0 ? static_cast<uint64_t>(generationValue) : 0,
        access);
    if (resultCode == SshForwardingResult::Ok) {
        resultCode = access.adapter->removeForwarding(id);
    }
    return CreateSshForwardingResultValue(env, resultCode);
}

napi_value NapiStartSshForwarding(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    int64_t generationValue = 0;
    if (argc > 0) {
        (void)napi_get_value_int32(env, args[0], &sessionId);
    }
    if (argc > 1) {
        (void)napi_get_value_int64(env, args[1], &generationValue);
    }
    const std::string id = argc > 2 ? GetNapiString(env, args[2]) : "";
    SshForwardingSessionAccess access;
    SshForwardingResult resultCode = ResolveSshForwardingSession(
        sessionId, generationValue > 0 ? static_cast<uint64_t>(generationValue) : 0,
        access);
    if (resultCode == SshForwardingResult::Ok) {
        resultCode = access.adapter->startForwarding(id, access.generation);
    }
    return CreateSshForwardingResultValue(env, resultCode);
}

napi_value NapiMarkSshForwardingListening(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    int64_t generationValue = 0;
    if (argc > 0) {
        (void)napi_get_value_int32(env, args[0], &sessionId);
    }
    if (argc > 1) {
        (void)napi_get_value_int64(env, args[1], &generationValue);
    }
    const std::string id = argc > 2 ? GetNapiString(env, args[2]) : "";
    SshForwardingSessionAccess access;
    SshForwardingResult resultCode = ResolveSshForwardingSession(
        sessionId, generationValue > 0 ? static_cast<uint64_t>(generationValue) : 0,
        access);
    if (resultCode == SshForwardingResult::Ok) {
        resultCode = access.adapter->markForwardingListening(id, access.generation);
    }
    return CreateSshForwardingResultValue(env, resultCode);
}

napi_value NapiFailSshForwarding(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    int64_t generationValue = 0;
    int32_t error = 0;
    if (argc > 0) {
        (void)napi_get_value_int32(env, args[0], &sessionId);
    }
    if (argc > 1) {
        (void)napi_get_value_int64(env, args[1], &generationValue);
    }
    const std::string id = argc > 2 ? GetNapiString(env, args[2]) : "";
    if (argc > 3) {
        (void)napi_get_value_int32(env, args[3], &error);
    }
    SshForwardingSessionAccess access;
    SshForwardingResult resultCode = ResolveSshForwardingSession(
        sessionId, generationValue > 0 ? static_cast<uint64_t>(generationValue) : 0,
        access);
    if (resultCode == SshForwardingResult::Ok) {
        resultCode = access.adapter->failForwarding(id, access.generation, error);
    }
    return CreateSshForwardingResultValue(env, resultCode);
}

napi_value NapiStopSshForwarding(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    int64_t generationValue = 0;
    if (argc > 0) {
        (void)napi_get_value_int32(env, args[0], &sessionId);
    }
    if (argc > 1) {
        (void)napi_get_value_int64(env, args[1], &generationValue);
    }
    const std::string id = argc > 2 ? GetNapiString(env, args[2]) : "";
    SshForwardingSessionAccess access;
    SshForwardingResult resultCode = ResolveSshForwardingSession(
        sessionId, generationValue > 0 ? static_cast<uint64_t>(generationValue) : 0,
        access);
    if (resultCode == SshForwardingResult::Ok) {
        resultCode = access.adapter->requestForwardingStop(id, access.generation);
    }
    return CreateSshForwardingResultValue(env, resultCode);
}

napi_value NapiCompleteSshForwardingStop(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    int64_t generationValue = 0;
    if (argc > 0) {
        (void)napi_get_value_int32(env, args[0], &sessionId);
    }
    if (argc > 1) {
        (void)napi_get_value_int64(env, args[1], &generationValue);
    }
    const std::string id = argc > 2 ? GetNapiString(env, args[2]) : "";
    SshForwardingSessionAccess access;
    SshForwardingResult resultCode = ResolveSshForwardingSession(
        sessionId, generationValue > 0 ? static_cast<uint64_t>(generationValue) : 0,
        access);
    if (resultCode == SshForwardingResult::Ok) {
        resultCode = access.adapter->completeForwardingStop(id, access.generation);
    }
    return CreateSshForwardingResultValue(env, resultCode);
}

napi_value NapiAcquireSshForwardingConnection(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    int64_t generationValue = 0;
    if (argc > 0) {
        (void)napi_get_value_int32(env, args[0], &sessionId);
    }
    if (argc > 1) {
        (void)napi_get_value_int64(env, args[1], &generationValue);
    }
    const std::string id = argc > 2 ? GetNapiString(env, args[2]) : "";
    SshForwardingSessionAccess access;
    SshForwardingResult resultCode = ResolveSshForwardingSession(
        sessionId, generationValue > 0 ? static_cast<uint64_t>(generationValue) : 0,
        access);
    if (resultCode == SshForwardingResult::Ok) {
        resultCode = access.adapter->acquireForwardingConnection(id, access.generation);
    }
    return CreateSshForwardingResultValue(env, resultCode);
}

napi_value NapiReleaseSshForwardingConnection(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    int64_t generationValue = 0;
    if (argc > 0) {
        (void)napi_get_value_int32(env, args[0], &sessionId);
    }
    if (argc > 1) {
        (void)napi_get_value_int64(env, args[1], &generationValue);
    }
    const std::string id = argc > 2 ? GetNapiString(env, args[2]) : "";
    SshForwardingSessionAccess access;
    SshForwardingResult resultCode = ResolveSshForwardingSession(
        sessionId, generationValue > 0 ? static_cast<uint64_t>(generationValue) : 0,
        access);
    if (resultCode == SshForwardingResult::Ok) {
        resultCode = access.adapter->releaseForwardingConnection(id, access.generation);
    }
    return CreateSshForwardingResultValue(env, resultCode);
}

napi_value NapiGetSshForwardingSnapshots(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    int64_t generationValue = 0;
    if (argc > 0) {
        (void)napi_get_value_int32(env, args[0], &sessionId);
    }
    if (argc > 1) {
        (void)napi_get_value_int64(env, args[1], &generationValue);
    }
    SshForwardingSessionAccess access;
    SshForwardingResult resultCode = ResolveSshForwardingSession(
        sessionId, generationValue > 0 ? static_cast<uint64_t>(generationValue) : 0,
        access);
    std::vector<SshForwardingSnapshot> snapshots;
    const uint64_t generation = resultCode == SshForwardingResult::Ok
        ? access.generation : 0;
    if (resultCode == SshForwardingResult::Ok) {
        snapshots = access.adapter->forwardingSnapshots();
    }
    return CreateSshForwardingSnapshotsValue(
        env, sessionId, resultCode, generation, snapshots);
}

/**
 * Native network observer ingress for RustDesk continuity.  This only feeds
 * the native continuity owner; it never starts a second ArkTS reconnect loop.
 * sessionGeneration is the SessionContext generation captured by the single
 * production observer. Numeric session ids alone are intentionally rejected.
 * networkGeneration is supplied by the platform observer so duplicate
 * availability notifications can be coalesced by the owner.
 */
napi_value NapiOnRustDeskNetworkChanged(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    bool accepted = false;
    int32_t sessionId = 0;
    int64_t sessionGeneration = 0;
    bool available = false;
    int64_t networkGeneration = 0;
    if (argc >= 4 &&
        napi_get_value_int32(env, args[0], &sessionId) == napi_ok &&
        napi_get_value_int64(env, args[1], &sessionGeneration) == napi_ok &&
        napi_get_value_bool(env, args[2], &available) == napi_ok &&
        napi_get_value_int64(env, args[3], &networkGeneration) == napi_ok &&
        sessionId > 0 && sessionGeneration > 0 && networkGeneration > 0) {
        accepted = DispatchRustDeskNetworkEvent(
            sessionId, static_cast<uint64_t>(sessionGeneration), available,
            static_cast<uint64_t>(networkGeneration));
    }
    napi_value result;
    napi_get_boolean(env, accepted, &result);
    return result;
}

/**
 * NAPI: submitRustDesk2FA(sessionId: number, code: string): boolean
 * Submit only a transient Peer TOTP code; the secret never crosses this API.
 */
napi_value NapiSubmitRustDesk2FA(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    if (argc < 2 || napi_get_value_int32(env, args[0], &sessionId) != napi_ok) {
        napi_value result;
        napi_get_boolean(env, false, &result);
        return result;
    }
    std::string code = GetNapiString(env, args[1]);
    bool accepted = false;
    auto it = g_sessionRegistry.find(sessionId);
    const std::shared_ptr<SessionContext> session =
        it == g_sessionRegistry.end() ? nullptr : it->second;
    if (session) {
        const std::shared_ptr<RustDeskBridge> rustdesk = GetRustDeskAdapter(session);
        if (rustdesk) {
            accepted = rustdesk->submitTwoFactorCode(code);
        }
    }
    secureClearString(code);
    napi_value result;
    napi_get_boolean(env, accepted, &result);
    return result;
}

static void FinalizeRemoteCursorPixels(napi_env /*env*/, void* /*data*/, void* hint) {
    delete static_cast<std::vector<uint8_t>*>(hint);
}

/**
 * Build the JS cursor object in one place. Async shape reads can transfer the
 * worker-owned RGBA vector as an external ArrayBuffer, so the JS completion
 * callback does not copy a 384x384 bitmap on the UI thread.
 */
static napi_value CreateRemoteCursorSnapshotValue(
    napi_env env, const RemoteCursorSnapshot& snapshot,
    std::vector<uint8_t>* transferredPixels = nullptr) {
    napi_value result;
    napi_create_object(env, &result);
    const auto setInt32 = [env, result](const char* name, int32_t value) {
        napi_value field;
        napi_create_int32(env, value, &field);
        napi_set_named_property(env, result, name, field);
    };
    const auto setUint64 = [env, result](const char* name, uint64_t value) {
        napi_value field;
        napi_create_double(env, static_cast<double>(value), &field);
        napi_set_named_property(env, result, name, field);
    };
    const auto setUint64String = [env, result](const char* name, uint64_t value) {
        const std::string text = std::to_string(value);
        napi_value field;
        napi_create_string_utf8(env, text.c_str(), text.size(), &field);
        napi_set_named_property(env, result, name, field);
    };
    setUint64("sessionId", snapshot.sessionId);
    setUint64("generation", snapshot.generation);
    // Cursor ids are protocol u64 values.  They are opaque to ArkTS and must
    // not pass through a JS Number, whose integer precision stops at 2^53.
    setUint64String("shapeId", snapshot.shapeId);
    setUint64("shapeRevision", snapshot.shapeRevision);
    setUint64("positionRevision", snapshot.positionRevision);
    setUint64("visibilityRevision", snapshot.visibilityRevision);
    setInt32("x", snapshot.x);
    setInt32("y", snapshot.y);
    setInt32("width", snapshot.width);
    setInt32("height", snapshot.height);
    setInt32("hotX", snapshot.hotX);
    setInt32("hotY", snapshot.hotY);
    napi_value fallbackShape;
    napi_get_boolean(env, snapshot.fallbackShape, &fallbackShape);
    napi_set_named_property(env, result, "fallbackShape", fallbackShape);
    napi_value positionAvailable;
    napi_get_boolean(env, snapshot.positionAvailable, &positionAvailable);
    napi_set_named_property(env, result, "positionAvailable", positionAvailable);
    napi_value visible;
    napi_get_boolean(env, snapshot.visible, &visible);
    napi_set_named_property(env, result, "visible", visible);
    napi_value protocol;
    napi_create_string_utf8(env, snapshot.protocol.c_str(), snapshot.protocol.size(), &protocol);
    napi_set_named_property(env, result, "protocol", protocol);
    napi_value shapeSource;
    napi_create_string_utf8(env, snapshot.shapeSource.c_str(), snapshot.shapeSource.size(),
                            &shapeSource);
    napi_set_named_property(env, result, "shapeSource", shapeSource);
    napi_value protocolShapeAvailable;
    napi_get_boolean(env, snapshot.protocolShapeAvailable, &protocolShapeAvailable);
    napi_set_named_property(env, result, "protocolShapeAvailable", protocolShapeAvailable);
    napi_value legacyVncCursorBootstrap;
    napi_get_boolean(env, snapshot.legacyVncCursorBootstrap, &legacyVncCursorBootstrap);
    napi_set_named_property(env, result, "legacyVncCursorBootstrap", legacyVncCursorBootstrap);

    napi_value pixels = nullptr;
    if (transferredPixels != nullptr && !transferredPixels->empty()) {
        if (napi_create_external_arraybuffer(env, transferredPixels->data(),
                transferredPixels->size(), FinalizeRemoteCursorPixels, transferredPixels,
                &pixels) != napi_ok) {
            // Fall back to a normal ArrayBuffer if the platform rejects an
            // external buffer. The worker still removed the native snapshot
            // copy from the UI path; this is only a compatibility fallback.
            void* pixelsData = nullptr;
            napi_create_arraybuffer(env, transferredPixels->size(), &pixelsData, &pixels);
            if (pixelsData) {
                std::memcpy(pixelsData, transferredPixels->data(), transferredPixels->size());
            }
            delete transferredPixels;
        }
    } else {
        const std::vector<uint8_t>* source = transferredPixels != nullptr
            ? transferredPixels : &snapshot.rgba;
        void* pixelsData = nullptr;
        napi_create_arraybuffer(env, source->size(), &pixelsData, &pixels);
        if (pixels != nullptr && napi_get_arraybuffer_info(env, pixels, &pixelsData, nullptr) == napi_ok &&
            pixelsData && !source->empty()) {
            std::memcpy(pixelsData, source->data(), source->size());
        }
        if (transferredPixels != nullptr) {
            delete transferredPixels;
        }
    }
    napi_set_named_property(env, result, "rgba", pixels);
    return result;
}

/**
 * NAPI: getRemoteCursorSnapshot(sessionId: number, includePixels?: boolean): object
 * Positions and shapes use independent revisions so ArkUI can poll without copying pixels.
 */
napi_value NapiGetRemoteCursorSnapshot(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    bool includePixels = false;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &sessionId);
    }
    if (argc > 1) {
        napi_get_value_bool(env, args[1], &includePixels);
    }

    RemoteCursorSnapshot snapshot;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter) {
        snapshot = it->second->adapter->getRemoteCursorSnapshot(includePixels);
    }

    return CreateRemoteCursorSnapshotValue(env, snapshot);
}

struct RemoteCursorSnapshotAsyncData {
    int32_t sessionId = 0;
    std::shared_ptr<ProtocolAdapter> adapter;
    RemoteCursorSnapshot snapshot;
    std::string errorMessage;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
    bool workerFailed = false;
};

static void ExecuteRemoteCursorSnapshotAsync(napi_env /*env*/, void* rawData) {
    auto* data = static_cast<RemoteCursorSnapshotAsyncData*>(rawData);
    if (data == nullptr || !data->adapter) {
        if (data != nullptr) {
            data->workerFailed = true;
            data->errorMessage = "remote cursor session is unavailable";
        }
        return;
    }

    try {
        // The cursor store owns its mutex and returns a self-contained copy.
        // This is deliberately executed on the N-API worker thread, never in
        // the 33 ms ArkTS cursor timer.
        data->snapshot = data->adapter->getRemoteCursorSnapshot(true);
    } catch (const std::exception& ex) {
        data->workerFailed = true;
        data->errorMessage = std::string("remote cursor snapshot failed: ") + ex.what();
    } catch (...) {
        data->workerFailed = true;
        data->errorMessage = "remote cursor snapshot failed: unknown native exception";
    }
}

static void CompleteRemoteCursorSnapshotAsync(napi_env env, napi_status status, void* rawData) {
    auto* data = static_cast<RemoteCursorSnapshotAsyncData*>(rawData);
    if (data == nullptr) {
        return;
    }

    if (status != napi_ok || data->workerFailed) {
        napi_value error;
        const std::string message = data->errorMessage.empty()
            ? "remote cursor snapshot async work failed" : data->errorMessage;
        napi_create_string_utf8(env, message.c_str(), NAPI_AUTO_LENGTH, &error);
        napi_reject_deferred(env, data->deferred, error);
    } else {
        std::vector<uint8_t>* transferredPixels = nullptr;
        if (!data->snapshot.rgba.empty()) {
            transferredPixels = new (std::nothrow) std::vector<uint8_t>(
                std::move(data->snapshot.rgba));
            if (transferredPixels == nullptr) {
                napi_value error;
                napi_create_string_utf8(env, "remote cursor pixel buffer allocation failed",
                    NAPI_AUTO_LENGTH, &error);
                napi_reject_deferred(env, data->deferred, error);
                napi_delete_async_work(env, data->work);
                delete data;
                return;
            }
        }
        napi_value result = CreateRemoteCursorSnapshotValue(env, data->snapshot,
            transferredPixels);
        napi_resolve_deferred(env, data->deferred, result);
    }

    napi_delete_async_work(env, data->work);
    delete data;
}

/**
 * NAPI: getRemoteCursorSnapshotPixelsAsync(sessionId: number): Promise<object>
 * Only the shape bitmap crosses the worker boundary. Metadata remains on the
 * cheap synchronous snapshot path used by cursor motion polling.
 */
napi_value NapiGetRemoteCursorSnapshotPixelsAsync(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    auto* data = new (std::nothrow) RemoteCursorSnapshotAsyncData();
    if (data == nullptr) {
        napi_throw_error(env, nullptr, "remote cursor async allocation failed");
        return nullptr;
    }
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &data->sessionId);
    }
    auto it = g_sessionRegistry.find(data->sessionId);
    if (it != g_sessionRegistry.end() && it->second) {
        data->adapter = it->second->adapter;
    }

    napi_value promise;
    napi_status status = napi_create_promise(env, &data->deferred, &promise);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "remote cursor async promise creation failed");
        return nullptr;
    }

    napi_value resourceName;
    status = napi_create_string_utf8(env, "RemoteCursorSnapshotPixelsAsync", NAPI_AUTO_LENGTH,
        &resourceName);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "remote cursor async resource creation failed");
        return nullptr;
    }
    status = napi_create_async_work(env, resourceName, resourceName,
        ExecuteRemoteCursorSnapshotAsync, CompleteRemoteCursorSnapshotAsync, data, &data->work);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "remote cursor async work creation failed");
        return nullptr;
    }
    status = napi_queue_async_work(env, data->work);
    if (status != napi_ok) {
        napi_delete_async_work(env, data->work);
        delete data;
        napi_throw_error(env, nullptr, "remote cursor async work queue failed");
        return nullptr;
    }
    return promise;
}

/**
 * NAPI: getConnectionLastMessage(sessionId: number): string
 * 返回协议适配器最近一次连接状态消息。
 */
napi_value NapiGetConnectionLastMessage(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId;
    napi_get_value_int32(env, args[0], &sessionId);

    std::string message;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end()) {
        std::lock_guard<std::mutex> lock(it->second->messageMutex);
        message = it->second->lastStateMessage;
    }

    napi_value result;
    napi_create_string_utf8(env, message.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

/**
 * NAPI: getRustDeskLastError(): string
 * 返回 RustDesk FFI 最近一次连接/流错误，供 ArkTS 显示真实握手失败原因。
 */
napi_value NapiGetRustDeskLastError(napi_env env, napi_callback_info /*info*/) {
    char buf[2048] = {0};
#ifdef RUSTDESK_USE_REAL_CORE
    rustdesk_last_error(buf, sizeof(buf));
#endif
    napi_value result;
    napi_create_string_utf8(env, buf, NAPI_AUTO_LENGTH, &result);
    return result;
}

/**
 * NAPI: readData(sessionId: number): string
 *
 * 从 SSH 会话读取终端输出数据 (加密通道).
 * 返回接收到的数据字符串, 无数据时返回空字符串 "".
 */
napi_value NapiReadData(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId;
    if (napi_get_value_int32(env, args[0], &sessionId) != napi_ok) {
        napi_value empty;
        napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &empty);
        return empty;
    }

    auto it = g_sessionRegistry.find(sessionId);
    if (it == g_sessionRegistry.end() || !it->second->adapter) {
        napi_value empty;
        napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &empty);
        return empty;
    }

    // 仅 SSH 适配器支持 readData
    auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(it->second->adapter);
    if (!sshAdapter) {
        napi_value empty;
        napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &empty);
        return empty;
    }

    // 使用堆分配避免 64KB 栈溢出 (低内存 OHOS 设备风险)
    const size_t bufferSize = SSH_BUFFER_SIZE;
    std::vector<uint8_t> buf(bufferSize);
    int n = sshAdapter->readData(buf.data(), bufferSize - 1);
    if (n <= 0) {
        napi_value empty;
        napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &empty);
        return empty;
    }
    buf[n] = '\0';

    napi_value result;
    napi_create_string_utf8(env, reinterpret_cast<const char*>(buf.data()), n, &result);
    return result;
}

/**
 * NAPI: getSshTerminalDiagnostics(sessionId: number): object
 *
 * Exposes counters/timestamps for the SSH PTY pipeline only.  The snapshot
 * deliberately contains no terminal bytes, command text, credentials, or
 * rendered output.
 */
napi_value NapiGetSshTerminalDiagnostics(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    if (argc > 0) {
        napi_get_value_int32(env, args[0], &sessionId);
    }

    SshTerminalDiagnosticsSnapshot snapshot;
    snapshot.sessionId = static_cast<uint64_t>(sessionId);
    bool supported = false;
    bool sessionActive = false;
    const auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second && it->second->adapter) {
        auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(it->second->adapter);
        if (sshAdapter) {
            snapshot = sshAdapter->terminalDiagnostics();
            supported = true;
            sessionActive = it->second->lifecycle.load(std::memory_order_acquire) ==
                SessionContext::Lifecycle::Active;
        }
    }

    napi_value result;
    napi_create_object(env, &result);
    SetObjectBool(env, result, "supported", supported);
    SetObjectBool(env, result, "sessionActive", sessionActive);
    SetObjectInt64(env, result, "schemaVersion", static_cast<int64_t>(snapshot.schemaVersion));
    SetObjectInt64(env, result, "sessionId", static_cast<int64_t>(snapshot.sessionId));
    SetObjectInt64(env, result, "sessionGeneration",
                   static_cast<int64_t>(snapshot.sessionGeneration));
    SetObjectString(env, result, "channelId", snapshot.channelId);
    SetObjectInt64(env, result, "inputEvents", static_cast<int64_t>(snapshot.inputEvents));
    SetObjectInt64(env, result, "inputBytes", static_cast<int64_t>(snapshot.inputBytes));
    SetObjectInt64(env, result, "nativeEnqueueEvents",
                   static_cast<int64_t>(snapshot.nativeEnqueueEvents));
    SetObjectInt64(env, result, "writeAttempts", static_cast<int64_t>(snapshot.writeAttempts));
    SetObjectInt64(env, result, "writeCompleteEvents",
                   static_cast<int64_t>(snapshot.writeCompleteEvents));
    SetObjectInt64(env, result, "writeBytes", static_cast<int64_t>(snapshot.writeBytes));
    SetObjectInt64(env, result, "writeEagain", static_cast<int64_t>(snapshot.writeEagain));
    SetObjectInt64(env, result, "remoteReadEvents",
                   static_cast<int64_t>(snapshot.remoteReadEvents));
    SetObjectInt64(env, result, "remoteReadBytes",
                   static_cast<int64_t>(snapshot.remoteReadBytes));
    SetObjectInt64(env, result, "callbackAcceptedEvents",
                   static_cast<int64_t>(snapshot.callbackAcceptedEvents));
    SetObjectInt64(env, result, "callbackAcceptedBytes",
                   static_cast<int64_t>(snapshot.callbackAcceptedBytes));
    SetObjectInt64(env, result, "callbackQueueFull",
                   static_cast<int64_t>(snapshot.callbackQueueFull));
    SetObjectInt64(env, result, "callbackDeliveryErrors",
                   static_cast<int64_t>(snapshot.callbackDeliveryErrors));
    SetObjectInt64(env, result, "callbackClosed",
                   static_cast<int64_t>(snapshot.callbackClosed));
    SetObjectInt64(env, result, "inputDuplicate",
                   static_cast<int64_t>(snapshot.inputDuplicate));
    SetObjectInt64(env, result, "inputLoss", static_cast<int64_t>(snapshot.inputLoss));
    SetObjectInt64(env, result, "inputReorder", static_cast<int64_t>(snapshot.inputReorder));
    SetObjectInt64(env, result, "ownerStallEvents",
                   static_cast<int64_t>(snapshot.ownerStallEvents));
    SetObjectInt64(env, result, "coverageMask",
                   static_cast<int64_t>(snapshot.coverageMask));
    SetObjectBool(env, result, "coverageComplete", snapshot.coverageComplete);
    SetObjectInt64(env, result, "inputQueueDepth",
                   static_cast<int64_t>(snapshot.inputQueueDepth));
    SetObjectInt64(env, result, "inputQueueBytes",
                   static_cast<int64_t>(snapshot.inputQueueBytes));
    SetObjectInt64(env, result, "inputQueueMaxDepth",
                   static_cast<int64_t>(snapshot.inputQueueMaxDepth));
    SetObjectInt64(env, result, "inputQueueMaxBytes",
                   static_cast<int64_t>(snapshot.inputQueueMaxBytes));
    SetObjectInt64(env, result, "lastInputSequence",
                   static_cast<int64_t>(snapshot.lastInputSequence));
    SetObjectInt64(env, result, "lastInputCapturedAtNs",
                   static_cast<int64_t>(snapshot.lastInputCapturedAtNs));
    SetObjectInt64(env, result, "lastNativeEnqueueAtNs",
                   static_cast<int64_t>(snapshot.lastNativeEnqueueAtNs));
    SetObjectInt64(env, result, "lastWriteAttemptAtNs",
                   static_cast<int64_t>(snapshot.lastWriteAttemptAtNs));
    SetObjectInt64(env, result, "lastWriteCompleteAtNs",
                   static_cast<int64_t>(snapshot.lastWriteCompleteAtNs));
    SetObjectInt64(env, result, "lastRemoteReadAtNs",
                   static_cast<int64_t>(snapshot.lastRemoteReadAtNs));
    SetObjectInt64(env, result, "maxInputToWriteAttemptNs",
                   static_cast<int64_t>(snapshot.maxInputToWriteAttemptNs));
    SetObjectInt64(env, result, "maxInputToWriteCompleteNs",
                   static_cast<int64_t>(snapshot.maxInputToWriteCompleteNs));
    return result;
}

/**
 * NAPI: execSshCommand(sessionId: number, command: string, timeoutMs?: number): object
 *
 * 在独立 channel 执行命令，返回原始 stdout/stderr、退出码和错误码。
 */
napi_value NapiExecSshCommand(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    if (argc < 2 || napi_get_value_int32(env, args[0], &sessionId) != napi_ok) {
        napi_throw_type_error(env, nullptr, "sessionId and command are required");
        return nullptr;
    }
    const std::string command = GetNapiString(env, args[1]);
    int32_t timeoutMs = 30000;
    if (argc > 2) { napi_get_value_int32(env, args[2], &timeoutMs); }

    SshCommandResult commandResult;
    int errorCode = ERR_SSH_SESSION_CLOSED;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second && it->second->adapter) {
        auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(it->second->adapter);
        if (sshAdapter) {
            errorCode = sshAdapter->executeCommand(command, commandResult, timeoutMs);
        } else {
            errorCode = ERR_SSH_SUBSYSTEM_FAILED;
        }
    }

    napi_value result;
    napi_create_object(env, &result);
    napi_value field;
    napi_create_int32(env, errorCode, &field);
    napi_set_named_property(env, result, "errorCode", field);
    napi_create_int32(env, commandResult.exitCode, &field);
    napi_set_named_property(env, result, "exitCode", field);
    napi_get_boolean(env, commandResult.signaled, &field);
    napi_set_named_property(env, result, "signaled", field);
    napi_create_string_utf8(env, commandResult.signal.c_str(),
                            commandResult.signal.size(), &field);
    napi_set_named_property(env, result, "signal", field);

    void* stdoutData = nullptr;
    napi_value stdoutBuffer;
    napi_create_arraybuffer(env, commandResult.stdoutBytes.size(), &stdoutData, &stdoutBuffer);
    if (stdoutData != nullptr && !commandResult.stdoutBytes.empty()) {
        std::memcpy(stdoutData, commandResult.stdoutBytes.data(),
                    commandResult.stdoutBytes.size());
    }
    napi_set_named_property(env, result, "stdout", stdoutBuffer);

    void* stderrData = nullptr;
    napi_value stderrBuffer;
    napi_create_arraybuffer(env, commandResult.stderrBytes.size(), &stderrData, &stderrBuffer);
    if (stderrData != nullptr && !commandResult.stderrBytes.empty()) {
        std::memcpy(stderrData, commandResult.stderrBytes.data(),
                    commandResult.stderrBytes.size());
    }
    napi_set_named_property(env, result, "stderr", stderrBuffer);
    return result;
}

/** NAPI: execSshSubsystem(sessionId: number, subsystem: string, timeoutMs?: number): object */
napi_value NapiExecSshSubsystem(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    if (argc < 2 || napi_get_value_int32(env, args[0], &sessionId) != napi_ok) {
        napi_throw_type_error(env, nullptr, "sessionId and subsystem are required");
        return nullptr;
    }
    const std::string subsystem = GetNapiString(env, args[1]);
    int32_t timeoutMs = 30000;
    if (argc > 2) { napi_get_value_int32(env, args[2], &timeoutMs); }

    SshCommandResult commandResult;
    int errorCode = ERR_SSH_SESSION_CLOSED;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second && it->second->adapter) {
        auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(it->second->adapter);
        if (sshAdapter) {
            errorCode = sshAdapter->executeSubsystem(subsystem, commandResult, timeoutMs);
        } else {
            errorCode = ERR_SSH_SUBSYSTEM_FAILED;
        }
    }

    napi_value result;
    napi_create_object(env, &result);
    napi_value field;
    napi_create_int32(env, errorCode, &field);
    napi_set_named_property(env, result, "errorCode", field);
    napi_create_int32(env, commandResult.exitCode, &field);
    napi_set_named_property(env, result, "exitCode", field);
    napi_get_boolean(env, commandResult.signaled, &field);
    napi_set_named_property(env, result, "signaled", field);
    napi_create_string_utf8(env, commandResult.signal.c_str(),
                            commandResult.signal.size(), &field);
    napi_set_named_property(env, result, "signal", field);

    void* stdoutData = nullptr;
    napi_value stdoutBuffer;
    napi_create_arraybuffer(env, commandResult.stdoutBytes.size(), &stdoutData, &stdoutBuffer);
    if (stdoutData != nullptr && !commandResult.stdoutBytes.empty()) {
        std::memcpy(stdoutData, commandResult.stdoutBytes.data(),
                    commandResult.stdoutBytes.size());
    }
    napi_set_named_property(env, result, "stdout", stdoutBuffer);

    void* stderrData = nullptr;
    napi_value stderrBuffer;
    napi_create_arraybuffer(env, commandResult.stderrBytes.size(), &stderrData, &stderrBuffer);
    if (stderrData != nullptr && !commandResult.stderrBytes.empty()) {
        std::memcpy(stderrData, commandResult.stderrBytes.data(),
                    commandResult.stderrBytes.size());
    }
    napi_set_named_property(env, result, "stderr", stderrBuffer);
    return result;
}

static napi_value CreateSshCommandResultValue(napi_env env, int errorCode,
                                               const SshCommandResult& commandResult) {
    napi_value result;
    napi_create_object(env, &result);
    napi_value field;
    napi_create_int32(env, errorCode, &field);
    napi_set_named_property(env, result, "errorCode", field);
    napi_create_int32(env, commandResult.exitCode, &field);
    napi_set_named_property(env, result, "exitCode", field);
    napi_get_boolean(env, commandResult.signaled, &field);
    napi_set_named_property(env, result, "signaled", field);
    napi_create_string_utf8(env, commandResult.signal.c_str(),
                            commandResult.signal.size(), &field);
    napi_set_named_property(env, result, "signal", field);

    void* stdoutData = nullptr;
    napi_value stdoutBuffer;
    napi_create_arraybuffer(env, commandResult.stdoutBytes.size(), &stdoutData, &stdoutBuffer);
    if (stdoutData != nullptr && !commandResult.stdoutBytes.empty()) {
        std::memcpy(stdoutData, commandResult.stdoutBytes.data(),
                    commandResult.stdoutBytes.size());
    }
    napi_set_named_property(env, result, "stdout", stdoutBuffer);

    void* stderrData = nullptr;
    napi_value stderrBuffer;
    napi_create_arraybuffer(env, commandResult.stderrBytes.size(), &stderrData, &stderrBuffer);
    if (stderrData != nullptr && !commandResult.stderrBytes.empty()) {
        std::memcpy(stderrData, commandResult.stderrBytes.data(),
                    commandResult.stderrBytes.size());
    }
    napi_set_named_property(env, result, "stderr", stderrBuffer);
    return result;
}

struct SshCommandAsyncData {
    std::shared_ptr<SshAdapter> adapter;
    std::string request;
    int timeoutMs = 30000;
    bool subsystem = false;
    int errorCode = ERR_SSH_SESSION_CLOSED;
    SshCommandResult result;
    bool workerFailed = false;
    std::string errorMessage;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

static void ExecuteSshCommandAsync(napi_env /*env*/, void* rawData) {
    auto* data = static_cast<SshCommandAsyncData*>(rawData);
    if (data == nullptr || !data->adapter) {
        return;
    }
    try {
        data->errorCode = data->subsystem
            ? data->adapter->executeSubsystem(data->request, data->result, data->timeoutMs)
            : data->adapter->executeCommand(data->request, data->result, data->timeoutMs);
    } catch (const std::exception& ex) {
        data->workerFailed = true;
        data->errorMessage = std::string("SSH channel async work failed: ") + ex.what();
    } catch (...) {
        data->workerFailed = true;
        data->errorMessage = "SSH channel async work failed: unknown native exception";
    }
}

static void CompleteSshCommandAsync(napi_env env, napi_status status, void* rawData) {
    auto* data = static_cast<SshCommandAsyncData*>(rawData);
    if (data == nullptr) {
        return;
    }
    if (status != napi_ok || data->workerFailed) {
        napi_value error;
        const std::string message = data->errorMessage.empty()
            ? "SSH channel async work failed" : data->errorMessage;
        napi_create_string_utf8(env, message.c_str(), NAPI_AUTO_LENGTH, &error);
        napi_reject_deferred(env, data->deferred, error);
    } else {
        napi_value result = CreateSshCommandResultValue(env, data->errorCode, data->result);
        napi_resolve_deferred(env, data->deferred, result);
    }
    napi_delete_async_work(env, data->work);
    delete data;
}

static napi_value QueueSshCommandAsync(napi_env env, SshCommandAsyncData* data,
                                       const char* resourceName) {
    if (data == nullptr) {
        napi_throw_error(env, nullptr, "SSH channel async allocation failed");
        return nullptr;
    }
    napi_value promise;
    napi_status status = napi_create_promise(env, &data->deferred, &promise);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "SSH channel async promise creation failed");
        return nullptr;
    }
    napi_value resource;
    status = napi_create_string_utf8(env, resourceName, NAPI_AUTO_LENGTH, &resource);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "SSH channel async resource creation failed");
        return nullptr;
    }
    status = napi_create_async_work(env, resource, resource,
        ExecuteSshCommandAsync, CompleteSshCommandAsync, data, &data->work);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "SSH channel async work creation failed");
        return nullptr;
    }
    status = napi_queue_async_work(env, data->work);
    if (status != napi_ok) {
        napi_delete_async_work(env, data->work);
        delete data;
        napi_throw_error(env, nullptr, "SSH channel async work queue failed");
        return nullptr;
    }
    return promise;
}

static napi_value QueueSshChannelAsync(napi_env env, napi_callback_info info,
                                       bool subsystem, const char* resourceName) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_type_error(env, nullptr,
            subsystem ? "sessionId and subsystem are required" : "sessionId and command are required");
        return nullptr;
    }

    int32_t sessionId = 0;
    if (napi_get_value_int32(env, args[0], &sessionId) != napi_ok) {
        napi_throw_type_error(env, nullptr, "sessionId must be an integer");
        return nullptr;
    }
    auto* data = new (std::nothrow) SshCommandAsyncData();
    if (data == nullptr) {
        napi_throw_error(env, nullptr, "SSH channel async allocation failed");
        return nullptr;
    }
    data->request = GetNapiString(env, args[1]);
    if (argc > 2 && napi_get_value_int32(env, args[2], &data->timeoutMs) != napi_ok) {
        delete data;
        napi_throw_type_error(env, nullptr, "timeoutMs must be an integer");
        return nullptr;
    }
    data->subsystem = subsystem;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second && it->second->adapter) {
        data->adapter = std::dynamic_pointer_cast<SshAdapter>(it->second->adapter);
    }
    return QueueSshCommandAsync(env, data, resourceName);
}

/** NAPI: execSshCommandAsync(sessionId: number, command: string, timeoutMs?: number) */
napi_value NapiExecSshCommandAsync(napi_env env, napi_callback_info info) {
    return QueueSshChannelAsync(env, info, false, "SshExecCommandAsync");
}

/** NAPI: execSshSubsystemAsync(sessionId: number, subsystem: string, timeoutMs?: number) */
napi_value NapiExecSshSubsystemAsync(napi_env env, napi_callback_info info) {
    return QueueSshChannelAsync(env, info, true, "SshExecSubsystemAsync");
}

/** NAPI: sendSshSignal(sessionId: number, signal: string): number */
napi_value NapiSendSshSignal(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    if (argc < 2) {
        napi_value result;
        napi_create_int32(env, ERR_SSH_SESSION_CLOSED, &result);
        return result;
    }
    napi_get_value_int32(env, args[0], &sessionId);
    const std::string signal = GetNapiString(env, args[1]);
    int errorCode = ERR_SSH_SESSION_CLOSED;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second && it->second->adapter) {
        auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(it->second->adapter);
        if (sshAdapter) { errorCode = sshAdapter->sendChannelSignal(signal); }
    }
    napi_value result;
    napi_create_int32(env, errorCode, &result);
    return result;
}

/** NAPI: sendSshEof(sessionId: number): number */
napi_value NapiSendSshEof(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    if (argc > 0) { napi_get_value_int32(env, args[0], &sessionId); }
    int errorCode = ERR_SSH_SESSION_CLOSED;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second && it->second->adapter) {
        auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(it->second->adapter);
        if (sshAdapter) { errorCode = sshAdapter->sendChannelEof(); }
    }
    napi_value result;
    napi_create_int32(env, errorCode, &result);
    return result;
}

/**
 * NAPI: resizePty(sessionId: number, cols: number, rows: number): void
 *
 * 调整 SSH PTY 终端窗口大小 (触发远程 SIGWINCH).
 */
napi_value NapiResizePty(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId, cols, rows;
    napi_get_value_int32(env, args[0], &sessionId);
    napi_get_value_int32(env, args[1], &cols);
    napi_get_value_int32(env, args[2], &rows);

    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter) {
        auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(it->second->adapter);
        if (sshAdapter) {
            sshAdapter->resizePty(cols, rows);
        }
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * NAPI: measureSshLatency(sessionId: number): number
 *
 * 使用 SSH keepalive 做协议级往返检测, 不向终端写入字符.
 * 返回毫秒数; 负数表示失败.
 */
napi_value NapiMeasureSshLatency(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId;
    if (napi_get_value_int32(env, args[0], &sessionId) != napi_ok) {
        napi_value result;
        napi_create_int32(env, -1, &result);
        return result;
    }

    int latency = -1;
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second->adapter) {
        auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(it->second->adapter);
        if (sshAdapter) {
            latency = sshAdapter->measureLatencyMs();
        }
    }

    napi_value result;
    napi_create_int32(env, latency, &result);
    return result;
}

struct SshLatencyAsyncData {
    std::shared_ptr<SshAdapter> adapter;
    int latency = -1;
    bool workerFailed = false;
    std::string errorMessage;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;
};

static void ExecuteSshLatencyAsync(napi_env /*env*/, void* rawData) {
    auto* data = static_cast<SshLatencyAsyncData*>(rawData);
    if (data == nullptr || !data->adapter) {
        return;
    }
    try {
        data->latency = data->adapter->measureLatencyMs();
    } catch (const std::exception& ex) {
        data->workerFailed = true;
        data->errorMessage = std::string("SSH latency async work failed: ") + ex.what();
    } catch (...) {
        data->workerFailed = true;
        data->errorMessage = "SSH latency async work failed: unknown native exception";
    }
}

static void CompleteSshLatencyAsync(napi_env env, napi_status status, void* rawData) {
    auto* data = static_cast<SshLatencyAsyncData*>(rawData);
    if (data == nullptr) {
        return;
    }
    if (status != napi_ok || data->workerFailed) {
        napi_value error;
        const std::string message = data->errorMessage.empty()
            ? "SSH latency async work failed" : data->errorMessage;
        napi_create_string_utf8(env, message.c_str(), NAPI_AUTO_LENGTH, &error);
        napi_reject_deferred(env, data->deferred, error);
    } else {
        napi_value result;
        napi_create_int32(env, data->latency, &result);
        napi_resolve_deferred(env, data->deferred, result);
    }
    napi_delete_async_work(env, data->work);
    delete data;
}

/** NAPI: measureSshLatencyAsync(sessionId: number): Promise<number> */
napi_value NapiMeasureSshLatencyAsync(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId = 0;
    if (argc < 1 || napi_get_value_int32(env, args[0], &sessionId) != napi_ok) {
        napi_throw_type_error(env, nullptr, "sessionId is required");
        return nullptr;
    }

    auto* data = new (std::nothrow) SshLatencyAsyncData();
    if (data == nullptr) {
        napi_throw_error(env, nullptr, "SSH latency async allocation failed");
        return nullptr;
    }
    auto it = g_sessionRegistry.find(sessionId);
    if (it != g_sessionRegistry.end() && it->second && it->second->adapter) {
        data->adapter = std::dynamic_pointer_cast<SshAdapter>(it->second->adapter);
    }

    napi_value promise;
    napi_status status = napi_create_promise(env, &data->deferred, &promise);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "SSH latency async promise creation failed");
        return nullptr;
    }
    napi_value resource;
    status = napi_create_string_utf8(env, "SshMeasureLatencyAsync", NAPI_AUTO_LENGTH, &resource);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "SSH latency async resource creation failed");
        return nullptr;
    }
    status = napi_create_async_work(env, resource, resource,
        ExecuteSshLatencyAsync, CompleteSshLatencyAsync, data, &data->work);
    if (status != napi_ok) {
        delete data;
        napi_throw_error(env, nullptr, "SSH latency async work creation failed");
        return nullptr;
    }
    status = napi_queue_async_work(env, data->work);
    if (status != napi_ok) {
        napi_delete_async_work(env, data->work);
        delete data;
        napi_throw_error(env, nullptr, "SSH latency async work queue failed");
        return nullptr;
    }
    return promise;
}

// ============================================================
// 推送式 SSH 数据回调 (TSFN — ThreadSafeFunction)
// ============================================================

/**
 * TSFN 主线程回调: 把 SSH 原始字节转为 ArrayBuffer 调用 jsCb.
 *
 * SSH 输出不是文本协议，ANSI 控制序列和 UTF-8 字符都可能跨 chunk；
 * 这里保持字节不变，把解码责任交给终端核心。
 */
static void FinalizeSshDataTsfn(napi_env /*env*/, void* finalizeData,
                                void* /*finalizeHint*/) {
    delete static_cast<SshDataTsfnContext*>(finalizeData);
}

static void DataTsfnCallJs(napi_env env, napi_value jsCallback,
                            void* context, void* data) {
    auto* bytes = static_cast<std::vector<uint8_t>*>(data);
    auto* callbackContext = static_cast<SshDataTsfnContext*>(context);
    const std::shared_ptr<SshDataTsfnRegistration> registration =
        callbackContext == nullptr ? nullptr : callbackContext->registration;
    const bool accepting = registration != nullptr &&
        registration->accepting.load(std::memory_order_acquire);
    const bool redeliverOnStop = registration != nullptr &&
        registration->redeliverOnStop.load(std::memory_order_acquire);
    if (bytes != nullptr && registration != nullptr &&
        SshTerminalResumePolicy::shouldRedeliverCallback(
            accepting, redeliverOnStop)) {
        if (registration->adapter) {
            registration->adapter->redeliverTerminalOutputAfterDetach(*bytes);
        }
    } else if (env != nullptr && jsCallback != nullptr && bytes != nullptr) {
        void* rawData = nullptr;
        napi_value arrayBuffer = nullptr;
        napi_status s = napi_create_arraybuffer(env, bytes->size(), &rawData, &arrayBuffer);
        if (s == napi_ok && rawData != nullptr && !bytes->empty()) {
            std::memcpy(rawData, bytes->data(), bytes->size());
        }
        if (s == napi_ok) {
            napi_value undefined;
            napi_get_undefined(env, &undefined);
            napi_call_function(env, undefined, jsCallback, 1, &arrayBuffer, nullptr);
        }
    }
    if (bytes != nullptr) {
        if (!bytes->empty()) {
            volatile uint8_t* raw = bytes->data();
            for (size_t i = 0; i < bytes->size(); ++i) { raw[i] = 0; }
        }
        delete bytes;
    }
}

static void SshDataTsfnPump(
    const std::shared_ptr<SshDataTsfnRegistration>& registration) {
    while (true) {
        std::vector<uint8_t>* heapBytes = nullptr;
        {
            std::unique_lock<std::mutex> lock(registration->pendingMutex);
            registration->pendingCondition.wait(lock, [&registration]() {
                return !registration->accepting.load(std::memory_order_acquire) ||
                    !registration->pending.empty();
            });
            if (registration->pending.empty() &&
                !registration->accepting.load(std::memory_order_acquire)) {
                break;
            }
            if (registration->pending.empty()) {
                continue;
            }
            heapBytes = registration->pending.front();
            registration->pending.pop_front();
            registration->pendingBytes -= heapBytes->size();
        }

        bool delivered = false;
        bool closing = false;
        while (registration->accepting.load(std::memory_order_acquire)) {
            const napi_status status = napi_call_threadsafe_function(
                registration->tsfn, heapBytes, napi_tsfn_nonblocking);
            if (status == napi_ok) {
                delivered = true;
                if (registration->adapter) {
                    registration->adapter->recordTerminalCallbackAccepted(heapBytes->size());
                }
                break;
            }
            if (status != napi_queue_full) {
                closing = status == napi_closing;
                if (closing) {
                    registration->accepting.store(false, std::memory_order_release);
                    registration->pendingCondition.notify_all();
                    DetachSshDataRegistrationOnClose(registration);
                }
                if (registration->adapter) {
                    registration->adapter->recordTerminalCallbackDeliveryError(closing);
                }
                break;
            }
            if (registration->adapter) {
                registration->adapter->recordTerminalCallbackQueueFull();
            }
            // Only the pump waits for the JS queue; the SSH reader owner never
            // waits and can continue servicing terminal input and SFTP slices.
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }

        if (!delivered) {
            const bool accepting =
                registration->accepting.load(std::memory_order_acquire);
            const bool redeliverOnStop =
                registration->redeliverOnStop.load(std::memory_order_acquire);
            if (!closing && registration->adapter &&
                SshTerminalResumePolicy::shouldRedeliverCallback(
                    accepting, redeliverOnStop)) {
                registration->adapter->redeliverTerminalOutputAfterDetach(*heapBytes);
            } else if (!accepting && !closing) {
                if (registration->adapter) {
                    registration->adapter->recordTerminalCallbackDeliveryError(true);
                }
            }
            delete heapBytes;
        }
    }
}

static void StopSshDataRegistrationInstance(
    const std::shared_ptr<SshDataTsfnRegistration>& registration,
    bool redeliverOnStop) {
    if (!registration) {
        return;
    }
    registration->redeliverOnStop.store(redeliverOnStop,
                                        std::memory_order_release);
    registration->accepting.store(false, std::memory_order_release);
    registration->pendingCondition.notify_all();
    if (registration->pumpThread.joinable()) {
        registration->pumpThread.join();
    }
}

/**
 * NAPI: setOnDataCallback(sessionId: number, cb: (data: ArrayBuffer) => void | null): void
 *
 * 注册推送式 SSH 数据回调. 后台 reader 线程读到数据后立即触发.
 * 传 null 卸载.
 */
napi_value NapiSetOnDataCallback(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId;
    if (napi_get_value_int32(env, args[0], &sessionId) != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "[ExtLoader] setOnDataCallback: 无效 sessionId");
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    auto it = g_sessionRegistry.find(sessionId);
    if (it == g_sessionRegistry.end() || !it->second) {
        OH_LOG_WARN(LOG_APP, "[ExtLoader] setOnDataCallback: 会话不存在 id=%{public}d", sessionId);
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }
    const std::shared_ptr<SessionContext> session = it->second;
    std::shared_ptr<ProtocolAdapter> adapter;
    {
        std::lock_guard<std::mutex> adapterLock(session->adapterMutex);
        adapter = session->adapter;
    }
    if (!adapter) {
        OH_LOG_WARN(LOG_APP, "[ExtLoader] setOnDataCallback: 会话适配器不存在 id=%{public}d", sessionId);
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }
    std::unique_lock<std::mutex> callbackRegistrationLock(
        session->callbackRegistrationMutex);
    if (session->lifecycle.load(std::memory_order_acquire) !=
        SessionContext::Lifecycle::Active) {
        OH_LOG_INFO(LOG_APP,
            "[ExtLoader] setOnDataCallback: teardown 已开始, 拒绝注册 id=%{public}d",
            sessionId);
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }
    auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(adapter);
    if (!sshAdapter) {
        OH_LOG_WARN(LOG_APP, "[ExtLoader] setOnDataCallback: 非 SSH 会话 id=%{public}d", sessionId);
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    napi_valuetype cbType;
    napi_typeof(env, args[1], &cbType);

    // 先停止旧生产者，再释放旧 TSFN。否则 reader 线程可能在旧 handle
    // 已释放后继续提交数据，造成偶发崩溃。
    std::shared_ptr<SshDataTsfnRegistration> oldRegistration;
    {
        std::lock_guard<std::mutex> lk(g_dataTsfnMutex);
        auto tit = g_dataTsfnMap.find(sessionId);
        if (tit != g_dataTsfnMap.end()) {
            oldRegistration = tit->second;
            g_dataTsfnMap.erase(tit);
        }
    }
    if (oldRegistration) {
        StopSshDataRegistrationInstance(oldRegistration);
    }
    // A detached session has already removed its registration. Reattaching a
    // fresh callback must reuse the live owner reactor instead of stopping
    // and restarting it unnecessarily. Explicit null/undefined still tears
    // down the producer below.
    if (cbType != napi_function || oldRegistration) {
        sshAdapter->setOnDataCallback(nullptr);
    }
    if (oldRegistration && oldRegistration->tsfn != nullptr) {
        napi_release_threadsafe_function(oldRegistration->tsfn, napi_tsfn_release);
    }

    if (cbType != napi_function) {
        // null/undefined 表示卸载, 已在上面处理
        OH_LOG_INFO(LOG_APP, "[ExtLoader] setOnDataCallback: 已卸载 id=%{public}d", sessionId);
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    auto registration = std::make_shared<SshDataTsfnRegistration>();
    registration->sessionId = sessionId;
    registration->adapter = sshAdapter;
    auto* callbackContext = new (std::nothrow) SshDataTsfnContext { registration };
    if (callbackContext == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[ExtLoader] setOnDataCallback: 创建回调上下文失败");
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    // 创建 TSFN
    napi_value resourceName;
    napi_create_string_utf8(env, "SshDataPush", NAPI_AUTO_LENGTH, &resourceName);
    napi_threadsafe_function tsfn = nullptr;
    napi_status s = napi_create_threadsafe_function(
        env,
        args[1],          // 用户 jsCb
        nullptr,          // async_resource
        resourceName,
        64,               // bounded queue; producer waits with cancellation
        1,                // 1 initial thread
        callbackContext,  // thread_finalize_data
        FinalizeSshDataTsfn,
        callbackContext,  // context
        DataTsfnCallJs,   // call_js_cb
        &tsfn);
    if (s != napi_ok || tsfn == nullptr) {
        delete callbackContext;
        OH_LOG_ERROR(LOG_APP, "[ExtLoader] setOnDataCallback: 创建 TSFN 失败 status=%{public}d", s);
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    registration->tsfn = tsfn;
    sshAdapter->markTerminalCallbackInstrumentation();
    {
        std::lock_guard<std::mutex> lk(g_dataTsfnMutex);
        g_dataTsfnMap[sessionId] = registration;
    }

    // 绑定到 adapter — 每次 reader 拿到数据时调用
    const std::weak_ptr<SshAdapter> weakAdapter = sshAdapter;
    sshAdapter->setOnDataCallback([registration, weakAdapter](const std::vector<uint8_t>& data) {
        if (data.empty()) { return; }
        if (!registration->accepting.load(std::memory_order_acquire)) {
            if (auto adapter = weakAdapter.lock()) {
                adapter->recordTerminalCallbackDeliveryError(true);
            }
            return;
        }
        auto* heapBytes = new std::vector<uint8_t>(data);
        bool queued = false;
        {
            std::lock_guard<std::mutex> lock(registration->pendingMutex);
            if (registration->accepting.load(std::memory_order_acquire) &&
                registration->pending.size() < SshDataTsfnRegistration::kMaxPendingChunks &&
                registration->pendingBytes + heapBytes->size() <=
                    SshDataTsfnRegistration::kMaxPendingBytes) {
                registration->pendingBytes += heapBytes->size();
                registration->pending.push_back(heapBytes);
                queued = true;
            }
        }
        if (queued) {
            registration->pendingCondition.notify_one();
            return;
        }
        if (auto adapter = weakAdapter.lock()) {
            adapter->recordTerminalCallbackQueueFull();
            adapter->recordTerminalCallbackDeliveryError(
                !registration->accepting.load(std::memory_order_acquire));
            if (registration->accepting.load(std::memory_order_acquire)) {
                // A full bounded queue would otherwise silently lose terminal
                // bytes. Stop the SSH owner and expose ERROR so the page can
                // offer an explicit reconnect instead of rendering a corrupt
                // shell transcript.
                adapter->failTerminalOutput("SSH terminal output queue overflow");
            }
        }
        // The bounded pending queue is deliberately non-blocking.  Reaching
        // the cap is observable through callback diagnostics instead of
        // freezing the SSH reader owner behind a JS queue.
        delete heapBytes;
    });

    try {
        registration->pumpThread = std::thread([registration]() {
            SshDataTsfnPump(registration);
        });
    } catch (const std::exception&) {
        registration->accepting.store(false, std::memory_order_release);
        registration->pendingCondition.notify_all();
        sshAdapter->setOnDataCallback(nullptr);
        registration->adapter.reset();
        {
            std::lock_guard<std::mutex> lk(g_dataTsfnMutex);
            auto it = g_dataTsfnMap.find(sessionId);
            if (it != g_dataTsfnMap.end() && it->second == registration) {
                g_dataTsfnMap.erase(it);
            }
        }
        napi_release_threadsafe_function(registration->tsfn, napi_tsfn_release);
        OH_LOG_ERROR(LOG_APP, "[ExtLoader] setOnDataCallback: 启动 SSH 回调泵失败 id=%{public}d",
            sessionId);
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    OH_LOG_INFO(LOG_APP, "[ExtLoader] setOnDataCallback: 已注册 id=%{public}d", sessionId);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/** Detach an SSH page consumer while retaining the connected session. */
napi_value NapiDetachSshSession(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    bool detached = false;
    if (argc > 0 && napi_get_value_int32(env, args[0], &sessionId) == napi_ok && sessionId > 0) {
        auto it = g_sessionRegistry.find(sessionId);
        if (it != g_sessionRegistry.end() && it->second) {
            const std::shared_ptr<SessionContext> session = it->second;
            std::shared_ptr<ProtocolAdapter> adapter;
            {
                std::lock_guard<std::mutex> adapterLock(session->adapterMutex);
                adapter = session->adapter;
            }
            const std::shared_ptr<SshAdapter> sshAdapter =
                std::dynamic_pointer_cast<SshAdapter>(adapter);
            std::unique_lock<std::mutex> callbackRegistrationLock(
                session->callbackRegistrationMutex);
            if (sshAdapter && session->lifecycle.load(std::memory_order_acquire) ==
                    SessionContext::Lifecycle::Active) {
                const DecoderSessionIdentity identity = session->identity();
                const DecoderSessionIdentity activeOwner =
                    Render::SharedSessionSinkOwnerLease().snapshot();
                const bool activeOwnerMatches =
                    Render::SessionOwnerMatches(activeOwner, identity);
                bool sharedSinkReleased = true;
                if (SshTerminalResumePolicy::shouldReleaseSharedSinkOnDetach(
                        session->sharedSinkForeground, activeOwnerMatches)) {
                    sharedSinkReleased = DeactivateSessionContextIfActive(adapter, identity);
                }
                if (SshTerminalResumePolicy::acceptsDetachSharedSinkRelease(
                        session->sharedSinkForeground, activeOwnerMatches,
                        sharedSinkReleased)) {
                    if (session->sharedSinkForeground && activeOwnerMatches) {
                        OH_LOG_INFO(LOG_APP,
                            "[ExtLoader] SSH detach released active owner id=%{public}d",
                            sessionId);
                    }
                    sshAdapter->suspendTerminalInput();
                    DetachSshDataRegistration(sessionId, sshAdapter);
                    detached = true;
                } else {
                    OH_LOG_WARN(LOG_APP,
                        "[ExtLoader] SSH detach active-owner release failed id=%{public}d",
                        sessionId);
                }
            }
        }
    }
    napi_value result;
    napi_get_boolean(env, detached, &result);
    return result;
}

/** Re-enable terminal input for an SSH session whose page has reattached. */
napi_value NapiResumeSshSession(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    bool resumed = false;
    if (argc > 0 && napi_get_value_int32(env, args[0], &sessionId) == napi_ok && sessionId > 0) {
        auto it = g_sessionRegistry.find(sessionId);
        if (it != g_sessionRegistry.end() && it->second) {
            const std::shared_ptr<SessionContext> session = it->second;
            std::unique_lock<std::mutex> callbackRegistrationLock(
                session->callbackRegistrationMutex);
            std::shared_ptr<ProtocolAdapter> adapter;
            {
                std::lock_guard<std::mutex> adapterLock(session->adapterMutex);
                adapter = session->adapter;
            }
            const std::shared_ptr<SshAdapter> sshAdapter =
                std::dynamic_pointer_cast<SshAdapter>(adapter);
            if (sshAdapter && session->lifecycle.load(std::memory_order_acquire) ==
                    SessionContext::Lifecycle::Active) {
                bool hasRegistration = false;
                {
                    std::lock_guard<std::mutex> registrationLock(g_dataTsfnMutex);
                    auto registration = g_dataTsfnMap.find(sessionId);
                    hasRegistration = registration != g_dataTsfnMap.end() && registration->second &&
                        registration->second->accepting.load(std::memory_order_acquire);
                }
                if (hasRegistration) {
                    const ConnectionState state = sshAdapter->getState();
                    // A page callback can be rebound while the transport is
                    // still reconnecting. Keep that live session attached;
                    // the page's state probe will expose CONNECTED later.
                    if (SshTerminalResumePolicy::acceptsPageBinding(state, hasRegistration)) {
                        const bool sharedSinkActivated =
                            !session->sharedSinkForeground ||
                            ActivateSessionContext(adapter, session->identity());
                        if (SshTerminalResumePolicy::acceptsSharedSinkActivation(
                                session->sharedSinkForeground, sharedSinkActivated)) {
                            // Foreground pages re-publish the process-wide owner.
                            // Independent-window pages route all terminal traffic
                            // by session id and deliberately keep owners isolated.
                            if (SshTerminalResumePolicy::shouldResumeInput(state)) {
                                sshAdapter->resumeTerminalInput();
                            }
                            resumed = true;
                        } else {
                            OH_LOG_WARN(LOG_APP,
                                "[ExtLoader] SSH resume active-owner activation failed id=%{public}d",
                                sessionId);
                        }
                    } else {
                        OH_LOG_WARN(LOG_APP,
                            "[ExtLoader] SSH resume page-binding policy rejected id=%{public}d",
                            sessionId);
                    }
                }
            }
        }
    }
    napi_value result;
    napi_get_boolean(env, resumed, &result);
    return result;
}

// ============================================================
/**
 * NAPI: setHelperSocketPath(socketPath: string, helperBinPath: string): void
 * 设置 rustdesk_helper IPC socket 路径 + helper 二进制路径
 */
#include "../rustdesk/rustdesk_ipc.h"
static napi_value NapiSetHelperSocketPath(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char socketPath[512] = {0};
    char binPath[512] = {0};
    if (argc > 0) {
        napi_get_value_string_utf8(env, args[0], socketPath, sizeof(socketPath), nullptr);
    }
    if (argc > 1) {
        napi_get_value_string_utf8(env, args[1], binPath, sizeof(binPath), nullptr);
    }
    rdSetHelperSocketPath(socketPath);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

// ============================================================
// SSH 密钥工具 NAPI 函数
// ============================================================

/**
 * NAPI: generateSshKeyPair(keyType: string, bits: number, comment: string, passphrase: string): object
 */
napi_value NapiGenerateSshKeyPair(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // 提取参数
    char keyTypeBuf[64] = {0};
    char commentBuf[256] = {0};
    char passBuf[256] = {0};
    int bits = 0;

    if (argc > 0) napi_get_value_string_utf8(env, args[0], keyTypeBuf, sizeof(keyTypeBuf), nullptr);
    if (argc > 1) napi_get_value_int32(env, args[1], &bits);
    if (argc > 2) napi_get_value_string_utf8(env, args[2], commentBuf, sizeof(commentBuf), nullptr);
    if (argc > 3) napi_get_value_string_utf8(env, args[3], passBuf, sizeof(passBuf), nullptr);

    std::string keyType(keyTypeBuf);
    std::string comment(commentBuf);
    std::string passphrase(passBuf);

    OH_LOG_INFO(LOG_APP, "[ExtLoader] generateSshKeyPair: type=%{public}s bits=%{public}d",
                keyType.c_str(), bits);

    GeneratedSshKeyPair pair = generateSshKeyPair(keyType, bits, comment, passphrase);

    // 构建返回对象
    napi_value result;
    napi_create_object(env, &result);

    napi_value valOk, valPem, valPub, valFp, valType, valBits, valErr;
    napi_get_boolean(env, pair.ok, &valOk);
    napi_create_string_utf8(env, pair.privateKeyPem.c_str(), NAPI_AUTO_LENGTH, &valPem);
    napi_create_string_utf8(env, pair.publicKeyOpenSsh.c_str(), NAPI_AUTO_LENGTH, &valPub);
    napi_create_string_utf8(env, pair.fingerprintSha256.c_str(), NAPI_AUTO_LENGTH, &valFp);
    napi_create_string_utf8(env, pair.keyType.c_str(), NAPI_AUTO_LENGTH, &valType);
    napi_create_int32(env, pair.keyBits, &valBits);
    napi_create_string_utf8(env, pair.error.c_str(), NAPI_AUTO_LENGTH, &valErr);

    napi_set_named_property(env, result, "ok", valOk);
    napi_set_named_property(env, result, "privateKeyPem", valPem);
    napi_set_named_property(env, result, "publicKeyOpenSsh", valPub);
    napi_set_named_property(env, result, "fingerprintSha256", valFp);
    napi_set_named_property(env, result, "keyType", valType);
    napi_set_named_property(env, result, "keyBits", valBits);
    napi_set_named_property(env, result, "error", valErr);

    return result;
}

/**
 * NAPI: inspectSshPrivateKey(privateKeyPem: string, passphrase: string): object
 */
napi_value NapiInspectSshPrivateKey(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char passBuf[256] = {0};

    std::string privateKeyPem;
    if (argc > 0) privateKeyPem = GetNapiString(env, args[0]);
    if (argc > 1) napi_get_value_string_utf8(env, args[1], passBuf, sizeof(passBuf), nullptr);

    SshPrivateKeyInfo info_result = inspectSshPrivateKey(privateKeyPem, std::string(passBuf));

    napi_value result;
    napi_create_object(env, &result);

    napi_value valOk, valType, valPub, valFp, valEnc, valErr;
    napi_get_boolean(env, info_result.ok, &valOk);
    napi_create_string_utf8(env, info_result.keyType.c_str(), NAPI_AUTO_LENGTH, &valType);
    napi_create_string_utf8(env, info_result.publicKeyOpenSsh.c_str(), NAPI_AUTO_LENGTH, &valPub);
    napi_create_string_utf8(env, info_result.fingerprintSha256.c_str(), NAPI_AUTO_LENGTH, &valFp);
    napi_get_boolean(env, info_result.encrypted, &valEnc);
    napi_create_string_utf8(env, info_result.error.c_str(), NAPI_AUTO_LENGTH, &valErr);

    napi_set_named_property(env, result, "ok", valOk);
    napi_set_named_property(env, result, "keyType", valType);
    napi_set_named_property(env, result, "publicKeyOpenSsh", valPub);
    napi_set_named_property(env, result, "fingerprintSha256", valFp);
    napi_set_named_property(env, result, "encrypted", valEnc);
    napi_set_named_property(env, result, "error", valErr);

    return result;
}

/**
 * NAPI: changeSshPrivateKeyPassphrase(privateKeyPem: string, oldPassphrase: string, newPassphrase: string): string
 */
napi_value NapiChangeSshPrivateKeyPassphrase(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char oldPassBuf[256] = {0};
    char newPassBuf[256] = {0};

    std::string privateKeyPem;
    if (argc > 0) privateKeyPem = GetNapiString(env, args[0]);
    if (argc > 1) napi_get_value_string_utf8(env, args[1], oldPassBuf, sizeof(oldPassBuf), nullptr);
    if (argc > 2) napi_get_value_string_utf8(env, args[2], newPassBuf, sizeof(newPassBuf), nullptr);

    std::string newPem = changeSshPrivateKeyPassphrase(
        privateKeyPem, std::string(oldPassBuf), std::string(newPassBuf));

    napi_value result;
    napi_create_string_utf8(env, newPem.c_str(), NAPI_AUTO_LENGTH, &result);
    return result;
}

/**
 * NAPI: validatePublicKeyForAuthorizedKeys(publicKeyOpenSsh: string): boolean
 */
napi_value NapiValidatePublicKeyForAuthorizedKeys(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char keyBuf[8192] = {0};
    if (argc > 0) napi_get_value_string_utf8(env, args[0], keyBuf, sizeof(keyBuf), nullptr);

    bool valid = validatePublicKeyForAuthorizedKeys(std::string(keyBuf));

    napi_value result;
    napi_get_boolean(env, valid, &result);
    return result;
}

/**
 * NAPI: installSshPublicKey(host, port, username, password, privateKeyPem, passphrase, publicKey): object
 * 同步阻塞 — 调用方应在 ArkTS async 上下文中调用并显示 loading 指示器
 */
napi_value NapiInstallSshPublicKey(napi_env env, napi_callback_info info) {
    size_t argc = 7;
    napi_value args[7];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char hostBuf[256] = {0};
    char userBuf[256] = {0};
    char passBuf[512] = {0};
    char passphraseBuf[256] = {0};
    char pubKeyBuf[8192] = {0};
    int port = 22;

    if (argc > 0) napi_get_value_string_utf8(env, args[0], hostBuf, sizeof(hostBuf), nullptr);
    if (argc > 1) napi_get_value_int32(env, args[1], &port);
    if (argc > 2) napi_get_value_string_utf8(env, args[2], userBuf, sizeof(userBuf), nullptr);
    if (argc > 3) napi_get_value_string_utf8(env, args[3], passBuf, sizeof(passBuf), nullptr);
    std::string privateKeyPem;
    if (argc > 4) privateKeyPem = GetNapiString(env, args[4]);
    if (argc > 5) napi_get_value_string_utf8(env, args[5], passphraseBuf, sizeof(passphraseBuf), nullptr);
    if (argc > 6) napi_get_value_string_utf8(env, args[6], pubKeyBuf, sizeof(pubKeyBuf), nullptr);

    const std::string logUser = SafeLog::MaskUser(userBuf);
    const std::string logHost = SafeLog::MaskHost(hostBuf);
    OH_LOG_INFO(LOG_APP, "[ExtLoader] installSshPublicKey: %{public}s@%{public}s:%{public}d",
                logUser.c_str(), logHost.c_str(), port);

    SshPublicKeyInstallResult res = installSshPublicKey(
        std::string(hostBuf), port, std::string(userBuf),
        std::string(passBuf), privateKeyPem,
        std::string(passphraseBuf), std::string(pubKeyBuf));

    napi_value result;
    napi_create_object(env, &result);

    napi_value valOk, valAlready, valVerified, valCode, valMsg;
    napi_get_boolean(env, res.ok, &valOk);
    napi_get_boolean(env, res.alreadyInstalled, &valAlready);
    napi_get_boolean(env, res.verified, &valVerified);
    napi_create_int32(env, res.code, &valCode);
    napi_create_string_utf8(env, res.message.c_str(), NAPI_AUTO_LENGTH, &valMsg);

    napi_set_named_property(env, result, "ok", valOk);
    napi_set_named_property(env, result, "alreadyInstalled", valAlready);
    napi_set_named_property(env, result, "verified", valVerified);
    napi_set_named_property(env, result, "code", valCode);
    napi_set_named_property(env, result, "message", valMsg);

    return result;
}

static napi_value CreateSshAuthTestResultValue(
    napi_env env, const SshAuthTestResult& resultValue) {
    napi_value result;
    napi_create_object(env, &result);
    SetObjectBool(env, result, "ok", resultValue.ok);
    SetObjectInt32(env, result, "code", resultValue.code);
    SetObjectString(env, result, "message", resultValue.message);
    return result;
}

static napi_value CreateSshHostKeyInfoValue(
    napi_env env, const SshHostKeyInfo& resultValue) {
    napi_value result;
    napi_create_object(env, &result);
    SetObjectBool(env, result, "ok", resultValue.ok);
    SetObjectString(env, result, "host", resultValue.host);
    SetObjectInt32(env, result, "port", resultValue.port);
    SetObjectString(env, result, "algorithm", resultValue.algorithm);
    SetObjectString(env, result, "fingerprintSha256", resultValue.fingerprintSha256);
    SetObjectString(env, result, "rawBase64", resultValue.rawBase64);
    SetObjectString(env, result, "serverBanner", resultValue.serverBanner);
    SetObjectInt32(env, result, "errorCode", resultValue.errorCode);
    SetObjectString(env, result, "errorMessage", resultValue.errorMessage);
    return result;
}

static bool ReadSshOperationEndpointArgs(
    napi_env env, napi_value hostValue, napi_value portValue,
    std::string& host, int32_t& port) {
    return hostValue != nullptr && portValue != nullptr &&
        ReadBoundedNapiStringValue(
            env, hostValue, remotedesk::endpoint::kMaxInputLength, host) &&
        ReadStrictNapiInt32Value(env, portValue, port) &&
        NormalizePersistedEndpoint(host, port);
}

/**
 * NAPI: testSshKeyAuth(host, port, username, privateKeyPem, passphrase): object
 * 同步阻塞
 */
napi_value NapiTestSshKeyAuth(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    try {
        std::string host;
        int32_t port = 22;
        std::string username;
        std::string privateKeyPem;
        std::string passphrase;
        SshProxyOptions proxy;
        if (argc < 5 || !ReadSshOperationEndpointArgs(
                env, args[0], args[1], host, port) ||
            !ReadBoundedNapiStringValue(env, args[2], 1024, username) ||
            !ReadBoundedNapiStringValue(
                env, args[3], kMaxGenericNapiStringLength, privateKeyPem) ||
            !ReadBoundedNapiStringValue(env, args[4], 65536, passphrase) ||
            !ReadSshProxyOptions(env, argc > 5 ? args[5] : nullptr, proxy)) {
            secureClearString(privateKeyPem);
            secureClearString(passphrase);
            ClearSshProxyOptions(proxy);
            napi_throw_type_error(env, nullptr, "invalid SSH key authentication input");
            return nullptr;
        }
        SshAuthTestResult res = testSshKeyAuth(
            host, port, username, privateKeyPem, passphrase, proxy);
        secureClearString(privateKeyPem);
        secureClearString(passphrase);
        ClearSshProxyOptions(proxy);
        return CreateSshAuthTestResultValue(env, res);
    } catch (const std::exception& ex) {
        napi_throw_error(env, nullptr, ex.what());
        return nullptr;
    } catch (...) {
        napi_throw_error(env, nullptr, "SSH key authentication native exception");
        return nullptr;
    }
}

/**
 * NAPI: probeSshHostKey(host, port): object
 * 仅 TCP + KEX, 不做用户认证. 同步阻塞 1-5s.
 */
napi_value NapiProbeSshHostKey(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    try {
        std::string host;
        int32_t port = 22;
        SshProxyOptions proxy;
        if (argc < 2 || !ReadSshOperationEndpointArgs(
                env, args[0], args[1], host, port) ||
            !ReadSshProxyOptions(env, argc > 2 ? args[2] : nullptr, proxy)) {
            ClearSshProxyOptions(proxy);
            napi_throw_type_error(env, nullptr, "invalid SSH host key probe input");
            return nullptr;
        }
        SshHostKeyInfo res = probeSshHostKey(host, port, proxy);
        ClearSshProxyOptions(proxy);
        return CreateSshHostKeyInfoValue(env, res);
    } catch (const std::exception& ex) {
        napi_throw_error(env, nullptr, ex.what());
        return nullptr;
    } catch (...) {
        napi_throw_error(env, nullptr, "SSH host key probe native exception");
        return nullptr;
    }
}

struct SshKeyAuthAsyncData {
    std::string host;
    int32_t port = 22;
    std::string username;
    std::string privateKeyPem;
    std::string passphrase;
    SshProxyOptions proxy;
    SshAuthTestResult result {};
    bool workerFailed = false;
    std::string errorMessage;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;

    ~SshKeyAuthAsyncData() {
        secureClearString(privateKeyPem);
        secureClearString(passphrase);
        ClearSshProxyOptions(proxy);
    }
};

static void ExecuteSshKeyAuthAsync(napi_env /*env*/, void* rawData) {
    auto* data = static_cast<SshKeyAuthAsyncData*>(rawData);
    if (data == nullptr) { return; }
    try {
        data->result = testSshKeyAuth(
            data->host, data->port, data->username,
            data->privateKeyPem, data->passphrase, data->proxy);
    } catch (const std::exception& ex) {
        data->workerFailed = true;
        data->errorMessage = std::string("SSH key authentication async work failed: ") + ex.what();
    } catch (...) {
        data->workerFailed = true;
        data->errorMessage = "SSH key authentication async work failed: unknown native exception";
    }
}

static void CompleteSshKeyAuthAsync(napi_env env, napi_status status, void* rawData) {
    auto* data = static_cast<SshKeyAuthAsyncData*>(rawData);
    if (data == nullptr) { return; }
    if (status != napi_ok || data->workerFailed) {
        napi_value error;
        const std::string message = data->errorMessage.empty()
            ? "SSH key authentication async work failed" : data->errorMessage;
        napi_create_string_utf8(env, message.c_str(), NAPI_AUTO_LENGTH, &error);
        napi_reject_deferred(env, data->deferred, error);
        OH_LOG_ERROR(LOG_APP, "[SSH-KEY-ASYNC] complete failed status=%{public}d", status);
    } else {
        napi_value result = CreateSshAuthTestResultValue(env, data->result);
        napi_resolve_deferred(env, data->deferred, result);
    }
    napi_delete_async_work(env, data->work);
    delete data;
}

/** NAPI: testSshKeyAuthAsync(host, port, username, privateKeyPem, passphrase, proxy): Promise<object> */
napi_value NapiTestSshKeyAuthAsync(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    try {
        std::unique_ptr<SshKeyAuthAsyncData> data(
            new (std::nothrow) SshKeyAuthAsyncData());
        if (!data) {
            napi_throw_error(env, nullptr, "SSH key authentication async allocation failed");
            return nullptr;
        }
        if (argc < 5 || !ReadSshOperationEndpointArgs(
                env, args[0], args[1], data->host, data->port) ||
            !ReadBoundedNapiStringValue(env, args[2], 1024, data->username) ||
            !ReadBoundedNapiStringValue(
                env, args[3], kMaxGenericNapiStringLength, data->privateKeyPem) ||
            !ReadBoundedNapiStringValue(env, args[4], 65536, data->passphrase) ||
            !ReadSshProxyOptions(
                env, argc > 5 ? args[5] : nullptr, data->proxy)) {
            napi_throw_type_error(env, nullptr, "invalid SSH key authentication async input");
            return nullptr;
        }

        napi_value promise;
        napi_status status = napi_create_promise(env, &data->deferred, &promise);
        if (status != napi_ok) {
            napi_throw_error(env, nullptr, "SSH key authentication async promise creation failed");
            return nullptr;
        }
        napi_value resource;
        status = napi_create_string_utf8(env, "SshKeyAuthAsync", NAPI_AUTO_LENGTH, &resource);
        if (status != napi_ok) {
            napi_throw_error(env, nullptr, "SSH key authentication async resource creation failed");
            return nullptr;
        }
        status = napi_create_async_work(env, resource, resource,
            ExecuteSshKeyAuthAsync, CompleteSshKeyAuthAsync, data.get(), &data->work);
        if (status != napi_ok) {
            napi_throw_error(env, nullptr, "SSH key authentication async work creation failed");
            return nullptr;
        }
        status = napi_queue_async_work(env, data->work);
        if (status != napi_ok) {
            napi_delete_async_work(env, data->work);
            napi_throw_error(env, nullptr, "SSH key authentication async work queue failed");
            return nullptr;
        }
        data.release();
        return promise;
    } catch (const std::exception& ex) {
        napi_throw_error(env, nullptr, ex.what());
        return nullptr;
    } catch (...) {
        napi_throw_error(env, nullptr, "SSH key authentication async native exception");
        return nullptr;
    }
}

struct SshHostKeyProbeAsyncData {
    std::string host;
    int32_t port = 22;
    SshProxyOptions proxy;
    SshHostKeyInfo result {};
    bool workerFailed = false;
    std::string errorMessage;
    napi_deferred deferred = nullptr;
    napi_async_work work = nullptr;

    ~SshHostKeyProbeAsyncData() {
        ClearSshProxyOptions(proxy);
    }
};

static void ExecuteSshHostKeyProbeAsync(napi_env /*env*/, void* rawData) {
    auto* data = static_cast<SshHostKeyProbeAsyncData*>(rawData);
    if (data == nullptr) { return; }
    try {
        data->result = probeSshHostKey(data->host, data->port, data->proxy);
    } catch (const std::exception& ex) {
        data->workerFailed = true;
        data->errorMessage = std::string("SSH host key probe async work failed: ") + ex.what();
    } catch (...) {
        data->workerFailed = true;
        data->errorMessage = "SSH host key probe async work failed: unknown native exception";
    }
}

static void CompleteSshHostKeyProbeAsync(napi_env env, napi_status status, void* rawData) {
    auto* data = static_cast<SshHostKeyProbeAsyncData*>(rawData);
    if (data == nullptr) { return; }
    if (status != napi_ok || data->workerFailed) {
        napi_value error;
        const std::string message = data->errorMessage.empty()
            ? "SSH host key probe async work failed" : data->errorMessage;
        napi_create_string_utf8(env, message.c_str(), NAPI_AUTO_LENGTH, &error);
        napi_reject_deferred(env, data->deferred, error);
        OH_LOG_ERROR(LOG_APP, "[SSH-HOSTKEY-ASYNC] complete failed status=%{public}d", status);
    } else {
        napi_value result = CreateSshHostKeyInfoValue(env, data->result);
        napi_resolve_deferred(env, data->deferred, result);
    }
    napi_delete_async_work(env, data->work);
    delete data;
}

/** NAPI: probeSshHostKeyAsync(host, port, proxy): Promise<object> */
napi_value NapiProbeSshHostKeyAsync(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    try {
        std::unique_ptr<SshHostKeyProbeAsyncData> data(
            new (std::nothrow) SshHostKeyProbeAsyncData());
        if (!data) {
            napi_throw_error(env, nullptr, "SSH host key probe async allocation failed");
            return nullptr;
        }
        if (argc < 2 || !ReadSshOperationEndpointArgs(
                env, args[0], args[1], data->host, data->port) ||
            !ReadSshProxyOptions(
                env, argc > 2 ? args[2] : nullptr, data->proxy)) {
            napi_throw_type_error(env, nullptr, "invalid SSH host key probe async input");
            return nullptr;
        }

        napi_value promise;
        napi_status status = napi_create_promise(env, &data->deferred, &promise);
        if (status != napi_ok) {
            napi_throw_error(env, nullptr, "SSH host key probe async promise creation failed");
            return nullptr;
        }
        napi_value resource;
        status = napi_create_string_utf8(env, "SshHostKeyProbeAsync", NAPI_AUTO_LENGTH, &resource);
        if (status != napi_ok) {
            napi_throw_error(env, nullptr, "SSH host key probe async resource creation failed");
            return nullptr;
        }
        status = napi_create_async_work(env, resource, resource,
            ExecuteSshHostKeyProbeAsync, CompleteSshHostKeyProbeAsync,
            data.get(), &data->work);
        if (status != napi_ok) {
            napi_throw_error(env, nullptr, "SSH host key probe async work creation failed");
            return nullptr;
        }
        status = napi_queue_async_work(env, data->work);
        if (status != napi_ok) {
            napi_delete_async_work(env, data->work);
            napi_throw_error(env, nullptr, "SSH host key probe async work queue failed");
            return nullptr;
        }
        data.release();
        return promise;
    } catch (const std::exception& ex) {
        napi_throw_error(env, nullptr, ex.what());
        return nullptr;
    } catch (...) {
        napi_throw_error(env, nullptr, "SSH host key probe async native exception");
        return nullptr;
    }
}

/**
 * NAPI: requestFrameRefresh(): void
 *
 * 请求关键帧刷新 (后台恢复前台后触发画面更新)。
 * RDP: 发送 Refresh Rect PDU。RustDesk: 发送 refresh_video_display。
 */
napi_value NapiRequestFrameRefresh(napi_env env, napi_callback_info info) {
    (void)info;
    const std::shared_ptr<ProtocolAdapter> activeConnection = GetActiveSessionAdapter();
    if (activeConnection) {
        activeConnection->requestFrameRefresh();
        OH_LOG_INFO(LOG_APP, "[ExtLoader] requestFrameRefresh: sent to active adapter");
    } else {
        OH_LOG_WARN(LOG_APP, "[ExtLoader] requestFrameRefresh: no active connection, skipped");
    }
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value NapiIsVideoPlaybackActive(napi_env env, napi_callback_info /*info*/) {
    napi_value active;
    napi_get_boolean(env, isRemoteVideoPlaybackActive(), &active);
    return active;
}

/**
 * NAPI: bindRendererToSession(rendererHandle, sessionId): boolean
 *
 * Renderer recreation is a surface lifecycle operation, not a protocol
 * reconnect. initRenderer() can only see the process-wide owner that is
 * active at that instant; after a background/PIP renderer is destroyed that
 * renderer owner is intentionally cleared. Rebind the new renderer to the
 * still-live SessionContext so raw VNC/RDP callbacks are admitted again.
 */
static napi_value NapiBindRendererToSession(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t rendererHandle = 0;
    int32_t sessionId = 0;
    if (argc >= 1) {
        napi_get_value_int64(env, args[0], &rendererHandle);
    }
    if (argc >= 2) {
        napi_get_value_int32(env, args[1], &sessionId);
    }

    bool bound = false;
    if (rendererHandle > 0 && sessionId > 0) {
        const auto it = g_sessionRegistry.find(sessionId);
        if (it != g_sessionRegistry.end() && it->second &&
            it->second->lifecycle.load(std::memory_order_acquire) ==
                SessionContext::Lifecycle::Active) {
            const std::shared_ptr<SessionContext> session = it->second;
            const DecoderSessionIdentity owner = session->identity();
            if (owner.valid() &&
                Render::SharedSessionSinkOwnerLease().accepts(owner) &&
                DecoderNapi::IsActiveSessionOwner(owner)) {
                bound = RendererNapi::SetActiveRenderer(rendererHandle, owner);
            }
        }
    }

    OH_LOG_INFO(LOG_APP,
        "[ExtLoader] bindRendererToSession renderer=%{public}lld session=%{public}d bound=%{public}s",
        static_cast<long long>(rendererHandle), sessionId, bound ? "true" : "false");
    napi_value result;
    napi_get_boolean(env, bound, &result);
    return result;
}

// ============================================================
// ExtensionLoaderNapi::Init
// ============================================================

napi_value ExtensionLoaderNapi::Init(napi_env env, napi_value exports) {
    napi_value fn;
    const std::shared_ptr<VncCertificateProbeEnvironmentState> probeState =
        GetVncCertificateProbeEnvironmentState(env);
    bool cleanupAlreadyRegistered = false;
    {
        std::lock_guard<std::mutex> stateLock(probeState->mutex);
        cleanupAlreadyRegistered = probeState->cleanupHookRegistered &&
            !probeState->cleanupHookRemoved;
    }
    if (!cleanupAlreadyRegistered) {
        napi_async_cleanup_hook_handle cleanupHandle = nullptr;
        const napi_status cleanupStatus = napi_add_async_cleanup_hook(
            env, CancelVncCertificateProbesForEnvironment, probeState.get(), &cleanupHandle);
        if (cleanupStatus == napi_ok) {
            napi_async_cleanup_hook_handle removeImmediately = nullptr;
            {
                std::lock_guard<std::mutex> registryLock(g_vncCertificateProbeMutex);
                std::lock_guard<std::mutex> stateLock(probeState->mutex);
                probeState->cleanupHandle = cleanupHandle;
                probeState->cleanupHookRegistered = true;
                if (probeState->closing && probeState->activeWorks == 0 &&
                    !probeState->cleanupHookRemoved) {
                    probeState->cleanupHookRemoved = true;
                    removeImmediately = cleanupHandle;
                }
            }
            if (removeImmediately != nullptr) {
                (void)napi_remove_async_cleanup_hook(removeImmediately);
            }
        } else {
            // Certificate probes fail closed when the runtime cannot provide
            // the supported asynchronous teardown contract.
            std::lock_guard<std::mutex> registryLock(g_vncCertificateProbeMutex);
            std::lock_guard<std::mutex> stateLock(probeState->mutex);
            probeState->closing = true;
            auto environment = g_vncCertificateProbeEnvironments.find(env);
            if (environment != g_vncCertificateProbeEnvironments.end() &&
                environment->second == probeState) {
                g_vncCertificateProbeEnvironments.erase(environment);
            }
            OH_LOG_ERROR(LOG_APP,
                         "[VNC-CERT-ASYNC] cleanup hook registration failed status=%{public}d",
                         cleanupStatus);
        }
    }

    napi_create_function(env, "listProtocols", NAPI_AUTO_LENGTH,
                         NapiListProtocols, nullptr, &fn);
    napi_set_named_property(env, exports, "listProtocols", fn);

    napi_create_function(env, "connect", NAPI_AUTO_LENGTH,
                         NapiConnect, nullptr, &fn);
    napi_set_named_property(env, exports, "connect", fn);

    napi_create_function(env, "connectSshAsync", NAPI_AUTO_LENGTH,
                         NapiConnectSshAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "connectSshAsync", fn);

    napi_create_function(env, "getPendingSshConnectId", NAPI_AUTO_LENGTH,
                         NapiGetPendingSshConnectId, nullptr, &fn);
    napi_set_named_property(env, exports, "getPendingSshConnectId", fn);
    napi_create_function(env, "getPendingSshConnectIds", NAPI_AUTO_LENGTH,
                         NapiGetPendingSshConnectIds, nullptr, &fn);
    napi_set_named_property(env, exports, "getPendingSshConnectIds", fn);

    napi_create_function(env, "probeRdpCertificate", NAPI_AUTO_LENGTH,
                         NapiProbeRdpCertificate, nullptr, &fn);
    napi_set_named_property(env, exports, "probeRdpCertificate", fn);

    napi_create_function(env, "probeRdpCertificateAsync", NAPI_AUTO_LENGTH,
                         NapiProbeRdpCertificateAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "probeRdpCertificateAsync", fn);

    napi_create_function(env, "probeRdpCertificateRouteAsync", NAPI_AUTO_LENGTH,
                         NapiProbeRdpCertificateRouteAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "probeRdpCertificateRouteAsync", fn);

    napi_create_function(env, "probeRustDeskPresenceAsync", NAPI_AUTO_LENGTH,
                         NapiProbeRustDeskPresenceAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "probeRustDeskPresenceAsync", fn);

    napi_create_function(env, "probeVncCertificateAsync", NAPI_AUTO_LENGTH,
                         NapiProbeVncCertificateAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "probeVncCertificateAsync", fn);
    napi_create_function(env, "probeVncGatewayDeepAsync", NAPI_AUTO_LENGTH,
                         NapiProbeVncGatewayDeepAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "probeVncGatewayDeepAsync", fn);
    napi_create_function(env, "cancelVncCertificateProbe", NAPI_AUTO_LENGTH,
                         NapiCancelVncCertificateProbe, nullptr, &fn);
    napi_set_named_property(env, exports, "cancelVncCertificateProbe", fn);
    napi_create_function(env, "cancelVncGatewayDeep", NAPI_AUTO_LENGTH,
                         NapiCancelVncCertificateProbe, nullptr, &fn);
    napi_set_named_property(env, exports, "cancelVncGatewayDeep", fn);

    napi_create_function(env, "getRdpRenderStats", NAPI_AUTO_LENGTH,
                         NapiGetRdpRenderStats, nullptr, &fn);
    napi_set_named_property(env, exports, "getRdpRenderStats", fn);
    napi_create_function(env, "requestRdpDisplayLayout", NAPI_AUTO_LENGTH,
                         NapiRequestRdpDisplayLayout, nullptr, &fn);
    napi_set_named_property(env, exports, "requestRdpDisplayLayout", fn);
    napi_create_function(env, "cancelRdpDisplayLayout", NAPI_AUTO_LENGTH,
                         NapiCancelRdpDisplayLayout, nullptr, &fn);
    napi_set_named_property(env, exports, "cancelRdpDisplayLayout", fn);
    napi_create_function(env, "getSessionDiagnostics", NAPI_AUTO_LENGTH,
                         NapiGetSessionDiagnostics, nullptr, &fn);
    napi_set_named_property(env, exports, "getSessionDiagnostics", fn);
    napi_create_function(env, "getRustDeskDiagnostics", NAPI_AUTO_LENGTH,
                         NapiGetSessionDiagnostics, nullptr, &fn);
    napi_set_named_property(env, exports, "getRustDeskDiagnostics", fn);
    napi_create_function(env, "replayPendingRustDeskFrame", NAPI_AUTO_LENGTH,
                         NapiReplayPendingRustDeskFrame, nullptr, &fn);
    napi_set_named_property(env, exports, "replayPendingRustDeskFrame", fn);
    napi_create_function(env, "getLocalResourceStats", NAPI_AUTO_LENGTH,
                         NapiGetLocalResourceStats, nullptr, &fn);
    napi_set_named_property(env, exports, "getLocalResourceStats", fn);
    napi_create_function(env, "getSessionTransferStatus", NAPI_AUTO_LENGTH,
                         NapiGetSessionTransferStatus, nullptr, &fn);
    napi_set_named_property(env, exports, "getSessionTransferStatus", fn);

    napi_create_function(env, "setRdpBackgroundVideoPrewarm", NAPI_AUTO_LENGTH,
                         NapiSetRdpBackgroundVideoPrewarm, nullptr, &fn);
    napi_set_named_property(env, exports, "setRdpBackgroundVideoPrewarm", fn);

    napi_create_function(env, "presentRdpCachedFrame", NAPI_AUTO_LENGTH,
                         NapiPresentRdpCachedFrame, nullptr, &fn);
    napi_set_named_property(env, exports, "presentRdpCachedFrame", fn);

    napi_create_function(env, "disconnect", NAPI_AUTO_LENGTH,
                         NapiDisconnect, nullptr, &fn);
    napi_set_named_property(env, exports, "disconnect", fn);

    napi_create_function(env, "beginDisconnect", NAPI_AUTO_LENGTH,
                         NapiDisconnect, nullptr, &fn);
    napi_set_named_property(env, exports, "beginDisconnect", fn);

    napi_create_function(env, "getSessionOwnerIdentity", NAPI_AUTO_LENGTH,
                         NapiGetSessionOwnerIdentity, nullptr, &fn);
    napi_set_named_property(env, exports, "getSessionOwnerIdentity", fn);

    napi_create_function(env, "beginDisconnectWithReceipt", NAPI_AUTO_LENGTH,
                         NapiBeginDisconnectWithReceipt, nullptr, &fn);
    napi_set_named_property(env, exports, "beginDisconnectWithReceipt", fn);

    napi_create_function(env, "disconnectAll", NAPI_AUTO_LENGTH,
                         NapiDisconnectAll, nullptr, &fn);
    napi_set_named_property(env, exports, "disconnectAll", fn);

    napi_create_function(env, "getDisconnectState", NAPI_AUTO_LENGTH,
                         NapiGetDisconnectState, nullptr, &fn);
    napi_set_named_property(env, exports, "getDisconnectState", fn);

    napi_create_function(env, "sendKey", NAPI_AUTO_LENGTH,
                         NapiSendKey, nullptr, &fn);
    napi_set_named_property(env, exports, "sendKey", fn);

    napi_create_function(env, "sendKeySequence", NAPI_AUTO_LENGTH,
                         NapiSendKeySequence, nullptr, &fn);
    napi_set_named_property(env, exports, "sendKeySequence", fn);

    napi_create_function(env, "sendKeyEvents", NAPI_AUTO_LENGTH,
                         NapiSendKeyEvents, nullptr, &fn);
    napi_set_named_property(env, exports, "sendKeyEvents", fn);

    napi_create_function(env, "sendMouse", NAPI_AUTO_LENGTH,
                         NapiSendMouse, nullptr, &fn);
    napi_set_named_property(env, exports, "sendMouse", fn);

    napi_create_function(env, "sendMouseWheel", NAPI_AUTO_LENGTH,
                         NapiSendMouseWheel, nullptr, &fn);
    napi_set_named_property(env, exports, "sendMouseWheel", fn);

    napi_create_function(env, "sendRustDeskTouchpadWheel", NAPI_AUTO_LENGTH,
                         NapiSendRustDeskTouchpadWheel, nullptr, &fn);
    napi_set_named_property(env, exports, "sendRustDeskTouchpadWheel", fn);

    napi_create_function(env, "setRustDeskImageQuality", NAPI_AUTO_LENGTH,
                         NapiSetRustDeskImageQuality, nullptr, &fn);
    napi_set_named_property(env, exports, "setRustDeskImageQuality", fn);

    napi_create_function(env, "getRustDeskDisplayCapabilities", NAPI_AUTO_LENGTH,
                         NapiGetRustDeskDisplayCapabilities, nullptr, &fn);
    napi_set_named_property(env, exports, "getRustDeskDisplayCapabilities", fn);

    napi_create_function(env, "attachRustDeskMultiCanvasPreview", NAPI_AUTO_LENGTH,
                         NapiAttachRustDeskMultiCanvasPreview, nullptr, &fn);
    napi_set_named_property(env, exports, "attachRustDeskMultiCanvasPreview", fn);

    napi_create_function(env, "detachRustDeskMultiCanvasPreview", NAPI_AUTO_LENGTH,
                         NapiDetachRustDeskMultiCanvasPreview, nullptr, &fn);
    napi_set_named_property(env, exports, "detachRustDeskMultiCanvasPreview", fn);

    napi_create_function(env, "getRustDeskMultiCanvasPreview", NAPI_AUTO_LENGTH,
                         NapiGetRustDeskMultiCanvasPreview, nullptr, &fn);
    napi_set_named_property(env, exports, "getRustDeskMultiCanvasPreview", fn);

    napi_create_function(env, "beginRustDeskDisplaySwitch", NAPI_AUTO_LENGTH,
                         NapiBeginRustDeskDisplaySwitch, nullptr, &fn);
    napi_set_named_property(env, exports, "beginRustDeskDisplaySwitch", fn);

    napi_create_function(env, "switchRustDeskDisplay", NAPI_AUTO_LENGTH,
                         NapiSwitchRustDeskDisplay, nullptr, &fn);
    napi_set_named_property(env, exports, "switchRustDeskDisplay", fn);

    napi_create_function(env, "changeRustDeskDisplayResolution", NAPI_AUTO_LENGTH,
                         NapiChangeRustDeskDisplayResolution, nullptr, &fn);
    napi_set_named_property(env, exports, "changeRustDeskDisplayResolution", fn);

    napi_create_function(env, "sendRustDeskTouchScale", NAPI_AUTO_LENGTH,
                         NapiSendRustDeskTouchScale, nullptr, &fn);
    napi_set_named_property(env, exports, "sendRustDeskTouchScale", fn);

    napi_create_function(env, "sendRustDeskTouchPan", NAPI_AUTO_LENGTH,
                         NapiSendRustDeskTouchPan, nullptr, &fn);
    napi_set_named_property(env, exports, "sendRustDeskTouchPan", fn);

    napi_create_function(env, "sendText", NAPI_AUTO_LENGTH,
                         NapiSendText, nullptr, &fn);
    napi_set_named_property(env, exports, "sendText", fn);

    napi_create_function(env, "enqueueSshTerminalInput", NAPI_AUTO_LENGTH,
                         NapiEnqueueSshTerminalInput, nullptr, &fn);
    napi_set_named_property(env, exports, "enqueueSshTerminalInput", fn);

    napi_create_function(env, "sendFile", NAPI_AUTO_LENGTH,
                         NapiSendFile, nullptr, &fn);
    napi_set_named_property(env, exports, "sendFile", fn);

    napi_create_function(env, "writeRemoteFileChunk", NAPI_AUTO_LENGTH,
                         NapiWriteRemoteFileChunk, nullptr, &fn);
    napi_set_named_property(env, exports, "writeRemoteFileChunk", fn);
    napi_create_function(env, "writeRemoteFileChunkAsync", NAPI_AUTO_LENGTH,
                         NapiWriteRemoteFileChunkAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "writeRemoteFileChunkAsync", fn);

    napi_create_function(env, "listRemoteDir", NAPI_AUTO_LENGTH,
                         NapiListRemoteDir, nullptr, &fn);
    napi_set_named_property(env, exports, "listRemoteDir", fn);
    napi_create_function(env, "listRemoteDirAsync", NAPI_AUTO_LENGTH,
                         NapiListRemoteDirAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "listRemoteDirAsync", fn);

    napi_create_function(env, "readRemoteFile", NAPI_AUTO_LENGTH,
                         NapiReadRemoteFile, nullptr, &fn);
    napi_set_named_property(env, exports, "readRemoteFile", fn);

    napi_create_function(env, "readRemoteFileChunk", NAPI_AUTO_LENGTH,
                         NapiReadRemoteFileChunk, nullptr, &fn);
    napi_set_named_property(env, exports, "readRemoteFileChunk", fn);
    napi_create_function(env, "readRemoteFileChunkAsync", NAPI_AUTO_LENGTH,
                         NapiReadRemoteFileChunkAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "readRemoteFileChunkAsync", fn);

    napi_create_function(env, "removeRemoteFile", NAPI_AUTO_LENGTH,
                         NapiRemoveRemoteFile, nullptr, &fn);
    napi_set_named_property(env, exports, "removeRemoteFile", fn);
    napi_create_function(env, "removeRemoteFileAsync", NAPI_AUTO_LENGTH,
                         NapiRemoveRemoteFileAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "removeRemoteFileAsync", fn);

    napi_create_function(env, "removeRemoteDir", NAPI_AUTO_LENGTH,
                         NapiRemoveRemoteDir, nullptr, &fn);
    napi_set_named_property(env, exports, "removeRemoteDir", fn);
    napi_create_function(env, "removeRemoteDirAsync", NAPI_AUTO_LENGTH,
                         NapiRemoveRemoteDirAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "removeRemoteDirAsync", fn);

    napi_create_function(env, "makeRemoteDir", NAPI_AUTO_LENGTH,
                         NapiMakeRemoteDir, nullptr, &fn);
    napi_set_named_property(env, exports, "makeRemoteDir", fn);
    napi_create_function(env, "makeRemoteDirAsync", NAPI_AUTO_LENGTH,
                         NapiMakeRemoteDirAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "makeRemoteDirAsync", fn);

    napi_create_function(env, "renameRemotePath", NAPI_AUTO_LENGTH,
                         NapiRenameRemotePath, nullptr, &fn);
    napi_set_named_property(env, exports, "renameRemotePath", fn);
    napi_create_function(env, "renameRemotePathAsync", NAPI_AUTO_LENGTH,
                         NapiRenameRemotePathAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "renameRemotePathAsync", fn);

    napi_create_function(env, "sendClipboard", NAPI_AUTO_LENGTH,
                         NapiSendClipboard, nullptr, &fn);
    napi_set_named_property(env, exports, "sendClipboard", fn);
    napi_create_function(env, "setSessionClipboardFiles", NAPI_AUTO_LENGTH,
                         NapiSetSessionClipboardFiles, nullptr, &fn);
    napi_set_named_property(env, exports, "setSessionClipboardFiles", fn);
    napi_create_function(env, "getSessionClipboardText", NAPI_AUTO_LENGTH,
                         NapiGetSessionClipboardText, nullptr, &fn);
    napi_set_named_property(env, exports, "getSessionClipboardText", fn);
    napi_create_function(env, "isSessionClipboardReady", NAPI_AUTO_LENGTH,
                         NapiIsSessionClipboardReady, nullptr, &fn);
    napi_set_named_property(env, exports, "isSessionClipboardReady", fn);
    napi_create_function(env, "setSessionClipboardEnabled", NAPI_AUTO_LENGTH,
                         NapiSetSessionClipboardEnabled, nullptr, &fn);
    napi_set_named_property(env, exports, "setSessionClipboardEnabled", fn);

    napi_create_function(env, "getConnectionState", NAPI_AUTO_LENGTH,
                         NapiGetConnectionState, nullptr, &fn);
    napi_set_named_property(env, exports, "getConnectionState", fn);

    napi_create_function(env, "getSshAuthPrompt", NAPI_AUTO_LENGTH,
                         NapiGetSshAuthPrompt, nullptr, &fn);
    napi_set_named_property(env, exports, "getSshAuthPrompt", fn);
    napi_create_function(env, "respondSshAuthPrompt", NAPI_AUTO_LENGTH,
                         NapiRespondSshAuthPrompt, nullptr, &fn);
    napi_set_named_property(env, exports, "respondSshAuthPrompt", fn);
    napi_create_function(env, "cancelSshAuthPrompt", NAPI_AUTO_LENGTH,
                         NapiCancelSshAuthPrompt, nullptr, &fn);
    napi_set_named_property(env, exports, "cancelSshAuthPrompt", fn);
    napi_create_function(env, "getSshSessionSnapshot", NAPI_AUTO_LENGTH,
                         NapiGetSshSessionSnapshot, nullptr, &fn);
    napi_set_named_property(env, exports, "getSshSessionSnapshot", fn);
    napi_create_function(env, "getSshSessionEvents", NAPI_AUTO_LENGTH,
                         NapiGetSshSessionEvents, nullptr, &fn);
    napi_set_named_property(env, exports, "getSshSessionEvents", fn);

    napi_create_function(env, "configureSshForwarding", NAPI_AUTO_LENGTH,
                         NapiConfigureSshForwarding, nullptr, &fn);
    napi_set_named_property(env, exports, "configureSshForwarding", fn);
    napi_create_function(env, "removeSshForwarding", NAPI_AUTO_LENGTH,
                         NapiRemoveSshForwarding, nullptr, &fn);
    napi_set_named_property(env, exports, "removeSshForwarding", fn);
    napi_create_function(env, "startSshForwarding", NAPI_AUTO_LENGTH,
                         NapiStartSshForwarding, nullptr, &fn);
    napi_set_named_property(env, exports, "startSshForwarding", fn);
    napi_create_function(env, "markSshForwardingListening", NAPI_AUTO_LENGTH,
                         NapiMarkSshForwardingListening, nullptr, &fn);
    napi_set_named_property(env, exports, "markSshForwardingListening", fn);
    napi_create_function(env, "failSshForwarding", NAPI_AUTO_LENGTH,
                         NapiFailSshForwarding, nullptr, &fn);
    napi_set_named_property(env, exports, "failSshForwarding", fn);
    napi_create_function(env, "stopSshForwarding", NAPI_AUTO_LENGTH,
                         NapiStopSshForwarding, nullptr, &fn);
    napi_set_named_property(env, exports, "stopSshForwarding", fn);
    napi_create_function(env, "completeSshForwardingStop", NAPI_AUTO_LENGTH,
                         NapiCompleteSshForwardingStop, nullptr, &fn);
    napi_set_named_property(env, exports, "completeSshForwardingStop", fn);
    napi_create_function(env, "acquireSshForwardingConnection", NAPI_AUTO_LENGTH,
                         NapiAcquireSshForwardingConnection, nullptr, &fn);
    napi_set_named_property(env, exports, "acquireSshForwardingConnection", fn);
    napi_create_function(env, "releaseSshForwardingConnection", NAPI_AUTO_LENGTH,
                         NapiReleaseSshForwardingConnection, nullptr, &fn);
    napi_set_named_property(env, exports, "releaseSshForwardingConnection", fn);
    napi_create_function(env, "getSshForwardingSnapshots", NAPI_AUTO_LENGTH,
                         NapiGetSshForwardingSnapshots, nullptr, &fn);
    napi_set_named_property(env, exports, "getSshForwardingSnapshots", fn);

    napi_create_function(env, "onRustDeskNetworkChanged", NAPI_AUTO_LENGTH,
                         NapiOnRustDeskNetworkChanged, nullptr, &fn);
    napi_set_named_property(env, exports, "onRustDeskNetworkChanged", fn);

    napi_create_function(env, "submitRustDesk2FA", NAPI_AUTO_LENGTH,
                         NapiSubmitRustDesk2FA, nullptr, &fn);
    napi_set_named_property(env, exports, "submitRustDesk2FA", fn);

    napi_create_function(env, "getRemoteCursorSnapshot", NAPI_AUTO_LENGTH,
                         NapiGetRemoteCursorSnapshot, nullptr, &fn);
    napi_set_named_property(env, exports, "getRemoteCursorSnapshot", fn);
    napi_create_function(env, "getRemoteCursorSnapshotPixelsAsync", NAPI_AUTO_LENGTH,
                         NapiGetRemoteCursorSnapshotPixelsAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "getRemoteCursorSnapshotPixelsAsync", fn);

    napi_create_function(env, "getConnectionLastMessage", NAPI_AUTO_LENGTH,
                         NapiGetConnectionLastMessage, nullptr, &fn);
    napi_set_named_property(env, exports, "getConnectionLastMessage", fn);

    napi_create_function(env, "getRustDeskLastError", NAPI_AUTO_LENGTH,
                         NapiGetRustDeskLastError, nullptr, &fn);
    napi_set_named_property(env, exports, "getRustDeskLastError", fn);

    napi_create_function(env, "readData", NAPI_AUTO_LENGTH,
                         NapiReadData, nullptr, &fn);
    napi_set_named_property(env, exports, "readData", fn);

    napi_create_function(env, "getSshTerminalDiagnostics", NAPI_AUTO_LENGTH,
                         NapiGetSshTerminalDiagnostics, nullptr, &fn);
    napi_set_named_property(env, exports, "getSshTerminalDiagnostics", fn);

    napi_create_function(env, "execSshCommand", NAPI_AUTO_LENGTH,
                         NapiExecSshCommand, nullptr, &fn);
    napi_set_named_property(env, exports, "execSshCommand", fn);

    napi_create_function(env, "execSshCommandAsync", NAPI_AUTO_LENGTH,
                         NapiExecSshCommandAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "execSshCommandAsync", fn);

    napi_create_function(env, "execSshSubsystem", NAPI_AUTO_LENGTH,
                         NapiExecSshSubsystem, nullptr, &fn);
    napi_set_named_property(env, exports, "execSshSubsystem", fn);

    napi_create_function(env, "execSshSubsystemAsync", NAPI_AUTO_LENGTH,
                         NapiExecSshSubsystemAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "execSshSubsystemAsync", fn);

    napi_create_function(env, "sendSshSignal", NAPI_AUTO_LENGTH,
                         NapiSendSshSignal, nullptr, &fn);
    napi_set_named_property(env, exports, "sendSshSignal", fn);

    napi_create_function(env, "sendSshEof", NAPI_AUTO_LENGTH,
                         NapiSendSshEof, nullptr, &fn);
    napi_set_named_property(env, exports, "sendSshEof", fn);

    napi_create_function(env, "resizePty", NAPI_AUTO_LENGTH,
                         NapiResizePty, nullptr, &fn);
    napi_set_named_property(env, exports, "resizePty", fn);

    napi_create_function(env, "measureSshLatency", NAPI_AUTO_LENGTH,
                         NapiMeasureSshLatency, nullptr, &fn);
    napi_set_named_property(env, exports, "measureSshLatency", fn);

    napi_create_function(env, "measureSshLatencyAsync", NAPI_AUTO_LENGTH,
                         NapiMeasureSshLatencyAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "measureSshLatencyAsync", fn);

    napi_create_function(env, "setOnDataCallback", NAPI_AUTO_LENGTH,
                         NapiSetOnDataCallback, nullptr, &fn);
    napi_set_named_property(env, exports, "setOnDataCallback", fn);

    napi_create_function(env, "detachSshSession", NAPI_AUTO_LENGTH,
                         NapiDetachSshSession, nullptr, &fn);
    napi_set_named_property(env, exports, "detachSshSession", fn);

    napi_create_function(env, "resumeSshSession", NAPI_AUTO_LENGTH,
                         NapiResumeSshSession, nullptr, &fn);
    napi_set_named_property(env, exports, "resumeSshSession", fn);

    napi_create_function(env, "setHelperSocketPath", NAPI_AUTO_LENGTH,
                         NapiSetHelperSocketPath, nullptr, &fn);
    napi_set_named_property(env, exports, "setHelperSocketPath", fn);

    napi_create_function(env, "requestFrameRefresh", NAPI_AUTO_LENGTH,
                         NapiRequestFrameRefresh, nullptr, &fn);
    napi_set_named_property(env, exports, "requestFrameRefresh", fn);

    napi_create_function(env, "isVideoPlaybackActive", NAPI_AUTO_LENGTH,
                         NapiIsVideoPlaybackActive, nullptr, &fn);
    napi_set_named_property(env, exports, "isVideoPlaybackActive", fn);

    napi_create_function(env, "bindRendererToSession", NAPI_AUTO_LENGTH,
                         NapiBindRendererToSession, nullptr, &fn);
    napi_set_named_property(env, exports, "bindRendererToSession", fn);

    // SSH 密钥工具
    napi_create_function(env, "generateSshKeyPair", NAPI_AUTO_LENGTH,
                         NapiGenerateSshKeyPair, nullptr, &fn);
    napi_set_named_property(env, exports, "generateSshKeyPair", fn);

    napi_create_function(env, "inspectSshPrivateKey", NAPI_AUTO_LENGTH,
                         NapiInspectSshPrivateKey, nullptr, &fn);
    napi_set_named_property(env, exports, "inspectSshPrivateKey", fn);

    napi_create_function(env, "changeSshPrivateKeyPassphrase", NAPI_AUTO_LENGTH,
                         NapiChangeSshPrivateKeyPassphrase, nullptr, &fn);
    napi_set_named_property(env, exports, "changeSshPrivateKeyPassphrase", fn);

    napi_create_function(env, "validatePublicKeyForAuthorizedKeys", NAPI_AUTO_LENGTH,
                         NapiValidatePublicKeyForAuthorizedKeys, nullptr, &fn);
    napi_set_named_property(env, exports, "validatePublicKeyForAuthorizedKeys", fn);

    // SSH 远端安装/测试
    napi_create_function(env, "installSshPublicKey", NAPI_AUTO_LENGTH,
                         NapiInstallSshPublicKey, nullptr, &fn);
    napi_set_named_property(env, exports, "installSshPublicKey", fn);

    napi_create_function(env, "testSshKeyAuth", NAPI_AUTO_LENGTH,
                         NapiTestSshKeyAuth, nullptr, &fn);
    napi_set_named_property(env, exports, "testSshKeyAuth", fn);

    napi_create_function(env, "testSshKeyAuthAsync", NAPI_AUTO_LENGTH,
                         NapiTestSshKeyAuthAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "testSshKeyAuthAsync", fn);

    napi_create_function(env, "probeSshHostKey", NAPI_AUTO_LENGTH,
                         NapiProbeSshHostKey, nullptr, &fn);
    napi_set_named_property(env, exports, "probeSshHostKey", fn);

    napi_create_function(env, "probeSshHostKeyAsync", NAPI_AUTO_LENGTH,
                         NapiProbeSshHostKeyAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "probeSshHostKeyAsync", fn);

    OH_LOG_INFO(LOG_APP, "[ExtLoader] NAPI 方法已注册: ... probeSshHostKeyAsync");
    return exports;
}
