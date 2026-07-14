/**
 * extension_loader_napi.cpp — 扩展加载器 NAPI 桥接
 *
 * 将 ExtensionSystem 暴露给 ArkTS 层。
 * ArkTS 通过此模块查询已注册的协议适配器、建立连接、发送输入。
 */

#include "extension_registry.h"
#include "protocol_adapter.h"
#include "rdp/freerdp_adapter.h"
#include "ssh/ssh_adapter.h"
#include "ssh/ssh_key_tool.h"
#include "audio/input_handler.h"
#include "audio/audio_player.h"
#include "common/safe_log.h"
#include "render/hw_decoder.h"
#include "render/gl_renderer.h"
#include "render/video_perf_counters.h"
#include "video/video_activity_state.h"
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
#include <exception>
#include <new>
#include <vector>

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

// ============================================================
// 全局状态
// ============================================================

// 当前活跃连接
static std::shared_ptr<ProtocolAdapter> g_activeConnection = nullptr;

// 连接会话上下文
struct SessionContext {
    std::shared_ptr<ProtocolAdapter> adapter;
    std::string protocolName;
    std::string lastStateMessage;
    std::mutex messageMutex;
};

static std::map<int, std::shared_ptr<SessionContext>> g_sessions;
static int g_nextSessionId = 1;
static std::atomic<uint64_t> g_napiWheelSendCount {0};
static std::atomic<uint64_t> g_napiTextSendCount {0};
static std::atomic<uint64_t> g_napiFileSendCount {0};
static std::atomic<uint64_t> g_napiKeySendCount {0};
static std::atomic<uint64_t> g_napiMouseSendCount {0};
static Render::VideoPerfCounters g_rustdeskVideoPerf;

// SSH 推送回调的 TSFN 映射 (sessionId → tsfn). 由 setOnDataCallback / disconnect 维护.
static std::map<int, napi_threadsafe_function> g_dataTsfnMap;
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
    SetObjectInt32(env, result, "inputQueueDepth", stats.inputQueueDepth);
    SetObjectInt32(env, result, "inputQueueMax", stats.inputQueueMax);
    SetObjectInt64(env, result, "inputTextUnits", stats.inputTextUnits);
    SetObjectInt64(env, result, "inputDroppedMouseMoves", stats.inputDroppedMouseMoves);
    SetObjectInt64(env, result, "inputNonDisposableOverflow", stats.inputNonDisposableOverflow);
    SetObjectString(env, result, "graphicsMode", stats.graphicsMode);
    return result;
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
 * config 字段: protocol, host, port, username, password, domain, width, height, codec
 * 返回会话 ID (>0=成功, -1=协议未找到, -2=连接失败)
 */
napi_value NapiConnect(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // 解析 config 对象
    ConnectionConfig cfg;

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

    // 🆕 SSH 认证字段
    getString("authMethod", cfg.authMethod);
    getString("privateKeyPem", cfg.privateKeyPem);
    getString("privateKeyPassphrase", cfg.privateKeyPassphrase);
    getString("expectedHostKeyRawBase64", cfg.expectedHostKeyRawBase64);
    getString("expectedHostKeyFingerprintSha256", cfg.expectedHostKeyFingerprintSha256);
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
    getInt("rdPasswordLength", cfg.rdPasswordLength);
    getString("rdRelayId", cfg.rdRelayId);
    getString("rdAccountId", cfg.rdAccountId);
    getString("rdServerKey", cfg.rdServerKey);

    if (cfg.port == 0) cfg.port = 3389; // 默认端口
    if (cfg.width == 0) cfg.width = 1920;
    if (cfg.height == 0) cfg.height = 1080;
    if (cfg.gatewayPort == 0) cfg.gatewayPort = 443;
    if (cfg.colorDepth == 0) cfg.colorDepth = 32;
    if (cfg.rdImageQuality < 0 || cfg.rdImageQuality > 2) cfg.rdImageQuality = 1;
    if (cfg.rdDirectPort <= 0) cfg.rdDirectPort = 21118;
    if (cfg.rdPasswordMode != 1) cfg.rdPasswordMode = 0;
    if (cfg.rdPasswordLength != 8 && cfg.rdPasswordLength != 10) cfg.rdPasswordLength = 6;

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
        const std::string serverKeyLog = cfg.rdServerKey.empty() ? "default" : SafeLog::HashForLog(cfg.rdServerKey);
        OH_LOG_INFO(LOG_APP, "[ExtLoader] RustDesk配置: quality=%{public}d direct=%{public}s:%{public}d lan=%{public}s privacy=%{public}s audio=%{public}s pwdMode=%{public}d pwdLen=%{public}d relayId=%{public}s account=%{public}s serverKeyId=%{public}s",
                    cfg.rdImageQuality, cfg.rdDirectIp ? "on" : "off", cfg.rdDirectPort,
                    cfg.rdLanDiscovery ? "on" : "off", cfg.rdPrivacyMode ? "on" : "off",
                    cfg.rdAudioEnabled ? "on" : "off",
                    cfg.rdPasswordMode, cfg.rdPasswordLength,
                    relayLog.c_str(), accountLog.c_str(),
                    serverKeyLog.c_str());
    } else if (protocolName == "rdp") {
        const std::string drivePathLog = cfg.rdDrivePath.empty() ? "off" : SafeLog::HashForLog(cfg.rdDrivePath);
        OH_LOG_INFO(LOG_APP,
            "[ExtLoader] RDP配置: desktop=%{public}dx%{public}d colorDepth=%{public}d audio=%{public}s clipboard=%{public}s driveName=%{public}s drivePathId=%{public}s authIdentityMode=%{public}d",
            cfg.width,
            cfg.height,
            cfg.colorDepth,
            cfg.rdAudioEnabled ? "on" : "off",
            cfg.rdClipboardEnabled ? "on" : "off",
            cfg.rdDriveName.empty() ? "RemoteDesktop" : cfg.rdDriveName.c_str(),
            drivePathLog.c_str(),
            cfg.rdpAuthIdentityMode);
    }

    // 查找协议适配器
    auto adapter = FindAdapter(protocolName);
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

    int sessionId = g_nextSessionId++;
    g_sessions[sessionId] = session;
    g_activeConnection = adapter;

    // R0: 连接成功后设置活跃 adapter, 输入事件通过 InputHandler 统一派发
    InputHandler::instance().setActiveAdapter(adapter);

    adapter->setConnectionStateCallback([session](ConnectionState state, const std::string& message) {
        std::lock_guard<std::mutex> lock(session->messageMutex);
        session->lastStateMessage = message;
        OH_LOG_INFO(LOG_APP, "[ExtLoader] 状态变更: protocol=%{public}s state=%{public}d msg=%{public}s",
                    session->protocolName.c_str(), static_cast<int>(state), message.c_str());
    });

    adapter->setVideoCallback([](const VideoFrame& frame) {
        static uint64_t frameCount = 0;
        static std::atomic<uint64_t> decodeRetOk {0};
        static std::atomic<uint64_t> decodeRetNotReady {0};
        static std::atomic<uint64_t> decodeRetBadCodec {0};
        static std::atomic<uint64_t> decodeRetMismatch {0};
        static std::atomic<uint64_t> decodeRetOther {0};
        if (frame.width > 0 && frame.height > 0) {
            RendererNapi::SetActiveSourceSize(frame.width, frame.height);
        }
        recordRemoteVideoFrame(frame.size, frame.width, frame.height);
        g_rustdeskVideoPerf.recordIngressFrame("rustdesk", frame.width, frame.height,
                                               frame.size, frame.isKeyFrame);
        int ret = DecoderNapi::DecodeActiveNative(frame);
        g_rustdeskVideoPerf.recordDecodeResult(ret, 0, 0, 0);
        frameCount++;
        switch (ret) {
            case 0: decodeRetOk.fetch_add(1); break;
            case -1: decodeRetNotReady.fetch_add(1); break;
            case -2: decodeRetBadCodec.fetch_add(1); break;
            case -3: decodeRetMismatch.fetch_add(1); break;
            default: if (ret < 0) decodeRetOther.fetch_add(1); break;
        }
        if (g_activeConnection && frameCount % 30 == 0) {
            g_activeConnection->reportVideoPressure(DecoderNapi::ActiveVideoPressureLevel());
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
    if (ret != 0) {
        OH_LOG_ERROR(LOG_APP, "[ExtLoader] 连接失败: ret=%{public}d host=%{public}s:%{public}d auth=%{public}s",
            ret, logHost.c_str(), cfg.port, cfg.authMethod.c_str());
        g_sessions.erase(sessionId);
        if (g_activeConnection == adapter) {
            g_activeConnection = nullptr;
        }
        napi_value errVal;
        napi_create_int32(env, ret, &errVal);  // 传递真实错误码而非通用 -2
        return errVal;
    }

    OH_LOG_INFO(LOG_APP, "[ExtLoader] 连接成功, sessionId=%{public}d", sessionId);

    napi_value result;
    napi_create_int32(env, sessionId, &result);
    return result;
}

/**
 * NAPI: disconnect(sessionId: number): void
 */
napi_value NapiDisconnect(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sessionId;
    napi_get_value_int32(env, args[0], &sessionId);
    const auto shutdownStartedAt = std::chrono::steady_clock::now();
    OH_LOG_INFO(LOG_APP, "[ExtLoader][SHUTDOWN] sessionId=%{public}d phase=napi-entry", sessionId);

    // 先清掉 SSH 数据回调 TSFN, 避免 reader 线程已停后还有 push 在排队
    {
        std::lock_guard<std::mutex> lk(g_dataTsfnMutex);
        auto tit = g_dataTsfnMap.find(sessionId);
        if (tit != g_dataTsfnMap.end()) {
            auto sit = g_sessions.find(sessionId);
            if (sit != g_sessions.end() && sit->second->adapter) {
                auto sshAdapter = std::dynamic_pointer_cast<SshAdapter>(sit->second->adapter);
                if (sshAdapter) { sshAdapter->setOnDataCallback(nullptr); }
            }
            napi_release_threadsafe_function(tit->second, napi_tsfn_release);
            g_dataTsfnMap.erase(tit);
        }
    }

    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) {
        if (g_activeConnection == it->second->adapter) {
            InputHandler::instance().setActiveAdapter(nullptr);
            g_activeConnection = nullptr;
        }
        it->second->adapter->disconnect();
    }
    g_sessions.erase(sessionId);
    AudioPlayerNapi::DestroyActiveNative();

    if (g_activeConnection && g_sessions.empty()) {
        g_activeConnection = nullptr;
        InputHandler::instance().setActiveAdapter(nullptr);
    }
    resetRemoteVideoActivity();

    const auto shutdownElapsedUs = std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now() - shutdownStartedAt).count();
    OH_LOG_INFO(LOG_APP,
        "[ExtLoader][SHUTDOWN] sessionId=%{public}d phase=napi-return elapsedUs=%{public}lld",
        sessionId, static_cast<long long>(shutdownElapsedUs));

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * NAPI: disconnectAll(): void
 *
 * Ability 退后台/销毁时兜底释放所有协议会话。RDP 如果只靠页面 aboutToDisappear,
 * 在系统手势回桌面或后台清理时可能来不及触发, Windows 侧会保留会话。
 */
napi_value NapiDisconnectAll(napi_env env, napi_callback_info info) {
    (void)info;
    const auto shutdownStartedAt = std::chrono::steady_clock::now();

    std::vector<std::shared_ptr<SessionContext>> sessions;
    sessions.reserve(g_sessions.size());
    for (const auto& item : g_sessions) {
        if (item.second) {
            sessions.push_back(item.second);
        }
    }

    g_activeConnection = nullptr;
    InputHandler::instance().setActiveAdapter(nullptr);
    for (const auto& session : sessions) {
        if (session->adapter) {
            session->adapter->disconnect();
        }
    }

    g_sessions.clear();
    AudioPlayerNapi::DestroyActiveNative();
    resetRemoteVideoActivity();

    const auto shutdownElapsedUs = std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now() - shutdownStartedAt).count();
    OH_LOG_INFO(LOG_APP,
        "[ExtLoader][SHUTDOWN] phase=disconnect-all-return sessions=%{public}zu elapsedUs=%{public}lld",
        sessions.size(), static_cast<long long>(shutdownElapsedUs));

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
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
        it->second->adapter->sendKey(static_cast<uint32_t>(scancode), pressed);
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
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
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

    char text[4096] = {0};
    size_t textLen = 0;
    napi_get_value_string_utf8(env, args[1], text, sizeof(text), &textLen);

    auto it = g_sessions.find(sessionId);
    if (it != g_sessions.end() && it->second->adapter) {
        uint64_t index = ++g_napiTextSendCount;
        OH_LOG_INFO(LOG_APP,
            "[ExtLoader] NapiSendText #%{public}llu session=%{public}d len=%{public}zu found=yes",
            static_cast<unsigned long long>(index),
            sessionId,
            textLen);
        it->second->adapter->sendText(text);
    } else {
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

// ============================================================
// 推送式 SSH 数据回调 (TSFN — ThreadSafeFunction)
// ============================================================

/**
 * TSFN 主线程回调: 把 std::string* (heap) 转 JS string 调用 jsCb.
 */
static void DataTsfnCallJs(napi_env env, napi_value jsCallback,
                            void* /*context*/, void* data) {
    auto* str = static_cast<std::string*>(data);
    if (env != nullptr && jsCallback != nullptr && str != nullptr) {
        napi_value jsStr;
        napi_status s = napi_create_string_utf8(env, str->c_str(), str->size(), &jsStr);
        if (s == napi_ok) {
            napi_value undefined;
            napi_get_undefined(env, &undefined);
            napi_call_function(env, undefined, jsCallback, 1, &jsStr, nullptr);
        }
    }
    if (str != nullptr) { delete str; }
}

/**
 * NAPI: setOnDataCallback(sessionId: number, cb: (data: string) => void | null): void
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

    // 先释放旧 TSFN (如有)
    {
        std::lock_guard<std::mutex> lk(g_dataTsfnMutex);
        auto tit = g_dataTsfnMap.find(sessionId);
        if (tit != g_dataTsfnMap.end()) {
            sshAdapter->setOnDataCallback(nullptr);
            napi_release_threadsafe_function(tit->second, napi_tsfn_release);
            g_dataTsfnMap.erase(tit);
        }
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
        0,                // unlimited queue
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

    {
        std::lock_guard<std::mutex> lk(g_dataTsfnMutex);
        g_dataTsfnMap[sessionId] = tsfn;
    }

    // 绑定到 adapter — 每次 reader 拿到数据时调用
    sshAdapter->setOnDataCallback([tsfn](const std::string& data) {
        if (data.empty()) { return; }
        auto* heapStr = new std::string(data);
        napi_status r = napi_call_threadsafe_function(tsfn, heapStr, napi_tsfn_blocking);
        if (r != napi_ok) {
            // 队列错误时不泄漏内存
            delete heapStr;
        }
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
    size_t argc = 5;
    napi_value args[5];
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

    SshAuthTestResult res = testSshKeyAuth(
        std::string(hostBuf), port, std::string(userBuf),
        privateKeyPem, std::string(passphraseBuf));

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
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char hostBuf[256] = {0};
    int port = 22;

    if (argc > 0) napi_get_value_string_utf8(env, args[0], hostBuf, sizeof(hostBuf), nullptr);
    if (argc > 1) napi_get_value_int32(env, args[1], &port);

    SshHostKeyInfo res = probeSshHostKey(std::string(hostBuf), port);

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
    if (g_activeConnection) {
        g_activeConnection->requestFrameRefresh();
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

    napi_create_function(env, "probeRdpCertificate", NAPI_AUTO_LENGTH,
                         NapiProbeRdpCertificate, nullptr, &fn);
    napi_set_named_property(env, exports, "probeRdpCertificate", fn);

    napi_create_function(env, "probeRdpCertificateAsync", NAPI_AUTO_LENGTH,
                         NapiProbeRdpCertificateAsync, nullptr, &fn);
    napi_set_named_property(env, exports, "probeRdpCertificateAsync", fn);

    napi_create_function(env, "getRdpRenderStats", NAPI_AUTO_LENGTH,
                         NapiGetRdpRenderStats, nullptr, &fn);
    napi_set_named_property(env, exports, "getRdpRenderStats", fn);
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

    napi_create_function(env, "disconnectAll", NAPI_AUTO_LENGTH,
                         NapiDisconnectAll, nullptr, &fn);
    napi_set_named_property(env, exports, "disconnectAll", fn);

    napi_create_function(env, "sendKey", NAPI_AUTO_LENGTH,
                         NapiSendKey, nullptr, &fn);
    napi_set_named_property(env, exports, "sendKey", fn);

    napi_create_function(env, "sendMouse", NAPI_AUTO_LENGTH,
                         NapiSendMouse, nullptr, &fn);
    napi_set_named_property(env, exports, "sendMouse", fn);

    napi_create_function(env, "sendMouseWheel", NAPI_AUTO_LENGTH,
                         NapiSendMouseWheel, nullptr, &fn);
    napi_set_named_property(env, exports, "sendMouseWheel", fn);

    napi_create_function(env, "sendText", NAPI_AUTO_LENGTH,
                         NapiSendText, nullptr, &fn);
    napi_set_named_property(env, exports, "sendText", fn);

    napi_create_function(env, "sendFile", NAPI_AUTO_LENGTH,
                         NapiSendFile, nullptr, &fn);
    napi_set_named_property(env, exports, "sendFile", fn);

    napi_create_function(env, "writeRemoteFileChunk", NAPI_AUTO_LENGTH,
                         NapiWriteRemoteFileChunk, nullptr, &fn);
    napi_set_named_property(env, exports, "writeRemoteFileChunk", fn);

    napi_create_function(env, "listRemoteDir", NAPI_AUTO_LENGTH,
                         NapiListRemoteDir, nullptr, &fn);
    napi_set_named_property(env, exports, "listRemoteDir", fn);

    napi_create_function(env, "readRemoteFile", NAPI_AUTO_LENGTH,
                         NapiReadRemoteFile, nullptr, &fn);
    napi_set_named_property(env, exports, "readRemoteFile", fn);

    napi_create_function(env, "readRemoteFileChunk", NAPI_AUTO_LENGTH,
                         NapiReadRemoteFileChunk, nullptr, &fn);
    napi_set_named_property(env, exports, "readRemoteFileChunk", fn);

    napi_create_function(env, "removeRemoteFile", NAPI_AUTO_LENGTH,
                         NapiRemoveRemoteFile, nullptr, &fn);
    napi_set_named_property(env, exports, "removeRemoteFile", fn);

    napi_create_function(env, "removeRemoteDir", NAPI_AUTO_LENGTH,
                         NapiRemoveRemoteDir, nullptr, &fn);
    napi_set_named_property(env, exports, "removeRemoteDir", fn);

    napi_create_function(env, "makeRemoteDir", NAPI_AUTO_LENGTH,
                         NapiMakeRemoteDir, nullptr, &fn);
    napi_set_named_property(env, exports, "makeRemoteDir", fn);

    napi_create_function(env, "renameRemotePath", NAPI_AUTO_LENGTH,
                         NapiRenameRemotePath, nullptr, &fn);
    napi_set_named_property(env, exports, "renameRemotePath", fn);

    napi_create_function(env, "sendClipboard", NAPI_AUTO_LENGTH,
                         NapiSendClipboard, nullptr, &fn);
    napi_set_named_property(env, exports, "sendClipboard", fn);
    napi_create_function(env, "getSessionClipboardText", NAPI_AUTO_LENGTH,
                         NapiGetSessionClipboardText, nullptr, &fn);
    napi_set_named_property(env, exports, "getSessionClipboardText", fn);
    napi_create_function(env, "isSessionClipboardReady", NAPI_AUTO_LENGTH,
                         NapiIsSessionClipboardReady, nullptr, &fn);
    napi_set_named_property(env, exports, "isSessionClipboardReady", fn);

    napi_create_function(env, "getConnectionState", NAPI_AUTO_LENGTH,
                         NapiGetConnectionState, nullptr, &fn);
    napi_set_named_property(env, exports, "getConnectionState", fn);

    napi_create_function(env, "getConnectionLastMessage", NAPI_AUTO_LENGTH,
                         NapiGetConnectionLastMessage, nullptr, &fn);
    napi_set_named_property(env, exports, "getConnectionLastMessage", fn);

    napi_create_function(env, "getRustDeskLastError", NAPI_AUTO_LENGTH,
                         NapiGetRustDeskLastError, nullptr, &fn);
    napi_set_named_property(env, exports, "getRustDeskLastError", fn);

    napi_create_function(env, "readData", NAPI_AUTO_LENGTH,
                         NapiReadData, nullptr, &fn);
    napi_set_named_property(env, exports, "readData", fn);

    napi_create_function(env, "resizePty", NAPI_AUTO_LENGTH,
                         NapiResizePty, nullptr, &fn);
    napi_set_named_property(env, exports, "resizePty", fn);

    napi_create_function(env, "measureSshLatency", NAPI_AUTO_LENGTH,
                         NapiMeasureSshLatency, nullptr, &fn);
    napi_set_named_property(env, exports, "measureSshLatency", fn);

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
