/**
 * extension_loader_napi.cpp — 扩展加载器 NAPI 桥接
 *
 * 将 ExtensionSystem 暴露给 ArkTS 层。
 * ArkTS 通过此模块查询已注册的协议适配器、建立连接、发送输入。
 */

#include "extension_registry.h"
#include "protocol_adapter.h"
#include "session_teardown_executor.h"
#include "rdp/freerdp_adapter.h"
#include "rdp/rdp_auth_mode_policy.h"
#include "ssh/ssh_adapter.h"
#include "ssh/ssh_key_tool.h"
#include "audio/input_handler.h"
#include "audio/audio_player.h"
#include "common/safe_log.h"
#include "render/hw_decoder.h"
#include "render/gl_renderer.h"
#include "render/video_perf_counters.h"
#include "video/video_activity_state.h"
#include "rustdesk/rustdesk_bridge.h"
#include "vnc/vnc_rfb_protocol.h"
#include <napi/native_api.h>
#include <hilog/log.h>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <algorithm>
#include <cctype>
#include <atomic>
#include <chrono>
#include <cstring>
#include <condition_variable>
#include <deque>
#include <exception>
#include <fstream>
#include <new>
#include <sstream>
#include <stdexcept>
#include <vector>
#include <unistd.h>

#ifdef RUSTDESK_USE_REAL_CORE
extern "C" {
    size_t rustdesk_last_error(char* buffer, size_t buffer_len);
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
        for (std::string& response : config.sshKeyboardInteractiveResponses) {
            secureClearString(response);
        }
        config.sshKeyboardInteractiveResponses.clear();
    }
};

} // namespace

// ============================================================
// 全局状态
// ============================================================

// 当前活跃连接
static std::shared_ptr<ProtocolAdapter> g_activeConnection = nullptr;
static std::mutex g_activeConnectionMutex;

static void ActivateSessionContext(
    const std::shared_ptr<ProtocolAdapter>& adapter, uint64_t sessionId) {
    std::lock_guard<std::mutex> lock(g_activeConnectionMutex);
    g_activeConnection = adapter;
    DecoderNapi::SetActiveSessionId(sessionId);
    InputHandler::instance().setActiveAdapter(adapter);
}

static bool DeactivateSessionContextIfActive(
    const std::shared_ptr<ProtocolAdapter>& adapter, uint64_t sessionId) {
    std::lock_guard<std::mutex> lock(g_activeConnectionMutex);
    if (g_activeConnection != adapter) {
        return false;
    }
    DecoderNapi::ClearActiveSessionId(sessionId);
    InputHandler::instance().setActiveAdapter(nullptr);
    g_activeConnection = nullptr;
    return true;
}

static void DeactivateAllSessionContexts() {
    std::lock_guard<std::mutex> lock(g_activeConnectionMutex);
    g_activeConnection = nullptr;
    InputHandler::instance().setActiveAdapter(nullptr);
}

static std::shared_ptr<ProtocolAdapter> GetActiveSessionAdapter() {
    std::lock_guard<std::mutex> lock(g_activeConnectionMutex);
    return g_activeConnection;
}

struct SessionDiagnosticsCounters {
    std::atomic<uint64_t> ingressFrames {0};
    std::atomic<uint64_t> ingressBytes {0};
    std::atomic<uint64_t> keyframes {0};
    std::atomic<uint64_t> presentedFrames {0};
    std::atomic<uint64_t> presentationRejected {0};
    std::atomic<uint64_t> decodeOk {0};
    std::atomic<uint64_t> decodeErrors {0};
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
        ingressBytes.store(0, std::memory_order_release);
        keyframes.store(0, std::memory_order_release);
        presentedFrames.store(0, std::memory_order_release);
        presentationRejected.store(0, std::memory_order_release);
        decodeOk.store(0, std::memory_order_release);
        decodeErrors.store(0, std::memory_order_release);
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
    std::string lastStateMessage;
    std::mutex messageMutex;
    std::atomic<Lifecycle> lifecycle {Lifecycle::Active};
    std::atomic<uint64_t> teardownRequestId {0};
    SessionDiagnosticsCounters diagnostics;
    std::string vncConnectionPath = "unknown";
    std::string vncRequestedColorDepth = "auto";
};

static std::map<int, std::shared_ptr<SessionContext>> g_sessions;
static std::map<int, uint64_t> g_disconnectRequestBySession;
static SessionTeardown::Executor g_teardownExecutor;
static uint64_t g_disconnectAllRequestId = 0;
static int g_nextSessionId = 1;
static std::atomic<int> g_pendingSshConnectId {-1};
static std::atomic<uint64_t> g_napiWheelSendCount {0};
static std::atomic<uint64_t> g_napiTextSendCount {0};
static std::atomic<uint64_t> g_napiFileSendCount {0};
static std::atomic<uint64_t> g_napiKeySendCount {0};
static std::atomic<uint64_t> g_napiMouseSendCount {0};
static Render::VideoPerfCounters g_rustdeskVideoPerf;

// SSH 推送回调的 TSFN 映射 (sessionId → registration). 由 setOnDataCallback /
// disconnect 维护。registration 先停止生产者，再释放 TSFN，避免 reader 线程
// 在 N-API handle 已释放后仍调用 napi_call_threadsafe_function。
struct SshDataTsfnRegistration {
    napi_threadsafe_function tsfn = nullptr;
    std::atomic<bool> accepting {true};
    std::mutex waitMutex;
    std::condition_variable waitCondition;
};
static std::map<int, std::shared_ptr<SshDataTsfnRegistration>> g_dataTsfnMap;
static std::mutex g_dataTsfnMutex;

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

static std::string GetNapiString(napi_env env, napi_value value) {
    size_t len = 0;
    napi_status status = napi_get_value_string_utf8(env, value, nullptr, 0, &len);
    if (status != napi_ok) {
        return "";
    }
    std::vector<char> buffer(len + 1, '\0');
    size_t copied = 0;
    status = napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &copied);
    if (status != napi_ok) {
        return "";
    }
    return std::string(buffer.data(), copied);
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

static napi_value CreateRdpCertificateInfoValue(napi_env env, const RdpCertificateInfo& cert) {
    napi_value result;
    napi_create_object(env, &result);
    SetObjectBool(env, result, "ok", cert.ok);
    SetObjectString(env, result, "host", cert.host);
    SetObjectInt32(env, result, "port", cert.port);
    SetObjectString(env, result, "commonName", cert.commonName);
    SetObjectString(env, result, "subject", cert.subject);
    SetObjectString(env, result, "issuer", cert.issuer);
    SetObjectString(env, result, "fingerprintSha256", cert.fingerprintSha256);
    SetObjectInt32(env, result, "flags", cert.flags);
    SetObjectBool(env, result, "rootTrusted", cert.rootTrusted);
    SetObjectBool(env, result, "hostMismatch", cert.hostMismatch);
    SetObjectInt32(env, result, "errorCode", cert.errorCode);
    SetObjectString(env, result, "errorMessage", cert.errorMessage);
    return result;
}

// ============================================================
// NAPI 导出函数 (ArkTS 可见)
// ============================================================

/**
 * NAPI: listProtocols(): Array<{name: string, port: number, version: string}>
 *
 * 列出所有已注册的远程协议适配器
 */
napi_value NapiListProtocols(napi_env env, napi_callback_info info) {
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
    if (argc > 0) {
        host = GetNapiString(env, args[0]);
    }
    if (argc > 1) {
        napi_get_value_int32(env, args[1], &port);
    }
    if (argc > 2) {
        serverName = GetNapiString(env, args[2]);
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

    if (argc > 0) {
        data->host = GetNapiString(env, args[0]);
    }
    if (argc > 1) {
        napi_get_value_int32(env, args[1], &data->port);
    }
    if (argc > 2) {
        data->serverName = GetNapiString(env, args[2]);
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) {
        stats = it->second->adapter->getRdpRenderStats();
    }

    napi_value result;
    napi_create_object(env, &result);
    SetObjectInt32(env, result, "paintCount", stats.paintCount);
    SetObjectInt32(env, result, "renderedPaintCount", stats.renderedPaintCount);
    SetObjectInt64(env, result, "firstPaintMs", stats.firstPaintMs);
    SetObjectInt64(env, result, "lastPaintMs", stats.lastPaintMs);
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
    SetObjectInt32(env, result, "inputQueueDepth", stats.inputQueueDepth);
    SetObjectInt32(env, result, "inputQueueMax", stats.inputQueueMax);
    SetObjectInt64(env, result, "inputTextUnits", stats.inputTextUnits);
    SetObjectInt64(env, result, "inputDroppedMouseMoves", stats.inputDroppedMouseMoves);
    SetObjectInt64(env, result, "inputNonDisposableOverflow", stats.inputNonDisposableOverflow);
    SetObjectString(env, result, "graphicsMode", stats.graphicsMode);
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
    SessionDiagnosticsCounters* counters = nullptr;
    bool sessionActive = false;
    bool vncSession = false;
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second) {
        counters = &it->second->diagnostics;
        if (it->second->protocolName == "rustdesk" && it->second->adapter) {
            sessionActive = true;
            auto* bridge = dynamic_cast<RustDeskBridge*>(it->second->adapter.get());
            if (bridge) {
                nativeStats = bridge->getDiagnostics();
            }
        }
        if (it->second->protocolName == "vnc" && it->second->adapter) {
            sessionActive = true;
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
    }

    const uint64_t nowMs = static_cast<uint64_t>(std::chrono::duration_cast<
        std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
    DecoderTelemetrySnapshot decoder = DecoderNapi::GetActiveTelemetry(
        static_cast<uint64_t>(sessionId > 0 ? sessionId : 0));
    const RdpPresentationMetricsSnapshot renderer = RendererNapi::GetActivePresentationStats();
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
    SetObjectInt32(env, result, "sessionId", sessionId);
    SetObjectInt32(env, result, "latencyMs", nativeStats.latencyMs);
    SetObjectInt32(env, result, "targetBitrateKbps", nativeStats.targetBitrateKbps);
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
    SetObjectString(env, result, "connectionPath", vncSession && it != g_sessions.end() ?
        it->second->vncConnectionPath :
        (nativeStats.connectionPath == 1 ? "direct" : (nativeStats.supported ? "relay" : "unknown")));
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
    SetObjectString(env, result, "requestedColorDepth", vncSession && it != g_sessions.end() ?
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
    SetObjectInt64(env, result, "droppedFrames", static_cast<int64_t>(decoder.droppedFrames));
    const int sourceEncoding = counters ?
        counters->sourceEncoding.load(std::memory_order_acquire) : -1;
    const std::string vncBackend = sourceEncoding == VncRfbProtocol::kZrleEncoding ? "ZRLE" :
        (sourceEncoding == VncRfbProtocol::kCopyRectEncoding ? "CopyRect" :
         (sourceEncoding == VncRfbProtocol::kRawEncoding ? "RAW" : "等待服务器"));
    SetObjectString(env, result, "decoderBackend", vncSession ? vncBackend :
        (decoder.valid && decoder.ready ? (decoder.software ? "software" : "hardware") : "unknown"));
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) {
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second && it->second->adapter &&
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second && it->second->adapter &&
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
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // 解析 config 对象
    ConnectionConfig cfg;
    SshSecretGuard sshSecretGuard { cfg };

    auto getString = [&](const char* key, std::string& out) {
        napi_value val;
        if (napi_get_named_property(env, args[0], key, &val) == napi_ok) {
            napi_valuetype type = napi_undefined;
            napi_typeof(env, val, &type);
            if (type != napi_string) {
                return;
            }
            size_t len = 0;
            if (napi_get_value_string_utf8(env, val, nullptr, 0, &len) != napi_ok) {
                return;
            }
            std::vector<char> buf(len + 1, 0);
            if (napi_get_value_string_utf8(env, val, buf.data(), buf.size(), &len) == napi_ok) {
                out.assign(buf.data(), len);
            }
        }
    };
    auto getInt = [&](const char* key, int& out) {
        napi_value val;
        if (napi_get_named_property(env, args[0], key, &val) == napi_ok) {
            napi_get_value_int32(env, val, &out);
        }
    };
    auto getBool = [&](const char* key, bool& out) {
        napi_value val;
        if (napi_get_named_property(env, args[0], key, &val) == napi_ok) {
            napi_get_value_bool(env, val, &out);
        }
    };

    std::string protocolName;
    getString("protocol", protocolName);
    getString("host", cfg.host);
    getInt("port", cfg.port);
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
    getString("customHostname", cfg.customHostname);
    getString("gatewayHost", cfg.gatewayHost);
    getInt("gatewayPort", cfg.gatewayPort);
    getInt("monitorCount", cfg.monitorCount);
    napi_value multiMonVal;
    if (napi_get_named_property(env, args[0], "multiMonitor", &multiMonVal) == napi_ok) {
        napi_get_value_bool(env, multiMonVal, &cfg.multiMonitor);
    }
    getInt("colorDepth", cfg.colorDepth);
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
    if (protocolName == "ssh") {
        getString("sshProxyType", cfg.sshProxyType);
        getString("sshProxyHost", cfg.sshProxyHost);
        getInt("sshProxyPort", cfg.sshProxyPort);
        getString("sshProxyUsername", cfg.sshProxyUsername);
        getString("sshProxyPassword", cfg.sshProxyPassword);
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
                    std::string response = GetNapiString(env, responseItem);
                    if (response.size() > 4096) {
                        secureClearString(response);
                        continue;
                    }
                    cfg.sshKeyboardInteractiveResponses.push_back(std::move(response));
                }
            }
        }
    }
    if (cfg.authMethod.empty()) cfg.authMethod = "password";

    // RustDesk 扩展配置
    getInt("rdImageQuality", cfg.rdImageQuality);
    getBool("rdDirectIp", cfg.rdDirectIp);
    getInt("rdDirectPort", cfg.rdDirectPort);
    getBool("rdLanDiscovery", cfg.rdLanDiscovery);
    getBool("rdPrivacyMode", cfg.rdPrivacyMode);
    getBool("rdAudioEnabled", cfg.rdAudioEnabled);
    getBool("rdClipboardEnabled", cfg.rdClipboardEnabled);
    getString("rdDriveName", cfg.rdDriveName);
    getString("rdDrivePath", cfg.rdDrivePath);
    getString("expectedRdpCertificateFingerprintSha256", cfg.expectedRdpCertificateFingerprintSha256);
    getBool("rdpAllowUntrustedRoot", cfg.rdpAllowUntrustedRoot);
    getBool("rdpAllowHostMismatch", cfg.rdpAllowHostMismatch);
    getInt("rdPasswordMode", cfg.rdPasswordMode);
    getInt("rdAuthMode", cfg.rdAuthMode);
    getInt("rdPasswordLength", cfg.rdPasswordLength);
    getString("rdRelayId", cfg.rdRelayId);
    getString("rdAccountId", cfg.rdAccountId);
    getString("rdServerKey", cfg.rdServerKey);
    getInt("rdServerKeyMode", cfg.rdServerKeyMode);
    getInt("rdRelayPort", cfg.rdRelayPort);
    getString("rdAccessToken", cfg.rdAccessToken);

    // VNC-only connection contract. These values are assembled from the
    // isolated VNC data domain and are ignored by the other adapters.
    getString("vncTransport", cfg.vncTransport);
    getString("vncGatewayHost", cfg.vncGatewayHost);
    getInt("vncGatewayPort", cfg.vncGatewayPort);
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

    if (cfg.rdDirectPort <= 0) cfg.rdDirectPort = 21118;
    if (cfg.port == 0) {
        // RustDesk 的通用端口字段在直连模式代表 peer TCP 端口；
        // 非直连模式才代表 ID/rendezvous 端口，不能落回 RDP 3389。
        if (protocolName == "rustdesk") {
            cfg.port = cfg.rdDirectIp ? cfg.rdDirectPort : 21116;
        } else if (protocolName == "vnc") {
            cfg.port = 5900;
        } else {
            cfg.port = 3389;
        }
    }
    if (cfg.width == 0) cfg.width = 1920;
    if (cfg.height == 0) cfg.height = 1080;
    if (cfg.gatewayPort == 0) cfg.gatewayPort = 443;
    if (cfg.colorDepth == 0) cfg.colorDepth = 32;
    if (cfg.rdImageQuality < 0 || cfg.rdImageQuality > 2) cfg.rdImageQuality = 1;
    if (cfg.rdPasswordMode != 1) cfg.rdPasswordMode = 0;
    if (cfg.rdAuthMode != 1) cfg.rdAuthMode = 0;
    if (cfg.rdPasswordLength != 8 && cfg.rdPasswordLength != 10) cfg.rdPasswordLength = 6;
    if (cfg.rdServerKeyMode != 1 && cfg.rdServerKeyMode != 2) cfg.rdServerKeyMode = 0;
    if (cfg.rdRelayPort <= 0 || cfg.rdRelayPort > 65535) cfg.rdRelayPort = 21117;
    if (cfg.vncTransport.empty()) cfg.vncTransport = "direct_tcp";
    if (cfg.vncGatewayPath.empty()) cfg.vncGatewayPath = "/vnc";
    // An omitted mode gets the only viewer mode we currently support. An
    // explicitly unknown mode is preserved so policy/Native reject it
    // instead of silently changing the requested repeater role.
    if (cfg.vncRepeaterMode.empty()) cfg.vncRepeaterMode = "mode12";
    if (cfg.vncGatewayPort <= 0 || cfg.vncGatewayPort > 65535) cfg.vncGatewayPort = 5901;
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

    const std::string logHost = SafeLog::MaskHost(cfg.host);
    const std::string logGatewayHost = cfg.gatewayHost.empty() ? "无" : SafeLog::MaskHost(cfg.gatewayHost);
    const std::string logCustomHostname = cfg.customHostname.empty() ? "未设置" : SafeLog::MaskHost(cfg.customHostname);

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
        OH_LOG_INFO(LOG_APP, "[ExtLoader] RustDesk配置: quality=%{public}d direct=%{public}s:%{public}d lan=%{public}s privacy=%{public}s audio=%{public}s pwdMode=%{public}d authMode=%{public}d pwdLen=%{public}d relayId=%{public}s account=%{public}s serverKeyMode=%{public}s relayFallbackPort=%{public}d proToken=%{public}s",
                    cfg.rdImageQuality, cfg.rdDirectIp ? "on" : "off", cfg.rdDirectPort,
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
    adapter->setSessionIdentity(static_cast<uint64_t>(sessionId));
    g_disconnectAllRequestId = 0;
    if (g_disconnectRequestBySession.size() > 256) {
        for (auto it = g_disconnectRequestBySession.begin();
             it != g_disconnectRequestBySession.end();) {
            const SessionTeardown::State state = g_teardownExecutor.state(it->second);
            if (state == SessionTeardown::State::Complete ||
                state == SessionTeardown::State::Failed ||
                state == SessionTeardown::State::Unknown) {
                it = g_disconnectRequestBySession.erase(it);
            } else {
                ++it;
            }
        }
    }
    g_sessions[sessionId] = session;
    const bool deferSshActivation = protocolName == "ssh";
    if (!deferSshActivation) {
        // R0: existing desktop protocols keep their established activation
        // order for compatibility. SSH commits the same context only after
        // its synchronous connect succeeds below.
        ActivateSessionContext(adapter, static_cast<uint64_t>(sessionId));
    }

    const std::weak_ptr<SessionContext> weakSession = session;
    adapter->setConnectionStateCallback([weakSession](ConnectionState state, const std::string& message) {
        const std::shared_ptr<SessionContext> session = weakSession.lock();
        if (!session) { return; }
        std::lock_guard<std::mutex> lock(session->messageMutex);
        session->lastStateMessage = message;
        OH_LOG_INFO(LOG_APP, "[ExtLoader] 状态变更: protocol=%{public}s state=%{public}d msg=%{public}s",
                    session->protocolName.c_str(), static_cast<int>(state), message.c_str());
    });

    if (auto* rustdesk = dynamic_cast<RustDeskBridge*>(adapter.get())) {
        rustdesk->setDisplayStateCallback([](int display) {
            // RustDesk invokes this before its stream thread starts. The
            // decoder therefore knows the peer's current display before any
            // interleaved display frame can arrive.
            if (DecoderNapi::SetActiveDisplay(display)) {
                DecoderNapi::RequestActiveDecoderRecovery();
            }
        });
    }

    adapter->setVideoCallback([session](const VideoFrame& frame) {
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
            RendererNapi::SetActiveSourceSize(frame.width, frame.height);
            const RdpPresentationTarget target = RendererNapi::GetActivePresentationTarget();
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
                    frame.data, frame.size, frame.width, frame.height, frame.stride,
                    frame.dirtyX, frame.dirtyY, frame.dirtyWidth, frame.dirtyHeight,
                    target.generation);
            } else {
                present = RendererNapi::PresentRawBgraActive(
                    frame.data, frame.size, frame.width, frame.height, frame.stride,
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
            if (frameNumber <= 8 || frameNumber % 60 == 0 || !present.presented()) {
                OH_LOG_INFO(LOG_APP,
                            "[ExtLoader][VNC-DIAG] raw frame presented count=%{public}llu size=%{public}zu framebuffer=%{public}dx%{public}d dirty=%{public}d,%{public}d %{public}dx%{public}d generation=%{public}llu result=%{public}d",
                            static_cast<unsigned long long>(frameNumber), frame.size, frame.width, frame.height,
                            frame.dirtyX, frame.dirtyY, frame.dirtyWidth, frame.dirtyHeight,
                            static_cast<unsigned long long>(target.generation),
                            static_cast<int>(present.result));
            }
            return;
        }
        static uint64_t frameCount = 0;
        static std::atomic<uint64_t> decodeRetOk {0};
        static std::atomic<uint64_t> decodeRetNotReady {0};
        static std::atomic<uint64_t> decodeRetBadCodec {0};
        static std::atomic<uint64_t> decodeRetMismatch {0};
        static std::atomic<uint64_t> decodeRetOther {0};
        static std::atomic<uint64_t> inactiveDisplayFrames {0};
        if (!DecoderNapi::IsActiveDisplayFrame(frame)) {
            const uint64_t dropped = inactiveDisplayFrames.fetch_add(1, std::memory_order_relaxed) + 1;
            if (dropped <= 8 || dropped % 300 == 0) {
                OH_LOG_INFO(LOG_APP,
                    "[ExtLoader] drop inactive RustDesk display before render display=%{public}d total=%{public}llu",
                    frame.display,
                    static_cast<unsigned long long>(dropped));
            }
            return;
        }
        if (frame.width > 0 && frame.height > 0) {
            RendererNapi::SetActiveSourceSize(frame.width, frame.height);
        }
        session->diagnostics.ingressFrames.fetch_add(1, std::memory_order_relaxed);
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
        g_rustdeskVideoPerf.recordIngressFrame("rustdesk", frame.width, frame.height,
                                               frame.size, frame.isKeyFrame);
        const auto decodeStartedAt = std::chrono::steady_clock::now();
        int ret = DecoderNapi::DecodeActiveNative(frame);
        const int64_t decodeElapsedUs = std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - decodeStartedAt).count();
        if (ret == DecoderNapi::kDecodeInactiveDisplay) {
            return;
        }
        session->diagnostics.addDecodeSample(decodeElapsedUs);
        if (ret == 0) {
            session->diagnostics.decodeOk.fetch_add(1, std::memory_order_relaxed);
        } else {
            session->diagnostics.decodeErrors.fetch_add(1, std::memory_order_relaxed);
        }
        g_rustdeskVideoPerf.recordDecodeResult(ret, 0, 0, 0);
        frameCount++;
        switch (ret) {
            case 0: decodeRetOk.fetch_add(1); break;
            case -1: decodeRetNotReady.fetch_add(1); break;
            case -2: decodeRetBadCodec.fetch_add(1); break;
            case -3: decodeRetMismatch.fetch_add(1); break;
            default: if (ret < 0) decodeRetOther.fetch_add(1); break;
        }
        if (frameCount % 30 == 0) {
            const std::shared_ptr<ProtocolAdapter> activeConnection = GetActiveSessionAdapter();
            if (activeConnection) {
                activeConnection->reportVideoPressure(DecoderNapi::ActiveVideoPressureLevel());
            }
        }
        if (frameCount <= 3 || frameCount % 300 == 0 || ret != 0) {
            Render::VideoPerfSnapshot perf = g_rustdeskVideoPerf.snapshotAndReset();
            Render::VideoPressureLevel pressure = Render::classifyVideoPressure(perf);
            OH_LOG_INFO(LOG_APP,
                "[ExtLoader] video callback #%{public}llu codec=%{public}d frame=%{public}dx%{public}d size=%{public}zu key=%{public}s decodeRet=%{public}d hist[ok=%{public}llu nrdy=%{public}llu bad=%{public}llu mism=%{public}llu other=%{public}llu] perf[ingress=%{public}llu decodeOk=%{public}llu notReady=%{public}llu mismatch=%{public}llu render=%{public}llu pressure=%{public}s bytes=%{public}llu]",
                static_cast<unsigned long long>(frameCount),
                static_cast<int>(frame.codec),
                frame.width,
                frame.height,
                frame.size,
                frame.isKeyFrame ? "yes" : "no",
                ret,
                static_cast<unsigned long long>(decodeRetOk.load()),
                static_cast<unsigned long long>(decodeRetNotReady.load()),
                static_cast<unsigned long long>(decodeRetBadCodec.load()),
                static_cast<unsigned long long>(decodeRetMismatch.load()),
                static_cast<unsigned long long>(decodeRetOther.load()),
                static_cast<unsigned long long>(perf.ingressFrames),
                static_cast<unsigned long long>(perf.decodeOk),
                static_cast<unsigned long long>(perf.decodeNotReady),
                static_cast<unsigned long long>(perf.decodeMismatch),
                static_cast<unsigned long long>(perf.renderFrames),
                Render::videoPressureName(pressure),
                static_cast<unsigned long long>(perf.bytesTotal));
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
        adapter->setAudioCallback([](const AudioData& data) {
            static uint64_t audioCount = 0;
            audioCount++;
            int ret = AudioPlayerNapi::DispatchActiveNative(
                data.data, data.size, data.sampleRate, data.channels);
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
        if (auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(adapter)) {
            sshAdapter->setConnectionStateCallback(nullptr);
            sshAdapter->disconnect();
        }
        g_sessions.erase(sessionId);
        DeactivateSessionContextIfActive(adapter, static_cast<uint64_t>(sessionId));
        napi_value errVal;
        napi_create_int32(env, ret, &errVal);  // 传递真实错误码而非通用 -2
        return errVal;
    }

    OH_LOG_INFO(LOG_APP, "[ExtLoader] 连接成功, sessionId=%{public}d", sessionId);
    if (deferSshActivation) {
        ActivateSessionContext(adapter, static_cast<uint64_t>(sessionId));
    }

    napi_value result;
    napi_create_int32(env, sessionId, &result);
    return result;
}

static void ClearSshConnectionSecrets(ConnectionConfig& config) {
    secureClearString(config.password);
    secureClearString(config.privateKeyPem);
    secureClearString(config.privateKeyPassphrase);
    secureClearString(config.sshProxyPassword);
    for (std::string& response : config.sshKeyboardInteractiveResponses) {
        secureClearString(response);
    }
    config.sshKeyboardInteractiveResponses.clear();
}

static bool ParseSshConnectionConfig(napi_env env, napi_value value,
                                      ConnectionConfig& config) {
    napi_valuetype valueType = napi_undefined;
    if (value == nullptr || napi_typeof(env, value, &valueType) != napi_ok ||
        valueType != napi_object) {
        return false;
    }

    auto getString = [&](const char* key, std::string& out) {
        napi_value item;
        if (napi_get_named_property(env, value, key, &item) != napi_ok) { return; }
        napi_valuetype type = napi_undefined;
        if (napi_typeof(env, item, &type) != napi_ok || type != napi_string) { return; }
        out = GetNapiString(env, item);
    };
    auto getInt = [&](const char* key, int& out, bool* present = nullptr) {
        napi_value item;
        if (napi_get_named_property(env, value, key, &item) != napi_ok) { return; }
        if (present != nullptr) { *present = true; }
        napi_get_value_int32(env, item, &out);
    };

    std::string protocol;
    getString("protocol", protocol);
    if (protocol != "ssh") { return false; }
    getString("host", config.host);
    bool hasPort = false;
    getInt("port", config.port, &hasPort);
    getString("username", config.username);
    getString("password", config.password);
    getInt("width", config.width);
    getInt("height", config.height);
    getString("authMethod", config.authMethod);
    getString("privateKeyPem", config.privateKeyPem);
    getString("privateKeyPassphrase", config.privateKeyPassphrase);
    getString("expectedHostKeyRawBase64", config.expectedHostKeyRawBase64);
    getString("expectedHostKeyFingerprintSha256", config.expectedHostKeyFingerprintSha256);
    getString("sshProxyType", config.sshProxyType);
    getString("sshProxyHost", config.sshProxyHost);
    getInt("sshProxyPort", config.sshProxyPort);
    getString("sshProxyUsername", config.sshProxyUsername);
    getString("sshProxyPassword", config.sshProxyPassword);

    // Keep the legacy generic gateway fail-closed behavior identical to the
    // synchronous connect path; never silently turn it into a direct socket.
    std::string gatewayHost;
    int gatewayPort = 0;
    getString("gatewayHost", gatewayHost);
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
                std::string response = GetNapiString(env, item);
                if (response.size() > 4096) {
                    secureClearString(response);
                    continue;
                }
                config.sshKeyboardInteractiveResponses.push_back(std::move(response));
            }
        }
    }

    if (config.host.empty() || config.username.empty()) { return false; }
    if (!hasPort) { config.port = 22; }
    if (config.port <= 0 || config.port > 65535) { return false; }
    if (config.width <= 0) { config.width = 80; }
    if (config.height <= 0) { config.height = 24; }
    if (config.authMethod.empty()) { config.authMethod = "password"; }
    if (config.sshProxyType.empty()) {
        config.sshProxyType = config.sshProxyHost.empty() ? "direct" : "http_connect";
    }
    return true;
}

struct SshConnectAsyncData {
    int sessionId = -1;
    std::shared_ptr<SshAdapter> adapter;
    std::shared_ptr<SessionContext> session;
    ConnectionConfig config;
    int resultCode = ERR_SSH_SESSION_INIT;
    bool workerFailed = false;
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
    auto it = g_sessions.find(data.sessionId);
    if (it != g_sessions.end() && (!data.session || it->second == data.session)) {
        g_sessions.erase(it);
    }
    DeactivateSessionContextIfActive(
        data.adapter, static_cast<uint64_t>(std::max(data.sessionId, 0)));
    if (data.adapter) {
        data.adapter->setConnectionStateCallback(nullptr);
        data.adapter->disconnect();
    }
}

static bool RegisterSshConnectSession(SshConnectAsyncData& data) {
    data.adapter = std::make_shared<SshAdapter>();
    if (!data.adapter) { return false; }
    data.session = std::shared_ptr<SessionContext>(new (std::nothrow) SessionContext());
    if (!data.session) {
        data.adapter.reset();
        return false;
    }
    data.session->adapter = data.adapter;
    data.session->protocolName = "ssh";
    data.sessionId = g_nextSessionId++;
    data.adapter->setSessionIdentity(static_cast<uint64_t>(data.sessionId));
    g_sessions[data.sessionId] = data.session;

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
    int expectedSessionId = data->sessionId;
    g_pendingSshConnectId.compare_exchange_strong(
        expectedSessionId, -1, std::memory_order_acq_rel);
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
        ActivateSessionContext(data->adapter, static_cast<uint64_t>(data->sessionId));
        napi_value result;
        napi_create_int32(env, data->sessionId, &result);
        napi_resolve_deferred(env, data->deferred, result);
    }
    napi_delete_async_work(env, data->work);
    delete data;
}

/** NAPI: getPendingSshConnectId(): number */
napi_value NapiGetPendingSshConnectId(napi_env env, napi_callback_info /*info*/) {
    napi_value result;
    napi_create_int32(env, g_pendingSshConnectId.load(std::memory_order_acquire), &result);
    return result;
}

/** NAPI: connectSshAsync(config: SessionConfig): Promise<number> */
napi_value NapiConnectSshAsync(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "SSH config is required");
        return nullptr;
    }
    if (g_pendingSshConnectId.load(std::memory_order_acquire) > 0) {
        napi_throw_error(env, nullptr, "SSH connection already in progress");
        return nullptr;
    }

    ConnectionConfig config;
    SshSecretGuard secretGuard {config};
    if (!ParseSshConnectionConfig(env, args[0], config)) {
        napi_throw_type_error(env, nullptr, "invalid SSH connection config");
        return nullptr;
    }

    auto* data = new (std::nothrow) SshConnectAsyncData();
    if (data == nullptr) {
        napi_throw_error(env, nullptr, "SSH async connect allocation failed");
        return nullptr;
    }
    data->config = std::move(config);
    if (!RegisterSshConnectSession(*data)) {
        delete data;
        napi_throw_error(env, nullptr, "SSH async session allocation failed");
        return nullptr;
    }

    napi_value promise;
    napi_status status = napi_create_promise(env, &data->deferred, &promise);
    if (status != napi_ok) {
        CleanupSshConnectFailure(*data);
        delete data;
        napi_throw_error(env, nullptr, "SSH async connect promise creation failed");
        return nullptr;
    }
    napi_value resource;
    status = napi_create_string_utf8(env, "SshConnectAsync", NAPI_AUTO_LENGTH, &resource);
    if (status != napi_ok) {
        CleanupSshConnectFailure(*data);
        delete data;
        napi_throw_error(env, nullptr, "SSH async connect resource creation failed");
        return nullptr;
    }
    status = napi_create_async_work(env, resource, resource,
        ExecuteSshConnectAsync, CompleteSshConnectAsync, data, &data->work);
    if (status != napi_ok) {
        CleanupSshConnectFailure(*data);
        delete data;
        napi_throw_error(env, nullptr, "SSH async connect work creation failed");
        return nullptr;
    }
    g_pendingSshConnectId.store(data->sessionId, std::memory_order_release);
    status = napi_queue_async_work(env, data->work);
    if (status != napi_ok) {
        int expectedSessionId = data->sessionId;
        g_pendingSshConnectId.compare_exchange_strong(
            expectedSessionId, -1, std::memory_order_acq_rel);
        napi_delete_async_work(env, data->work);
        CleanupSshConnectFailure(*data);
        delete data;
        napi_throw_error(env, nullptr, "SSH async connect work queue failed");
        return nullptr;
    }
    return promise;
}

struct TeardownNativeResources {
    int64_t rendererHandle = -1;
    int64_t decoderHandle = -1;
    int64_t audioHandle = -1;
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
    RendererNapi::DeactivateRenderer(resources.rendererHandle);
    DecoderNapi::DeactivateDecoder(resources.decoderHandle);
    resources.activeAudioPlayer = AudioPlayerNapi::TakeActiveNative();
    resetRemoteVideoActivity();
}

static void DestroyNativeResources(TeardownNativeResources resources) {
    OH_LOG_INFO(LOG_APP, "[ExtLoader][SHUTDOWN] phase=decoder-destroy-begin");
    DecoderNapi::DestroyDecoderHandle(resources.decoderHandle);
    OH_LOG_INFO(LOG_APP, "[ExtLoader][SHUTDOWN] phase=decoder-destroy-return");
    OH_LOG_INFO(LOG_APP, "[ExtLoader][SHUTDOWN] phase=renderer-destroy-begin");
    RendererNapi::DestroyRendererHandle(resources.rendererHandle);
    OH_LOG_INFO(LOG_APP, "[ExtLoader][SHUTDOWN] phase=renderer-destroy-return");
    OH_LOG_INFO(LOG_APP, "[ExtLoader][SHUTDOWN] phase=audio-destroy-begin");
    AudioPlayerNapi::DestroyDetachedNative(
        resources.audioHandle, std::move(resources.activeAudioPlayer));
    OH_LOG_INFO(LOG_APP, "[ExtLoader][SHUTDOWN] phase=audio-destroy-return");
}

static void PrepareAdapterForTeardown(const std::shared_ptr<ProtocolAdapter>& adapter) {
    if (!adapter) {
        return;
    }
    adapter->setVideoCallback(nullptr);
    adapter->setAudioCallback(nullptr);
    if (auto* ssh = dynamic_cast<SshAdapter*>(adapter.get())) {
        // Cancel before enqueueing the potentially blocking disconnect task;
        // this also covers an async SSH worker that has not started yet.
        ssh->requestConnectCancel();
    }
    if (auto* rustdesk = dynamic_cast<RustDeskBridge*>(adapter.get())) {
        rustdesk->setDisplayStateCallback(nullptr);
    }
}

static bool HasNativeResources(const TeardownNativeResources& resources) {
    return resources.rendererHandle > 0 || resources.decoderHandle > 0 ||
        resources.audioHandle > 0;
}

static uint64_t BeginSessionTeardown(
    int32_t sessionId, TeardownNativeResources resources) {
    if (sessionId > 0) {
        const auto existing = g_disconnectRequestBySession.find(sessionId);
        if (existing != g_disconnectRequestBySession.end()) {
            return existing->second;
        }
    }

    auto it = g_sessions.find(sessionId);
    if (it == g_sessions.end() || !it->second) {
        if (sessionId > 0) {
            DecoderNapi::ClearActiveSessionId(static_cast<uint64_t>(sessionId));
        }
        if (!HasNativeResources(resources)) {
            return 0;
        }
        DeactivateNativeResources(resources);
        auto resourceTask = [resources = std::move(resources)]() mutable {
            DestroyNativeResources(std::move(resources));
        };
        const uint64_t resourceRequestId = g_teardownExecutor.enqueue(resourceTask);
        if (resourceRequestId == 0) {
            resourceTask();
        }
        return resourceRequestId;
    }
    const std::shared_ptr<SessionContext> session = it->second;
    SessionContext::Lifecycle expected = SessionContext::Lifecycle::Active;
    if (!session->lifecycle.compare_exchange_strong(
            expected, SessionContext::Lifecycle::Disconnecting)) {
        return session->teardownRequestId.load(std::memory_order_acquire);
    }

    const std::shared_ptr<ProtocolAdapter> adapter = session->adapter;
    PrepareAdapterForTeardown(adapter);
    DeactivateSessionContextIfActive(adapter, static_cast<uint64_t>(sessionId));
    DeactivateNativeResources(resources);
    g_sessions.erase(it);

    auto task = [sessionId, session, adapter, resources = std::move(resources)]() mutable {
        const auto startedAt = std::chrono::steady_clock::now();
        OH_LOG_INFO(LOG_APP,
            "[ExtLoader][SHUTDOWN] sessionId=%{public}d phase=executor-start",
            sessionId);
        bool failed = false;
        try {
            if (adapter) {
                adapter->disconnect();
            }
        } catch (...) {
            failed = true;
        }
        try {
            DestroyNativeResources(std::move(resources));
        } catch (...) {
            failed = true;
        }
        session->adapter.reset();
        session->lifecycle.store(
            failed ? SessionContext::Lifecycle::Failed : SessionContext::Lifecycle::Complete,
            std::memory_order_release);
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
        task();
        return 0;
    }
    session->teardownRequestId.store(requestId, std::memory_order_release);
    g_disconnectRequestBySession[sessionId] = requestId;
    return requestId;
}

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

    // 先停止有界队列的生产者，再释放 TSFN。生产者在队列满时只等待
    // 可取消的短周期，因此页面同步断开不会和 JS 线程互相等待。
    std::shared_ptr<SshDataTsfnRegistration> dataRegistration;
    {
        std::lock_guard<std::mutex> lk(g_dataTsfnMutex);
        auto tit = g_dataTsfnMap.find(sessionId);
        if (tit != g_dataTsfnMap.end()) {
            dataRegistration = tit->second;
            g_dataTsfnMap.erase(tit);
        }
    }
    if (dataRegistration) {
        dataRegistration->accepting.store(false, std::memory_order_release);
        dataRegistration->waitCondition.notify_all();
    }
    auto dataSession = g_sessions.find(sessionId);
    if (dataSession != g_sessions.end() && dataSession->second && dataSession->second->adapter) {
        auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(dataSession->second->adapter);
        if (sshAdapter) { sshAdapter->setOnDataCallback(nullptr); }
    }
    if (dataRegistration && dataRegistration->tsfn != nullptr) {
        napi_release_threadsafe_function(dataRegistration->tsfn, napi_tsfn_release);
    }

    TeardownNativeResources resources;
    resources.rendererHandle = GetOptionalHandle(env, argc, args, 1);
    resources.decoderHandle = GetOptionalHandle(env, argc, args, 2);
    resources.audioHandle = GetOptionalHandle(env, argc, args, 3);
    const uint64_t requestId = BeginSessionTeardown(sessionId, std::move(resources));

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

    std::vector<std::pair<int, std::shared_ptr<SessionContext>>> sessions;
    sessions.reserve(g_sessions.size());
    for (const auto& item : g_sessions) {
        if (item.second) {
            sessions.push_back(item);
        }
    }

    std::vector<std::shared_ptr<SshDataTsfnRegistration>> dataRegistrations;
    {
        std::lock_guard<std::mutex> lock(g_dataTsfnMutex);
        dataRegistrations.reserve(g_dataTsfnMap.size());
        for (const auto& entry : g_dataTsfnMap) {
            dataRegistrations.push_back(entry.second);
        }
        g_dataTsfnMap.clear();
    }
    for (const auto& registration : dataRegistrations) {
        if (registration) {
            registration->accepting.store(false, std::memory_order_release);
            registration->waitCondition.notify_all();
        }
    }
    for (const auto& item : sessions) {
        if (item.second && item.second->adapter) {
            const auto sshAdapter =
                std::dynamic_pointer_cast<SshAdapter>(item.second->adapter);
            if (sshAdapter) {
                sshAdapter->setOnDataCallback(nullptr);
            }
        }
    }
    for (const auto& registration : dataRegistrations) {
        if (registration && registration->tsfn != nullptr) {
            napi_release_threadsafe_function(registration->tsfn, napi_tsfn_release);
        }
    }

    DeactivateAllSessionContexts();
    for (const auto& item : sessions) {
        DecoderNapi::ClearActiveSessionId(static_cast<uint64_t>(item.first));
        item.second->lifecycle.store(SessionContext::Lifecycle::Disconnecting,
                                     std::memory_order_release);
        PrepareAdapterForTeardown(item.second->adapter);
    }
    g_sessions.clear();

    TeardownNativeResources resources;
    resources.rendererHandle = GetOptionalHandle(env, argc, args, 0);
    resources.decoderHandle = GetOptionalHandle(env, argc, args, 1);
    resources.audioHandle = GetOptionalHandle(env, argc, args, 2);
    DeactivateNativeResources(resources);

    auto task = [sessions, resources = std::move(resources)]() mutable {
        bool failed = false;
        for (const auto& item : sessions) {
            const std::shared_ptr<SessionContext>& session = item.second;
            bool sessionFailed = false;
            try {
                if (session->adapter) {
                    session->adapter->disconnect();
                }
            } catch (...) {
                failed = true;
                sessionFailed = true;
            }
            session->adapter.reset();
            session->lifecycle.store(
                sessionFailed ? SessionContext::Lifecycle::Failed : SessionContext::Lifecycle::Complete,
                std::memory_order_release);
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
        task();
    } else {
        g_disconnectAllRequestId = requestId;
        for (const auto& item : sessions) {
            item.second->teardownRequestId.store(requestId, std::memory_order_release);
            g_disconnectRequestBySession[item.first] = requestId;
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

    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) {
        if (it->second->protocolName == "vnc") {
            it->second->diagnostics.inputEventsSent.fetch_add(1, std::memory_order_relaxed);
        }
        it->second->adapter->sendKey(static_cast<uint32_t>(scancode), pressed);
    } else if (it != g_sessions.end() && it->second->protocolName == "vnc") {
        it->second->diagnostics.inputEventsDropped.fetch_add(1, std::memory_order_relaxed);
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
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

    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) {
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
    } else if (it != g_sessions.end() && it->second->protocolName == "vnc") {
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

    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) {
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
    } else if (it != g_sessions.end() && it->second->protocolName == "vnc") {
        it->second->diagnostics.inputEventsDropped.fetch_add(1, std::memory_order_relaxed);
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/** NAPI: getRustDeskDisplayCapabilities(sessionId): object */
napi_value NapiGetRustDeskDisplayCapabilities(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sessionId = 0;
    if (argc > 0) napi_get_value_int32(env, args[0], &sessionId);

    RustDeskDisplayCapabilities capabilities;
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second && it->second->protocolName == "rustdesk" &&
        it->second->adapter) {
        auto* bridge = dynamic_cast<RustDeskBridge*>(it->second->adapter.get());
        if (bridge) capabilities = bridge->getDisplayCapabilities();
    }

    napi_value result;
    napi_create_object(env, &result);
    SetObjectBool(env, result, "supported", capabilities.supported);
    SetObjectInt32(env, result, "currentDisplay", capabilities.currentDisplay);
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
    auto it = g_sessions.find(sessionId);
    if (IsValidRustDeskDisplay(display) && it != g_sessions.end() && it->second &&
        it->second->protocolName == "rustdesk" && it->second->adapter) {
        auto* bridge = dynamic_cast<RustDeskBridge*>(it->second->adapter.get());
        if (bridge) {
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
    auto it = g_sessions.find(sessionId);
    if (IsValidRustDeskDisplay(display) && it != g_sessions.end() && it->second &&
        it->second->protocolName == "rustdesk" &&
        it->second->adapter) {
        auto* bridge = dynamic_cast<RustDeskBridge*>(it->second->adapter.get());
        if (bridge) accepted = bridge->changeDisplayResolution(display, width, height);
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second && it->second->protocolName == "rustdesk" &&
        it->second->adapter) {
        auto* bridge = dynamic_cast<RustDeskBridge*>(it->second->adapter.get());
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second && it->second->protocolName == "rustdesk" &&
        it->second->adapter) {
        auto* bridge = dynamic_cast<RustDeskBridge*>(it->second->adapter.get());
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
    const size_t textLen = text.size();

    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) {
        if (it->second->protocolName == "vnc") {
            it->second->diagnostics.inputEventsSent.fetch_add(1, std::memory_order_relaxed);
        }
        uint64_t index = ++g_napiTextSendCount;
        OH_LOG_INFO(LOG_APP,
            "[ExtLoader] NapiSendText #%{public}llu session=%{public}d len=%{public}zu found=yes",
            static_cast<unsigned long long>(index),
            sessionId,
            textLen);
        it->second->adapter->sendText(text);
    } else {
        if (it != g_sessions.end() && it->second->protocolName == "vnc") {
            it->second->diagnostics.inputEventsDropped.fetch_add(1, std::memory_order_relaxed);
        }
        OH_LOG_WARN(LOG_APP,
            "[ExtLoader] NapiSendText session=%{public}d len=%{public}zu found=no",
            sessionId,
            textLen);
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
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

    auto it = g_sessions.find(sessionId);
    const std::string pathId = SafeLog::HashForLog(remotePath);
    if (it != g_sessions.end() && it->second->adapter) {
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) {
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

    auto it = g_sessions.find(sessionId);
    if (it == g_sessions.end() || !it->second->adapter) {
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
        napi_create_double(env, static_cast<double>(entries[i].size), &val);
        napi_set_named_property(env, item, "size", val);
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) {
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter && maxLen > 0) {
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
    std::shared_ptr<ProtocolAdapter> adapter;
    std::string remotePath;
    std::string newRemotePath;
    std::vector<uint8_t> input;
    std::vector<uint8_t> output;
    std::vector<SftpFileEntry> entries;
    uint64_t offset = 0;
    uint32_t maxLen = 0;
    bool truncate = false;
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

    try {
        auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(data->adapter);
        if (!sshAdapter) {
            data->errorCode = ERR_SSH_SESSION_CLOSED;
            return;
        }
        switch (data->operation) {
            case SftpAsyncOperation::ListDirectory:
                data->errorCode = sshAdapter->listRemoteDir(data->remotePath, data->entries);
                break;
            case SftpAsyncOperation::ReadChunk:
                data->errorCode = sshAdapter->readRemoteFileChunk(
                    data->remotePath, data->offset, data->maxLen, data->output);
                break;
            case SftpAsyncOperation::WriteChunk:
                data->bytesWritten = sshAdapter->writeRemoteFileChunk(
                    data->remotePath,
                    data->input.empty() ? nullptr : data->input.data(),
                    static_cast<uint32_t>(data->input.size()),
                    data->offset,
                    data->truncate);
                data->errorCode = data->bytesWritten < 0 ? data->bytesWritten : 0;
                break;
            case SftpAsyncOperation::RemoveFile:
                data->errorCode = sshAdapter->removeRemoteFile(data->remotePath);
                break;
            case SftpAsyncOperation::RemoveDirectory:
                data->errorCode = sshAdapter->removeRemoteDir(data->remotePath);
                break;
            case SftpAsyncOperation::MakeDirectory:
                data->errorCode = sshAdapter->makeRemoteDir(data->remotePath);
                break;
            case SftpAsyncOperation::RenamePath:
                data->errorCode = sshAdapter->renameRemotePath(
                    data->remotePath, data->newRemotePath);
                break;
        }
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
    napi_create_double(env, static_cast<double>(entry.size), &value);
    napi_set_named_property(env, item, "size", value);
    napi_create_double(env, static_cast<double>(entry.mtime), &value);
    napi_set_named_property(env, item, "mtime", value);
}

static napi_value CreateSftpAsyncResult(napi_env env, const SftpAsyncData& data) {
    napi_value result;
    napi_create_object(env, &result);
    napi_value errorCode;
    napi_create_int32(env, data.errorCode, &errorCode);
    napi_set_named_property(env, result, "errorCode", errorCode);

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

static std::shared_ptr<ProtocolAdapter> FindSshSessionAdapter(int32_t sessionId) {
    auto it = g_sessions.find(sessionId);
    if (it == g_sessions.end() || !it->second) {
        return nullptr;
    }
    return it->second->adapter;
}

napi_value NapiListRemoteDirAsync(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto* data = new (std::nothrow) SftpAsyncData();
    if (data == nullptr) {
        napi_throw_error(env, nullptr, "SFTP list async allocation failed");
        return nullptr;
    }
    if (argc > 0) { napi_get_value_int32(env, args[0], &data->sessionId); }
    if (argc > 1) { data->remotePath = GetNapiString(env, args[1]); }
    data->operation = SftpAsyncOperation::ListDirectory;
    data->adapter = FindSshSessionAdapter(data->sessionId);
    return QueueSftpAsync(env, data, "SshListRemoteDirAsync");
}

napi_value NapiReadRemoteFileChunkAsync(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
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
    data->operation = SftpAsyncOperation::ReadChunk;
    data->offset = static_cast<uint64_t>(offset);
    data->maxLen = static_cast<uint32_t>(maxLen);
    data->adapter = FindSshSessionAdapter(data->sessionId);
    return QueueSftpAsync(env, data, "SshReadRemoteFileChunkAsync");
}

napi_value NapiWriteRemoteFileChunkAsync(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
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
    data->operation = SftpAsyncOperation::WriteChunk;
    data->offset = static_cast<uint64_t>(offset);
    data->adapter = FindSshSessionAdapter(data->sessionId);
    return QueueSftpAsync(env, data, "SshWriteRemoteFileChunkAsync");
}

static SftpAsyncData* CreateSftpPathAsyncData(
    napi_env env, napi_callback_info info, SftpAsyncOperation operation, size_t argc) {
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto* data = new (std::nothrow) SftpAsyncData();
    if (data == nullptr) {
        napi_throw_error(env, nullptr, "SFTP mutation async allocation failed");
        return nullptr;
    }
    if (argc > 0) { napi_get_value_int32(env, args[0], &data->sessionId); }
    if (argc > 1) { data->remotePath = GetNapiString(env, args[1]); }
    data->operation = operation;
    data->adapter = FindSshSessionAdapter(data->sessionId);
    return data;
}

napi_value NapiRemoveRemoteFileAsync(napi_env env, napi_callback_info info) {
    SftpAsyncData* data = CreateSftpPathAsyncData(
        env, info, SftpAsyncOperation::RemoveFile, 2);
    if (data == nullptr) {
        return nullptr;
    }
    return QueueSftpAsync(env, data, "SshRemoveRemoteFileAsync");
}

napi_value NapiRemoveRemoteDirAsync(napi_env env, napi_callback_info info) {
    SftpAsyncData* data = CreateSftpPathAsyncData(
        env, info, SftpAsyncOperation::RemoveDirectory, 2);
    if (data == nullptr) {
        return nullptr;
    }
    return QueueSftpAsync(env, data, "SshRemoveRemoteDirAsync");
}

napi_value NapiMakeRemoteDirAsync(napi_env env, napi_callback_info info) {
    SftpAsyncData* data = CreateSftpPathAsyncData(
        env, info, SftpAsyncOperation::MakeDirectory, 2);
    if (data == nullptr) {
        return nullptr;
    }
    return QueueSftpAsync(env, data, "SshMakeRemoteDirAsync");
}

napi_value NapiRenameRemotePathAsync(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto* data = new (std::nothrow) SftpAsyncData();
    if (data == nullptr) {
        napi_throw_error(env, nullptr, "SFTP rename async allocation failed");
        return nullptr;
    }
    if (argc > 0) { napi_get_value_int32(env, args[0], &data->sessionId); }
    if (argc > 1) { data->remotePath = GetNapiString(env, args[1]); }
    if (argc > 2) { data->newRemotePath = GetNapiString(env, args[2]); }
    if (data->remotePath.empty() || data->newRemotePath.empty()) {
        delete data;
        napi_throw_type_error(env, nullptr, "SFTP rename paths must not be empty");
        return nullptr;
    }
    data->operation = SftpAsyncOperation::RenamePath;
    data->adapter = FindSshSessionAdapter(data->sessionId);
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) {
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) {
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) {
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) {
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

    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) {
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
            auto it = g_sessions.find(sessionId);
            if (valid && it != g_sessions.end() && it->second->adapter) {
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) text = it->second->adapter->getClipboardText();
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) ready = it->second->adapter->isClipboardReceiveReady();
    napi_value result;
    napi_get_boolean(env, ready, &result);
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) {
        state = static_cast<int>(it->second->adapter->getState());
    }

    napi_value result;
    napi_create_int32(env, state, &result);
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->protocolName == "rustdesk" && it->second->adapter) {
        auto rustdesk = std::dynamic_pointer_cast<RustDeskBridge>(it->second->adapter);
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) {
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
    auto it = g_sessions.find(data->sessionId);
    if (it != g_sessions.end() && it->second) {
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end()) {
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
napi_value NapiGetRustDeskLastError(napi_env env, napi_callback_info info) {
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

    auto it = g_sessions.find(sessionId);
    if (it == g_sessions.end() || !it->second->adapter) {
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second && it->second->adapter) {
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second && it->second->adapter) {
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second && it->second->adapter) {
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second && it->second->adapter) {
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second && it->second->adapter) {
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

    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) {
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) {
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
    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second && it->second->adapter) {
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
static void DataTsfnCallJs(napi_env env, napi_value jsCallback,
                            void* /*context*/, void* data) {
    auto* bytes = static_cast<std::vector<uint8_t>*>(data);
    if (env != nullptr && jsCallback != nullptr && bytes != nullptr) {
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

    auto it = g_sessions.find(sessionId);
    if (it == g_sessions.end() || !it->second->adapter) {
        OH_LOG_WARN(LOG_APP, "[ExtLoader] setOnDataCallback: 会话不存在 id=%{public}d", sessionId);
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }
    auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(it->second->adapter);
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
        oldRegistration->accepting.store(false, std::memory_order_release);
        oldRegistration->waitCondition.notify_all();
    }
    sshAdapter->setOnDataCallback(nullptr);
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
        nullptr,          // thread_finalize_data
        nullptr,          // thread_finalize_cb
        nullptr,          // context
        DataTsfnCallJs,   // call_js_cb
        &tsfn);
    if (s != napi_ok || tsfn == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[ExtLoader] setOnDataCallback: 创建 TSFN 失败 status=%{public}d", s);
        napi_value undefined;
        napi_get_undefined(env, &undefined);
        return undefined;
    }

    auto registration = std::make_shared<SshDataTsfnRegistration>();
    registration->tsfn = tsfn;
    {
        std::lock_guard<std::mutex> lk(g_dataTsfnMutex);
        g_dataTsfnMap[sessionId] = registration;
    }

    // 绑定到 adapter — 每次 reader 拿到数据时调用
    sshAdapter->setOnDataCallback([registration](const std::vector<uint8_t>& data) {
        if (data.empty()) { return; }
        if (!registration->accepting.load(std::memory_order_acquire)) { return; }
        auto* heapBytes = new std::vector<uint8_t>(data);
        while (registration->accepting.load(std::memory_order_acquire)) {
            const napi_status r = napi_call_threadsafe_function(
                registration->tsfn, heapBytes, napi_tsfn_nonblocking);
            if (r == napi_ok) {
                return;
            }
            if (r != napi_queue_full) {
                break;
            }
            std::unique_lock<std::mutex> waitLock(registration->waitMutex);
            registration->waitCondition.wait_for(
                waitLock, std::chrono::milliseconds(10), [&registration]() {
                    return !registration->accepting.load(std::memory_order_acquire);
                });
        }
        // 关闭/TSFN 错误时释放尚未入队的字节；已入队数据由 DataTsfnCallJs 释放。
        delete heapBytes;
    });

    OH_LOG_INFO(LOG_APP, "[ExtLoader] setOnDataCallback: 已注册 id=%{public}d", sessionId);
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
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

/**
 * NAPI: testSshKeyAuth(host, port, username, privateKeyPem, passphrase): object
 * 同步阻塞
 */
napi_value NapiTestSshKeyAuth(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char hostBuf[256] = {0};
    char userBuf[256] = {0};
    char passphraseBuf[256] = {0};
    int port = 22;

    if (argc > 0) napi_get_value_string_utf8(env, args[0], hostBuf, sizeof(hostBuf), nullptr);
    if (argc > 1) napi_get_value_int32(env, args[1], &port);
    if (argc > 2) napi_get_value_string_utf8(env, args[2], userBuf, sizeof(userBuf), nullptr);
    std::string privateKeyPem;
    if (argc > 3) privateKeyPem = GetNapiString(env, args[3]);
    if (argc > 4) napi_get_value_string_utf8(env, args[4], passphraseBuf, sizeof(passphraseBuf), nullptr);

    SshProxyOptions proxy;
    if (argc > 5) {
        napi_value proxyValue;
        napi_valuetype proxyType = napi_undefined;
        if (napi_get_named_property(env, args[5], "type", &proxyValue) == napi_ok) {
            proxy.type = GetNapiString(env, proxyValue);
        }
        if (napi_get_named_property(env, args[5], "host", &proxyValue) == napi_ok) {
            proxy.host = GetNapiString(env, proxyValue);
        }
        if (napi_get_named_property(env, args[5], "port", &proxyValue) == napi_ok) {
            napi_get_value_int32(env, proxyValue, &proxy.port);
        }
        if (napi_get_named_property(env, args[5], "username", &proxyValue) == napi_ok) {
            proxy.username = GetNapiString(env, proxyValue);
        }
        if (napi_get_named_property(env, args[5], "password", &proxyValue) == napi_ok) {
            proxy.password = GetNapiString(env, proxyValue);
        }
        (void)napi_typeof(env, args[5], &proxyType);
        if (proxyType != napi_object) {
            proxy = SshProxyOptions();
        }
    }

    SshAuthTestResult res = testSshKeyAuth(
        std::string(hostBuf), port, std::string(userBuf),
        privateKeyPem, std::string(passphraseBuf), proxy);
    secureClearString(proxy.password);

    napi_value result;
    napi_create_object(env, &result);

    napi_value valOk, valCode, valMsg;
    napi_get_boolean(env, res.ok, &valOk);
    napi_create_int32(env, res.code, &valCode);
    napi_create_string_utf8(env, res.message.c_str(), NAPI_AUTO_LENGTH, &valMsg);

    napi_set_named_property(env, result, "ok", valOk);
    napi_set_named_property(env, result, "code", valCode);
    napi_set_named_property(env, result, "message", valMsg);

    return result;
}

/**
 * NAPI: probeSshHostKey(host, port): object
 * 仅 TCP + KEX, 不做用户认证. 同步阻塞 1-5s.
 */
napi_value NapiProbeSshHostKey(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char hostBuf[256] = {0};
    int port = 22;

    if (argc > 0) napi_get_value_string_utf8(env, args[0], hostBuf, sizeof(hostBuf), nullptr);
    if (argc > 1) napi_get_value_int32(env, args[1], &port);

    SshProxyOptions proxy;
    if (argc > 2) {
        napi_value proxyValue;
        napi_valuetype proxyType = napi_undefined;
        if (napi_get_named_property(env, args[2], "type", &proxyValue) == napi_ok) {
            proxy.type = GetNapiString(env, proxyValue);
        }
        if (napi_get_named_property(env, args[2], "host", &proxyValue) == napi_ok) {
            proxy.host = GetNapiString(env, proxyValue);
        }
        if (napi_get_named_property(env, args[2], "port", &proxyValue) == napi_ok) {
            napi_get_value_int32(env, proxyValue, &proxy.port);
        }
        if (napi_get_named_property(env, args[2], "username", &proxyValue) == napi_ok) {
            proxy.username = GetNapiString(env, proxyValue);
        }
        if (napi_get_named_property(env, args[2], "password", &proxyValue) == napi_ok) {
            proxy.password = GetNapiString(env, proxyValue);
        }
        (void)napi_typeof(env, args[2], &proxyType);
        if (proxyType != napi_object) {
            proxy = SshProxyOptions();
        }
    }

    SshHostKeyInfo res = probeSshHostKey(std::string(hostBuf), port, proxy);
    secureClearString(proxy.password);

    napi_value result;
    napi_create_object(env, &result);

    napi_value valOk, valHost, valPort, valAlg, valFp, valRaw, valBanner, valErrCode, valErrMsg;
    napi_get_boolean(env, res.ok, &valOk);
    napi_create_string_utf8(env, res.host.c_str(), NAPI_AUTO_LENGTH, &valHost);
    napi_create_int32(env, res.port, &valPort);
    napi_create_string_utf8(env, res.algorithm.c_str(), NAPI_AUTO_LENGTH, &valAlg);
    napi_create_string_utf8(env, res.fingerprintSha256.c_str(), NAPI_AUTO_LENGTH, &valFp);
    napi_create_string_utf8(env, res.rawBase64.c_str(), NAPI_AUTO_LENGTH, &valRaw);
    napi_create_string_utf8(env, res.serverBanner.c_str(), NAPI_AUTO_LENGTH, &valBanner);
    napi_create_int32(env, res.errorCode, &valErrCode);
    napi_create_string_utf8(env, res.errorMessage.c_str(), NAPI_AUTO_LENGTH, &valErrMsg);

    napi_set_named_property(env, result, "ok", valOk);
    napi_set_named_property(env, result, "host", valHost);
    napi_set_named_property(env, result, "port", valPort);
    napi_set_named_property(env, result, "algorithm", valAlg);
    napi_set_named_property(env, result, "fingerprintSha256", valFp);
    napi_set_named_property(env, result, "rawBase64", valRaw);
    napi_set_named_property(env, result, "serverBanner", valBanner);
    napi_set_named_property(env, result, "errorCode", valErrCode);
    napi_set_named_property(env, result, "errorMessage", valErrMsg);

    return result;
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

// ============================================================
// ExtensionLoaderNapi::Init
// ============================================================

napi_value ExtensionLoaderNapi::Init(napi_env env, napi_value exports) {
    napi_value fn;

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

    napi_create_function(env, "probeRdpCertificate", NAPI_AUTO_LENGTH,
                         NapiProbeRdpCertificate, nullptr, &fn);
    napi_set_named_property(env, exports, "probeRdpCertificate", fn);

    napi_create_function(env, "probeRdpCertificateAsync", NAPI_AUTO_LENGTH,
                         NapiProbeRdpCertificateAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "probeRdpCertificateAsync", fn);

    napi_create_function(env, "getRdpRenderStats", NAPI_AUTO_LENGTH,
                         NapiGetRdpRenderStats, nullptr, &fn);
    napi_set_named_property(env, exports, "getRdpRenderStats", fn);
    napi_create_function(env, "getSessionDiagnostics", NAPI_AUTO_LENGTH,
                         NapiGetSessionDiagnostics, nullptr, &fn);
    napi_set_named_property(env, exports, "getSessionDiagnostics", fn);
    napi_create_function(env, "getRustDeskDiagnostics", NAPI_AUTO_LENGTH,
                         NapiGetSessionDiagnostics, nullptr, &fn);
    napi_set_named_property(env, exports, "getRustDeskDiagnostics", fn);
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

    napi_create_function(env, "disconnectAll", NAPI_AUTO_LENGTH,
                         NapiDisconnectAll, nullptr, &fn);
    napi_set_named_property(env, exports, "disconnectAll", fn);

    napi_create_function(env, "getDisconnectState", NAPI_AUTO_LENGTH,
                         NapiGetDisconnectState, nullptr, &fn);
    napi_set_named_property(env, exports, "getDisconnectState", fn);

    napi_create_function(env, "sendKey", NAPI_AUTO_LENGTH,
                         NapiSendKey, nullptr, &fn);
    napi_set_named_property(env, exports, "sendKey", fn);

    napi_create_function(env, "sendMouse", NAPI_AUTO_LENGTH,
                         NapiSendMouse, nullptr, &fn);
    napi_set_named_property(env, exports, "sendMouse", fn);

    napi_create_function(env, "sendMouseWheel", NAPI_AUTO_LENGTH,
                         NapiSendMouseWheel, nullptr, &fn);
    napi_set_named_property(env, exports, "sendMouseWheel", fn);

    napi_create_function(env, "getRustDeskDisplayCapabilities", NAPI_AUTO_LENGTH,
                         NapiGetRustDeskDisplayCapabilities, nullptr, &fn);
    napi_set_named_property(env, exports, "getRustDeskDisplayCapabilities", fn);

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

    napi_create_function(env, "getConnectionState", NAPI_AUTO_LENGTH,
                         NapiGetConnectionState, nullptr, &fn);
    napi_set_named_property(env, exports, "getConnectionState", fn);

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

    napi_create_function(env, "setHelperSocketPath", NAPI_AUTO_LENGTH,
                         NapiSetHelperSocketPath, nullptr, &fn);
    napi_set_named_property(env, exports, "setHelperSocketPath", fn);

    napi_create_function(env, "requestFrameRefresh", NAPI_AUTO_LENGTH,
                         NapiRequestFrameRefresh, nullptr, &fn);
    napi_set_named_property(env, exports, "requestFrameRefresh", fn);

    napi_create_function(env, "isVideoPlaybackActive", NAPI_AUTO_LENGTH,
                         NapiIsVideoPlaybackActive, nullptr, &fn);
    napi_set_named_property(env, exports, "isVideoPlaybackActive", fn);

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

    napi_create_function(env, "probeSshHostKey", NAPI_AUTO_LENGTH,
                         NapiProbeSshHostKey, nullptr, &fn);
    napi_set_named_property(env, exports, "probeSshHostKey", fn);

    OH_LOG_INFO(LOG_APP, "[ExtLoader] NAPI 方法已注册: ... probeSshHostKey");
    return exports;
}
