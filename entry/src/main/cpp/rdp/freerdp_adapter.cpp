/**
 * freerdp_adapter.cpp — FreeRDP 3.x 协议适配器
 *
 * 双路径架构:
 *   1. USE_REAL_FREERDP: FreeRDP 3.x 客户端 (freerdp_new/freerdp_connect/NLA/GFX)
 *   2. 默认回退: 手写 TCP/X.224/RDP Negotiation/MCS 骨架
 */

#include "freerdp_adapter.h"
#include "extensions/extension_registry.h"
#include "render/gl_renderer.h"
#include "render/video_perf_counters.h"
#include "video/video_activity_state.h"
#include "common/safe_log.h"
#include "rdp_audio_policy.h"
#include "rdp_auth_identity_policy.h"
#include "rdp_background_frame_cache.h"
#include "rdp_certificate_policy.h"
#include "rdp_frame_pump.h"
#include "rdp_keymap.h"
#include "rdp_performance_policy.h"
#include "rdp_input_queue.h"
#include "rdp_shutdown_state.h"
#ifdef USE_REAL_FREERDP
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/gdi/gfx.h>
#endif
#include <hilog/log.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <functional>
#include <iomanip>
#include <sstream>
#include <thread>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "RDP_ADAPTER"

namespace {

constexpr int kDefaultRdpPort = 3389;
constexpr int kRdpCertFlagUntrustedRoot = 0x01;
constexpr int kRdpCertFlagHostMismatch = 0x02;

std::string sha256FingerprintFromCert(X509* cert) {
    if (!cert) {
        return "";
    }
    unsigned char digest[EVP_MAX_MD_SIZE] = {0};
    unsigned int digestLen = 0;
    if (X509_digest(cert, EVP_sha256(), digest, &digestLen) != 1 || digestLen == 0) {
        return "";
    }
    std::ostringstream oss;
    oss << "sha256:";
    for (unsigned int i = 0; i < digestLen; ++i) {
        oss << std::hex << std::setfill('0') << std::setw(2)
            << static_cast<unsigned int>(digest[i]);
    }
    return oss.str();
}

std::string x509NameToString(X509_NAME* name) {
    if (!name) {
        return "";
    }
    char* text = X509_NAME_oneline(name, nullptr, 0);
    if (!text) {
        return "";
    }
    std::string out(text);
    OPENSSL_free(text);
    return out;
}

std::string x509CommonName(X509* cert) {
    if (!cert) {
        return "";
    }
    char buffer[256] = {0};
    const int len = X509_NAME_get_text_by_NID(X509_get_subject_name(cert), NID_commonName,
                                               buffer, sizeof(buffer));
    return len > 0 ? std::string(buffer, static_cast<size_t>(len)) : "";
}

int64_t probeNowUs() {
    using clock = std::chrono::steady_clock;
    return std::chrono::duration_cast<std::chrono::microseconds>(
        clock::now().time_since_epoch()).count();
}

RdpCertificateInfo makeProbeError(const std::string& host, int port, int code,
                                  const std::string& message) {
    RdpCertificateInfo info;
    info.host = host;
    info.port = port > 0 ? port : kDefaultRdpPort;
    info.errorCode = code;
    info.errorMessage = message;
    OH_LOG_WARN(LOG_APP, "[RDP-CERT] probe failed host=%{public}s:%{public}d code=%{public}d msg=%{public}s",
                SafeLog::MaskHost(host).c_str(), info.port, code, message.c_str());
    return info;
}

int connectWithTimeout(int fd, const sockaddr* addr, socklen_t addrLen, int timeoutMs) {
    const int oldFlags = fcntl(fd, F_GETFL, 0);
    if (oldFlags < 0) {
        return -errno;
    }
    if (fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK) < 0) {
        return -errno;
    }
    int rc = connect(fd, addr, addrLen);
    if (rc == 0) {
        fcntl(fd, F_SETFL, oldFlags);
        return 0;
    }
    if (errno != EINPROGRESS) {
        const int err = errno;
        fcntl(fd, F_SETFL, oldFlags);
        return -err;
    }

    fd_set wfds;
    FD_ZERO(&wfds);
    FD_SET(fd, &wfds);
    timeval tv {};
    tv.tv_sec = timeoutMs / 1000;
    tv.tv_usec = (timeoutMs % 1000) * 1000;
    rc = select(fd + 1, nullptr, &wfds, nullptr, &tv);
    if (rc <= 0) {
        fcntl(fd, F_SETFL, oldFlags);
        return rc == 0 ? -ETIMEDOUT : -errno;
    }
    int soError = 0;
    socklen_t soErrorLen = sizeof(soError);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soErrorLen) < 0) {
        fcntl(fd, F_SETFL, oldFlags);
        return -errno;
    }
    fcntl(fd, F_SETFL, oldFlags);
    return soError == 0 ? 0 : -soError;
}

bool sendAll(int fd, const uint8_t* data, size_t size) {
    size_t sent = 0;
    while (sent < size) {
        const ssize_t n = send(fd, data + sent, size - sent, 0);
        if (n <= 0) {
            return false;
        }
        sent += static_cast<size_t>(n);
    }
    return true;
}

RdpCertificateInfo probeRdpCertificateOverTls(const std::string& host, int port,
                                              const std::string& serverName) {
    const int effectivePort = port > 0 ? port : kDefaultRdpPort;
    const std::string verifyName = serverName.empty() ? host : serverName;
    const std::string logHost = SafeLog::MaskHost(host);
    const std::string logServerName = serverName.empty() ? "<host>" : SafeLog::MaskHost(serverName);
    const int64_t startedUs = probeNowUs();
    OH_LOG_INFO(LOG_APP, "[RDP-CERT] probe start host=%{public}s:%{public}d targetName=%{public}s",
                logHost.c_str(), effectivePort, logServerName.c_str());
    if (host.empty()) {
        return makeProbeError(host, effectivePort, -10, "RDP host is empty");
    }

    addrinfo hints {};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo* results = nullptr;
    const std::string portText = std::to_string(effectivePort);
    const int gai = getaddrinfo(host.c_str(), portText.c_str(), &hints, &results);
    if (gai != 0 || !results) {
        OH_LOG_WARN(LOG_APP, "[RDP-CERT] resolve failed host=%{public}s:%{public}d gai=%{public}d",
                    logHost.c_str(), effectivePort, gai);
        return makeProbeError(host, effectivePort, -11, "Unable to resolve RDP host");
    }
    OH_LOG_INFO(LOG_APP, "[RDP-CERT] resolve ok host=%{public}s:%{public}d", logHost.c_str(), effectivePort);

    int fd = -1;
    int lastConnectErr = 0;
    for (addrinfo* ai = results; ai != nullptr; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) {
            continue;
        }
        timeval tv {};
        tv.tv_sec = 8;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        const int rc = connectWithTimeout(fd, ai->ai_addr, static_cast<socklen_t>(ai->ai_addrlen), 5000);
        if (rc == 0) {
            break;
        }
        lastConnectErr = rc;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(results);
    if (fd < 0) {
        OH_LOG_WARN(LOG_APP, "[RDP-CERT] tcp connect failed host=%{public}s:%{public}d err=%{public}d elapsedMs=%{public}lld",
                    logHost.c_str(), effectivePort, lastConnectErr,
                    static_cast<long long>((probeNowUs() - startedUs) / 1000));
        return makeProbeError(host, effectivePort, -12, "Unable to connect to RDP host");
    }
    OH_LOG_INFO(LOG_APP, "[RDP-CERT] tcp connected host=%{public}s:%{public}d elapsedMs=%{public}lld",
                logHost.c_str(), effectivePort,
                static_cast<long long>((probeNowUs() - startedUs) / 1000));

    static const uint8_t kNegotiateTls[] = {
        0x03, 0x00, 0x00, 0x13,
        0x0e, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x08, 0x00,
        0x03, 0x00, 0x00, 0x00
    };
    if (!sendAll(fd, kNegotiateTls, sizeof(kNegotiateTls))) {
        close(fd);
        return makeProbeError(host, effectivePort, -13, "Unable to send RDP negotiation request");
    }
    OH_LOG_INFO(LOG_APP, "[RDP-CERT] negotiation request sent host=%{public}s:%{public}d",
                logHost.c_str(), effectivePort);

    uint8_t response[64] = {0};
    const ssize_t received = recv(fd, response, sizeof(response), 0);
    if (received < 11 || response[0] != 0x03) {
        close(fd);
        return makeProbeError(host, effectivePort, -14, "RDP negotiation response is invalid");
    }
    OH_LOG_INFO(LOG_APP, "[RDP-CERT] negotiation response received host=%{public}s:%{public}d bytes=%{public}zd",
                logHost.c_str(), effectivePort, received);

    SSL_CTX* sslCtx = SSL_CTX_new(TLS_client_method());
    if (!sslCtx) {
        close(fd);
        return makeProbeError(host, effectivePort, -15, "Unable to create TLS context");
    }
    SSL_CTX_set_verify(sslCtx, SSL_VERIFY_NONE, nullptr);
    SSL* ssl = SSL_new(sslCtx);
    if (!ssl) {
        SSL_CTX_free(sslCtx);
        close(fd);
        return makeProbeError(host, effectivePort, -16, "Unable to create TLS session");
    }
    SSL_set_fd(ssl, fd);
    if (!verifyName.empty()) {
        SSL_set_tlsext_host_name(ssl, verifyName.c_str());
    }
    if (SSL_connect(ssl) != 1) {
        const unsigned long err = ERR_get_error();
        SSL_free(ssl);
        SSL_CTX_free(sslCtx);
        close(fd);
        OH_LOG_WARN(LOG_APP, "[RDP-CERT] tls handshake failed host=%{public}s:%{public}d sslErr=%{public}lu",
                    logHost.c_str(), effectivePort, err);
        return makeProbeError(host, effectivePort, static_cast<int>(err),
                              "RDP TLS handshake failed");
    }
    OH_LOG_INFO(LOG_APP, "[RDP-CERT] tls handshake ok host=%{public}s:%{public}d",
                logHost.c_str(), effectivePort);

    X509* cert = SSL_get_peer_certificate(ssl);
    if (!cert) {
        SSL_free(ssl);
        SSL_CTX_free(sslCtx);
        close(fd);
        return makeProbeError(host, effectivePort, -17, "RDP host did not provide a certificate");
    }

    RdpCertificateInfo info;
    info.ok = true;
    info.host = host;
    info.port = effectivePort;
    info.commonName = x509CommonName(cert);
    info.subject = x509NameToString(X509_get_subject_name(cert));
    info.issuer = x509NameToString(X509_get_issuer_name(cert));
    info.fingerprintSha256 = sha256FingerprintFromCert(cert);

    const int hostCheck = verifyName.empty() ? 1 :
        X509_check_host(cert, verifyName.c_str(), verifyName.size(), 0, nullptr);
    info.hostMismatch = hostCheck != 1;

    X509_STORE* store = X509_STORE_new();
    X509_STORE_CTX* storeCtx = X509_STORE_CTX_new();
    if (store && storeCtx && X509_STORE_set_default_paths(store) == 1 &&
        X509_STORE_CTX_init(storeCtx, store, cert, nullptr) == 1) {
        info.rootTrusted = X509_verify_cert(storeCtx) == 1;
    }
    if (!info.rootTrusted) {
        info.flags |= kRdpCertFlagUntrustedRoot;
    }
    if (info.hostMismatch) {
        info.flags |= kRdpCertFlagHostMismatch;
    }

    if (storeCtx) {
        X509_STORE_CTX_free(storeCtx);
    }
    if (store) {
        X509_STORE_free(store);
    }
    X509_free(cert);
    SSL_shutdown(ssl);
    SSL_free(ssl);
    SSL_CTX_free(sslCtx);
    close(fd);
    OH_LOG_INFO(LOG_APP,
                "[RDP-CERT] probe ok host=%{public}s:%{public}d fingerprint=%{public}s rootTrusted=%{public}s hostMismatch=%{public}s elapsedMs=%{public}lld",
                logHost.c_str(), effectivePort,
                SafeLog::HashForLog(info.fingerprintSha256).c_str(),
                info.rootTrusted ? "true" : "false",
                info.hostMismatch ? "true" : "false",
                static_cast<long long>((probeNowUs() - startedUs) / 1000));
    return info;
}

} // namespace

#ifdef USE_REAL_FREERDP
// ============================================================
// 路径 1: 真实 FreeRDP 3.x 客户端
// ============================================================
#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/addin.h>
#include <freerdp/codec/color.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/event.h>
#include <freerdp/input.h>
#include <freerdp/settings_types.h>
#include <winpr/wtypes.h>
#include <winpr/thread.h>
#include <pthread.h>
#include <string>
#include <vector>
#include <cstring>
#include <mutex>
#include <cstdio>
#include <chrono>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "RDP_ADAPTER"

#define RDP_TCP_PORT 3389

extern "C" UINT freerdp_ohos_rdpdr_register_drive(rdpContext* context, const char* name,
                                                  const char* path, uint32_t* pid);

static const char* safeFreeRdpString(const char* value, const char* fallback) {
    return value ? value : fallback;
}

static std::string sanitizeRdpDriveName(const std::string& name) {
    std::string out;
    for (char ch : name) {
        const bool alnum = (ch >= '0' && ch <= '9') ||
                           (ch >= 'A' && ch <= 'Z') ||
                           (ch >= 'a' && ch <= 'z');
        if (alnum || ch == '_' || ch == '-') {
            out.push_back(ch);
        } else if (ch == ' ' || ch == '.' || ch == '/') {
            out.push_back('_');
        }
        if (out.size() >= 20) {
            break;
        }
    }
    return out.empty() ? "RemoteDesktop" : out;
}

static int64_t steadyNowUs() {
    using clock = std::chrono::steady_clock;
    return std::chrono::duration_cast<std::chrono::microseconds>(
        clock::now().time_since_epoch()).count();
}

static Render::VideoPerfCounters g_rdpVideoPerf;

// ---- RDP 错误码 → 官方可读描述 ----
static const char* freerdpErrorName(DWORD err) {
    return safeFreeRdpString(freerdp_get_last_error_name(err), "UNKNOWN_FREERDP_ERROR");
}

static const char* freerdpErrorString(DWORD err) {
    return safeFreeRdpString(freerdp_get_last_error_string(err), "");
}

static const char* freerdpErrorCategory(DWORD err) {
    return safeFreeRdpString(freerdp_get_last_error_category(err), "UNKNOWN");
}

static const char* freerdpErrorHint(DWORD err) {
    switch (err) {
        case FREERDP_ERROR_TLS_CONNECT_FAILED:
            return "RDP TLS/安全层连接失败: 需要继续检查 NLA/CredSSP、证书安全层或服务端安全策略";
        case FREERDP_ERROR_AUTHENTICATION_FAILED:
            return "Windows 认证失败: 请检查用户名、域和密码";
        case FREERDP_ERROR_CONNECT_PASSWORD_EXPIRED:
            return "Windows 密码已过期";
        case FREERDP_ERROR_CONNECT_ACCOUNT_DISABLED:
            return "Windows 账号已禁用";
        case FREERDP_ERROR_CONNECT_ACCOUNT_LOCKED_OUT:
            return "Windows 账号已锁定";
        case FREERDP_ERROR_CONNECT_ACCOUNT_RESTRICTION:
            return "Windows 账号受登录限制";
        case FREERDP_ERROR_CONNECT_LOGON_TYPE_NOT_GRANTED:
            return "Windows 拒绝远程登录类型: 请检查 Remote Desktop Users、Administrators 和本地安全策略";
        case FREERDP_ERROR_INSUFFICIENT_PRIVILEGES:
        case FREERDP_ERROR_SERVER_INSUFFICIENT_PRIVILEGES:
            return "Windows 拒绝登录: 当前账号没有远程桌面登录权限，或被本机/域策略拒绝";
        default:
            return "";
    }
}

static std::string freerdpErrorMessage(DWORD err, const char* errName) {
    char code[9] = {0};
    std::snprintf(code, sizeof(code), "%08X", static_cast<unsigned int>(err));
    std::string message = std::string("FreeRDP 连接错误: ") + errName + " [E-CONN-0x" + code + "]";
    const char* official = freerdpErrorString(err);
    if (official && official[0] != '\0') {
        message += " ";
        message += official;
    }
    const char* hint = freerdpErrorHint(err);
    if (hint[0] != '\0') {
        message += " ";
        message += hint;
    }
    return message;
}

static std::string rdpErrorInfoMessage(UINT32 code) {
    char codeBuf[11] = {0};
    std::snprintf(codeBuf, sizeof(codeBuf), "0x%08X", static_cast<unsigned int>(code));
    const char* name = safeFreeRdpString(freerdp_get_error_info_name(code), "UNKNOWN_ERRINFO");
    const char* official = safeFreeRdpString(freerdp_get_error_info_string(code), "");
    const char* category = safeFreeRdpString(freerdp_get_error_info_category(code), "UNKNOWN");
    std::string message = std::string("RDP server ErrorInfo: ") + name +
        " [E-RDP-ERRINFO-" + codeBuf + "] category=" + category;
    if (official[0] != '\0') {
        message += " ";
        message += official;
    }
    return message;
}

static void logFreeRdpFailureDiagnostics(freerdp* instance, rdpSettings* settings, DWORD err, const char* errName) {
    const char* official = freerdpErrorString(err);
    const char* category = freerdpErrorCategory(err);
    const UINT32 selectedProtocol = settings ? freerdp_settings_get_uint32(settings, FreeRDP_SelectedProtocol) : 0;
    const UINT32 errorInfo = instance ? freerdp_error_info(instance) : 0;
    CONNECTION_STATE state = CONNECTION_STATE_INITIAL;
    const char* stateName = "UNKNOWN";

    if (instance && instance->context) {
        state = freerdp_get_state(instance->context);
        stateName = safeFreeRdpString(freerdp_state_string(state), "UNKNOWN");
    }

    OH_LOG_ERROR(LOG_APP, "[RDP] freerdp_connect 失败: code=0x%{public}08X name=%{public}s official=%{public}s category=%{public}s",
                 err, errName, official, category);
    OH_LOG_ERROR(LOG_APP, "[RDP] failure detail: selectedProtocol=0x%{public}08X freerdp_error_info=0x%{public}08X nla_sspi=skipped freerdp_state=%{public}d(%{public}s)",
                 selectedProtocol, errorInfo, static_cast<int>(state), stateName);
}

// ---- UTF-8 → UTF-16 code units 解码器 ----
static std::vector<UINT16> utf8ToUtf16(const std::string& text) {
    std::vector<UINT16> result;
    const uint8_t* p = reinterpret_cast<const uint8_t*>(text.data());
    const uint8_t* end = p + text.size();
    while (p < end) {
        uint32_t cp;
        if ((*p & 0x80) == 0) {
            cp = *p++;  // ASCII
        } else if ((*p & 0xE0) == 0xC0 && p + 1 < end) {
            cp = ((*p & 0x1F) << 6) | (*(p+1) & 0x3F); p += 2;
        } else if ((*p & 0xF0) == 0xE0 && p + 2 < end) {
            cp = ((*p & 0x0F) << 12) | ((*(p+1) & 0x3F) << 6) | (*(p+2) & 0x3F); p += 3;
        } else if ((*p & 0xF8) == 0xF0 && p + 3 < end) {
            cp = ((*p & 0x07) << 18) | ((*(p+1) & 0x3F) << 12) | ((*(p+2) & 0x3F) << 6) | (*(p+3) & 0x3F); p += 4;
        } else { p++; continue; }  // 跳过无效字节
        // 编码为 UTF-16
        if (cp <= 0xFFFF) {
            result.push_back(static_cast<UINT16>(cp));
        } else if (cp <= 0x10FFFF) {
            cp -= 0x10000;
            result.push_back(static_cast<UINT16>(0xD800 | (cp >> 10)));
            result.push_back(static_cast<UINT16>(0xDC00 | (cp & 0x3FF)));
        }
    }
    return result;
}

static std::atomic<uint64_t> g_nextRdpSessionGeneration {1};

struct FreeRdpAdapter::Impl {
    TransferRuntimeStatus transferStatus;
    ConnectionConfig        config;
    ConnectionState         state = ConnectionState::DISCONNECTED;
    VideoFrameCallback      videoCallback;
    AudioDataCallback       audioCallback;
    ConnectionStateCallback stateCallback;
    std::string             clipboardText;
    CliprdrClientContext*   cliprdr = nullptr;
    pthread_t               eventThread = 0;
    pthread_t               connectThread = 0;
    pthread_t               driveThread = 0;
    std::mutex              stateMutex;
    std::mutex              instanceMutex;
    std::mutex              shutdownMutex;
    std::mutex              workerLifecycleMutex;
    std::mutex              renderMutex;
    RdpShutdown::State      shutdownState;
    std::atomic<uint64_t>   sessionGeneration {0};
    std::atomic<int64_t>    shutdownStartedUs {0};
    RdpFramePump            framePump;
    std::shared_ptr<RdpDamageAccumulator> damageAccumulator {
        std::make_shared<RdpDamageAccumulator>()
    };
    std::atomic<bool>       backgroundVideoPrewarmEnabled {false};
    std::atomic<uint32_t>   backgroundVideoPrewarmIntervalMs {1000};
    RdpBackgroundFrameCache backgroundFrameCache;
    std::mutex              inputQueueMutex;
    std::condition_variable inputQueueCv;
    std::thread             inputQueueThread;
    RdpInputQueue           inputQueue;
    uint64_t                inputQueueGeneration = 0;
    bool                    inputQueueRunning = false;
    bool                    inputQueueStop = false;
    std::atomic<bool>       connecting {false};
    std::atomic<bool>       connectThreadStarted {false};
    std::atomic<bool>       driveThreadStarted {false};
    std::atomic<bool>       stopRequested {false};
    std::atomic<bool>       gdiInitialized {false};
    std::atomic<bool>       presentationEnabled {false};
    uint32_t                driveDeviceId = 0;
    std::atomic<int>        paintCount {0};
    std::atomic<int64_t>    firstPaintUs {0};
    std::atomic<int64_t>    lastPaintUs {0};
    int64_t                 lastRenderDiagUs = 0;
    std::atomic<uint64_t>   lastRenderBytes {0};
    int                     lastFrameWidth = 0;
    int                     lastFrameHeight = 0;
    bool                    forceNextFullFrame = false;
    std::string             graphicsMode = "gdi";

    void beginShutdownTrace() {
        shutdownStartedUs.store(steadyNowUs(), std::memory_order_release);
        traceShutdown("request", "begin");
    }

    void traceShutdown(const char* phase, const char* result) const {
        const int64_t startedUs = shutdownStartedUs.load(std::memory_order_acquire);
        const int64_t elapsedUs = startedUs > 0 ? steadyNowUs() - startedUs : 0;
        const uint64_t threadId = static_cast<uint64_t>(
            std::hash<std::thread::id>{}(std::this_thread::get_id()));
        OH_LOG_INFO(LOG_APP,
            "[RDP-SHUTDOWN] generation=%{public}llu phase=%{public}s result=%{public}s elapsedUs=%{public}lld thread=%{public}llu",
            static_cast<unsigned long long>(sessionGeneration.load(std::memory_order_acquire)),
            phase ? phase : "unknown",
            result ? result : "unknown",
            static_cast<long long>(elapsedUs),
            static_cast<unsigned long long>(threadId));
    }

    void sendQueuedInputEvent(FreeRdpAdapter* owner, const RdpQueuedInputEvent& event,
                              uint64_t workerGeneration) {
        std::lock_guard<std::mutex> queueLock(inputQueueMutex);
        if (!inputQueueRunning || inputQueueStop || workerGeneration != inputQueueGeneration) {
            return;
        }
        std::lock_guard<std::mutex> lock(instanceMutex);
        if (!owner || !owner->instance_ || !owner->instance_->input) {
            return;
        }
        switch (event.type) {
            case RdpInputEventType::Key:
                freerdp_input_send_keyboard_event(owner->instance_->input, event.flags, event.code);
                break;
            case RdpInputEventType::TextBatch:
                DispatchTextBatch(event.text, KBD_FLAGS_RELEASE,
                    [this, owner](uint16_t flags, uint16_t code) {
                        freerdp_input_send_unicode_keyboard_event(owner->instance_->input, flags, code);
                    });
                break;
            case RdpInputEventType::Mouse:
            case RdpInputEventType::MouseWheel:
                freerdp_input_send_mouse_event(owner->instance_->input, event.flags,
                                               static_cast<UINT16>(event.x),
                                               static_cast<UINT16>(event.y));
                break;
        }
    }

    void inputQueueWorkerLoop(FreeRdpAdapter* owner, uint64_t workerGeneration) {
        while (true) {
            RdpQueuedInputEvent event;
            {
                std::unique_lock<std::mutex> lock(inputQueueMutex);
                inputQueueCv.wait(lock, [this]() {
                    return inputQueueStop || inputQueue.depth() > 0;
                });
                if (inputQueueStop || workerGeneration != inputQueueGeneration) {
                    break;
                }
                if (!inputQueue.pop(event)) {
                    continue;
                }
            }
            sendQueuedInputEvent(owner, event, workerGeneration);
        }
    }

    void startInputQueueWorker(FreeRdpAdapter* owner) {
        std::lock_guard<std::mutex> lock(inputQueueMutex);
        if (inputQueueRunning) {
            return;
        }
        inputQueueStop = false;
        inputQueue.clear();
        inputQueue.resetMetrics();
        ++inputQueueGeneration;
        const uint64_t workerGeneration = inputQueueGeneration;
        inputQueueRunning = true;
        try {
            inputQueueThread = std::thread([this, owner, workerGeneration]() {
                inputQueueWorkerLoop(owner, workerGeneration);
            });
        } catch (const std::exception& e) {
            inputQueueRunning = false;
            OH_LOG_WARN(LOG_APP, "[RDP] input queue worker start failed: %{public}s", e.what());
        } catch (...) {
            inputQueueRunning = false;
            OH_LOG_WARN(LOG_APP, "[RDP] input queue worker start failed: unknown");
        }
    }

    void stopInputQueueWorker() {
        {
            std::lock_guard<std::mutex> lock(inputQueueMutex);
            if (!inputQueueRunning) {
                return;
            }
            inputQueueStop = true;
            ++inputQueueGeneration;
            inputQueue.clear();
        }
        inputQueueCv.notify_all();
        if (inputQueueThread.joinable()) {
            inputQueueThread.join();
        }
        {
            std::lock_guard<std::mutex> lock(inputQueueMutex);
            inputQueueRunning = false;
            inputQueueStop = false;
            inputQueue.clear();
        }
    }

    void enqueueInputEvent(RdpQueuedInputEvent event) {
        {
            std::lock_guard<std::mutex> lock(inputQueueMutex);
            if (!inputQueueRunning || inputQueueStop) {
                return;
            }
            inputQueue.enqueue(std::move(event));
        }
        inputQueueCv.notify_one();
    }

    void enqueueMouseButtonWithMove(UINT16 moveFlags, UINT16 buttonFlags, UINT16 x, UINT16 y) {
        {
            std::lock_guard<std::mutex> lock(inputQueueMutex);
            if (!inputQueueRunning || inputQueueStop) {
                return;
            }
            // The paired move is non-disposable so a following button event
            // cannot purge it before the worker dispatches the click target.
            inputQueue.enqueue(RdpQueuedInputEvent::Mouse(moveFlags, 0, x, y, false));
            inputQueue.enqueue(RdpQueuedInputEvent::Mouse(buttonFlags, 0, x, y, false));
        }
        inputQueueCv.notify_one();
    }

    void startSessionWorkers(FreeRdpAdapter* owner) {
        std::lock_guard<std::mutex> lifecycleLock(workerLifecycleMutex);
        startInputQueueWorker(owner);
        if (!framePump.start()) {
            presentationEnabled.store(false, std::memory_order_release);
            OH_LOG_ERROR(LOG_APP, "[RDP] frame pump unavailable; presentation remains disabled");
            return;
        }
    }

    void stopSessionWorkers() {
        std::lock_guard<std::mutex> lifecycleLock(workerLifecycleMutex);
        traceShutdown("input-stop", "begin");
        stopInputQueueWorker();
        traceShutdown("input-stop", "complete");
        traceShutdown("frame-pump-stop", "begin");
        framePump.stop();
        traceShutdown("frame-pump-stop", "complete");
        damageAccumulator->clear();
    }

    void setState(ConnectionState s, const std::string& msg = "") {
        std::lock_guard<std::mutex> lock(stateMutex);
        state = s;
        if (stateCallback) { stateCallback(s, msg); }
    }
};

static std::mutex g_rdpAudioCallbackMutex;
static AudioDataCallback g_rdpAudioCallback;
static FreeRdpAdapter* g_rdpAudioCallbackOwner = nullptr;
static std::once_flag g_rdpAddinProviderOnce;

static void ensureFreeRdpStaticAddinProvider() {
    std::call_once(g_rdpAddinProviderOnce, []() {
        const int rc = freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry,
                                                       FREERDP_ADDIN_STATIC);
        OH_LOG_INFO(LOG_APP, "[RDP] static addin provider registered rc=%{public}d provider=%{public}p",
                    rc, reinterpret_cast<void*>(freerdp_get_current_addin_provider()));
    });
}

static void logRdpChannelSettings(rdpSettings* settings, const char* label) {
    if (!settings) {
        return;
    }
    OH_LOG_INFO(LOG_APP,
                "[RDP] channel settings %{public}s: audio=%{public}s clipboard=%{public}s deviceRedirection=%{public}s deviceCount=%{public}u static=%{public}u dynamic=%{public}u supportDynamic=%{public}s",
                label ? label : "unknown",
                freerdp_settings_get_bool(settings, FreeRDP_AudioPlayback) ? "true" : "false",
                freerdp_settings_get_bool(settings, FreeRDP_RedirectClipboard) ? "true" : "false",
                freerdp_settings_get_bool(settings, FreeRDP_DeviceRedirection) ? "true" : "false",
                freerdp_settings_get_uint32(settings, FreeRDP_DeviceCount),
                freerdp_settings_get_uint32(settings, FreeRDP_StaticChannelCount),
                freerdp_settings_get_uint32(settings, FreeRDP_DynamicChannelCount),
                freerdp_settings_get_bool(settings, FreeRDP_SupportDynamicChannels) ? "true" : "false");
}

static bool compiledWithRdpGfx() {
#if defined(CHANNEL_RDPGFX) && defined(CHANNEL_RDPGFX_CLIENT)
    return true;
#else
    return false;
#endif
}

static bool compiledWithGfxH264() {
#if defined(WITH_GFX_H264)
    return true;
#else
    return false;
#endif
}

static bool rdpGfxPipelineConsumerAvailable() {
#if defined(CHANNEL_RDPGFX_CLIENT)
    return true;
#else
    return false;
#endif
}

static bool rdpGfxResetPathSafe() {
    // Current OHOS RDP renderer consumes GDI primary buffers and does not yet
    // implement the full RDPGFX ResetGraphics/DesktopResize path safely.
    return false;
}

static RdpPerformancePolicy::GraphicsMode applyRdpPerformanceSettings(rdpSettings* settings) {
    const bool gfxAvailable = compiledWithRdpGfx();
    const bool h264Available = compiledWithGfxH264();
    const bool gfxConsumerAvailable = rdpGfxPipelineConsumerAvailable();
    const bool gfxResetSafe = rdpGfxResetPathSafe();
    const RdpPerformancePolicy::Settings perf =
        RdpPerformancePolicy::RecommendedLanSettings(gfxAvailable,
                                                     h264Available,
                                                     gfxConsumerAvailable,
                                                     gfxResetSafe);
    const RdpPerformancePolicy::GraphicsMode mode =
        RdpPerformancePolicy::SelectGraphicsMode(gfxAvailable,
                                                 h264Available,
                                                 gfxConsumerAvailable,
                                                 gfxResetSafe);

    freerdp_settings_set_bool(settings, FreeRDP_NetworkAutoDetect,
                              perf.networkAutoDetect ? TRUE : FALSE);
    freerdp_settings_set_uint32(settings, FreeRDP_ConnectionType, perf.connectionType);
    freerdp_settings_set_bool(settings, FreeRDP_SupportDynamicChannels,
                              perf.supportDynamicChannels ? TRUE : FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline,
                              perf.supportGraphicsPipeline ? TRUE : FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec,
                              perf.remoteFxCodec ? TRUE : FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_GfxH264,
                              perf.gfxH264 ? TRUE : FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_NSCodec,
                              perf.nsCodec ? TRUE : FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_NSCodecAllowSubsampling,
                              perf.nsCodecAllowSubsampling ? TRUE : FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_NSCodecAllowDynamicColorFidelity,
                              perf.nsCodecAllowDynamicColorFidelity ? TRUE : FALSE);
    freerdp_settings_set_uint32(settings, FreeRDP_NSCodecColorLossLevel,
                                perf.nsCodecColorLossLevel);
    freerdp_settings_set_uint32(settings, FreeRDP_FrameAcknowledge, perf.frameAcknowledge);

    OH_LOG_INFO(LOG_APP,
                "[RDP] performance settings: mode=%{public}s compiledGfx=%{public}s compiledH264=%{public}s gfxConsumer=%{public}s gfxResetSafe=%{public}s networkAuto=%{public}s connectionType=%{public}u gfx=%{public}s h264=%{public}s rfx=%{public}s frameAck=%{public}u",
                RdpPerformancePolicy::GraphicsModeName(mode),
                gfxAvailable ? "true" : "false",
                h264Available ? "true" : "false",
                gfxConsumerAvailable ? "true" : "false",
                gfxResetSafe ? "true" : "false",
                freerdp_settings_get_bool(settings, FreeRDP_NetworkAutoDetect) ? "true" : "false",
                freerdp_settings_get_uint32(settings, FreeRDP_ConnectionType),
                freerdp_settings_get_bool(settings, FreeRDP_SupportGraphicsPipeline) ? "true" : "false",
                freerdp_settings_get_bool(settings, FreeRDP_GfxH264) ? "true" : "false",
                freerdp_settings_get_bool(settings, FreeRDP_RemoteFxCodec) ? "true" : "false",
                freerdp_settings_get_uint32(settings, FreeRDP_FrameAcknowledge));
    return mode;
}

static FreeRdpAdapter* adapterFromInstance(freerdp* instance) {
    if (!instance || !instance->context) {
        return nullptr;
    }
    auto* ctx = reinterpret_cast<FreeRdpContext*>(instance->context);
    return ctx ? ctx->adapter : nullptr;
}

static std::string fingerprintFromPem(const BYTE* data, size_t length) {
    if (!data || length == 0) {
        return "";
    }
    BIO* bio = BIO_new_mem_buf(data, static_cast<int>(length));
    if (!bio) {
        return "";
    }
    X509* cert = PEM_read_bio_X509(bio, nullptr, nullptr, nullptr);
    BIO_free(bio);
    if (!cert) {
        return "";
    }
    std::string fingerprint = sha256FingerprintFromCert(cert);
    X509_free(cert);
    return fingerprint;
}

DWORD FreeRdpAdapter::evaluateCertificate(const char* host, UINT16 port,
                                          const char* commonName, const char* subject,
                                          const char* issuer, const std::string& fingerprint,
                                          DWORD flags) {
    const std::string logHost = SafeLog::MaskHost(host ? host : "");
    const std::string logCommonName = SafeLog::MaskHost(commonName ? commonName : "");
    const bool hostMismatch = (flags & VERIFY_CERT_FLAG_MISMATCH) != 0;

    ConnectionConfig& cfg = impl_->config;
    const bool fingerprintOk = RdpCertificatePolicy::FingerprintMatches(
        cfg.expectedRdpCertificateFingerprintSha256, fingerprint);
    const bool hostOk = !hostMismatch || cfg.rdpAllowHostMismatch;
    if (fingerprintOk && hostOk) {
        OH_LOG_WARN(LOG_APP,
            "[RDP] certificate accepted for this session host=%{public}s:%{public}u common_name=%{public}s flags=0x%{public}08X fingerprintMatch=%{public}s hostOk=%{public}s",
            logHost.c_str(), port, logCommonName.c_str(), flags,
            fingerprintOk ? "true" : "false", hostOk ? "true" : "false");
        return 2;
    }

    OH_LOG_ERROR(LOG_APP,
        "[RDP] certificate rejected host=%{public}s:%{public}u common_name=%{public}s flags=0x%{public}08X hostMismatch=%{public}s fingerprintMatch=%{public}s hostOk=%{public}s",
        logHost.c_str(), port, logCommonName.c_str(), flags,
        hostMismatch ? "true" : "false", fingerprintOk ? "true" : "false", hostOk ? "true" : "false");
    impl_->setState(ConnectionState::ERROR, "RDP certificate was not trusted or changed [E-RDP-CERT]");
    (void)subject;
    (void)issuer;
    return 0;
}

extern "C" UINT freerdp_ohos_rdpsnd_play(const BYTE* data, size_t size,
                                          UINT32 sampleRate, UINT16 channels,
                                          UINT16 bitsPerSample) {
    AudioDataCallback callback;
    {
        std::lock_guard<std::mutex> lock(g_rdpAudioCallbackMutex);
        callback = g_rdpAudioCallback;
    }
    if (!callback || !data || size == 0) {
        static uint64_t skippedAudioCount = 0;
        skippedAudioCount++;
        if (skippedAudioCount <= 10 || skippedAudioCount % 100 == 0) {
            OH_LOG_WARN(LOG_APP,
                "[RDP] rdpsnd play skipped #%{public}llu callback=%{public}s data=%{public}p size=%{public}zu",
                static_cast<unsigned long long>(skippedAudioCount),
                callback ? "yes" : "no",
                data,
                size);
        }
        return 0;
    }
    const RdpAudioPcmDecision pcmDecision =
        evaluateRdpAudioPcm(sampleRate, channels, bitsPerSample, size);
    if (!pcmDecision.accepted) {
        static uint64_t rejectedAudioCount = 0;
        rejectedAudioCount++;
        if (rejectedAudioCount <= 10 || rejectedAudioCount % 100 == 0) {
            OH_LOG_WARN(LOG_APP,
                "[RDP] rdpsnd PCM rejected #%{public}llu reason=%{public}s size=%{public}zu rate=%{public}u channels=%{public}u bits=%{public}u",
                static_cast<unsigned long long>(rejectedAudioCount),
                pcmDecision.reason,
                size,
                sampleRate,
                channels,
                bitsPerSample);
        }
        return 0;
    }
    static uint64_t rdpsndPlayCount = 0;
    rdpsndPlayCount++;
    if (rdpsndPlayCount <= 10 || rdpsndPlayCount % 100 == 0) {
        OH_LOG_INFO(LOG_APP,
            "[RDP] rdpsnd play #%{public}llu size=%{public}zu submit=%{public}zu rate=%{public}u channels=%{public}u bits=%{public}u",
            static_cast<unsigned long long>(rdpsndPlayCount),
            size,
            pcmDecision.bytesToSubmit,
            sampleRate,
            channels,
            bitsPerSample);
    }
    AudioData audio;
    audio.data = data;
    audio.size = pcmDecision.bytesToSubmit;
    audio.sampleRate = static_cast<int>(sampleRate);
    audio.channels = static_cast<int>(channels);
    audio.timestamp = static_cast<uint64_t>(steadyNowUs() / 1000);
    callback(audio);
    return 0;
}

// ---- 证书验证: 由 ArkTS 预检弹窗确认后, native 只接受匹配策略 ----
DWORD WINAPI FreeRdpAdapter::cbVerifyCertificate(freerdp* instance, const char* common_name,
                                                  const char* subject, const char* issuer,
                                                  const char* fingerprint, BOOL host_mismatch) {
    DWORD flags = host_mismatch ? VERIFY_CERT_FLAG_MISMATCH : VERIFY_CERT_FLAG_NONE;
    FreeRdpAdapter* self = adapterFromInstance(instance);
    return self ? self->evaluateCertificate(nullptr, 0, common_name, subject, issuer,
                                            fingerprint ? fingerprint : "", flags) : 0;
}

DWORD FreeRdpAdapter::cbVerifyCertificateEx(freerdp* instance, const char* host, UINT16 port,
                                            const char* common_name, const char* subject,
                                            const char* issuer, const char* fingerprint,
                                            DWORD flags) {
    FreeRdpAdapter* self = adapterFromInstance(instance);
    return self ? self->evaluateCertificate(host, port, common_name, subject, issuer,
                                            fingerprint ? fingerprint : "", flags) : 0;
}

DWORD FreeRdpAdapter::cbVerifyChangedCertificateEx(freerdp* instance, const char* host, UINT16 port,
                                                   const char* common_name, const char* subject,
                                                   const char* issuer, const char* new_fingerprint,
                                                   const char* /*old_subject*/, const char* /*old_issuer*/,
                                                   const char* /*old_fingerprint*/, DWORD flags) {
    FreeRdpAdapter* self = adapterFromInstance(instance);
    return self ? self->evaluateCertificate(host, port, common_name, subject, issuer,
                                            new_fingerprint ? new_fingerprint : "",
                                            flags | VERIFY_CERT_FLAG_CHANGED) : 0;
}

int FreeRdpAdapter::cbVerifyX509Certificate(freerdp* instance, const BYTE* data, size_t length,
                                            const char* hostname, UINT16 port, DWORD flags) {
    const std::string fingerprint = fingerprintFromPem(data, length);
    FreeRdpAdapter* self = adapterFromInstance(instance);
    return self ? static_cast<int>(self->evaluateCertificate(hostname, port, nullptr, nullptr,
                                                             nullptr, fingerprint, flags)) : 0;
}

static const char* logonErrorTypeName(UINT32 type) {
    switch (type) {
        case 0xFFFFFFF8: return "LOGON_MSG_SESSION_BUSY_OPTIONS";
        case 0xFFFFFFF9: return "LOGON_MSG_DISCONNECT_REFUSED";
        case 0xFFFFFFFA: return "LOGON_MSG_NO_PERMISSION";
        case 0xFFFFFFFB: return "LOGON_MSG_BUMP_OPTIONS";
        case 0xFFFFFFFC: return "LOGON_MSG_RECONNECT_OPTIONS";
        case 0xFFFFFFFD: return "LOGON_MSG_SESSION_TERMINATE";
        case 0xFFFFFFFE: return "LOGON_MSG_SESSION_CONTINUE";
        case 0x00000005: return "ERROR_CODE_ACCESS_DENIED";
        default: return "UNKNOWN";
    }
}

static const char* logonErrorDataName(UINT32 data) {
    switch (data) {
        case 0x00000000: return "LOGON_FAILED_BAD_PASSWORD";
        case 0x00000001: return "LOGON_FAILED_UPDATE_PASSWORD";
        case 0x00000002: return "LOGON_FAILED_OTHER";
        case 0x00000003: return "LOGON_WARNING";
        default: return "SESSION_ID_OR_UNKNOWN";
    }
}

int FreeRdpAdapter::cbLogonErrorInfo(freerdp* /*instance*/, UINT32 data, UINT32 type) {
    OH_LOG_ERROR(LOG_APP, "[RDP] LogonErrorInfo: type=0x%{public}08X(%{public}s) data=0x%{public}08X(%{public}s)",
                 type, logonErrorTypeName(type), data, logonErrorDataName(data));
    return 1;
}

void FreeRdpAdapter::cbErrorInfo(void* context, const ErrorInfoEventArgs* e) {
    auto* rdpContext = static_cast<::rdpContext*>(context);
    const UINT32 code = e ? e->code : 0;
    const char* errName = safeFreeRdpString(freerdp_get_error_info_name(code), "UNKNOWN_ERRINFO");
    const char* official = safeFreeRdpString(freerdp_get_error_info_string(code), "");
    const UINT32 selectedProtocol = rdpContext && rdpContext->settings
        ? freerdp_settings_get_uint32(rdpContext->settings, FreeRDP_SelectedProtocol)
        : 0;
    OH_LOG_ERROR(LOG_APP,
                 "[RDP] ErrorInfo event: raw=0x%{public}08X (%{public}s) selectedProtocol=0x%{public}08X official=%{public}s",
                 code, errName, selectedProtocol, official);
    if (code == 0 || !rdpContext) {
        return;
    }
    auto* freeRdpContext = reinterpret_cast<FreeRdpContext*>(rdpContext);
    FreeRdpAdapter* adapter = freeRdpContext ? freeRdpContext->adapter : nullptr;
    if (!adapter || !adapter->impl_) {
        OH_LOG_WARN(LOG_APP, "[RDP] ErrorInfo owner missing: raw=0x%{public}08X", code);
        return;
    }
    adapter->impl_->setState(ConnectionState::ERROR, rdpErrorInfoMessage(code));
}

void FreeRdpAdapter::cbChannelConnected(void* context, const ChannelConnectedEventArgs* e) {
    auto* rdpContext = static_cast<::rdpContext*>(context);
    if (!rdpContext || !e || !e->name) {
        OH_LOG_WARN(LOG_APP, "[RDP] ChannelConnected ignored: invalid context/event");
        return;
    }
    OH_LOG_INFO(LOG_APP, "[RDP] channel connected: %{public}s interface=%{public}p",
                e->name, e->pInterface);
    if (std::strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0 && e->pInterface) {
        auto* owner = reinterpret_cast<FreeRdpContext*>(rdpContext)->adapter;
        auto* cliprdr = reinterpret_cast<CliprdrClientContext*>(e->pInterface);
        if (owner && owner->impl_) {
            owner->impl_->cliprdr = cliprdr;
            cliprdr->custom = owner;
            cliprdr->MonitorReady = cbCliprdrMonitorReady;
            cliprdr->ServerFormatList = cbCliprdrServerFormatList;
            cliprdr->ServerFormatDataRequest = cbCliprdrServerFormatDataRequest;
            cliprdr->ServerFormatDataResponse = cbCliprdrServerFormatDataResponse;
        }
    }
#if defined(CHANNEL_RDPGFX_CLIENT)
    if (std::strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        auto* freeRdpContext = reinterpret_cast<FreeRdpContext*>(rdpContext);
        FreeRdpAdapter* adapter = freeRdpContext ? freeRdpContext->adapter : nullptr;
        if (!rdpContext->gdi || !e->pInterface) {
            OH_LOG_ERROR(LOG_APP, "[RDP] RDPGFX channel connected before GDI is ready [E-RDP-GFX-GDI]");
            if (adapter && adapter->impl_) {
                adapter->impl_->setState(ConnectionState::ERROR, "RDP graphics pipeline missing GDI [E-RDP-GFX-GDI]");
            }
            return;
        }
        if (!freerdp_settings_get_bool(rdpContext->settings, FreeRDP_SoftwareGdi)) {
            OH_LOG_ERROR(LOG_APP, "[RDP] RDPGFX requires SoftwareGdi in OHOS renderer [E-RDP-GFX-GDI-MODE]");
            if (adapter && adapter->impl_) {
                adapter->impl_->setState(ConnectionState::ERROR, "RDP graphics pipeline requires SoftwareGdi [E-RDP-GFX-GDI-MODE]");
            }
            return;
        }
        if (!gdi_graphics_pipeline_init(rdpContext->gdi,
                                        reinterpret_cast<RdpgfxClientContext*>(e->pInterface))) {
            OH_LOG_ERROR(LOG_APP, "[RDP] gdi_graphics_pipeline_init failed [E-RDP-GFX-INIT]");
            if (adapter && adapter->impl_) {
                adapter->impl_->setState(ConnectionState::ERROR, "RDP graphics pipeline init failed [E-RDP-GFX-INIT]");
            }
            return;
        }
        OH_LOG_INFO(LOG_APP, "[RDP] GDI graphics pipeline initialized for RDPGFX");
    }
#endif
}

UINT FreeRdpAdapter::cbCliprdrMonitorReady(CliprdrClientContext* context,
                                           const CLIPRDR_MONITOR_READY*) {
    if (!context || !context->ClientFormatList) return ERROR_INVALID_PARAMETER;
    CLIPRDR_FORMAT format {};
    format.formatId = CF_UNICODETEXT;
    CLIPRDR_FORMAT_LIST list {};
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = 1;
    list.formats = &format;
    return context->ClientFormatList(context, &list);
}

UINT FreeRdpAdapter::cbCliprdrServerFormatList(CliprdrClientContext* context,
                                               const CLIPRDR_FORMAT_LIST* list) {
    if (!context || !list || !context->ClientFormatDataRequest) return ERROR_INVALID_PARAMETER;
    for (UINT32 i = 0; i < list->numFormats; ++i) {
        if (list->formats[i].formatId == CF_UNICODETEXT) {
            CLIPRDR_FORMAT_DATA_REQUEST request {};
            request.common.msgType = CB_FORMAT_DATA_REQUEST;
            request.requestedFormatId = CF_UNICODETEXT;
            return context->ClientFormatDataRequest(context, &request);
        }
    }
    return CHANNEL_RC_OK;
}

UINT FreeRdpAdapter::cbCliprdrServerFormatDataRequest(CliprdrClientContext* context,
                                                      const CLIPRDR_FORMAT_DATA_REQUEST* request) {
    auto* owner = context ? static_cast<FreeRdpAdapter*>(context->custom) : nullptr;
    if (!owner || !owner->impl_ || !context->ClientFormatDataResponse || !request ||
        request->requestedFormatId != CF_UNICODETEXT) return ERROR_INVALID_PARAMETER;
    std::vector<uint16_t> wide = utf8ToUtf16(owner->impl_->clipboardText);
    wide.push_back(0);
    CLIPRDR_FORMAT_DATA_RESPONSE response {};
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    response.requestedFormatData = reinterpret_cast<BYTE*>(wide.data());
    response.common.dataLen = static_cast<UINT32>(wide.size() * sizeof(uint16_t));
    return context->ClientFormatDataResponse(context, &response);
}

UINT FreeRdpAdapter::cbCliprdrServerFormatDataResponse(CliprdrClientContext* context,
                                                       const CLIPRDR_FORMAT_DATA_RESPONSE* response) {
    auto* owner = context ? static_cast<FreeRdpAdapter*>(context->custom) : nullptr;
    if (!owner || !owner->impl_ || !response || !response->requestedFormatData) return ERROR_INVALID_PARAMETER;
    const auto* data = reinterpret_cast<const uint16_t*>(response->requestedFormatData);
    const size_t count = response->common.dataLen / sizeof(uint16_t);
    std::string text;
    text.reserve(count);
    for (size_t i = 0; i < count && data[i] != 0 && text.size() < 65536; ++i) {
        const uint32_t cp = data[i];
        if (cp < 0x80) text.push_back(static_cast<char>(cp));
        else if (cp < 0x800) { text.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            text.push_back(static_cast<char>(0x80 | (cp & 0x3F))); }
        else { text.push_back(static_cast<char>(0xE0 | (cp >> 12)));
            text.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            text.push_back(static_cast<char>(0x80 | (cp & 0x3F))); }
    }
    owner->impl_->clipboardText = std::move(text);
    return CHANNEL_RC_OK;
}

void FreeRdpAdapter::cbChannelDisconnected(void* context, const ChannelDisconnectedEventArgs* e) {
    auto* rdpContext = static_cast<::rdpContext*>(context);
    if (!rdpContext || !e || !e->name) {
        OH_LOG_WARN(LOG_APP, "[RDP] ChannelDisconnected ignored: invalid context/event");
        return;
    }
    OH_LOG_INFO(LOG_APP, "[RDP] channel disconnected: %{public}s interface=%{public}p",
                e->name, e->pInterface);
#if defined(CHANNEL_RDPGFX_CLIENT)
    if (std::strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        if (rdpContext->gdi && e->pInterface) {
            gdi_graphics_pipeline_uninit(rdpContext->gdi,
                                         reinterpret_cast<RdpgfxClientContext*>(e->pInterface));
            OH_LOG_INFO(LOG_APP, "[RDP] GDI graphics pipeline released for RDPGFX");
        }
    }
#endif
}

BOOL FreeRdpAdapter::cbLoadChannels(freerdp* instance) {
    if (!instance || !instance->context || !instance->context->channels || !instance->settings) {
        OH_LOG_ERROR(LOG_APP, "[RDP] LoadChannels failed: invalid FreeRDP context");
        return FALSE;
    }

    ensureFreeRdpStaticAddinProvider();
    if (!freerdp_get_current_addin_provider()) {
        OH_LOG_ERROR(LOG_APP, "[RDP] LoadChannels failed: static addin provider missing");
        return FALSE;
    }

    rdpSettings* settings = instance->settings;
    logRdpChannelSettings(settings, "loadchannels-before");
    const BOOL ok = freerdp_client_load_addins(instance->context->channels, settings);
    OH_LOG_INFO(LOG_APP,
                "[RDP] LoadChannels result=%{public}s audio=%{public}s clipboard=%{public}s deviceRedirection=%{public}s",
                ok ? "true" : "false",
                freerdp_settings_get_bool(settings, FreeRDP_AudioPlayback) ? "true" : "false",
                freerdp_settings_get_bool(settings, FreeRDP_RedirectClipboard) ? "true" : "false",
                freerdp_settings_get_bool(settings, FreeRDP_DeviceRedirection) ? "true" : "false");
    logRdpChannelSettings(settings, "loadchannels-after");
    return ok;
}

// ---- GDI BeginPaint/EndPaint — 首帧上屏 (BGRA raw → GLRenderer) ----
BOOL FreeRdpAdapter::cbPostConnect(freerdp* instance) {
    if (!instance || !instance->context) return FALSE;
    auto* ctx = reinterpret_cast<FreeRdpContext*>(instance->context);
    auto* self = ctx ? ctx->adapter : nullptr;
    if (!self) return FALSE;

    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) {
        OH_LOG_ERROR(LOG_APP, "[RDP] gdi_init(PIXEL_FORMAT_BGRA32) failed [E-GDI-INIT]");
        return FALSE;
    }
    if (!instance->update) {
        OH_LOG_ERROR(LOG_APP, "[RDP] update table missing after gdi_init [E-RDP-UPDATE]");
        gdi_free(instance);
        return FALSE;
    }

    instance->update->BeginPaint = cbBeginPaint;
    instance->update->EndPaint = cbEndPaint;
    self->impl_->gdiInitialized.store(true, std::memory_order_release);
    self->impl_->paintCount.store(0, std::memory_order_release);
    self->impl_->firstPaintUs.store(0, std::memory_order_release);
    self->impl_->lastPaintUs.store(0, std::memory_order_release);
    self->impl_->lastRenderDiagUs = 0;
    self->impl_->lastRenderBytes.store(0, std::memory_order_release);
    self->impl_->lastFrameWidth = 0;
    self->impl_->lastFrameHeight = 0;
    self->impl_->forceNextFullFrame = true;
    self->impl_->damageAccumulator->clear();
    RendererNapi::ReenableActivePresentation();
    self->impl_->presentationEnabled.store(true, std::memory_order_release);
    self->impl_->startSessionWorkers(self);
    OH_LOG_INFO(LOG_APP, "[RDP] GDI initialized: BGRA32 primary buffer ready");
    return TRUE;
}

void FreeRdpAdapter::cbPostDisconnect(freerdp* instance) {
    if (!instance || !instance->context) return;
    auto* ctx = reinterpret_cast<FreeRdpContext*>(instance->context);
    auto* self = ctx ? ctx->adapter : nullptr;
    if (!self) return;

    self->impl_->traceShutdown("post-disconnect", "begin");
    self->impl_->presentationEnabled.store(false, std::memory_order_release);
    RendererNapi::InvalidateActivePresentation();
    self->impl_->framePump.invalidatePending();
    self->impl_->stopSessionWorkers();
    if (self->impl_->gdiInitialized.exchange(false, std::memory_order_acq_rel) &&
        instance->context->gdi) {
        gdi_free(instance);
        OH_LOG_INFO(LOG_APP, "[RDP] GDI resources released");
    }
    self->impl_->traceShutdown("post-disconnect", "complete");
}

BOOL FreeRdpAdapter::cbBeginPaint(rdpContext* context) {
    auto* ctx = reinterpret_cast<FreeRdpContext*>(context);
    if (!ctx || !ctx->adapter) return FALSE;
    // FreeRDP 3.x: GDI 已在 rdpContext 中, primary buffer 就绪
    return TRUE;
}

BOOL FreeRdpAdapter::cbEndPaint(rdpContext* context) {
    const int64_t callbackBeginUs = steadyNowUs();
    auto* ctx = reinterpret_cast<FreeRdpContext*>(context);
    if (!ctx) return FALSE;
    auto* self = ctx->adapter;
    if (!self) return FALSE;

    // 从 FreeRDP GDI 获取 primary buffer (BGRA32 像素)
    if (context->gdi && context->gdi->primary_buffer) {
        int w = context->gdi->width;
        int h = context->gdi->height;
        int stride = context->gdi->stride;  // bytes per row, 通常 w*4
        const uint8_t* data = context->gdi->primary_buffer;
        size_t size = static_cast<size_t>(stride) * static_cast<size_t>(h);
        HGDI_WND hwnd = nullptr;
        if (context->gdi->primary && context->gdi->primary->hdc) {
            hwnd = context->gdi->primary->hdc->hwnd;
        }
        const int ninvalid = hwnd ? hwnd->ninvalid : 0;
        const bool hasInvalid = hwnd && hwnd->invalid && !hwnd->invalid->null && ninvalid > 0;
        const int invalidX = hasInvalid ? hwnd->invalid->x : 0;
        const int invalidY = hasInvalid ? hwnd->invalid->y : 0;
        const int invalidW = hasInvalid ? hwnd->invalid->w : 0;
        const int invalidH = hasInvalid ? hwnd->invalid->h : 0;
        const RdpDamageRect dirtyRect = RdpDamageAccumulator::ClipRect(
            w, h, invalidX, invalidY, invalidW, invalidH);
        const size_t renderBytes = dirtyRect.valid ?
            static_cast<size_t>(dirtyRect.width) * static_cast<size_t>(dirtyRect.height) * 4U : 0;
        const uint64_t nowMs = static_cast<uint64_t>(steadyNowUs() / 1000);
        if (ShouldCaptureRdpBackgroundFrame(
                self->impl_->backgroundVideoPrewarmEnabled.load(),
                nowMs,
                self->impl_->backgroundFrameCache.lastCaptureMs(),
                self->impl_->backgroundVideoPrewarmIntervalMs.load(),
                w, h, stride, size)) {
            const bool captured = self->impl_->backgroundFrameCache.capture(data, size, w, h, stride, nowMs);
            if (captured) {
                OH_LOG_DEBUG(LOG_APP,
                    "[RDP-PREWARM] cached frame %{public}dx%{public}d bytes=%{public}zu",
                    w, h, size);
            }
        }

        auto clearInvalid = [hwnd]() {
            if (hwnd && hwnd->invalid) {
                hwnd->invalid->null = TRUE;
                hwnd->ninvalid = 0;
            }
        };

        if (!hasInvalid) {
            clearInvalid();
            return TRUE;
        }

        const int64_t nowUs = steadyNowUs();
        if (self->impl_->firstPaintUs.load(std::memory_order_acquire) == 0) {
            self->impl_->firstPaintUs.store(nowUs, std::memory_order_release);
        }
        self->impl_->lastPaintUs.store(nowUs, std::memory_order_release);
        self->impl_->paintCount.fetch_add(1, std::memory_order_relaxed);
        recordRemoteVideoFrame(renderBytes, w, h);
        g_rdpVideoPerf.recordIngressFrame("rdp", w, h, renderBytes, true);

        const RdpPresentationTarget target = RendererNapi::GetActivePresentationTarget();
        const bool stagingAllowed =
            self->impl_->presentationEnabled.load(std::memory_order_acquire) &&
            target.generation != 0;
        const bool presentationAllowed = stagingAllowed && target.ready();
        const bool frameSizeChanged = self->impl_->lastFrameWidth != 0 &&
            (self->impl_->lastFrameWidth != w || self->impl_->lastFrameHeight != h);
        const bool forceFullDamage = self->impl_->forceNextFullFrame || frameSizeChanged ||
            self->impl_->framePump.consumeFullResyncRequired();
        RdpDamageUpdateResult damageUpdate;
        if (stagingAllowed) {
            const int64_t copyBeginUs = steadyNowUs();
            damageUpdate = self->impl_->damageAccumulator->update(
                data, size, w, h, stride, invalidX, invalidY, invalidW, invalidH,
                target.generation, forceFullDamage);
            self->impl_->framePump.recordCopy(
                damageUpdate.copiedBytes, steadyNowUs() - copyBeginUs, steadyNowUs());
        }

        int ret = static_cast<int>(RdpPresentResult::RendererNotReady);
        bool queued = false;
        bool dirtyPresentation = damageUpdate.accepted && !damageUpdate.fullResync;
        if (!stagingAllowed) {
            self->impl_->forceNextFullFrame = true;
        } else if (!damageUpdate.accepted) {
            ret = static_cast<int>(RdpPresentResult::InvalidFrame);
            self->impl_->forceNextFullFrame = true;
        } else {
            self->impl_->lastFrameWidth = w;
            self->impl_->lastFrameHeight = h;
            self->impl_->lastRenderBytes.store(
                damageUpdate.copiedBytes, std::memory_order_release);
            self->impl_->forceNextFullFrame = false;
            if (presentationAllowed) {
                RdpFrameSubmission submission;
                submission.damageSource = self->impl_->damageAccumulator;
                submission.callbackUs = steadyNowUs() - callbackBeginUs;
                submission.enqueuedAtUs = steadyNowUs();
                queued = self->impl_->framePump.submitLatest(std::move(submission));
                if (queued) {
                    ret = static_cast<int>(RdpPresentResult::Presented);
                } else {
                    self->impl_->forceNextFullFrame = true;
                }
            } else {
                ret = static_cast<int>(target.rejection);
            }
        }

        clearInvalid();
        self->impl_->framePump.recordInvalid(
            dirtyRect.valid ? static_cast<uint64_t>(dirtyRect.width) *
                static_cast<uint64_t>(dirtyRect.height) : 0,
            steadyNowUs() - callbackBeginUs, steadyNowUs());

        const int64_t firstPaintUs = self->impl_->firstPaintUs.load(std::memory_order_acquire);
        const int64_t sinceFirstMs = firstPaintUs > 0 ? (nowUs - firstPaintUs) / 1000 : 0;
        const bool diagDue = self->impl_->lastRenderDiagUs == 0 ||
            nowUs - self->impl_->lastRenderDiagUs >= 1000000;
        if (diagDue) {
            self->impl_->lastRenderDiagUs = nowUs;
            Render::VideoPerfSnapshot perf = g_rdpVideoPerf.snapshotAndReset();
            Render::VideoPressureLevel pressure = Render::classifyVideoPressure(perf);
            OH_LOG_INFO(LOG_APP,
                "[RDP] GDI EndPaint #%{public}d rendered=%{public}d skipped=%{public}d"
                " elapsed=%{public}lldms invalid=%{public}d rect=%{public}d,%{public}d %{public}dx%{public}d"
                " frame=%{public}dx%{public}d stride=%{public}d ret=%{public}d"
                " renderCost=%{public}lldus interval=%{public}lldus adaptations=%{public}d mode=%{public}s bytes=%{public}llu"
                " perf[paints=%{public}llu rendered=%{public}llu pressure=%{public}s maxRender=%{public}lldus bytes=%{public}llu]",
                self->impl_->paintCount.load(std::memory_order_acquire),
                static_cast<int>(self->impl_->framePump.rendered()),
                static_cast<int>(self->impl_->framePump.replaced()),
                static_cast<long long>(sinceFirstMs),
                ninvalid, invalidX, invalidY, invalidW, invalidH, w, h, stride, ret,
                static_cast<long long>(self->impl_->framePump.lastWorkerCostUs()),
                static_cast<long long>(self->impl_->framePump.targetIntervalUs()),
                static_cast<int>(self->impl_->framePump.adaptationCount()),
                dirtyPresentation ? "dirty" : "full",
                static_cast<unsigned long long>(renderBytes),
                static_cast<unsigned long long>(perf.ingressFrames),
                static_cast<unsigned long long>(perf.renderFrames),
                Render::videoPressureName(pressure),
                static_cast<long long>(perf.renderTotalMaxUs),
                static_cast<unsigned long long>(perf.bytesTotal));
        }
    }
    return TRUE;
}

// ---- 事件循环线程 ----
void FreeRdpAdapter::startEventLoop() {
    eventLoopRunning_.store(true, std::memory_order_release);
    const int rc = pthread_create(&impl_->eventThread, nullptr,
        [](void* arg) -> void* {
            auto* self = static_cast<FreeRdpAdapter*>(arg);
            self->processEventLoop();
            return nullptr;
        }, this);
    if (rc != 0) {
        eventLoopRunning_.store(false, std::memory_order_release);
        impl_->eventThread = 0;
        OH_LOG_ERROR(LOG_APP, "[RDP] event loop pthread_create failed rc=%{public}d", rc);
    }
}

void FreeRdpAdapter::stopEventLoop() {
    impl_->traceShutdown("event-stop", "begin");
    eventLoopRunning_.store(false, std::memory_order_release);
    if (impl_->eventThread) {
        if (!pthread_equal(pthread_self(), impl_->eventThread)) {
            pthread_join(impl_->eventThread, nullptr);
        }
        impl_->eventThread = 0;
    }
    impl_->traceShutdown("event-stop", "complete");
}

void FreeRdpAdapter::processEventLoop() {
    HANDLE handles[64];
    while (eventLoopRunning_.load(std::memory_order_acquire)) {
        rdpContext* context = nullptr;
        {
            std::lock_guard<std::mutex> lock(impl_->instanceMutex);
            if (!instance_ || !instance_->context) {
                break;
            }
            context = instance_->context;
        }

        DWORD count = freerdp_get_event_handles(context, handles, 64);
        if (count == 0) {
            usleep(10000); // 10ms
            continue;
        }
        DWORD ret = WaitForMultipleObjects(count, handles, FALSE, 100);
        if (!eventLoopRunning_.load(std::memory_order_acquire)) {
            break;
        }
        if (ret >= WAIT_OBJECT_0 && ret < WAIT_OBJECT_0 + count) {
            if (!eventLoopRunning_.load(std::memory_order_acquire)) {
                break;
            }
            if (!freerdp_check_event_handles(context)) {
                OH_LOG_WARN(LOG_APP, "[RDP] freerdp_check_event_handles returned false, stopping event loop");
                eventLoopRunning_.store(false, std::memory_order_release);
                break;
            }
        }
    }
}

// ---- 构造/析构 ----
void FreeRdpAdapter::joinConnectThread() {
    impl_->traceShutdown("connect-join", "begin");
    if (!impl_->connectThreadStarted || !impl_->connectThread) {
        impl_->traceShutdown("connect-join", "not-started");
        return;
    }
    if (pthread_equal(pthread_self(), impl_->connectThread)) {
        impl_->traceShutdown("connect-join", "self-skip");
        return;
    }
    pthread_join(impl_->connectThread, nullptr);
    impl_->connectThread = 0;
    impl_->connectThreadStarted = false;
    impl_->traceShutdown("connect-join", "complete");
}

void FreeRdpAdapter::joinDriveThread() {
    impl_->traceShutdown("drive-join", "begin");
    if (!impl_->driveThreadStarted || !impl_->driveThread) {
        impl_->traceShutdown("drive-join", "not-started");
        return;
    }
    if (pthread_equal(pthread_self(), impl_->driveThread)) {
        impl_->traceShutdown("drive-join", "self-skip");
        return;
    }
    pthread_join(impl_->driveThread, nullptr);
    impl_->driveThread = 0;
    impl_->driveThreadStarted = false;
    impl_->traceShutdown("drive-join", "complete");
}

struct RdpDriveMountRequest {
    FreeRdpAdapter* adapter;
    std::string driveName;
    std::string drivePath;
};

void FreeRdpAdapter::startDriveMountAfterConnected(const std::string& driveName, const std::string& drivePath) {
    if (drivePath.empty()) {
        return;
    }
    joinDriveThread();

    auto* request = new RdpDriveMountRequest { this, driveName, drivePath };
    const int rc = pthread_create(&impl_->driveThread, nullptr,
        [](void* arg) -> void* {
            auto* request = static_cast<RdpDriveMountRequest*>(arg);
            request->adapter->mountDriveAfterConnected(request->driveName, request->drivePath);
            delete request;
            return nullptr;
        }, request);
    if (rc != 0) {
        delete request;
        OH_LOG_WARN(LOG_APP, "[RDP] redirected drive async mount thread failed rc=%{public}d", rc);
        return;
    }
    impl_->driveThreadStarted = true;
    const std::string drivePathId = SafeLog::HashForLog(drivePath);
    OH_LOG_INFO(LOG_APP, "[RDP] redirected drive async mount scheduled: \\\\tsclient\\%{public}s drivePathId=%{public}s",
                driveName.c_str(), drivePathId.c_str());
}

void FreeRdpAdapter::mountDriveAfterConnected(const std::string& driveName, const std::string& drivePath) {
    // Give the event loop and rdpdr plugin a short window to finish post-connect setup.
    for (int i = 0; i < 10; i++) {
        if (impl_->stopRequested) {
            OH_LOG_INFO(LOG_APP, "[RDP] redirected drive async mount canceled before start");
            return;
        }
        usleep(100000);
    }
    if (impl_->stopRequested || getState() != ConnectionState::CONNECTED) {
        OH_LOG_INFO(LOG_APP, "[RDP] redirected drive async mount skipped: session no longer connected");
        return;
    }

    uint32_t driveId = 0;
    UINT driveRc = ERROR_NOT_READY;
    rdpContext* driveContext = nullptr;
    {
        std::lock_guard<std::mutex> lock(impl_->instanceMutex);
        if (impl_->stopRequested || !instance_ || !instance_->context) {
            OH_LOG_INFO(LOG_APP, "[RDP] redirected drive async mount skipped: instance unavailable");
            return;
        }
        driveContext = instance_->context;
    }
    if (impl_->stopRequested.load(std::memory_order_acquire)) {
        OH_LOG_INFO(LOG_APP, "[RDP] redirected drive async mount skipped: shutdown requested");
        return;
    }
    driveRc = freerdp_ohos_rdpdr_register_drive(driveContext, driveName.c_str(),
                                                drivePath.c_str(), &driveId);

    if (driveRc == CHANNEL_RC_OK) {
        impl_->driveDeviceId = driveId;
        impl_->transferStatus.markRdpDriveMounted();
        const std::string drivePathId = SafeLog::HashForLog(drivePath);
        OH_LOG_INFO(LOG_APP,
                    "[RDP] redirected drive mounted asynchronously: \\\\tsclient\\%{public}s drivePathId=%{public}s id=%{public}u",
                    driveName.c_str(), drivePathId.c_str(), driveId);
        impl_->setState(ConnectionState::CONNECTED, "RDP session established; drive redirection mounted");
    } else {
        impl_->transferStatus.markRdpDriveUnavailable("drive_unavailable");
        const std::string drivePathId = SafeLog::HashForLog(drivePath);
        OH_LOG_WARN(LOG_APP,
                    "[RDP] redirected drive async mount unavailable rc=%{public}u name=%{public}s drivePathId=%{public}s",
                    driveRc, driveName.c_str(), drivePathId.c_str());
        impl_->setState(ConnectionState::CONNECTED, "RDP session established; drive redirection unavailable");
    }
}

void FreeRdpAdapter::abortActiveConnection() {
    rdpContext* context = nullptr;
    {
        std::lock_guard<std::mutex> lock(impl_->instanceMutex);
        context = instance_ ? instance_->context : nullptr;
    }
    if (context) {
        impl_->traceShutdown("connect-abort", "begin");
        OH_LOG_INFO(LOG_APP, "[RDP] abort active connection context");
        freerdp_abort_connect_context(context);
        impl_->traceShutdown("connect-abort", "complete");
    }
}

void FreeRdpAdapter::disconnectActiveInstance() {
    freerdp* activeInstance = nullptr;
    {
        std::lock_guard<std::mutex> lock(impl_->instanceMutex);
        activeInstance = instance_;
    }
    if (!activeInstance) {
        impl_->traceShutdown("freerdp-disconnect", "no-instance");
        return;
    }
    impl_->traceShutdown("freerdp-disconnect", "begin");
    if (activeInstance->context) {
        freerdp_abort_connect_context(activeInstance->context);
    }
    freerdp_disconnect(activeInstance);
    impl_->traceShutdown("freerdp-disconnect", "complete");
}

void FreeRdpAdapter::cleanupInstance() {
    impl_->presentationEnabled.store(false, std::memory_order_release);
    RendererNapi::InvalidateActivePresentation();
    impl_->framePump.invalidatePending();
    impl_->stopSessionWorkers();
    freerdp* doomedInstance = nullptr;
    {
        std::lock_guard<std::mutex> lock(impl_->instanceMutex);
        doomedInstance = instance_;
        instance_ = nullptr;
    }
    if (!doomedInstance) {
        impl_->traceShutdown("context-free", "no-instance");
        return;
    }
    impl_->traceShutdown("context-free", "begin");
    if (impl_->gdiInitialized.exchange(false, std::memory_order_acq_rel) &&
        doomedInstance->context && doomedInstance->context->gdi) {
        gdi_free(doomedInstance);
    }
    if (doomedInstance->context) {
        freerdp_context_free(doomedInstance);
    }
    freerdp_free(doomedInstance);
    impl_->traceShutdown("context-free", "complete");
}

FreeRdpAdapter::FreeRdpAdapter() : impl_(std::make_unique<Impl>()) {
    ensureFreeRdpStaticAddinProvider();
    OH_LOG_INFO(LOG_APP, "[RDP] FreeRdpAdapter created (FreeRDP 3.x)");
}

FreeRdpAdapter::~FreeRdpAdapter() {
    // 断开活跃连接或等待连接线程结束
    disconnect();
}

// ---- 协议元信息 ----
std::string FreeRdpAdapter::protocolName() { return "RDP"; }
int FreeRdpAdapter::defaultPort() { return RDP_TCP_PORT; }
std::string FreeRdpAdapter::protocolVersion() { return FREERDP_VERSION_FULL; }

// ---- 连接管理 (异步, 不阻塞 NAPI 线程) ----
int FreeRdpAdapter::connect(const ConnectionConfig& cfg) {
    if (impl_->state == ConnectionState::CONNECTED || impl_->connecting) { disconnect(); }
    {
        std::lock_guard<std::mutex> shutdownLock(impl_->shutdownMutex);
        impl_->shutdownState.reset();
        impl_->sessionGeneration.store(
            g_nextRdpSessionGeneration.fetch_add(1, std::memory_order_relaxed),
            std::memory_order_release);
        impl_->shutdownStartedUs.store(0, std::memory_order_release);
    }
    impl_->config = cfg;
    impl_->connecting = true;
    impl_->stopRequested = false;
    {
        std::lock_guard<std::mutex> lock(g_rdpAudioCallbackMutex);
        if (cfg.rdAudioEnabled && impl_->audioCallback) {
            g_rdpAudioCallbackOwner = this;
            g_rdpAudioCallback = impl_->audioCallback;
        } else if (g_rdpAudioCallbackOwner == this) {
            g_rdpAudioCallbackOwner = nullptr;
            g_rdpAudioCallback = nullptr;
        }
    }
    impl_->setState(ConnectionState::CONNECTING, "Connecting...");

    // 在独立线程中执行 freerdp_connect(), 避免阻塞 NAPI/ArkTS UI
    impl_->connectThread = 0;
    int rc = pthread_create(&impl_->connectThread, nullptr,
        [](void* arg) -> void* {
            auto* self = static_cast<FreeRdpAdapter*>(arg);
            self->connectThreadFunc();
            return nullptr;
        }, this);
    if (rc != 0) {
        impl_->connecting = false;
        impl_->setState(ConnectionState::ERROR, "pthread_create() failed [E-RDP-THREAD]");
        return -11;
    }
    impl_->connectThreadStarted = true;

    // connect() 立即返回 — 连接结果通过 ConnectionStateCallback 异步报告
    return 0;
}

void FreeRdpAdapter::connectThreadFunc() {
    ConnectionConfig& cfg = impl_->config;

    freerdp* newInstance = freerdp_new();
    if (!newInstance) {
        impl_->setState(ConnectionState::ERROR, "freerdp_new() 失败 [E-FREERDP-NEW]");
        impl_->connecting = false;
        return;
    }

    // FreeRDP 3.x: ContextSize 模式
    {
        std::lock_guard<std::mutex> lock(impl_->instanceMutex);
        instance_ = newInstance;
    }
    instance_->ContextSize = sizeof(FreeRdpContext);
    if (!freerdp_context_new(instance_)) {
        impl_->setState(ConnectionState::ERROR, "freerdp_context_new() 失败 [E-FREERDP-CTX]");
        cleanupInstance();
        impl_->connecting = false;
        return;
    }
    auto* ctx = reinterpret_cast<FreeRdpContext*>(instance_->context);
    ctx->adapter = this;
    if (impl_->stopRequested.load(std::memory_order_acquire)) {
        impl_->traceShutdown("connect-cancel", "after-context");
        cleanupInstance();
        impl_->connecting = false;
        return;
    }

    int port = cfg.port > 0 ? cfg.port : RDP_TCP_PORT;

    // ---- 配置 FreeRDP settings (完整映射 ConnectionConfig) ----
    auto* s = instance_->settings;

    // 基础连接
    const RdpAuthIdentity authIdentity =
        NormalizeRdpAuthIdentity(cfg.username, cfg.domain, cfg.rdpAuthIdentityMode);
    std::string effectiveUsername = authIdentity.username;
    std::string effectiveDomain = authIdentity.domain;
    OH_LOG_INFO(LOG_APP, "[RDP] auth identity normalized mode=%{public}s",
                authIdentity.modeName.c_str());
    freerdp_settings_set_string(s, FreeRDP_ServerHostname, cfg.host.c_str());
    freerdp_settings_set_uint32(s, FreeRDP_ServerPort, static_cast<UINT32>(port));
    freerdp_settings_set_string(s, FreeRDP_Username, effectiveUsername.c_str());
    freerdp_settings_set_string(s, FreeRDP_Password, cfg.password.c_str());
    if (!effectiveDomain.empty()) {
        freerdp_settings_set_string(s, FreeRDP_Domain, effectiveDomain.c_str());
    }

    // 桌面尺寸
    freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth,
                                static_cast<UINT32>(cfg.width > 0 ? cfg.width : 1920));
    freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight,
                                static_cast<UINT32>(cfg.height > 0 ? cfg.height : 1080));

    // 色深 — 使用 cfg 值, 不再硬编码 32
    freerdp_settings_set_uint32(s, FreeRDP_ColorDepth,
                                static_cast<UINT32>(cfg.colorDepth > 0 ? cfg.colorDepth : 32));
    freerdp_settings_set_bool(s, FreeRDP_SoftwareGdi, TRUE);

    // 认证与安全: 对照实验禁用 HYBRID_EX, 只请求 TLS/NLA(HYBRID)。
    freerdp_settings_set_bool(s, FreeRDP_NegotiateSecurityLayer, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_UseRdpSecurityLayer, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_RdpSecurity, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_TlsSecurity, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_ExtSecurity, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_AadSecurity, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_NlaSecurity, TRUE);
    freerdp_settings_set_uint32(s, FreeRDP_RequestedProtocols, 0x00000003); // SSL|HYBRID, /sec:nla,tls
    freerdp_settings_set_bool(s, FreeRDP_Authentication, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_AutoLogonEnabled, TRUE);
    freerdp_settings_set_uint32(s, FreeRDP_TcpConnectTimeout, 30000);
    // HarmonyOS 侧没有可用的 Kerberos/U2U 凭据缓存，NLA/CredSSP 只允许 NTLM，避免 Negotiate 第二轮返回 SEC_E_NO_CREDENTIALS。
    freerdp_settings_set_string(s, FreeRDP_AuthenticationPackageList, "ntlm");
    freerdp_settings_set_bool(s, FreeRDP_ConsoleSession, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_RemoteCredentialGuard, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_RestrictedAdminModeRequired, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_RestrictedAdminModeSupported, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_SupportErrorInfoPdu, TRUE);
    const RdpPerformancePolicy::GraphicsMode graphicsMode = applyRdpPerformanceSettings(s);
    {
        std::lock_guard<std::mutex> renderLock(impl_->renderMutex);
        impl_->graphicsMode = RdpPerformancePolicy::GraphicsModeName(graphicsMode);
    }

    const bool requestedDriveEnabled = !cfg.rdDrivePath.empty();
    // 二阶段共享盘: 连接阶段只加载 rdpdr 通道, 不注册文件盘设备。
    // 文件盘挂载必须发生在 CONNECTED 上报之后, 失败也不能影响远程桌面进入。
    const bool driveEnabled = requestedDriveEnabled;
    if (requestedDriveEnabled) {
        const std::string drivePathId = SafeLog::HashForLog(cfg.rdDrivePath);
        OH_LOG_INFO(LOG_APP,
                    "[RDP] redirected drive requested for async post-connected mount: name=%{public}s drivePathId=%{public}s",
                    cfg.rdDriveName.empty() ? "RemoteDesktop" : cfg.rdDriveName.c_str(),
                    drivePathId.c_str());
    }

    // RDP 远端音频: rdpsnd 依赖客户端通道和 rdpdr，数据由 FreeRDP fake 后端转发到 OHAudio。
    // 文件共享盘同样依赖 rdpdr，因此 DeviceRedirection 由 audio/drive 任一能力打开。
    freerdp_settings_set_bool(s, FreeRDP_AudioPlayback, cfg.rdAudioEnabled ? TRUE : FALSE);
    freerdp_settings_set_bool(s, FreeRDP_DeviceRedirection,
                              (cfg.rdAudioEnabled || driveEnabled) ? TRUE : FALSE);
    freerdp_settings_set_bool(s, FreeRDP_RedirectClipboard, cfg.rdClipboardEnabled ? TRUE : FALSE);
    const std::string driveName = sanitizeRdpDriveName(cfg.rdDriveName);
    // 不在连接握手前注册自定义 drive。rdpdr 通道加载后由异步线程 post-connected 挂载。
    freerdp_settings_set_bool(s, FreeRDP_RedirectDrives, FALSE);
    if (cfg.rdAudioEnabled) {
        OH_LOG_INFO(LOG_APP, "[RDP] rdpsnd enabled: channel loading delegated to FreeRDP PreConnect");
    }

    // 目标服务器名: 连接仍走 host/port, NLA/CredSSP 使用该名称生成 TERMSRV/<name>。
    if (!cfg.customHostname.empty()) {
        freerdp_settings_set_string(s, FreeRDP_UserSpecifiedServerName, cfg.customHostname.c_str());
        freerdp_settings_set_string(s, FreeRDP_CertificateName, cfg.customHostname.c_str());
        const std::string logTargetName = SafeLog::MaskHost(cfg.customHostname);
        OH_LOG_INFO(LOG_APP, "[RDP] target server name override: %{public}s", logTargetName.c_str());
    }
    const std::string acceptedFingerprint =
        RdpCertificatePolicy::ToFreeRdpAcceptedFingerprint(
            cfg.expectedRdpCertificateFingerprintSha256);
    if (!acceptedFingerprint.empty()) {
        freerdp_settings_set_string(s, FreeRDP_CertificateAcceptedFingerprints,
                                    acceptedFingerprint.c_str());
        OH_LOG_INFO(LOG_APP, "[RDP] certificate fingerprint pin configured for this session");
    }

    // RD Gateway
    if (!cfg.gatewayHost.empty()) {
        freerdp_settings_set_string(s, FreeRDP_GatewayHostname, cfg.gatewayHost.c_str());
        freerdp_settings_set_uint32(s, FreeRDP_GatewayPort,
                                    static_cast<UINT32>(cfg.gatewayPort > 0 ? cfg.gatewayPort : 443));
        freerdp_settings_set_bool(s, FreeRDP_GatewayEnabled, TRUE);
        const std::string logGatewayHost = SafeLog::MaskHost(cfg.gatewayHost);
        OH_LOG_INFO(LOG_APP, "[RDP] RD Gateway: %{public}s:%{public}d",
                    logGatewayHost.c_str(), cfg.gatewayPort > 0 ? cfg.gatewayPort : 443);
    }

    // 多显示器当前会导致部分 Windows 会话只建连不出首帧, 先固定单屏稳定路径。
    if (cfg.multiMonitor) {
        OH_LOG_WARN(LOG_APP, "[RDP] 多显示器配置已忽略, 使用单屏稳定视频路径 (requested monitorCount=%{public}d)",
                    cfg.monitorCount);
    }

    const std::string logHost = SafeLog::MaskHost(cfg.host);
    const std::string logGatewayHost = cfg.gatewayHost.empty() ? "无" : SafeLog::MaskHost(cfg.gatewayHost);
    const std::string logTargetName = cfg.customHostname.empty() ? "未设置" : SafeLog::MaskHost(cfg.customHostname);
    const std::string logUser = SafeLog::MaskUser(effectiveUsername);
    const std::string logDomain = effectiveDomain.empty() ? "无" : SafeLog::MaskUser(effectiveDomain);
    const std::string logDrivePath = driveEnabled ? SafeLog::HashForLog(cfg.rdDrivePath) : "off";
    OH_LOG_INFO(LOG_APP, "[RDP] 连接参数: %{public}s:%{public}d %{public}dx%{public}d color=%{public}d"
                " gateway=%{public}s targetName=%{public}s authMode=%{public}d user=%{public}s domain=%{public}s"
                " audio=%{public}s driveName=%{public}s drivePathId=%{public}s"
                " passwordLen=%{public}zu encrypted=%{public}s",
                logHost.c_str(), port, cfg.width, cfg.height, cfg.colorDepth,
                logGatewayHost.c_str(),
                logTargetName.c_str(),
                cfg.rdpAuthIdentityMode,
                logUser.c_str(), logDomain.c_str(),
                cfg.rdAudioEnabled ? "on" : "off",
                driveEnabled ? driveName.c_str() : "off",
                logDrivePath.c_str(),
                cfg.password.length(), cfg.password.rfind("1:", 0) == 0 ? "true" : "false");
    const char* authPackageList = freerdp_settings_get_string(s, FreeRDP_AuthenticationPackageList);
    OH_LOG_INFO(LOG_APP, "[RDP] security: negotiate=%{public}s nla=%{public}s tls=%{public}s rdp=%{public}s"
                " ext=%{public}s aad=%{public}s auth=%{public}s autologon=%{public}s admin=%{public}s"
                " rcg=%{public}s restrictedRequired=%{public}s restrictedSupported=%{public}s"
                " requested=0x%{public}08X authPkg=%{public}s",
                freerdp_settings_get_bool(s, FreeRDP_NegotiateSecurityLayer) ? "true" : "false",
                freerdp_settings_get_bool(s, FreeRDP_NlaSecurity) ? "true" : "false",
                freerdp_settings_get_bool(s, FreeRDP_TlsSecurity) ? "true" : "false",
                freerdp_settings_get_bool(s, FreeRDP_RdpSecurity) ? "true" : "false",
                freerdp_settings_get_bool(s, FreeRDP_ExtSecurity) ? "true" : "false",
                freerdp_settings_get_bool(s, FreeRDP_AadSecurity) ? "true" : "false",
                freerdp_settings_get_bool(s, FreeRDP_Authentication) ? "true" : "false",
                freerdp_settings_get_bool(s, FreeRDP_AutoLogonEnabled) ? "true" : "false",
                freerdp_settings_get_bool(s, FreeRDP_ConsoleSession) ? "true" : "false",
                freerdp_settings_get_bool(s, FreeRDP_RemoteCredentialGuard) ? "true" : "false",
                freerdp_settings_get_bool(s, FreeRDP_RestrictedAdminModeRequired) ? "true" : "false",
                freerdp_settings_get_bool(s, FreeRDP_RestrictedAdminModeSupported) ? "true" : "false",
                freerdp_settings_get_uint32(s, FreeRDP_RequestedProtocols),
                authPackageList ? authPackageList : "无");

    // 证书验证回调: 只接受 ArkTS 预检确认并传入的指纹。
    instance_->VerifyCertificate = cbVerifyCertificate;
    instance_->VerifyCertificateEx = cbVerifyCertificateEx;
    instance_->VerifyChangedCertificateEx = cbVerifyChangedCertificateEx;
    instance_->VerifyX509Certificate = cbVerifyX509Certificate;
    instance_->LogonErrorInfo = cbLogonErrorInfo;
    if (instance_->context && instance_->context->pubSub) {
        if (PubSub_SubscribeErrorInfo(instance_->context->pubSub, cbErrorInfo) < 0) {
            OH_LOG_WARN(LOG_APP, "[RDP] subscribe ErrorInfo failed");
        } else {
            OH_LOG_INFO(LOG_APP, "[RDP] subscribed ErrorInfo events");
        }
        if (PubSub_SubscribeChannelConnected(instance_->context->pubSub, cbChannelConnected) < 0) {
            OH_LOG_WARN(LOG_APP, "[RDP] subscribe ChannelConnected failed");
        } else {
            OH_LOG_INFO(LOG_APP, "[RDP] subscribed ChannelConnected events");
        }
        if (PubSub_SubscribeChannelDisconnected(instance_->context->pubSub, cbChannelDisconnected) < 0) {
            OH_LOG_WARN(LOG_APP, "[RDP] subscribe ChannelDisconnected failed");
        } else {
            OH_LOG_INFO(LOG_APP, "[RDP] subscribed ChannelDisconnected events");
        }
    }
    instance_->LoadChannels = cbLoadChannels;
    instance_->PostConnect = cbPostConnect;
    instance_->PostDisconnect = cbPostDisconnect;

    // GDI 渲染回调 (首帧上屏)

    ensureFreeRdpStaticAddinProvider();
    if (!freerdp_get_current_addin_provider()) {
        OH_LOG_ERROR(LOG_APP, "[RDP] static addin provider missing");
        impl_->setState(ConnectionState::ERROR, "RDP static channel provider missing");
        cleanupInstance();
        impl_->connecting = false;
        return;
    }
    logRdpChannelSettings(s, "before-connect-loadchannels-delegated");
    OH_LOG_INFO(LOG_APP, "[RDP] client addins delegated: audio=%{public}s clipboard=%{public}s deviceRedirection=%{public}s drive=%{public}s deviceCount=%{public}u staticChannels=%{public}u dynamicChannels=%{public}u",
                freerdp_settings_get_bool(s, FreeRDP_AudioPlayback) ? "true" : "false",
                freerdp_settings_get_bool(s, FreeRDP_RedirectClipboard) ? "true" : "false",
                freerdp_settings_get_bool(s, FreeRDP_DeviceRedirection) ? "true" : "false",
                logDrivePath.c_str(),
                freerdp_settings_get_uint32(s, FreeRDP_DeviceCount),
                freerdp_settings_get_uint32(s, FreeRDP_StaticChannelCount),
                freerdp_settings_get_uint32(s, FreeRDP_DynamicChannelCount));

    // ---- 执行连接 ----
    if (impl_->stopRequested.load(std::memory_order_acquire)) {
        impl_->traceShutdown("connect-cancel", "before-connect");
        cleanupInstance();
        impl_->connecting = false;
        return;
    }
    OH_LOG_INFO(LOG_APP, "[RDP] 开始 freerdp_connect...");
    BOOL ok = freerdp_connect(instance_);
    if (!ok) {
        DWORD err = freerdp_get_last_error(instance_->context);
        const char* errName = freerdpErrorName(err);
        logFreeRdpFailureDiagnostics(instance_, s, err, errName);
        if (getState() != ConnectionState::ERROR) {
            const UINT32 errorInfo = freerdp_error_info(instance_);
            if (errorInfo != 0) {
                impl_->setState(ConnectionState::ERROR, rdpErrorInfoMessage(errorInfo));
            } else {
                impl_->setState(ConnectionState::ERROR, freerdpErrorMessage(err, errName));
            }
        }
        // 正确释放: context_free → free
        cleanupInstance();
        impl_->connecting = false;
        return;
    }

    // 连接成功 — 启动事件循环
    startEventLoop();

    if (getState() == ConnectionState::ERROR) {
        impl_->connecting = false;
        OH_LOG_WARN(LOG_APP, "[RDP] connection reached ERROR before CONNECTED publish");
        return;
    }
    impl_->setState(ConnectionState::CONNECTED, "RDP session established (FreeRDP)");
    impl_->connecting = false;
    OH_LOG_INFO(LOG_APP, "[RDP] ✓ FreeRDP session: %{public}s:%{public}d (user=%{public}s)",
                logHost.c_str(), port, logUser.c_str());
    if (driveEnabled) {
        startDriveMountAfterConnected(driveName, cfg.rdDrivePath);
    }
}

void FreeRdpAdapter::disconnect() {
    std::lock_guard<std::mutex> shutdownLock(impl_->shutdownMutex);
    if (!impl_->shutdownState.requestDisconnect()) {
        impl_->traceShutdown("request", "duplicate");
        return;
    }
    impl_->beginShutdownTrace();
    impl_->stopRequested.store(true, std::memory_order_release);
    impl_->presentationEnabled.store(false, std::memory_order_release);
    RendererNapi::InvalidateActivePresentation();
    impl_->framePump.invalidatePending();

    impl_->stopSessionWorkers();
    abortActiveConnection();

    // The connect thread can start both event and drive workers. Join the producer
    // first so no worker can appear after the corresponding stop/join returns.
    joinConnectThread();
    stopEventLoop();
    joinDriveThread();

    impl_->shutdownState.advance(RdpShutdown::Phase::Quiescing,
                                 RdpShutdown::Phase::TransportDisconnecting);
    disconnectActiveInstance();
    impl_->shutdownState.advance(RdpShutdown::Phase::TransportDisconnecting,
                                 RdpShutdown::Phase::Releasing);
    impl_->connecting = false;
    cleanupInstance();
    {
        std::lock_guard<std::mutex> lock(g_rdpAudioCallbackMutex);
        if (g_rdpAudioCallbackOwner == this) {
            g_rdpAudioCallbackOwner = nullptr;
            g_rdpAudioCallback = nullptr;
        }
    }

    if (impl_->state != ConnectionState::DISCONNECTED &&
        impl_->state != ConnectionState::ERROR) {
        impl_->setState(ConnectionState::DISCONNECTED, "Disconnected");
    }
    impl_->shutdownState.advance(RdpShutdown::Phase::Releasing,
                                 RdpShutdown::Phase::Complete);
    impl_->traceShutdown("complete", "success");
    OH_LOG_INFO(LOG_APP, "[RDP] FreeRDP session disconnected/cleaned");
    return;
#if 0
    // 等待连接线程结束 (如果正在连接中)
    if (impl_->connecting && impl_->connectThread) {
        impl_->connecting = false;  // 信号线程退出
        pthread_join(impl_->connectThread, nullptr);
        impl_->connectThread = 0;
    }

    if (impl_->state == ConnectionState::CONNECTED) {
        stopEventLoop();
        if (instance_) {
            freerdp_disconnect(instance_);
            // 正确释放: context_free → free (配对 freerdp_context_new)
            freerdp_context_free(instance_);
            freerdp_free(instance_);
            instance_ = nullptr;
        }
        impl_->setState(ConnectionState::DISCONNECTED, "Disconnected");
        OH_LOG_INFO(LOG_APP, "[RDP] FreeRDP session disconnected");
    }

    // 清理未完全建立的连接 (context 已创建但未连接)
    if (instance_ && impl_->state != ConnectionState::CONNECTED) {
        freerdp_context_free(instance_);
        freerdp_free(instance_);
        instance_ = nullptr;
        OH_LOG_INFO(LOG_APP, "[RDP] 已清理未完成连接的 FreeRDP context");
    }
#endif
}

ConnectionState FreeRdpAdapter::getState() {
    std::lock_guard<std::mutex> lock(impl_->stateMutex);
    return impl_->state;
}

void FreeRdpAdapter::requestFrameRefresh() {
    if (!impl_->presentationEnabled.load(std::memory_order_acquire)) {
        return;
    }
    const RdpPresentationTarget target = RendererNapi::GetActivePresentationTarget();
    if (!target.ready()) {
        return;
    }

    if (!impl_->damageAccumulator->requestFullSnapshot(target.generation)) {
        OH_LOG_WARN(LOG_APP, "[RDP] requestFrameRefresh skipped: owned frame not ready");
        return;
    }

    RdpFrameSubmission submission;
    submission.damageSource = impl_->damageAccumulator;
    submission.enqueuedAtUs = steadyNowUs();
    if (!impl_->framePump.submitLatest(std::move(submission))) {
        OH_LOG_WARN(LOG_APP, "[RDP] requestFrameRefresh skipped: frame pump unavailable");
    }
}

RdpCertificateInfo FreeRdpAdapter::probeRdpCertificate(const std::string& host, int port,
                                                       const std::string& serverName) {
    return probeRdpCertificateOverTls(host, port, serverName);
}

RdpRenderStats FreeRdpAdapter::getRdpRenderStats() {
    RdpRenderStats stats;
    if (!impl_) {
        return stats;
    }
    std::lock_guard<std::mutex> lock(impl_->renderMutex);
    stats.paintCount = impl_->paintCount.load(std::memory_order_acquire);
    stats.renderedPaintCount = static_cast<int>(impl_->framePump.rendered());
    const int64_t firstPaintUs = impl_->firstPaintUs.load(std::memory_order_acquire);
    const int64_t lastPaintUs = impl_->lastPaintUs.load(std::memory_order_acquire);
    stats.firstPaintMs = firstPaintUs > 0 ? firstPaintUs / 1000 : 0;
    stats.lastPaintMs = lastPaintUs > 0 ? lastPaintUs / 1000 : 0;
    stats.skippedPaintCount = static_cast<int>(impl_->framePump.replaced());
    stats.slowRenderCount = static_cast<int>(impl_->framePump.adaptationCount());
    stats.minRenderIntervalUs = impl_->framePump.targetIntervalUs();
    stats.lastRenderCostUs = impl_->framePump.lastWorkerCostUs();
    stats.lastRenderBytes = impl_->lastRenderBytes.load(std::memory_order_acquire);
    stats.pumpSubmitted = impl_->framePump.submitted();
    stats.pumpRendered = impl_->framePump.rendered();
    stats.pumpReplaced = impl_->framePump.replaced();
    stats.pumpRejected = impl_->framePump.rejected();
    const RdpPresentationMetricsSnapshot presentation =
        impl_->framePump.metricsSnapshot(steadyNowUs());
    stats.lastRenderResult = presentation.lastPresentResult;
    stats.invalidEvents = presentation.invalidEvents;
    stats.invalidPixels = presentation.invalidPixels;
    stats.copiedBytes = presentation.copiedBytes;
    stats.presentationRejected = presentation.rejectedFrames;
    stats.surfaceDetachedRejections = presentation.surfaceDetachedRejections;
    stats.generationRejections = presentation.generationRejections;
    stats.presentationWindowSamples = presentation.windowSamples;
    stats.callbackP50Us = presentation.callbackUs.p50;
    stats.callbackP95Us = presentation.callbackUs.p95;
    stats.callbackMaxUs = presentation.callbackUs.max;
    stats.copyP50Us = presentation.copyUs.p50;
    stats.copyP95Us = presentation.copyUs.p95;
    stats.copyMaxUs = presentation.copyUs.max;
    stats.queueP50Us = presentation.queueWaitUs.p50;
    stats.queueP95Us = presentation.queueWaitUs.p95;
    stats.queueMaxUs = presentation.queueWaitUs.max;
    stats.uploadP50Us = presentation.uploadUs.p50;
    stats.uploadP95Us = presentation.uploadUs.p95;
    stats.uploadMaxUs = presentation.uploadUs.max;
    stats.drawP50Us = presentation.drawUs.p50;
    stats.drawP95Us = presentation.drawUs.p95;
    stats.drawMaxUs = presentation.drawUs.max;
    stats.swapP50Us = presentation.swapUs.p50;
    stats.swapP95Us = presentation.swapUs.p95;
    stats.swapMaxUs = presentation.swapUs.max;
    stats.workerP50Us = presentation.workerUs.p50;
    stats.workerP95Us = presentation.workerUs.p95;
    stats.workerMaxUs = presentation.workerUs.max;
    stats.graphicsMode = impl_->graphicsMode;
    {
        std::lock_guard<std::mutex> inputLock(impl_->inputQueueMutex);
        stats.inputQueueDepth = static_cast<int>(impl_->inputQueue.depth());
        stats.inputQueueMax = static_cast<int>(impl_->inputQueue.maxDepth());
        stats.inputTextUnits = static_cast<int64_t>(impl_->inputQueue.textUnitDepth());
        stats.inputDroppedMouseMoves = static_cast<int64_t>(impl_->inputQueue.droppedMouseMoves());
        stats.inputNonDisposableOverflow = static_cast<int64_t>(impl_->inputQueue.nonDisposableOverflow());
    }
    return stats;
}

bool FreeRdpAdapter::setBackgroundVideoPrewarm(bool enabled, uint32_t intervalMs) {
    if (!impl_) {
        return false;
    }
    const uint32_t effectiveIntervalMs = intervalMs == 0 ? 1000 : intervalMs;
    impl_->backgroundVideoPrewarmEnabled.store(enabled);
    impl_->backgroundVideoPrewarmIntervalMs.store(effectiveIntervalMs);
    if (!enabled) {
        impl_->backgroundFrameCache.clear();
    }
    OH_LOG_INFO(LOG_APP, "[RDP-PREWARM] enabled=%{public}d interval=%{public}u",
                enabled ? 1 : 0, effectiveIntervalMs);
    return true;
}

bool FreeRdpAdapter::presentCachedBackgroundFrame() {
    if (!impl_) {
        return false;
    }
    const RdpPresentationTarget target = RendererNapi::GetActivePresentationTarget();
    if (!impl_->presentationEnabled.load(std::memory_order_acquire) || !target.ready()) {
        return false;
    }
    if (!impl_->damageAccumulator->requestFullSnapshot(target.generation)) {
        RdpBackgroundFrameSnapshot snapshot = impl_->backgroundFrameCache.snapshot();
        if (!snapshot.valid || snapshot.data.empty()) {
            OH_LOG_INFO(LOG_APP, "[RDP-PREWARM] no owned or cached frame to present");
            return false;
        }
        const int64_t copyBeginUs = steadyNowUs();
        const RdpDamageUpdateResult update = impl_->damageAccumulator->update(
            snapshot.data.data(), snapshot.data.size(), snapshot.width, snapshot.height,
            snapshot.stride, 0, 0, snapshot.width, snapshot.height, target.generation, true);
        impl_->framePump.recordCopy(
            update.copiedBytes, steadyNowUs() - copyBeginUs, steadyNowUs());
        if (!update.accepted) {
            return false;
        }
    }
    RdpFrameSubmission submission;
    submission.damageSource = impl_->damageAccumulator;
    submission.enqueuedAtUs = steadyNowUs();
    return impl_->framePump.submitLatest(std::move(submission));
}

// ---- 输入事件 ----
void FreeRdpAdapter::sendKey(uint32_t scancode, bool pressed) {
    if (!impl_) {
        return;
    }
    // 将 HarmonyOS keyCode 映射到 Windows RDP scancode
    uint32_t rdpScancode = mapHarmonyKeyCodeToRdpScancode(scancode);
    if (rdpScancode == 0) {
        // 未映射的键 — 直接传递原始值 (可能已经是正确的 scancode)
        rdpScancode = scancode;
        static int unhandledCount = 0;
        if (unhandledCount < 20 || unhandledCount % 50 == 0) {
            OH_LOG_DEBUG(LOG_APP, "[RDP] 键码未映射: harmonyKeyCode=%{public}u → pass-through scancode=%{public}u",
                        scancode, rdpScancode);
        }
        unhandledCount++;
    }
    UINT16 flags = pressed ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE;
    // 扩展 scancode (E0 prefix) 需要特殊标志
    if (rdpScancode & 0xFF00) {
        flags |= KBD_FLAGS_EXTENDED;
        rdpScancode &= 0xFF;
    }
    impl_->enqueueInputEvent(
        RdpQueuedInputEvent::Key(flags, static_cast<UINT16>(rdpScancode)));
}

void FreeRdpAdapter::sendMouse(int x, int y, MouseButton button, bool pressed) {
    if (!impl_) {
        return;
    }
    const UINT16 ux = static_cast<UINT16>(x);
    const UINT16 uy = static_cast<UINT16>(y);
    const int buttonValue = static_cast<int>(button);
    if (buttonValue < 0) {
        impl_->enqueueInputEvent(RdpQueuedInputEvent::Mouse(PTR_FLAGS_MOVE, 0, ux, uy, true));
        return;
    }

    // RDP 鼠标标志: 按下 = PTR_FLAGS_DOWN + 按钮标志; 释放 = 仅按钮标志
    UINT16 flags = 0;
    if (pressed) {
        flags |= PTR_FLAGS_DOWN;
    }
    // 始终携带按钮标志 (按下/释放都需要 — RDP 标准要求)
    switch (button) {
        case MouseButton::LEFT:   flags |= PTR_FLAGS_BUTTON1; break;
        case MouseButton::RIGHT:  flags |= PTR_FLAGS_BUTTON2; break;
        case MouseButton::MIDDLE: flags |= PTR_FLAGS_BUTTON3; break;
        default: return;
    }
    OH_LOG_INFO(LOG_APP,
        "[RDP] sendMouse queued flags=0x%{public}04x x=%{public}d y=%{public}d button=%{public}d pressed=%{public}s",
        flags, x, y, buttonValue, pressed ? "down" : "up");
    // 先移动到目标点，再发送纯按钮事件。队列中旧 mouse move 会被清理，避免点击被旧移动拖慢。
    impl_->enqueueMouseButtonWithMove(PTR_FLAGS_MOVE, flags, ux, uy);
}

void FreeRdpAdapter::sendMouseWheel(int x, int y, int delta) {
    if (!impl_) {
        return;
    }
    UINT16 flags = PTR_FLAGS_WHEEL;
    UINT16 magnitude = 0x78;
    if (delta < 0) {
        flags |= PTR_FLAGS_WHEEL_NEGATIVE;
    }
    flags |= magnitude;
    impl_->enqueueInputEvent(RdpQueuedInputEvent::MouseWheel(
        flags, 0, static_cast<UINT16>(x), static_cast<UINT16>(y)));
}

void FreeRdpAdapter::sendText(const std::string& text) {
    if (!impl_) {
        return;
    }
    // UTF-8 → UTF-16.  One user commit remains one queue item so later cursor
    // gestures and text cannot overtake part of a long batch.
    const std::vector<UINT16> codeUnits = utf8ToUtf16(text);
    std::u16string batch;
    batch.reserve(codeUnits.size());
    for (UINT16 unit : codeUnits) {
        batch.push_back(static_cast<char16_t>(unit));
    }
    if (!batch.empty()) {
        impl_->enqueueInputEvent(RdpQueuedInputEvent::Text(batch));
    }
}

// ---- 编码能力 ----
bool FreeRdpAdapter::supportsCodec(CodecType codec) {
    return codec == CodecType::H264 || codec == CodecType::H265;
}

std::vector<CodecType> FreeRdpAdapter::supportedCodecs() {
    return {CodecType::H264, CodecType::H265};
}

// ---- 回调 ----
void FreeRdpAdapter::setVideoCallback(VideoFrameCallback cb) { impl_->videoCallback = std::move(cb); }
void FreeRdpAdapter::setAudioCallback(AudioDataCallback cb) {
    impl_->audioCallback = std::move(cb);
    if (impl_->config.rdAudioEnabled) {
        std::lock_guard<std::mutex> lock(g_rdpAudioCallbackMutex);
        if (impl_->audioCallback) {
            g_rdpAudioCallbackOwner = this;
            g_rdpAudioCallback = impl_->audioCallback;
        } else if (g_rdpAudioCallbackOwner == this) {
            g_rdpAudioCallbackOwner = nullptr;
            g_rdpAudioCallback = nullptr;
        }
    }
}
void FreeRdpAdapter::setConnectionStateCallback(ConnectionStateCallback cb) { impl_->stateCallback = std::move(cb); }

void FreeRdpAdapter::setClipboardText(const std::string& t) {
    impl_->clipboardText = t;
    if (impl_->cliprdr && impl_->cliprdr->ClientFormatList) {
        CLIPRDR_FORMAT format {};
        format.formatId = CF_UNICODETEXT;
        CLIPRDR_FORMAT_LIST list {};
        list.common.msgType = CB_FORMAT_LIST;
        list.numFormats = 1;
        list.formats = &format;
        impl_->cliprdr->ClientFormatList(impl_->cliprdr, &list);
    }
}
void FreeRdpAdapter::sendClipboardData(const uint8_t* data, uint32_t len) {
    if (data == nullptr || len == 0) return;
    setClipboardText(std::string(reinterpret_cast<const char*>(data), len));
}
std::string FreeRdpAdapter::getClipboardText() { return impl_->clipboardText; }
bool FreeRdpAdapter::isClipboardReceiveReady() { return impl_->cliprdr != nullptr; }
bool FreeRdpAdapter::supportsFileTransfer() { return true; }
SessionTransferStatus FreeRdpAdapter::getSessionTransferStatus() { return impl_->transferStatus.snapshot(); }

void registerFreeRdpAdapter() {
    auto adapter = std::shared_ptr<FreeRdpAdapter>(new FreeRdpAdapter());
    ExtensionSystem::instance().protocols.registerExt("protocol", "rdp", adapter);
    OH_LOG_INFO(LOG_APP, "[RDP] FreeRDP 3.x adapter registered (REAL FREERDP)");
}

#else // !USE_REAL_FREERDP

// ============================================================
// 路径 2: 手写 RDP 骨架 (回退)
// ============================================================
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <cstring>
#include <cerrno>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "RDP_ADAPTER"

// RDP 协议常量
#define RDP_TCP_PORT          3389
#define X224_TPDU_CONN_REQUEST   0xE0
#define X224_TPDU_CONN_CONFIRM   0xD0
#define X224_TPDU_DATA           0xF0
#define RDP_NEG_REQ_TYPE         0x01
#define RDP_NEG_RSP_TYPE         0x02
#define RDP_NEG_FAILURE          0x03
#define RDP_NEG_RES_CORRELATION  0x06
#define PROTOCOL_RDP             0x00000000
#define PROTOCOL_SSL             0x00000001
#define PROTOCOL_HYBRID          0x00000002
#define PROTOCOL_RDSTLS          0x00000004
#define PROTOCOL_HYBRID_EX       0x00000008
#define RDP_NEG_REQ_SIZE         8
#define MCS_TYPE_CONNECT_INITIAL  0x65
#define MCS_TYPE_CONNECT_RESPONSE 0x66

struct FreeRdpAdapter::Impl {
    ConnectionConfig        config;
    ConnectionState         state = ConnectionState::DISCONNECTED;
    VideoFrameCallback      videoCallback;
    AudioDataCallback       audioCallback;
    ConnectionStateCallback stateCallback;
    std::string             clipboardText;
    int                     sockFd = -1;
    uint32_t                selectedProtocol = 0;
    bool                    tlsEnabled = false;

    void setState(ConnectionState s, const std::string& msg = "") {
        state = s;
        if (stateCallback) { stateCallback(s, msg); }
    }
};

// TCP 连接实现
static int rdpTcpConnect(const std::string& host, int port, int& sockFd) {
    const std::string logHost = SafeLog::MaskHost(host);
    sockFd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockFd < 0) {
        OH_LOG_ERROR(LOG_APP, "[RDP] socket() failed: %{public}s", strerror(errno));
        return -1;
    }
    int flags = fcntl(sockFd, F_GETFL, 0);
    fcntl(sockFd, F_SETFL, flags | O_NONBLOCK);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<uint16_t>(port));
    if (inet_pton(AF_INET, host.c_str(), &addr.sin_addr) <= 0) {
        OH_LOG_ERROR(LOG_APP, "[RDP] inet_pton failed: %{public}s", logHost.c_str());
        close(sockFd); sockFd = -1; return -14;
    }
    int ret = ::connect(sockFd, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr));
    if (ret < 0 && errno != EINPROGRESS) {
        OH_LOG_ERROR(LOG_APP, "[RDP] connect() failed: %{public}s", strerror(errno));
        close(sockFd); sockFd = -1; return -12;
    }
    if (ret < 0) { usleep(100000); }
    OH_LOG_INFO(LOG_APP, "[RDP] TCP connected to %{public}s:%{public}d fd=%{public}d", logHost.c_str(), port, sockFd);
    return 0;
}

// X.224 连接请求
static int rdpSendX224ConnectionRequest(int sockFd) {
    unsigned char x224Req[11] = {
        X224_TPDU_CONN_REQUEST, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    };
    ssize_t sent = send(sockFd, x224Req, sizeof(x224Req), 0);
    if (sent < 0) {
        OH_LOG_ERROR(LOG_APP, "[RDP] X.224 connection request send failed: %{public}s", strerror(errno));
        return -1;
    }
    OH_LOG_INFO(LOG_APP, "[RDP] X.224 Connection Request sent (%{public}zd bytes)", sent);
    return 0;
}

// X.224 连接确认
static int rdpRecvX224ConnectionConfirm(int sockFd) {
    unsigned char buf[256];
    ssize_t n = recv(sockFd, buf, sizeof(buf), 0);
    if (n < 6) {
        OH_LOG_ERROR(LOG_APP, "[RDP] X.224 Connection Confirm too short: %{public}zd bytes", n);
        return -1;
    }
    OH_LOG_INFO(LOG_APP, "[RDP] X.224 Connection Confirm received (%{public}zd bytes)", n);
    return 0;
}

// RDP 协商请求
static int rdpSendNegotiationRequest(int sockFd) {
    unsigned char negReq[RDP_NEG_REQ_SIZE] = {RDP_NEG_REQ_TYPE, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    negReq[7] = static_cast<unsigned char>(PROTOCOL_SSL | PROTOCOL_HYBRID);
    ssize_t sent = send(sockFd, negReq, RDP_NEG_REQ_SIZE, 0);
    if (sent < 0) {
        OH_LOG_ERROR(LOG_APP, "[RDP] Negotiation request send failed: %{public}s", strerror(errno));
        return -1;
    }
    OH_LOG_INFO(LOG_APP, "[RDP] RDP Negotiation Request sent (protocols: SSL|HYBRID)");
    return 0;
}

// RDP 协商响应
static int rdpRecvNegotiationResponse(int sockFd, uint32_t& selectedProtocol, bool& tlsEnabled) {
    unsigned char buf[8];
    ssize_t n = recv(sockFd, buf, 8, 0);
    if (n < 8) {
        OH_LOG_ERROR(LOG_APP, "[RDP] Negotiation response too short: %{public}zd bytes", n);
        return -1;
    }
    selectedProtocol = (static_cast<uint32_t>(buf[4])) | (static_cast<uint32_t>(buf[5]) << 8) |
                       (static_cast<uint32_t>(buf[6]) << 16) | (static_cast<uint32_t>(buf[7]) << 24);
    tlsEnabled = (selectedProtocol & PROTOCOL_SSL) || (selectedProtocol & PROTOCOL_HYBRID);
    OH_LOG_INFO(LOG_APP, "[RDP] Negotiation Response: protocol=0x%{public}08X TLS=%{public}s",
                selectedProtocol, tlsEnabled ? "yes" : "no");
    return 0;
}

// MCS Connect Initial
static int rdpSendMcsConnectInitial(int sockFd) {
    unsigned char mcsPdu[] = {
        0x03, 0x00, 0x00, 0x2A, 0x25, 0xE0, MCS_TYPE_CONNECT_INITIAL,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00
    };
    ssize_t sent = send(sockFd, mcsPdu, sizeof(mcsPdu), 0);
    if (sent < 0) {
        OH_LOG_ERROR(LOG_APP, "[RDP] MCS Connect Initial send failed: %{public}s", strerror(errno));
        return -1;
    }
    OH_LOG_INFO(LOG_APP, "[RDP] MCS Connect Initial PDU sent");
    return 0;
}

// MCS Connect Response
static int rdpRecvMcsConnectResponse(int sockFd) {
    unsigned char buf[512];
    ssize_t n = recv(sockFd, buf, sizeof(buf), 0);
    if (n < 4) {
        OH_LOG_ERROR(LOG_APP, "[RDP] MCS Connect Response too short: %{public}zd", n);
        return -1;
    }
    OH_LOG_INFO(LOG_APP, "[RDP] MCS Connect Response PDU received (%{public}zd bytes)", n);
    return 0;
}

// ---- 构造/析构 ----
FreeRdpAdapter::FreeRdpAdapter() : impl_(std::make_unique<Impl>()) {
    OH_LOG_INFO(LOG_APP, "[RDP] FreeRdpAdapter created (skeleton)");
}

FreeRdpAdapter::~FreeRdpAdapter() {
    if (impl_->state == ConnectionState::CONNECTED) { disconnect(); }
}

// ---- 协议元信息 ----
std::string FreeRdpAdapter::protocolName() { return "RDP"; }
int FreeRdpAdapter::defaultPort() { return RDP_TCP_PORT; }
std::string FreeRdpAdapter::protocolVersion() { return "3.7.0-skeleton"; }

// ---- 连接管理 ----
int FreeRdpAdapter::connect(const ConnectionConfig& cfg) {
    if (impl_->state == ConnectionState::CONNECTED) { disconnect(); }
    impl_->config = cfg;
    impl_->setState(ConnectionState::CONNECTING, "Connecting...");

    int port = cfg.port > 0 ? cfg.port : RDP_TCP_PORT;
    int ret;

    ret = rdpTcpConnect(cfg.host, port, impl_->sockFd);
    if (ret < 0) { impl_->setState(ConnectionState::ERROR, "TCP connection failed"); return ret; }
    ret = rdpSendX224ConnectionRequest(impl_->sockFd);
    if (ret < 0) { impl_->setState(ConnectionState::ERROR, "X.224 failed"); disconnect(); return -22; }
    ret = rdpRecvX224ConnectionConfirm(impl_->sockFd);
    if (ret < 0) { impl_->setState(ConnectionState::ERROR, "X.224 confirm failed"); disconnect(); return -23; }
    ret = rdpSendNegotiationRequest(impl_->sockFd);
    if (ret < 0) { impl_->setState(ConnectionState::ERROR, "RDP neg req failed"); disconnect(); return -24; }
    ret = rdpRecvNegotiationResponse(impl_->sockFd, impl_->selectedProtocol, impl_->tlsEnabled);
    if (ret < 0) { impl_->setState(ConnectionState::ERROR, "RDP neg resp failed"); disconnect(); return -25; }
    ret = rdpSendMcsConnectInitial(impl_->sockFd);
    if (ret < 0) { impl_->setState(ConnectionState::ERROR, "MCS init failed"); disconnect(); return -26; }
    ret = rdpRecvMcsConnectResponse(impl_->sockFd);
    if (ret < 0) { impl_->setState(ConnectionState::ERROR, "MCS resp failed"); disconnect(); return -27; }

    impl_->setState(ConnectionState::CONNECTED, "RDP session established (skeleton)");
    const std::string logHost = SafeLog::MaskHost(cfg.host);
    OH_LOG_INFO(LOG_APP, "[RDP] RDP skeleton session: %{public}s:%{public}d (TLS=%{public}s)",
                logHost.c_str(), port, impl_->tlsEnabled ? "yes" : "no");
    return 0;
}

void FreeRdpAdapter::disconnect() {
    if (impl_->sockFd >= 0) {
        shutdown(impl_->sockFd, SHUT_RDWR);
        close(impl_->sockFd);
        impl_->sockFd = -1;
    }
    impl_->selectedProtocol = 0;
    impl_->tlsEnabled = false;
    impl_->setState(ConnectionState::DISCONNECTED, "Disconnected");
    OH_LOG_INFO(LOG_APP, "[RDP] Disconnected");
}

ConnectionState FreeRdpAdapter::getState() { return impl_->state; }

void FreeRdpAdapter::requestFrameRefresh() {
    OH_LOG_WARN(LOG_APP, "[RDP] requestFrameRefresh skipped: skeleton adapter has no video surface");
}

RdpCertificateInfo FreeRdpAdapter::probeRdpCertificate(const std::string& host, int port,
                                                       const std::string& serverName) {
    return probeRdpCertificateOverTls(host, port, serverName);
}

RdpRenderStats FreeRdpAdapter::getRdpRenderStats() {
    return RdpRenderStats();
}

bool FreeRdpAdapter::setBackgroundVideoPrewarm(bool enabled, uint32_t intervalMs) {
    OH_LOG_INFO(LOG_APP, "[RDP-PREWARM] skeleton enabled=%{public}d interval=%{public}u",
                enabled ? 1 : 0, intervalMs);
    return true;
}

bool FreeRdpAdapter::presentCachedBackgroundFrame() {
    OH_LOG_INFO(LOG_APP, "[RDP-PREWARM] skeleton has no cached frame");
    return false;
}

void FreeRdpAdapter::sendKey(uint32_t scancode, bool pressed) {
    OH_LOG_DEBUG(LOG_APP, "[RDP] key sc=%{public}u p=%{public}s", scancode, pressed ? "down" : "up");
}

void FreeRdpAdapter::sendMouse(int x, int y, MouseButton button, bool pressed) {
    OH_LOG_DEBUG(LOG_APP, "[RDP] mouse (%{public}d,%{public}d) btn=%{public}d %{public}s",
                 x, y, static_cast<int>(button), pressed ? "down" : "up");
}

void FreeRdpAdapter::sendMouseWheel(int x, int y, int delta) {
    OH_LOG_DEBUG(LOG_APP, "[RDP] wheel (%{public}d,%{public}d) delta=%{public}d", x, y, delta);
}

void FreeRdpAdapter::sendText(const std::string& text) {
    OH_LOG_DEBUG(LOG_APP, "[RDP] text: %{public}s", text.c_str());
}

bool FreeRdpAdapter::supportsCodec(CodecType codec) {
    return codec == CodecType::H264 || codec == CodecType::H265;
}

std::vector<CodecType> FreeRdpAdapter::supportedCodecs() {
    return {CodecType::H264, CodecType::H265};
}

void FreeRdpAdapter::setVideoCallback(VideoFrameCallback cb) { impl_->videoCallback = std::move(cb); }
void FreeRdpAdapter::setAudioCallback(AudioDataCallback cb) { impl_->audioCallback = std::move(cb); }
void FreeRdpAdapter::setConnectionStateCallback(ConnectionStateCallback cb) { impl_->stateCallback = std::move(cb); }

void FreeRdpAdapter::setClipboardText(const std::string& t) { impl_->clipboardText = t; }
void FreeRdpAdapter::sendClipboardData(const uint8_t* data, uint32_t len) {
    if (data == nullptr || len == 0) return;
    setClipboardText(std::string(reinterpret_cast<const char*>(data), len));
}
std::string FreeRdpAdapter::getClipboardText() { return impl_->clipboardText; }
bool FreeRdpAdapter::supportsFileTransfer() { return true; }

void registerFreeRdpAdapter() {
    auto adapter = std::shared_ptr<FreeRdpAdapter>(new FreeRdpAdapter());
    ExtensionSystem::instance().protocols.registerExt("protocol", "rdp", adapter);
    OH_LOG_INFO(LOG_APP, "[RDP] FreeRDP skeleton adapter registered");
}

#endif // USE_REAL_FREERDP
