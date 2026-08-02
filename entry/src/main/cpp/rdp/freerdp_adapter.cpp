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
#include "render/callback_admission_context.h"
#include "render/video_perf_counters.h"
#include "video/video_activity_state.h"
#include "common/safe_log.h"
#include "rdp_audio_policy.h"
#include "rdp_auth_identity_policy.h"
#include "rdp_auth_mode_policy.h"
#include "rdp_background_frame_cache.h"
#include "rdp_certificate_policy.h"
#include "rdp_frame_pump.h"
#include "rdp_file_clipboard_bridge.h"
#include "rdp_graphics_lifecycle.h"
#include "rdp_keymap.h"
#include "rdp_performance_policy.h"
#include "rdp_redraw_notifier.h"
#include "rdp_input_queue.h"
#include "rdp_shutdown_state.h"
#ifdef USE_REAL_FREERDP
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/codec/color.h>
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
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <functional>
#include <iomanip>
#include <sstream>
#include <thread>
#include <unordered_map>
#include <unordered_set>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "RDP_ADAPTER"

namespace {

constexpr int kDefaultRdpPort = 3389;
constexpr int kRdpCertFlagUntrustedRoot = 0x01;
constexpr int kRdpCertFlagHostMismatch = 0x02;

using RdpShutdownDeadline = std::chrono::steady_clock::time_point;

struct RdpShutdownTicket {
    explicit RdpShutdownTicket(RdpShutdownDeadline value, uint64_t serialValue)
        : deadline(value), serial(serialValue) {}

    RdpShutdownDeadline deadline;
    uint64_t serial = 0;
};

#ifdef USE_REAL_FREERDP
static std::atomic<uint64_t> g_nextRdpShutdownTicket {1};

std::chrono::milliseconds remainingRdpShutdownBudget(RdpShutdownDeadline deadline) {
    if (deadline == RdpShutdownDeadline::max()) {
        return std::chrono::milliseconds(500);
    }
    const auto now = std::chrono::steady_clock::now();
    if (now >= deadline) {
        return std::chrono::milliseconds(0);
    }
    return std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now);
}
#endif

[[maybe_unused]] void secureClearString(std::string& value) {
    if (!value.empty()) {
        volatile char* data = value.data();
        for (size_t index = 0; index < value.size(); ++index) {
            data[index] = '\0';
        }
    }
    value.clear();
}

#ifdef USE_REAL_FREERDP
void secureClearFreeRdpPasswordHash(rdpSettings* settings) {
    if (!settings || !settings->PasswordHash) {
        return;
    }
    volatile char* data = settings->PasswordHash;
    const size_t length = std::strlen(settings->PasswordHash);
    for (size_t index = 0; index < length; ++index) {
        data[index] = '\0';
    }
    // Let FreeRDP replace and release its settings-owned copy only after the
    // buffer has been overwritten.  Keep the field empty for reconnects after
    // the instance is being torn down; while a live session is active the hash
    // remains available to FreeRDP's own reconnect path.
    freerdp_settings_set_string(settings, FreeRDP_PasswordHash, "");
}
#endif

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
#include <freerdp/locale/locale.h>
#include <freerdp/settings_types.h>
#include <winpr/input.h>
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

static UINT32 resolveRdpKeyboardLayoutFromSystemLocale() {
    // Match FreeRDP's desktop clients: use the controller's current locale as
    // the advertised Windows layout, then use US only as a deterministic last
    // resort. Leaving this as zero makes the server guess and can desynchronize
    // physical scan codes from the active remote IME.
    DWORD layout = 0;
    const int detectResult = freerdp_detect_keyboard_layout_from_system_locale(&layout);
    if (detectResult != 0 || layout == 0) {
        static constexpr UINT32 kEnglishUnitedStatesLayout = 0x00000409;
        OH_LOG_WARN(LOG_APP,
                    "[RDP] keyboard layout detection failed result=%{public}d; using US fallback=0x%{public}08x",
                    detectResult, kEnglishUnitedStatesLayout);
        return kEnglishUnitedStatesLayout;
    }
    OH_LOG_INFO(LOG_APP, "[RDP] keyboard layout detected from system locale=0x%{public}08x",
                static_cast<UINT32>(layout));
    return static_cast<UINT32>(layout);
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

void deferRdpWorker(std::thread worker, std::shared_ptr<void> keepAlive,
                    std::shared_ptr<std::atomic<bool>> done);

struct FreeRdpAdapter::Impl {
    TransferRuntimeStatus transferStatus;
    ConnectionConfig        config;
    ConnectionState         state = ConnectionState::DISCONNECTED;
    VideoFrameCallback      videoCallback;
    AudioDataCallback       audioCallback;
    ConnectionStateCallback stateCallback;
    std::string             clipboardText;
    CliprdrClientContext*   cliprdr = nullptr;
    std::unique_ptr<RdpFileClipboardBridge> fileClipboard;
    std::thread             eventThread;
    std::thread             connectThread;
    std::thread             driveThread;
    std::mutex              stateMutex;
    std::mutex              instanceMutex;
    std::mutex              shutdownMutex;
    // Connection workers may outlive the bounded disconnect call. Protect
    // the mutable configuration copy so a reconnect cannot race a stale
    // worker while it snapshots or scrubs credentials.
    mutable std::mutex      configMutex;
    // Serializes cursor callbacks with session identity/reset and the
    // post-disconnect cursor teardown. The store also performs a generation
    // check under its own mutex for callbacks that cannot take this lock.
    std::mutex              cursorLifecycleMutex;
    std::mutex              workerLifecycleMutex;
    std::mutex              workerDoneMutex;
    std::condition_variable workerDoneCv;
    std::weak_ptr<FreeRdpAdapter> lifetime;
    std::shared_ptr<std::atomic<bool>> eventThreadDone =
        std::make_shared<std::atomic<bool>>(true);
    std::shared_ptr<std::atomic<bool>> connectThreadDone =
        std::make_shared<std::atomic<bool>>(true);
    std::shared_ptr<std::atomic<bool>> driveThreadDone =
        std::make_shared<std::atomic<bool>>(true);
    // freerdp_disconnect is an SDK call with no caller-supplied deadline.
    // When it outlives the disconnect API, final context retirement waits on
    // this fence instead of touching the instance underneath the worker.
    std::shared_ptr<std::atomic<bool>> disconnectWorkerDone =
        std::make_shared<std::atomic<bool>>(true);
    std::mutex              renderMutex;
    mutable std::mutex      ownerMutex;
    mutable std::mutex      videoTelemetryMutex;
    RdpShutdown::State      shutdownState;
    std::atomic<uint64_t>   sessionGeneration {0};
    Render::DecoderSessionIdentity owner;
    RdpVideoTelemetryCallback videoTelemetryCallback;
#if defined(RDP_NATIVE_CALLBACK_TESTING) && defined(USE_REAL_FREERDP)
    mutable std::mutex callbackTestMutex;
    std::function<void()> endPaintBarrier;
#endif
    RemoteCursorStore       cursorStore;
    std::atomic<int64_t>    shutdownStartedUs {0};
    std::shared_ptr<RdpFramePump> framePump = std::make_shared<RdpFramePump>();
    RdpGraphicsLifecycle    graphicsLifecycle;
    std::shared_ptr<RdpDamageAccumulator> damageAccumulator {
        std::make_shared<RdpDamageAccumulator>()
    };
    std::atomic<bool>       backgroundVideoPrewarmEnabled {false};
    std::atomic<uint32_t>   backgroundVideoPrewarmIntervalMs {1000};
    RdpBackgroundFrameCache backgroundFrameCache;
    std::mutex              inputQueueMutex;
    std::condition_variable inputQueueCv;
    std::thread             inputQueueThread;
    std::shared_ptr<std::atomic<bool>> inputQueueDone =
        std::make_shared<std::atomic<bool>>(true);
    RdpInputQueue           inputQueue;
    std::atomic<uint64_t>   inputQueueGeneration {0};
    std::atomic<bool>       inputQueueRunning {false};
    std::atomic<bool>       inputQueueStop {false};
    std::atomic<bool>       connecting {false};
    std::atomic<bool>       connectThreadStarted {false};
    std::atomic<bool>       driveThreadStarted {false};
    std::atomic<bool>       stopRequested {false};
    std::atomic<bool>       gdiInitialized {false};
    std::atomic<bool>       presentationEnabled {false};
    std::atomic<bool>       postDisconnectTeardownQueued {false};
    std::atomic<bool>       cleanupDeferredForWorker {false};
    // All disconnect and PostDisconnect paths for one teardown share this
    // absolute ticket.  Atomic shared_ptr operations let a FreeRDP callback
    // observe it without taking shutdownMutex while disconnect holds that
    // mutex across the bounded orchestration.
    std::shared_ptr<RdpShutdownTicket> shutdownTicket;
    std::shared_ptr<RdpRedrawNotifier> redrawNotifier;
    uint64_t                redrawCallbackToken = 0;
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

    Render::DecoderSessionIdentity ownerSnapshot() const {
        std::lock_guard<std::mutex> lock(ownerMutex);
        return owner;
    }

    RdpVideoTelemetryCallback videoTelemetryCallbackSnapshot() const {
        std::lock_guard<std::mutex> lock(videoTelemetryMutex);
        return videoTelemetryCallback;
    }

    std::shared_ptr<RdpShutdownTicket> getOrCreateShutdownTicket() {
        auto ticket = std::atomic_load_explicit(
            &shutdownTicket, std::memory_order_acquire);
        if (ticket) {
            return ticket;
        }
        auto candidate = std::make_shared<RdpShutdownTicket>(
            std::chrono::steady_clock::now() + std::chrono::milliseconds(500),
            g_nextRdpShutdownTicket.fetch_add(1, std::memory_order_relaxed));
        if (std::atomic_compare_exchange_strong_explicit(
                &shutdownTicket, &ticket, candidate,
                std::memory_order_acq_rel, std::memory_order_acquire)) {
            return candidate;
        }
        return ticket;
    }

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

    bool isInputQueueWorkerCurrent(uint64_t workerGeneration) const {
        return inputQueueRunning.load(std::memory_order_acquire) &&
            !inputQueueStop.load(std::memory_order_acquire) &&
            workerGeneration == inputQueueGeneration.load(std::memory_order_acquire);
    }

    void sendQueuedInputEvent(FreeRdpAdapter* owner, const RdpQueuedInputEvent& event,
                              uint64_t workerGeneration) {
        if (!isInputQueueWorkerCurrent(workerGeneration)) {
            return;
        }
        std::lock_guard<std::mutex> lock(instanceMutex);
        // Do not hold inputQueueMutex while FreeRDP can block on transport I/O.
        // stopInputQueueWorker invalidates this generation before joining, so
        // this second check prevents a stale worker from dispatching after it
        // has waited for instanceMutex.
        if (!isInputQueueWorkerCurrent(workerGeneration) || !owner || !owner->instance_ ||
            !owner->instance_->input) {
            return;
        }
        switch (event.type) {
            case RdpInputEventType::Key:
                freerdp_input_send_keyboard_event(owner->instance_->input, event.flags, event.code);
                break;
            case RdpInputEventType::Pause:
                freerdp_input_send_keyboard_pause_event(owner->instance_->input);
                break;
            case RdpInputEventType::TextBatch:
                DispatchTextBatch(event.text, KBD_FLAGS_RELEASE,
                    [owner](uint16_t flags, uint16_t code) {
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
                    return inputQueueStop.load(std::memory_order_acquire) || inputQueue.depth() > 0;
                });
                if (!isInputQueueWorkerCurrent(workerGeneration)) {
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
        if (inputQueueRunning.load(std::memory_order_acquire)) {
            return;
        }
        std::shared_ptr<FreeRdpAdapter> retained;
        try {
            retained = owner ? owner->shared_from_this() : nullptr;
        } catch (const std::bad_weak_ptr&) {
            OH_LOG_ERROR(LOG_APP,
                "[RDP] input worker requires shared adapter lifetime");
            return;
        }
        if (!retained) {
            OH_LOG_ERROR(LOG_APP,
                "[RDP] input worker missing adapter lifetime");
            return;
        }
        inputQueueStop.store(false, std::memory_order_release);
        inputQueue.clear();
        inputQueue.resetMetrics();
        const uint64_t workerGeneration =
            inputQueueGeneration.fetch_add(1, std::memory_order_acq_rel) + 1;
        inputQueueRunning.store(true, std::memory_order_release);
        auto done = std::make_shared<std::atomic<bool>>(false);
        std::atomic_store_explicit(&inputQueueDone, done, std::memory_order_release);
        try {
            inputQueueThread = std::thread([this, retained, done, workerGeneration]() {
                inputQueueWorkerLoop(retained.get(), workerGeneration);
                inputQueueRunning.store(false, std::memory_order_release);
                done->store(true, std::memory_order_release);
                inputQueueCv.notify_all();
            });
        } catch (const std::exception& e) {
            inputQueueRunning.store(false, std::memory_order_release);
            done->store(true, std::memory_order_release);
            OH_LOG_WARN(LOG_APP, "[RDP] input queue worker start failed: %{public}s", e.what());
        } catch (...) {
            inputQueueRunning.store(false, std::memory_order_release);
            done->store(true, std::memory_order_release);
            OH_LOG_WARN(LOG_APP, "[RDP] input queue worker start failed: unknown");
        }
    }

    void stopInputQueueWorker(RdpShutdownDeadline deadline) {
        {
            std::lock_guard<std::mutex> lock(inputQueueMutex);
            if (!inputQueueThread.joinable()) {
                inputQueueRunning.store(false, std::memory_order_release);
                inputQueueStop.store(false, std::memory_order_release);
                return;
            }
            inputQueueStop.store(true, std::memory_order_release);
            inputQueueGeneration.fetch_add(1, std::memory_order_acq_rel);
            inputQueue.clear();
        }
        inputQueueCv.notify_all();
        if (inputQueueThread.joinable()) {
            const auto doneFence = std::atomic_load_explicit(
                &inputQueueDone, std::memory_order_acquire);
            std::unique_lock<std::mutex> lock(inputQueueMutex);
            const bool completed = inputQueueCv.wait_for(lock,
                remainingRdpShutdownBudget(deadline), [doneFence]() {
                return doneFence == nullptr || doneFence->load(std::memory_order_acquire);
            });
            lock.unlock();
            if (completed) {
                inputQueueThread.join();
            } else {
                OH_LOG_WARN(LOG_APP,
                    "[RDP] input worker exceeded shutdown budget; deferring join");
                deferRdpWorker(std::move(inputQueueThread), lifetime.lock(),
                               doneFence);
                return;
            }
        }
        {
            std::lock_guard<std::mutex> lock(inputQueueMutex);
            inputQueueRunning.store(false, std::memory_order_release);
            inputQueueStop.store(false, std::memory_order_release);
            inputQueue.clear();
        }
    }

    void enqueueInputEvent(RdpQueuedInputEvent event) {
        {
            std::lock_guard<std::mutex> lock(inputQueueMutex);
            if (!inputQueueRunning.load(std::memory_order_acquire) ||
                inputQueueStop.load(std::memory_order_acquire)) {
                return;
            }
            inputQueue.enqueue(std::move(event));
        }
        inputQueueCv.notify_one();
    }

    void enqueueMouseButtonWithMove(UINT16 moveFlags, UINT16 buttonFlags, UINT16 x, UINT16 y) {
        {
            std::lock_guard<std::mutex> lock(inputQueueMutex);
            if (!inputQueueRunning.load(std::memory_order_acquire) ||
                inputQueueStop.load(std::memory_order_acquire)) {
                return;
            }
            // The queue materializes this latest move before the button event,
            // preserving click/drag targets while coalescing prior movement.
            inputQueue.enqueue(RdpQueuedInputEvent::Mouse(moveFlags, 0, x, y, true));
            inputQueue.enqueue(RdpQueuedInputEvent::Mouse(buttonFlags, 0, x, y, false));
        }
        inputQueueCv.notify_one();
    }

    void startSessionWorkers(FreeRdpAdapter* owner) {
        std::lock_guard<std::mutex> lifecycleLock(workerLifecycleMutex);
        startInputQueueWorker(owner);
        if (!framePump->start()) {
            presentationEnabled.store(false, std::memory_order_release);
            OH_LOG_ERROR(LOG_APP, "[RDP] frame pump unavailable; presentation remains disabled");
            return;
        }
        // Canvas transforms only wake the pump. It redraws the already
        // uploaded texture and never asks the GDI accumulator for a snapshot.
        auto notifier = std::make_shared<RdpRedrawNotifier>();
        const auto retained = lifetime.lock();
        notifier->bind([retained]() {
            if (retained && retained->impl_ && retained->impl_->framePump) {
                retained->impl_->framePump->requestTransformRefresh();
            }
        });
        redrawNotifier = notifier;
        redrawCallbackToken = RendererNapi::RegisterActiveRedrawCallback([notifier]() {
            notifier->notify();
        });
    }

    void stopSessionWorkers(RdpShutdownDeadline deadline) {
        std::lock_guard<std::mutex> lifecycleLock(workerLifecycleMutex);
        const uint64_t callbackToken = redrawCallbackToken;
        redrawCallbackToken = 0;
        auto notifier = std::move(redrawNotifier);
        RendererNapi::UnregisterActiveRedrawCallback(callbackToken);
        if (notifier) {
            if (!notifier->disableAndWaitWithin(remainingRdpShutdownBudget(deadline))) {
                auto drained = std::make_shared<std::atomic<bool>>(false);
                auto retained = lifetime.lock();
                try {
                    std::thread drainThread([notifier, drained]() {
                        // The notifier's callback state is shared with every
                        // in-flight notify call, so the deferred owner does
                        // not need an unbounded retry loop to keep a raw gate
                        // alive. One bounded drain attempt is sufficient.
                        (void)notifier->disableAndWaitWithin(
                            std::chrono::milliseconds(500));
                        drained->store(true, std::memory_order_release);
                    });
                    deferRdpWorker(std::move(drainThread), retained, drained);
                } catch (const std::exception& e) {
                    OH_LOG_WARN(LOG_APP,
                        "[RDP] redraw drain worker start failed: %{public}s", e.what());
                } catch (...) {
                    OH_LOG_WARN(LOG_APP, "[RDP] redraw drain worker start failed");
                }
            }
        }
        traceShutdown("input-stop", "begin");
        stopInputQueueWorker(deadline);
        traceShutdown("input-stop", "complete");
        traceShutdown("frame-pump-stop", "begin");
        auto pump = std::move(framePump);
        if (pump && !pump->stopWithin(remainingRdpShutdownBudget(deadline))) {
            RdpFramePump::deferStopAndJoin(std::move(pump));
        }
        framePump = std::make_shared<RdpFramePump>();
        traceShutdown("frame-pump-stop", "complete");
        damageAccumulator->clear();
    }

    void setState(ConnectionState s, const std::string& msg = "") {
        ConnectionStateCallback callback;
        {
            std::lock_guard<std::mutex> lock(stateMutex);
            state = s;
            // Snapshot the callback while protected, but invoke it after the
            // state mutex is released.  State callbacks are application code
            // and may synchronously call getState(), disconnect(), or start a
            // new connection; invoking them under stateMutex would deadlock
            // or serialize teardown against an external re-entry.
            callback = stateCallback;
        }
        if (callback) {
            callback(s, msg);
        }
    }
};

// A FreeRDP worker can outlive the API call that requested cancellation when
// an SDK callback or network read is still unwinding.  Keep the thread object
// and the adapter lifetime together in an explicit app-scope owner.  The
// caller only waits for the supplied deadline; the owner joins after the
// worker's done fence, never by detaching or by blocking a static destructor.
struct DeferredRdpWorker {
    std::thread worker;
    std::shared_ptr<void> keepAlive;
    std::shared_ptr<std::atomic<bool>> done;
};

class RdpWorkerLifecycleOwner {
public:
    RdpWorkerLifecycleOwner() : worker_([this]() { run(); }) {}

    ~RdpWorkerLifecycleOwner() {
        // The owner is deleted only after shutdownWithin observes workerDone.
        // A live joinable worker here is a lifecycle bug; do not turn process
        // teardown into an unbounded join.
        if (worker_.joinable()) {
            std::abort();
        }
    }

    void enqueue(std::thread worker, std::shared_ptr<void> keepAlive,
                 std::shared_ptr<std::atomic<bool>> done) {
        if (!worker.joinable()) {
            return;
        }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            pending_.push_back(DeferredRdpWorker {
                std::move(worker), std::move(keepAlive), std::move(done)});
        }
        cv_.notify_one();
    }

    bool drainWithin(std::chrono::milliseconds timeout) {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, timeout, [this]() {
            return pending_.empty() && active_ == 0;
        });
    }

    std::size_t remaining() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return pending_.size() + active_;
    }

    bool shutdownWithin(std::chrono::milliseconds timeout) {
        const auto deadline = std::chrono::steady_clock::now() + timeout;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopping_ = true;
        }
        cv_.notify_all();
        std::unique_lock<std::mutex> lock(mutex_);
        if (!cv_.wait_until(lock, deadline, [this]() { return workerDone_; })) {
            return false;
        }
        lock.unlock();
        if (worker_.joinable() && worker_.get_id() != std::this_thread::get_id()) {
            worker_.join();
        }
        return true;
    }

private:
    void run() {
        for (;;) {
            DeferredRdpWorker item;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                cv_.wait(lock, [this]() { return stopping_ || !pending_.empty(); });
                if (pending_.empty() && stopping_) {
                    workerDone_ = true;
                    cv_.notify_all();
                    return;
                }
                item = std::move(pending_.front());
                pending_.pop_front();
                ++active_;
            }
            // Each deferred worker has an independent completion fence. Do
            // not let one stalled worker block completed workers behind it.
            if (item.done && !item.done->load(std::memory_order_acquire)) {
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    pending_.push_back(std::move(item));
                    --active_;
                }
                cv_.notify_all();
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }
            item.worker.join();
            item.keepAlive.reset();
            {
                std::lock_guard<std::mutex> lock(mutex_);
                --active_;
                cv_.notify_all();
            }
        }
    }

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::deque<DeferredRdpWorker> pending_;
    std::thread worker_;
    bool stopping_ = false;
    bool workerDone_ = false;
    std::size_t active_ = 0;
};

std::mutex g_rdpWorkerOwnerMutex;
RdpWorkerLifecycleOwner* g_rdpWorkerOwner = nullptr;

RdpWorkerLifecycleOwner& rdpWorkerOwner() {
    std::lock_guard<std::mutex> lock(g_rdpWorkerOwnerMutex);
    if (g_rdpWorkerOwner == nullptr) {
        g_rdpWorkerOwner = new RdpWorkerLifecycleOwner();
    }
    return *g_rdpWorkerOwner;
}

bool shutdownRdpWorkersWithin(std::chrono::milliseconds timeout) {
    RdpWorkerLifecycleOwner* owner = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_rdpWorkerOwnerMutex);
        owner = g_rdpWorkerOwner;
    }
    if (owner == nullptr) {
        return true;
    }
    const bool done = owner->shutdownWithin(timeout);
    if (done) {
        std::lock_guard<std::mutex> lock(g_rdpWorkerOwnerMutex);
        if (g_rdpWorkerOwner == owner) {
            g_rdpWorkerOwner = nullptr;
            // A caller may still hold the raw reference returned by
            // rdpWorkerOwner() while shutdown completes. The worker is joined
            // here; retain the retired owner until process exit to avoid a
            // delete-after-unlock use-after-free.
        }
    }
    return done;
}

std::size_t rdpWorkerRemaining() {
    std::lock_guard<std::mutex> lock(g_rdpWorkerOwnerMutex);
    return g_rdpWorkerOwner == nullptr ? 0 : g_rdpWorkerOwner->remaining();
}

void deferRdpWorker(std::thread worker, std::shared_ptr<void> keepAlive,
                    std::shared_ptr<std::atomic<bool>> done) {
    rdpWorkerOwner().enqueue(std::move(worker), std::move(keepAlive),
                             std::move(done));
}

static std::mutex g_rdpAudioCallbackMutex;
static AudioDataCallback g_rdpAudioCallback;
static Render::DecoderSessionIdentity g_rdpAudioCallbackOwner;
static std::shared_ptr<Render::CallbackAdmissionContext> g_rdpAudioAdmission;
static uint64_t g_rdpAudioCallbackToken = 0;
static std::atomic<int64_t> g_rdpCallbackToken {1};

struct RdpCallbackRegistryEntry {
    std::shared_ptr<Render::CallbackAdmissionContext> admission;
    // Production callbacks retain the adapter through the admission lease.
    // Test-only stack adapters keep the raw pointer for the fixture lifetime.
    std::shared_ptr<FreeRdpAdapter> keepAlive;
    FreeRdpAdapter* adapter = nullptr;
    Render::DecoderSessionIdentity owner;
    uint64_t generation = 0;
    uint64_t token = 0;
};

struct RdpCallbackLease {
    std::shared_ptr<Render::CallbackAdmissionContext> admission;
    Render::CallbackAdmissionContext::Lease lease;
    std::shared_ptr<FreeRdpAdapter> keepAlive;
    FreeRdpAdapter* adapter = nullptr;
    rdpContext* context = nullptr;
    CliprdrClientContext* channel = nullptr;
    Render::DecoderSessionIdentity owner;
    uint64_t generation = 0;
    // Admission alone protects the adapter/context lifetime.  This shared
    // sink lease additionally serializes every external platform/sink side
    // effect against S1->S2 activation and teardown.
    Render::SessionSinkOwnerLease::Lease ownerLease;

    explicit operator bool() const { return adapter != nullptr && static_cast<bool>(lease); }
};

static std::mutex g_rdpCallbackRegistryMutex;
static std::unordered_map<rdpContext*, RdpCallbackRegistryEntry> g_rdpCallbackRegistry;
static std::unordered_map<freerdp*, rdpContext*> g_rdpCallbackInstanceRegistry;
static std::unordered_map<CliprdrClientContext*, RdpCallbackRegistryEntry>
    g_rdpChannelCallbackRegistry;
// FreeRDP's static callback ABI carries only raw addresses.  Once a source is
// unregistered, the address cannot be reused until the final retire owner has
// confirmed source quiescence; otherwise a late S1 callback is
// indistinguishable from an S2 callback at the ABI boundary.
static std::unordered_map<rdpContext*, uint64_t> g_rdpContextQuarantine;
static std::unordered_map<freerdp*, uint64_t> g_rdpInstanceQuarantine;
static std::unordered_map<CliprdrClientContext*, uint64_t> g_rdpChannelQuarantine;
// A raw FreeRDP callback carries no epoch.  A quarantined address therefore
// remains unavailable until the production source-revoke sequence has
// completed.  This is deliberately separate from the quarantine token: a
// token proves which session retired, while this bit proves that every source
// which could emit the raw ABI has been detached.
static std::unordered_map<rdpContext*, uint64_t> g_rdpSourceRevokeConfirmed;

static void quarantineChannelLocked(CliprdrClientContext* channel, uint64_t token) {
    if (channel != nullptr && token != 0) {
        g_rdpChannelQuarantine[channel] = token;
    }
}

static void quarantineRdpCallbackSourceLocked(
    rdpContext* context, uint64_t token,
    const std::shared_ptr<Render::CallbackAdmissionContext>& admission) {
    if (context == nullptr || token == 0) {
        return;
    }
    g_rdpContextQuarantine[context] = token;
    for (const auto& instance : g_rdpCallbackInstanceRegistry) {
        if (instance.second == context) {
            g_rdpInstanceQuarantine[instance.first] = token;
        }
    }
    for (const auto& channel : g_rdpChannelCallbackRegistry) {
        if (channel.second.admission == admission) {
            quarantineChannelLocked(channel.first, token);
        }
    }
}

static bool releaseRdpCallbackSourceQuarantine(rdpContext* context, freerdp* instance) {
    uint64_t token = 0;
    {
        std::lock_guard<std::mutex> lock(g_rdpCallbackRegistryMutex);
        if (context != nullptr) {
            const auto contextIt = g_rdpContextQuarantine.find(context);
            if (contextIt != g_rdpContextQuarantine.end()) {
                token = contextIt->second;
                const auto confirmed = g_rdpSourceRevokeConfirmed.find(context);
                if (confirmed == g_rdpSourceRevokeConfirmed.end() ||
                    confirmed->second != token) {
                    return false;
                }
                g_rdpContextQuarantine.erase(contextIt);
                g_rdpSourceRevokeConfirmed.erase(confirmed);
            }
        }
        if (instance != nullptr) {
            g_rdpInstanceQuarantine.erase(instance);
        }
        for (auto it = g_rdpChannelQuarantine.begin();
             it != g_rdpChannelQuarantine.end();) {
            if (token != 0 && it->second == token) {
                it = g_rdpChannelQuarantine.erase(it);
            } else {
                ++it;
            }
        }
    }
    return token != 0;
}

static bool confirmRdpCallbackSourceRevoked(rdpContext* context) {
    if (context == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lock(g_rdpCallbackRegistryMutex);
    const auto it = g_rdpContextQuarantine.find(context);
    if (it == g_rdpContextQuarantine.end() || it->second == 0) {
        return false;
    }
    g_rdpSourceRevokeConfirmed[context] = it->second;
    return true;
}

static bool rdpCallbackSourcesAreCleared(
    freerdp* instance, rdpContext* context, CliprdrClientContext* cliprdr) {
    if (context == nullptr) {
        return false;
    }
    if (context->update != nullptr &&
        (context->update->BeginPaint != nullptr ||
         context->update->EndPaint != nullptr ||
         context->update->DesktopResize != nullptr)) {
        return false;
    }
    if (context->graphics != nullptr &&
        context->graphics->Pointer_Prototype != nullptr) {
        const auto* pointer = context->graphics->Pointer_Prototype;
        if (pointer->New != nullptr || pointer->Free != nullptr ||
            pointer->Set != nullptr || pointer->SetNull != nullptr ||
            pointer->SetDefault != nullptr || pointer->SetPosition != nullptr) {
            return false;
        }
    }
    if (cliprdr != nullptr &&
        (cliprdr->ServerCapabilities != nullptr ||
         cliprdr->MonitorReady != nullptr ||
         cliprdr->ServerFormatList != nullptr ||
         cliprdr->ServerFormatDataRequest != nullptr ||
         cliprdr->ServerFormatDataResponse != nullptr)) {
        return false;
    }
    if (instance != nullptr &&
        (instance->VerifyCertificate != nullptr ||
         instance->VerifyChangedCertificate != nullptr ||
         instance->VerifyCertificateEx != nullptr ||
         instance->VerifyChangedCertificateEx != nullptr ||
         instance->VerifyX509Certificate != nullptr ||
         instance->LogonErrorInfo != nullptr ||
         instance->PostConnect != nullptr ||
         instance->PostDisconnect != nullptr ||
         instance->LoadChannels != nullptr ||
         instance->PostFinalDisconnect != nullptr)) {
        return false;
    }
    return true;
}

// FreeRDP exposes callback sources as function slots on the instance/update/
// graphics/channel objects.  There is no user-data epoch in this ABI, so this
// routine is the source-slot half of the single production revoke operation.
// PubSub unsubscription is performed by the owning adapter immediately before
// this helper because the callback functions are private class members.  The
// caller still owns admission close/drain and final destruction ordering.
static bool revokeRdpCallbackSources(
    freerdp* instance, rdpContext* context, CliprdrClientContext* cliprdr) {
    if (context == nullptr) {
        return false;
    }
    if (context->update != nullptr) {
        context->update->BeginPaint = nullptr;
        context->update->EndPaint = nullptr;
        context->update->DesktopResize = nullptr;
    }
    if (context->graphics != nullptr &&
        context->graphics->Pointer_Prototype != nullptr) {
        auto* pointer = context->graphics->Pointer_Prototype;
        pointer->New = nullptr;
        pointer->Free = nullptr;
        pointer->Set = nullptr;
        pointer->SetNull = nullptr;
        pointer->SetDefault = nullptr;
        pointer->SetPosition = nullptr;
    }
    if (cliprdr != nullptr) {
        cliprdr->ServerCapabilities = nullptr;
        cliprdr->MonitorReady = nullptr;
        cliprdr->ServerFormatList = nullptr;
        cliprdr->ServerFormatDataRequest = nullptr;
        cliprdr->ServerFormatDataResponse = nullptr;
    }
    if (instance != nullptr) {
        instance->VerifyCertificate = nullptr;
        instance->VerifyChangedCertificate = nullptr;
        instance->VerifyCertificateEx = nullptr;
        instance->VerifyChangedCertificateEx = nullptr;
        instance->VerifyX509Certificate = nullptr;
        instance->LogonErrorInfo = nullptr;
        instance->PostConnect = nullptr;
        instance->PostDisconnect = nullptr;
        instance->LoadChannels = nullptr;
        instance->PostFinalDisconnect = nullptr;
    }
    if (!rdpCallbackSourcesAreCleared(instance, context, cliprdr)) {
        return false;
    }
    return confirmRdpCallbackSourceRevoked(context);
}

static void eraseRdpChannelCallbacksForAdmission(
    const std::shared_ptr<Render::CallbackAdmissionContext>& admission) {
    if (!admission) {
        return;
    }
    for (auto it = g_rdpChannelCallbackRegistry.begin();
         it != g_rdpChannelCallbackRegistry.end();) {
        if (it->second.admission == admission) {
            it = g_rdpChannelCallbackRegistry.erase(it);
        } else {
            ++it;
        }
    }
}

static std::shared_ptr<Render::CallbackAdmissionContext>
takeRdpCallbackContext(rdpContext* context) {
    if (context == nullptr) {
        return nullptr;
    }
    std::lock_guard<std::mutex> lock(g_rdpCallbackRegistryMutex);
    const auto it = g_rdpCallbackRegistry.find(context);
    if (it == g_rdpCallbackRegistry.end()) {
        return nullptr;
    }
    const auto admission = it->second.admission;
    quarantineRdpCallbackSourceLocked(context, it->second.token, admission);
    g_rdpCallbackRegistry.erase(it);
    for (auto instanceIt = g_rdpCallbackInstanceRegistry.begin();
         instanceIt != g_rdpCallbackInstanceRegistry.end();) {
        if (instanceIt->second == context) {
            instanceIt = g_rdpCallbackInstanceRegistry.erase(instanceIt);
        } else {
            ++instanceIt;
        }
    }
    eraseRdpChannelCallbacksForAdmission(admission);
    return admission;
}

static bool closeRdpCallbackAdmission(
    const std::shared_ptr<Render::CallbackAdmissionContext>& admission,
    const char* source) {
    if (!admission) {
        return true;
    }
    const bool drained = admission->closeAndWait();
    if (!drained) {
        OH_LOG_WARN(LOG_APP,
            "[RDP] callback admission deferred source=%{public}s",
            source ? source : "unknown");
    }
    return drained;
}

static void closeRdpCallbackAdmissionsForAdapter(FreeRdpAdapter* adapter) {
    if (adapter == nullptr) {
        return;
    }
    std::vector<std::shared_ptr<Render::CallbackAdmissionContext>> admissions;
    {
        std::lock_guard<std::mutex> lock(g_rdpCallbackRegistryMutex);
        for (const auto& entry : g_rdpCallbackRegistry) {
            if (entry.second.adapter == adapter && entry.second.admission &&
                std::find(admissions.begin(), admissions.end(), entry.second.admission) ==
                    admissions.end()) {
                admissions.push_back(entry.second.admission);
            }
        }
        for (const auto& entry : g_rdpChannelCallbackRegistry) {
            if (entry.second.adapter == adapter && entry.second.admission &&
                std::find(admissions.begin(), admissions.end(), entry.second.admission) ==
                    admissions.end()) {
                admissions.push_back(entry.second.admission);
            }
        }
    }
    for (const auto& admission : admissions) {
        (void)closeRdpCallbackAdmission(admission, "owner-switch");
    }
}

static bool registerRdpCallbackContext(
    freerdp* instance, rdpContext* context, FreeRdpAdapter* adapter,
    std::shared_ptr<FreeRdpAdapter> keepAlive,
    const Render::DecoderSessionIdentity& owner, uint64_t generation) {
    if (instance == nullptr || context == nullptr || adapter == nullptr ||
        !owner.valid() || generation == 0) {
        return false;
    }
    auto admission = std::make_shared<Render::CallbackAdmissionContext>();
    const uint64_t token = static_cast<uint64_t>(
        g_rdpCallbackToken.fetch_add(1, std::memory_order_relaxed));
    if (!admission->bind(token, owner, generation)) {
        return false;
    }
    std::lock_guard<std::mutex> lock(g_rdpCallbackRegistryMutex);
    if (g_rdpCallbackRegistry.find(context) != g_rdpCallbackRegistry.end() ||
        g_rdpCallbackInstanceRegistry.find(instance) !=
            g_rdpCallbackInstanceRegistry.end() ||
        g_rdpContextQuarantine.find(context) != g_rdpContextQuarantine.end() ||
        g_rdpInstanceQuarantine.find(instance) != g_rdpInstanceQuarantine.end()) {
        return false;
    }
    g_rdpCallbackRegistry.emplace(context, RdpCallbackRegistryEntry {
        std::move(admission), std::move(keepAlive), adapter, owner, generation, token});
    g_rdpCallbackInstanceRegistry.emplace(instance, context);
    return true;
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
static bool registerRdpCallbackContext(
    rdpContext* context, FreeRdpAdapter* adapter,
    const Render::DecoderSessionIdentity& owner, uint64_t generation) {
    // Test fixtures do not have a real freerdp instance. Production always
    // uses the instance-keyed overload above, so callbacks never need to
    // dereference freerdp->context before admission.
    return registerRdpCallbackContext(
        reinterpret_cast<freerdp*>(context), context, adapter, nullptr,
        owner, generation);
}
#endif

static bool registerRdpChannelCallbackContext(
    CliprdrClientContext* channel, const RdpCallbackLease& parent) {
    if (channel == nullptr || !parent || !parent.admission) {
        return false;
    }
    std::lock_guard<std::mutex> lock(g_rdpCallbackRegistryMutex);
    if (g_rdpChannelCallbackRegistry.find(channel) !=
        g_rdpChannelCallbackRegistry.end() ||
        g_rdpChannelQuarantine.find(channel) != g_rdpChannelQuarantine.end()) {
        return false;
    }
    g_rdpChannelCallbackRegistry.emplace(channel, RdpCallbackRegistryEntry {
        parent.admission, parent.keepAlive, parent.adapter, parent.owner,
        parent.generation,
        static_cast<uint64_t>(parent.lease.snapshot().token)});
    return true;
}

static RdpCallbackLease acquireRdpCallbackContext(
    rdpContext* context, uint64_t expectedToken = 0);

static RdpCallbackLease acquireRdpCallbackInstance(freerdp* instance) {
    if (instance == nullptr) {
        return RdpCallbackLease {};
    }
    rdpContext* context = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_rdpCallbackRegistryMutex);
        const auto it = g_rdpCallbackInstanceRegistry.find(instance);
        if (it != g_rdpCallbackInstanceRegistry.end()) {
            context = it->second;
        }
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    // The existing host fixture passes a temporary freerdp shell containing
    // only context. This fallback is test-only; production callbacks always
    // resolve by the stable instance carrier without reading instance->context.
    if (context == nullptr) {
        context = instance->context;
    }
#endif
    if (context == nullptr) {
        return RdpCallbackLease {};
    }
    auto result = acquireRdpCallbackContext(context);
    if (result) {
        result.context = context;
    }
    return result;
}

static RdpCallbackLease acquireRdpChannelCallbackContext(
    CliprdrClientContext* channel) {
    if (channel == nullptr) {
        return RdpCallbackLease {};
    }
    RdpCallbackRegistryEntry entry;
    {
        std::lock_guard<std::mutex> lock(g_rdpCallbackRegistryMutex);
        const auto it = g_rdpChannelCallbackRegistry.find(channel);
        if (it == g_rdpChannelCallbackRegistry.end()) {
            return RdpCallbackLease {};
        }
        entry = it->second;
    }
    if (!entry.admission) {
        return RdpCallbackLease {};
    }
    auto lease = entry.admission->tryAcquire();
    if (!lease) {
        return RdpCallbackLease {};
    }
    return RdpCallbackLease {
        std::move(entry.admission), std::move(lease), std::move(entry.keepAlive),
        entry.adapter, nullptr, channel, entry.owner, entry.generation, {}};
}

static void unregisterRdpChannelCallbackContext(CliprdrClientContext* channel) {
    if (!channel) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_rdpCallbackRegistryMutex);
    const auto it = g_rdpChannelCallbackRegistry.find(channel);
    if (it != g_rdpChannelCallbackRegistry.end()) {
        quarantineChannelLocked(channel, it->second.token);
    }
    g_rdpChannelCallbackRegistry.erase(channel);
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
static void unregisterRdpCallbackContext(rdpContext* context) {
    auto admission = takeRdpCallbackContext(context);
    // The map removal rejects callbacks that have not entered admission. The
    // close waits for callbacks that already hold a lease before FreeRDP frees
    // the rdpContext/GDI storage.
    if (admission) {
        const bool drained = admission->closeAndWait();
        if (!drained) {
            // The context owner must use deferCleanupAfterDrain for platform
            // storage. This helper is used only by explicit unregister/test
            // paths where there is no storage left to free; retaining the
            // admission object until its callback lease drains is sufficient.
            (void)admission->deferCleanupAfterDrain(nullptr);
        }
    }
}
#endif

static RdpCallbackLease acquireRdpCallbackContext(rdpContext* context, uint64_t expectedToken) {
    if (context == nullptr) {
        return RdpCallbackLease {};
    }
    std::shared_ptr<Render::CallbackAdmissionContext> admission;
    std::shared_ptr<FreeRdpAdapter> keepAlive;
    FreeRdpAdapter* adapter = nullptr;
    Render::DecoderSessionIdentity owner;
    uint64_t generation = 0;
    {
        std::lock_guard<std::mutex> lock(g_rdpCallbackRegistryMutex);
        const auto it = g_rdpCallbackRegistry.find(context);
        if (it == g_rdpCallbackRegistry.end()) {
            return RdpCallbackLease {};
        }
        if (expectedToken != 0 && it->second.token != expectedToken) {
            return RdpCallbackLease {};
        }
        admission = it->second.admission;
        keepAlive = it->second.keepAlive;
        adapter = it->second.adapter;
        owner = it->second.owner;
        generation = it->second.generation;
    }
    if (!admission) {
        return RdpCallbackLease {};
    }
    auto lease = admission->tryAcquire();
    if (!lease) {
        return RdpCallbackLease {};
    }
    return RdpCallbackLease {
        std::move(admission), std::move(lease), std::move(keepAlive), adapter,
        context, nullptr, owner, generation, {}};
}

static bool isRdpCallbackLeaseRegistered(const RdpCallbackLease& callbackLease) {
    if (!callbackLease || !callbackLease.admission) {
        return false;
    }
    const uint64_t token = static_cast<uint64_t>(
        callbackLease.lease.snapshot().token);
    std::lock_guard<std::mutex> lock(g_rdpCallbackRegistryMutex);
    if (callbackLease.context != nullptr) {
        const auto it = g_rdpCallbackRegistry.find(callbackLease.context);
        return it != g_rdpCallbackRegistry.end() &&
            it->second.admission == callbackLease.admission &&
            it->second.token == token;
    }
    if (callbackLease.channel != nullptr) {
        const auto it = g_rdpChannelCallbackRegistry.find(callbackLease.channel);
        return it != g_rdpChannelCallbackRegistry.end() &&
            it->second.admission == callbackLease.admission &&
            it->second.token == token;
    }
    return false;
}

// A callback may keep its admission lease while an owner transition is being
// prepared.  Every platform read or external sink call therefore performs a
// second, cheap validation immediately before the side effect.  The registry
// check rejects an unregistered source; the owner check rejects a lease that
// no longer represents the active session/generation.
static bool isRdpCallbackLeaseCurrent(const RdpCallbackLease& callbackLease) {
    return isRdpCallbackLeaseRegistered(callbackLease) && callbackLease.adapter != nullptr &&
        callbackLease.adapter->isCallbackOwnerCurrent(
            callbackLease.owner, callbackLease.generation);
}

static bool acquireCurrentRdpCallbackOwnerLease(RdpCallbackLease& callbackLease) {
    if (!isRdpCallbackLeaseCurrent(callbackLease)) {
        return false;
    }
    callbackLease.ownerLease = Render::SharedSessionSinkOwnerLease().acquire(
        callbackLease.owner);
    // The owner can be deactivated between the registry check and the shared
    // lease acquisition.  Re-check while retaining the lease; once this
    // succeeds, the activation exclusive side cannot publish S2 until the
    // entire callback body has returned.
    return static_cast<bool>(callbackLease.ownerLease) &&
        isRdpCallbackLeaseCurrent(callbackLease);
}
static std::once_flag g_rdpAddinProviderOnce;
static RdpNextConnectionGfxFallback g_nextConnectionGfxFallback;

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
    // The path is implemented, but production advertisement stays closed until
    // the final dynamic-resize and reconnect device matrix passes.
    return false;
}

static bool rdpGfxH264PathSafe() {
    // Keep H.264 disabled until decoder lifecycle, visual, and stress gates pass.
    return false;
}

static RdpPerformancePolicy::GraphicsMode applyRdpPerformanceSettings(rdpSettings* settings) {
    const bool compiledGfx = compiledWithRdpGfx();
    const bool compiledH264 = compiledWithGfxH264();
    const bool fallbackForThisConnection = g_nextConnectionGfxFallback.consume();
    const bool gfxAvailable = compiledGfx && !fallbackForThisConnection;
    const bool h264Available = compiledH264;
    const bool gfxConsumerAvailable = rdpGfxPipelineConsumerAvailable();
    const bool gfxResetSafe = rdpGfxResetPathSafe();
    const bool h264PathSafe = rdpGfxH264PathSafe();
    const RdpPerformancePolicy::Settings perf =
        RdpPerformancePolicy::RecommendedLanSettings(gfxAvailable,
                                                     h264Available,
                                                     gfxConsumerAvailable,
                                                     gfxResetSafe,
                                                     h264PathSafe);
    const RdpPerformancePolicy::GraphicsMode mode =
        RdpPerformancePolicy::SelectGraphicsMode(gfxAvailable,
                                                 h264Available,
                                                 gfxConsumerAvailable,
                                                 gfxResetSafe,
                                                 h264PathSafe);

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
                "[RDP] performance settings: mode=%{public}s compiledGfx=%{public}s compiledH264=%{public}s gfxConsumer=%{public}s gfxResetSafe=%{public}s h264PathSafe=%{public}s nextFallback=%{public}s networkAuto=%{public}s connectionType=%{public}u gfx=%{public}s h264=%{public}s rfx=%{public}s frameAck=%{public}u",
                RdpPerformancePolicy::GraphicsModeName(mode),
                compiledGfx ? "true" : "false",
                compiledH264 ? "true" : "false",
                gfxConsumerAvailable ? "true" : "false",
                gfxResetSafe ? "true" : "false",
                h264PathSafe ? "true" : "false",
                fallbackForThisConnection ? "true" : "false",
                freerdp_settings_get_bool(settings, FreeRDP_NetworkAutoDetect) ? "true" : "false",
                freerdp_settings_get_uint32(settings, FreeRDP_ConnectionType),
                freerdp_settings_get_bool(settings, FreeRDP_SupportGraphicsPipeline) ? "true" : "false",
                freerdp_settings_get_bool(settings, FreeRDP_GfxH264) ? "true" : "false",
                freerdp_settings_get_bool(settings, FreeRDP_RemoteFxCodec) ? "true" : "false",
                freerdp_settings_get_uint32(settings, FreeRDP_FrameAcknowledge));
    return mode;
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

    std::string expectedFingerprint;
    bool allowHostMismatch = false;
    {
        std::lock_guard<std::mutex> lock(impl_->configMutex);
        expectedFingerprint = impl_->config.expectedRdpCertificateFingerprintSha256;
        allowHostMismatch = impl_->config.rdpAllowHostMismatch;
    }
    const bool fingerprintOk = RdpCertificatePolicy::FingerprintMatches(
        expectedFingerprint, fingerprint);
    const bool hostOk = !hostMismatch || allowHostMismatch;
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

static UINT invokeRdpSoundWithExpectedToken(
    uint64_t expectedToken, const BYTE* data, size_t size,
    UINT32 sampleRate, UINT16 channels, UINT16 bitsPerSample) {
    AudioDataCallback callback;
    Render::DecoderSessionIdentity owner;
    std::shared_ptr<Render::CallbackAdmissionContext> admission;
    {
        std::lock_guard<std::mutex> lock(g_rdpAudioCallbackMutex);
        if (expectedToken != 0 && g_rdpAudioCallbackToken != expectedToken) {
            return 0;
        }
        callback = g_rdpAudioCallback;
        owner = g_rdpAudioCallbackOwner;
        admission = g_rdpAudioAdmission;
    }
    auto callbackLease = admission ? admission->tryAcquire() : Render::CallbackAdmissionContext::Lease();
    // Keep the owner lease through the actual callback/sink write. The
    // extension callback may synchronously route into AudioPlayer; the shared
    // owner lease has a same-thread reentrant path for that exact owner, while
    // S1->S2 activation still waits until this callback returns.
    auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!callbackLease || !ownerLease || !callback || !data || size == 0) {
        static std::atomic<uint64_t> skippedAudioCount {0};
        const uint64_t skippedAudio =
            skippedAudioCount.fetch_add(1, std::memory_order_relaxed) + 1;
        if (skippedAudio <= 10 || skippedAudio % 100 == 0) {
            OH_LOG_WARN(LOG_APP,
                "[RDP] rdpsnd play skipped #%{public}llu callback=%{public}s data=%{public}p size=%{public}zu",
                static_cast<unsigned long long>(skippedAudio),
                callback ? "yes" : "no",
                data,
                size);
        }
        return 0;
    }
    const RdpAudioPcmDecision pcmDecision =
        evaluateRdpAudioPcm(sampleRate, channels, bitsPerSample, size);
    if (!pcmDecision.accepted) {
        static std::atomic<uint64_t> rejectedAudioCount {0};
        const uint64_t rejectedAudio =
            rejectedAudioCount.fetch_add(1, std::memory_order_relaxed) + 1;
        if (rejectedAudio <= 10 || rejectedAudio % 100 == 0) {
            OH_LOG_WARN(LOG_APP,
                "[RDP] rdpsnd PCM rejected #%{public}llu reason=%{public}s size=%{public}zu rate=%{public}u channels=%{public}u bits=%{public}u",
                static_cast<unsigned long long>(rejectedAudio),
                pcmDecision.reason,
                size,
                sampleRate,
                channels,
                bitsPerSample);
        }
        return 0;
    }
    static std::atomic<uint64_t> rdpsndPlayCount {0};
    const uint64_t rdpsndPlay =
        rdpsndPlayCount.fetch_add(1, std::memory_order_relaxed) + 1;
    if (rdpsndPlay <= 10 || rdpsndPlay % 100 == 0) {
        OH_LOG_INFO(LOG_APP,
            "[RDP] rdpsnd play #%{public}llu size=%{public}zu submit=%{public}zu rate=%{public}u channels=%{public}u bits=%{public}u",
            static_cast<unsigned long long>(rdpsndPlay),
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

extern "C" UINT freerdp_ohos_rdpsnd_play(const BYTE* data, size_t size,
                                          UINT32 sampleRate, UINT16 channels,
                                          UINT16 bitsPerSample) {
    return invokeRdpSoundWithExpectedToken(
        0, data, size, sampleRate, channels, bitsPerSample);
}

// ---- 证书验证: 由 ArkTS 预检弹窗确认后, native 只接受匹配策略 ----
DWORD WINAPI FreeRdpAdapter::cbVerifyCertificate(freerdp* instance, const char* common_name,
                                                  const char* subject, const char* issuer,
                                                  const char* fingerprint, BOOL host_mismatch) {
    auto callbackLease = acquireRdpCallbackInstance(instance);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return 0;
    }
    DWORD flags = host_mismatch ? VERIFY_CERT_FLAG_MISMATCH : VERIFY_CERT_FLAG_NONE;
    FreeRdpAdapter* self = callbackLease.adapter;
    return self ? self->evaluateCertificate(nullptr, 0, common_name, subject, issuer,
                                            fingerprint ? fingerprint : "", flags) : 0;
}

DWORD FreeRdpAdapter::cbVerifyCertificateEx(freerdp* instance, const char* host, UINT16 port,
                                            const char* common_name, const char* subject,
                                            const char* issuer, const char* fingerprint,
                                            DWORD flags) {
    auto callbackLease = acquireRdpCallbackInstance(instance);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return 0;
    }
    FreeRdpAdapter* self = callbackLease.adapter;
    return self ? self->evaluateCertificate(host, port, common_name, subject, issuer,
                                            fingerprint ? fingerprint : "", flags) : 0;
}

DWORD FreeRdpAdapter::cbVerifyChangedCertificateEx(freerdp* instance, const char* host, UINT16 port,
                                                   const char* common_name, const char* subject,
                                                   const char* issuer, const char* new_fingerprint,
                                                   const char* /*old_subject*/, const char* /*old_issuer*/,
                                                   const char* /*old_fingerprint*/, DWORD flags) {
    auto callbackLease = acquireRdpCallbackInstance(instance);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return 0;
    }
    FreeRdpAdapter* self = callbackLease.adapter;
    return self ? self->evaluateCertificate(host, port, common_name, subject, issuer,
                                            new_fingerprint ? new_fingerprint : "",
                                            flags | VERIFY_CERT_FLAG_CHANGED) : 0;
}

int FreeRdpAdapter::cbVerifyX509Certificate(freerdp* instance, const BYTE* data, size_t length,
                                            const char* hostname, UINT16 port, DWORD flags) {
    auto callbackLease = acquireRdpCallbackInstance(instance);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return 0;
    }
    const std::string fingerprint = fingerprintFromPem(data, length);
    FreeRdpAdapter* self = callbackLease.adapter;
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

int FreeRdpAdapter::cbLogonErrorInfo(freerdp* instance, UINT32 data, UINT32 type) {
    // Even callbacks which only report scalar error fields must be admitted
    // before touching the owning session.  This also rejects a late callback
    // after cleanup/reconnect instead of treating it as a process-global log.
    auto callbackLease = acquireRdpCallbackInstance(instance);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return 0;
    }
    OH_LOG_ERROR(LOG_APP, "[RDP] LogonErrorInfo: type=0x%{public}08X(%{public}s) data=0x%{public}08X(%{public}s)",
                 type, logonErrorTypeName(type), data, logonErrorDataName(data));
    return 1;
}

void FreeRdpAdapter::cbErrorInfo(void* context, const ErrorInfoEventArgs* e) {
    auto callbackLease = acquireRdpCallbackContext(
        static_cast<::rdpContext*>(context));
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return;
    }
    if (!isRdpCallbackLeaseRegistered(callbackLease) ||
        !callbackLease.adapter->isCallbackOwnerCurrent(
            callbackLease.owner, callbackLease.generation)) {
        return;
    }
    auto* rdpContext = callbackLease.context;
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
    FreeRdpAdapter* adapter = callbackLease.adapter;
    if (!adapter || !adapter->impl_) {
        OH_LOG_WARN(LOG_APP, "[RDP] ErrorInfo owner missing: raw=0x%{public}08X", code);
        return;
    }
    adapter->impl_->setState(ConnectionState::ERROR, rdpErrorInfoMessage(code));
}

void FreeRdpAdapter::cbChannelConnected(void* context, const ChannelConnectedEventArgs* e) {
    auto callbackLease = acquireRdpCallbackContext(
        static_cast<::rdpContext*>(context));
    if (!callbackLease || !e || !e->name ||
        !acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        OH_LOG_WARN(LOG_APP, "[RDP] ChannelConnected ignored: invalid context/event");
        return;
    }
    auto* rdpContext = callbackLease.context;
    FreeRdpAdapter* owner = callbackLease.adapter;
    if (!owner || !isRdpCallbackLeaseRegistered(callbackLease) ||
        !owner->isCallbackOwnerCurrent(callbackLease.owner,
                                       callbackLease.generation)) {
        return;
    }
    OH_LOG_INFO(LOG_APP, "[RDP] channel connected: %{public}s interface=%{public}p",
                e->name, e->pInterface);
    if (std::strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0 && e->pInterface) {
        auto* cliprdr = reinterpret_cast<CliprdrClientContext*>(e->pInterface);
        if (!isRdpCallbackLeaseRegistered(callbackLease) ||
            !owner->isCallbackOwnerCurrent(callbackLease.owner,
                                           callbackLease.generation)) {
            return;
        }
        if (owner && owner->impl_ && owner->impl_->fileClipboard &&
            owner->impl_->fileClipboard->attach(cliprdr) &&
            registerRdpChannelCallbackContext(cliprdr, callbackLease)) {
            owner->impl_->cliprdr = cliprdr;
            cliprdr->ServerCapabilities = cbCliprdrServerCapabilities;
            cliprdr->MonitorReady = cbCliprdrMonitorReady;
            cliprdr->ServerFormatList = cbCliprdrServerFormatList;
            cliprdr->ServerFormatDataRequest = cbCliprdrServerFormatDataRequest;
            cliprdr->ServerFormatDataResponse = cbCliprdrServerFormatDataResponse;
        } else {
            OH_LOG_WARN(LOG_APP,
                        "[RDP] file clipboard bridge unavailable; clipboard disabled for this session");
        }
    }
#if defined(CHANNEL_RDPGFX_CLIENT)
    if (std::strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        FreeRdpAdapter* adapter = callbackLease.adapter;
        auto failGfxChannel = [adapter](const char* message) {
            g_nextConnectionGfxFallback.mark();
            if (adapter && adapter->impl_) {
                adapter->impl_->setState(ConnectionState::ERROR, message);
            }
            // The callback must not synchronously enter the FreeRDP transport
            // while holding its admission lease.  The same deferred owner
            // used by explicit disconnect performs abort+disconnect and
            // observes the callback lease after this body returns.
            if (adapter) {
                adapter->queuePostDisconnectTeardown();
            }
        };
        if (!rdpContext->gdi || !e->pInterface) {
            OH_LOG_ERROR(LOG_APP, "[RDP] RDPGFX channel connected before GDI is ready [E-RDP-GFX-GDI]");
            failGfxChannel("RDP graphics pipeline missing GDI [E-RDP-GFX-GDI]");
            return;
        }
        if (!freerdp_settings_get_bool(rdpContext->settings, FreeRDP_SoftwareGdi)) {
            OH_LOG_ERROR(LOG_APP, "[RDP] RDPGFX requires SoftwareGdi in OHOS renderer [E-RDP-GFX-GDI-MODE]");
            failGfxChannel("RDP graphics pipeline requires SoftwareGdi [E-RDP-GFX-GDI-MODE]");
            return;
        }
        if (!adapter || !adapter->impl_) {
            OH_LOG_ERROR(LOG_APP, "[RDP] RDPGFX channel owner missing [E-RDP-GFX-OWNER]");
            failGfxChannel("RDP graphics pipeline owner missing [E-RDP-GFX-OWNER]");
            return;
        }
        const uintptr_t channelContext = reinterpret_cast<uintptr_t>(e->pInterface);
        if (!isRdpCallbackLeaseRegistered(callbackLease) ||
            !adapter->isCallbackOwnerCurrent(callbackLease.owner,
                                             callbackLease.generation)) {
            return;
        }
        const RdpGfxChannelAction action =
            adapter->impl_->graphicsLifecycle.onChannelConnected(channelContext);
        if (action == RdpGfxChannelAction::Ignore) {
            OH_LOG_INFO(LOG_APP, "[RDP] duplicate RDPGFX channel connect ignored");
            return;
        }
        if (action != RdpGfxChannelAction::Initialize) {
            OH_LOG_ERROR(LOG_APP, "[RDP] conflicting RDPGFX channel connect rejected [E-RDP-GFX-CONFLICT]");
            failGfxChannel("RDP graphics pipeline channel conflict [E-RDP-GFX-CONFLICT]");
            return;
        }
        if (!isRdpCallbackLeaseRegistered(callbackLease) ||
            !adapter->isCallbackOwnerCurrent(callbackLease.owner,
                                             callbackLease.generation)) {
            return;
        }
        const bool initialized = gdi_graphics_pipeline_init(
            rdpContext->gdi, reinterpret_cast<RdpgfxClientContext*>(e->pInterface)) == TRUE;
        adapter->impl_->graphicsLifecycle.completeChannelInitialization(
            channelContext, initialized);
        if (!initialized) {
            OH_LOG_ERROR(LOG_APP, "[RDP] gdi_graphics_pipeline_init failed [E-RDP-GFX-INIT]");
            failGfxChannel("RDP graphics pipeline init failed [E-RDP-GFX-INIT]");
            return;
        }
        OH_LOG_INFO(LOG_APP, "[RDP] GDI graphics pipeline initialized for RDPGFX");
    }
#endif
}

UINT FreeRdpAdapter::cbCliprdrMonitorReady(CliprdrClientContext* context,
                                           const CLIPRDR_MONITOR_READY*) {
    auto callbackLease = acquireRdpChannelCallbackContext(context);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return ERROR_INVALID_PARAMETER;
    }
    auto* owner = callbackLease.adapter;
    if (!owner || !owner->impl_ || !owner->impl_->fileClipboard) {
        return ERROR_INVALID_PARAMETER;
    }
    const UINT capabilityResult = owner->impl_->fileClipboard->sendClientCapabilities();
    if (capabilityResult != CHANNEL_RC_OK) {
        return capabilityResult;
    }
    return owner->impl_->fileClipboard->sendCurrentFormatList(true);
}

UINT FreeRdpAdapter::cbCliprdrServerCapabilities(
    CliprdrClientContext* context, const CLIPRDR_CAPABILITIES* capabilities) {
    auto callbackLease = acquireRdpChannelCallbackContext(context);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return ERROR_INVALID_PARAMETER;
    }
    auto* owner = callbackLease.adapter;
    if (!owner || !owner->impl_ || !owner->impl_->fileClipboard) {
        return ERROR_INVALID_PARAMETER;
    }
    return owner->impl_->fileClipboard->updateServerCapabilities(capabilities);
}

UINT FreeRdpAdapter::cbCliprdrServerFormatList(CliprdrClientContext* context,
                                               const CLIPRDR_FORMAT_LIST* list) {
    auto callbackLease = acquireRdpChannelCallbackContext(context);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return ERROR_INVALID_PARAMETER;
    }
    auto* owner = callbackLease.adapter;
    if (!owner || !owner->impl_ || !owner->impl_->fileClipboard || !list ||
        !isRdpCallbackLeaseCurrent(callbackLease) ||
        !context->ClientFormatListResponse) {
        return ERROR_INVALID_PARAMETER;
    }
    const UINT notifyResult = owner->impl_->fileClipboard->notifyServerFormatList();
    if (notifyResult != CHANNEL_RC_OK) {
        return notifyResult;
    }
    CLIPRDR_FORMAT_LIST_RESPONSE response {};
    response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    const UINT responseResult = context->ClientFormatListResponse(context, &response);
    if (responseResult != CHANNEL_RC_OK || !context->ClientFormatDataRequest) {
        return responseResult;
    }
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
    auto callbackLease = acquireRdpChannelCallbackContext(context);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return ERROR_INVALID_PARAMETER;
    }
    auto* owner = callbackLease.adapter;
    if (!owner || !owner->impl_ || !isRdpCallbackLeaseCurrent(callbackLease) ||
        !context->ClientFormatDataResponse || !request) {
        return ERROR_INVALID_PARAMETER;
    }
    if (owner->impl_->fileClipboard &&
        owner->impl_->fileClipboard->isFileFormat(request->requestedFormatId)) {
        return owner->impl_->fileClipboard->respondToFileFormatRequest(request);
    }
    if (request->requestedFormatId != CF_UNICODETEXT) {
        return ERROR_INVALID_PARAMETER;
    }
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
    auto callbackLease = acquireRdpChannelCallbackContext(context);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return ERROR_INVALID_PARAMETER;
    }
    auto* owner = callbackLease.adapter;
    if (!owner || !owner->impl_ || !isRdpCallbackLeaseCurrent(callbackLease) ||
        !response || !response->requestedFormatData) return ERROR_INVALID_PARAMETER;
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
    auto callbackLease = acquireRdpCallbackContext(
        static_cast<::rdpContext*>(context));
    if (!callbackLease || !e || !e->name ||
        !acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        OH_LOG_WARN(LOG_APP, "[RDP] ChannelDisconnected ignored: invalid context/event");
        return;
    }
    auto* rdpContext = callbackLease.context;
    FreeRdpAdapter* owner = callbackLease.adapter;
    if (!owner || !isRdpCallbackLeaseRegistered(callbackLease) ||
        !owner->isCallbackOwnerCurrent(callbackLease.owner,
                                       callbackLease.generation)) {
        return;
    }
    OH_LOG_INFO(LOG_APP, "[RDP] channel disconnected: %{public}s interface=%{public}p",
                e->name, e->pInterface);
    if (std::strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        if (owner && owner->impl_) {
            if (owner->impl_->fileClipboard) {
                owner->impl_->fileClipboard->detach();
            }
            unregisterRdpChannelCallbackContext(owner->impl_->cliprdr);
            owner->impl_->cliprdr = nullptr;
        }
    }
#if defined(CHANNEL_RDPGFX_CLIENT)
    if (std::strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        FreeRdpAdapter* adapter = callbackLease.adapter;
        const uintptr_t channelContext = reinterpret_cast<uintptr_t>(e->pInterface);
        const RdpGfxChannelAction action = adapter && adapter->impl_ ?
            adapter->impl_->graphicsLifecycle.onChannelDisconnected(channelContext) :
            RdpGfxChannelAction::Ignore;
        if (action == RdpGfxChannelAction::Release && rdpContext->gdi && e->pInterface) {
            gdi_graphics_pipeline_uninit(rdpContext->gdi,
                                         reinterpret_cast<RdpgfxClientContext*>(e->pInterface));
            OH_LOG_INFO(LOG_APP, "[RDP] GDI graphics pipeline released for RDPGFX");
        } else {
            OH_LOG_INFO(LOG_APP, "[RDP] stale or duplicate RDPGFX channel disconnect ignored");
        }
    }
#endif
}

BOOL FreeRdpAdapter::cbLoadChannels(freerdp* instance) {
    auto callbackLease = acquireRdpCallbackInstance(instance);
    if (!callbackLease) {
        return FALSE;
    }
    auto* context = callbackLease.context;
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return FALSE;
    }
    if (!context || !context->channels || !instance->settings) {
        OH_LOG_ERROR(LOG_APP, "[RDP] LoadChannels failed: invalid FreeRDP context");
        return FALSE;
    }

    ensureFreeRdpStaticAddinProvider();
    if (!freerdp_get_current_addin_provider()) {
        OH_LOG_ERROR(LOG_APP, "[RDP] LoadChannels failed: static addin provider missing");
        return FALSE;
    }

    if (!isRdpCallbackLeaseCurrent(callbackLease)) {
        return FALSE;
    }
    rdpSettings* settings = instance->settings;
    logRdpChannelSettings(settings, "loadchannels-before");
    const BOOL ok = freerdp_client_load_addins(context->channels, settings);
    OH_LOG_INFO(LOG_APP,
                "[RDP] LoadChannels result=%{public}s audio=%{public}s clipboard=%{public}s deviceRedirection=%{public}s",
                ok ? "true" : "false",
                freerdp_settings_get_bool(settings, FreeRDP_AudioPlayback) ? "true" : "false",
                freerdp_settings_get_bool(settings, FreeRDP_RedirectClipboard) ? "true" : "false",
                freerdp_settings_get_bool(settings, FreeRDP_DeviceRedirection) ? "true" : "false");
    logRdpChannelSettings(settings, "loadchannels-after");
    return ok;
}

struct HarmonyRdpPointer {
    rdpPointer pointer;
    uint8_t* rgba = nullptr;
    size_t rgbaLen = 0;
    uint64_t shapeId = 0;
};

static uint64_t hashRdpPointer(const uint8_t* data, size_t size, const rdpPointer* pointer) {
    uint64_t hash = 1469598103934665603ULL;
    const auto mix = [&hash](uint8_t value) {
        hash ^= value;
        hash *= 1099511628211ULL;
    };
    for (size_t i = 0; i < size; ++i) {
        mix(data[i]);
    }
    const uint32_t metadata[] = {
        pointer->width, pointer->height, pointer->xPos, pointer->yPos
    };
    for (uint32_t value : metadata) {
        for (int shift = 0; shift < 32; shift += 8) {
            mix(static_cast<uint8_t>((value >> shift) & 0xFFU));
        }
    }
    return hash;
}

BOOL FreeRdpAdapter::cbPointerNew(rdpContext* context, rdpPointer* pointer) {
    auto callbackLease = acquireRdpCallbackContext(context);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return FALSE;
    }
    context = callbackLease.context;
    if (!context || !context->gdi || !pointer || pointer->width == 0 || pointer->height == 0 ||
        pointer->width > static_cast<UINT32>(kRemoteCursorMaxDimension) ||
        pointer->height > static_cast<UINT32>(kRemoteCursorMaxDimension)) {
        return FALSE;
    }
    auto* cursor = reinterpret_cast<HarmonyRdpPointer*>(pointer);
    cursor->rgbaLen = static_cast<size_t>(pointer->width) * pointer->height * 4U;
    cursor->rgba = static_cast<uint8_t*>(std::malloc(cursor->rgbaLen));
    if (!cursor->rgba) {
        return FALSE;
    }
    if (!isRdpCallbackLeaseCurrent(callbackLease)) {
        std::free(cursor->rgba);
        cursor->rgba = nullptr;
        cursor->rgbaLen = 0;
        return FALSE;
    }
    if (!freerdp_image_copy_from_pointer_data(
            cursor->rgba, PIXEL_FORMAT_BGRA32, 0, 0, 0, pointer->width, pointer->height,
            pointer->xorMaskData, pointer->lengthXorMask, pointer->andMaskData,
            pointer->lengthAndMask, pointer->xorBpp, &context->gdi->palette)) {
        std::free(cursor->rgba);
        cursor->rgba = nullptr;
        cursor->rgbaLen = 0;
        return FALSE;
    }
    for (size_t i = 0; i < cursor->rgbaLen; i += 4) {
        std::swap(cursor->rgba[i], cursor->rgba[i + 2]);
    }
    cursor->shapeId = hashRdpPointer(cursor->rgba, cursor->rgbaLen, pointer);
    return TRUE;
}

void FreeRdpAdapter::cbPointerFree(rdpContext* context, rdpPointer* pointer) {
    auto callbackLease = acquireRdpCallbackContext(context);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return;
    }
    auto* cursor = reinterpret_cast<HarmonyRdpPointer*>(pointer);
    if (cursor) {
        std::free(cursor->rgba);
        cursor->rgba = nullptr;
        cursor->rgbaLen = 0;
    }
}

BOOL FreeRdpAdapter::cbPointerSet(rdpContext* context, rdpPointer* pointer) {
    auto callbackLease = acquireRdpCallbackContext(context);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return FALSE;
    }
    context = callbackLease.context;
    auto* ctx = reinterpret_cast<FreeRdpContext*>(context);
    auto* cursor = reinterpret_cast<HarmonyRdpPointer*>(pointer);
    auto* adapter = callbackLease.adapter;
    if (!ctx || !adapter || !cursor || !cursor->rgba || cursor->rgbaLen == 0 ||
        !isRdpCallbackLeaseCurrent(callbackLease)) {
        return FALSE;
    }
    std::vector<uint8_t> rgba(cursor->rgba, cursor->rgba + cursor->rgbaLen);
    std::lock_guard<std::mutex> cursorLock(adapter->impl_->cursorLifecycleMutex);
    const uint64_t currentGeneration =
        adapter->impl_->sessionGeneration.load(std::memory_order_acquire);
    if (ctx->generation == 0 || ctx->generation != currentGeneration) {
        OH_LOG_WARN(LOG_APP,
            "[RDP-CURSOR] stale Set generation=%{public}llu current=%{public}llu ignored",
            static_cast<unsigned long long>(ctx->generation),
            static_cast<unsigned long long>(currentGeneration));
        return FALSE;
    }
    const bool accepted = adapter->impl_->cursorStore.setShapeIfGeneration(
        ctx->generation, cursor->shapeId, static_cast<int>(pointer->width),
        static_cast<int>(pointer->height), static_cast<int>(pointer->xPos),
        static_cast<int>(pointer->yPos), rgba);
    if (accepted && !adapter->impl_->cursorStore.setVisibleIfGeneration(
            ctx->generation, true)) {
        return FALSE;
    }
    return accepted ? TRUE : FALSE;
}

BOOL FreeRdpAdapter::cbPointerSetPosition(rdpContext* context, UINT32 x, UINT32 y) {
    auto callbackLease = acquireRdpCallbackContext(context);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return FALSE;
    }
    context = callbackLease.context;
    auto* ctx = reinterpret_cast<FreeRdpContext*>(context);
    auto* adapter = callbackLease.adapter;
    if (!ctx || !adapter || !isRdpCallbackLeaseCurrent(callbackLease)) {
        return FALSE;
    }
    std::lock_guard<std::mutex> cursorLock(adapter->impl_->cursorLifecycleMutex);
    const uint64_t currentGeneration =
        adapter->impl_->sessionGeneration.load(std::memory_order_acquire);
    if (ctx->generation == 0 || ctx->generation != currentGeneration) {
        return FALSE;
    }
    return adapter->impl_->cursorStore.setPositionIfGeneration(
        ctx->generation, static_cast<int>(x), static_cast<int>(y)) ? TRUE : FALSE;
}

BOOL FreeRdpAdapter::cbPointerSetNull(rdpContext* context) {
    auto callbackLease = acquireRdpCallbackContext(context);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return FALSE;
    }
    context = callbackLease.context;
    auto* ctx = reinterpret_cast<FreeRdpContext*>(context);
    auto* adapter = callbackLease.adapter;
    if (!ctx || !adapter || !isRdpCallbackLeaseCurrent(callbackLease)) {
        return FALSE;
    }
    std::lock_guard<std::mutex> cursorLock(adapter->impl_->cursorLifecycleMutex);
    const uint64_t currentGeneration =
        adapter->impl_->sessionGeneration.load(std::memory_order_acquire);
    if (ctx->generation == 0 || ctx->generation != currentGeneration) {
        return FALSE;
    }
    return adapter->impl_->cursorStore.setVisibleIfGeneration(ctx->generation, false)
        ? TRUE : FALSE;
}

BOOL FreeRdpAdapter::cbPointerSetDefault(rdpContext* context) {
    auto callbackLease = acquireRdpCallbackContext(context);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return FALSE;
    }
    context = callbackLease.context;
    auto* ctx = reinterpret_cast<FreeRdpContext*>(context);
    auto* adapter = callbackLease.adapter;
    if (!ctx || !adapter || !isRdpCallbackLeaseCurrent(callbackLease)) {
        return FALSE;
    }
    std::lock_guard<std::mutex> cursorLock(adapter->impl_->cursorLifecycleMutex);
    const uint64_t currentGeneration =
        adapter->impl_->sessionGeneration.load(std::memory_order_acquire);
    if (ctx->generation == 0 || ctx->generation != currentGeneration) {
        return FALSE;
    }
    const bool accepted = adapter->impl_->cursorStore.setDefaultShapeIfGeneration(
        ctx->generation);
    if (accepted && !adapter->impl_->cursorStore.setVisibleIfGeneration(
            ctx->generation, true)) {
        return FALSE;
    }
    return accepted ? TRUE : FALSE;
}

// ---- GDI BeginPaint/EndPaint — 首帧上屏 (BGRA raw → GLRenderer) ----
BOOL FreeRdpAdapter::cbPostConnect(freerdp* instance) {
    auto callbackLease = acquireRdpCallbackInstance(instance);
    if (!callbackLease) return FALSE;
    auto* self = callbackLease.adapter;
    if (!self || !acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return FALSE;
    }

    if (!isRdpCallbackLeaseCurrent(callbackLease)) {
        return FALSE;
    }
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) {
        OH_LOG_ERROR(LOG_APP, "[RDP] gdi_init(PIXEL_FORMAT_BGRA32) failed [E-GDI-INIT]");
        return FALSE;
    }
    if (!instance->update) {
        OH_LOG_ERROR(LOG_APP, "[RDP] update table missing after gdi_init [E-RDP-UPDATE]");
        gdi_free(instance);
        return FALSE;
    }
    if (!isRdpCallbackLeaseRegistered(callbackLease) ||
        !self->isCallbackOwnerCurrent(callbackLease.owner,
                                      callbackLease.generation)) {
        gdi_free(instance);
        return FALSE;
    }

    rdpPointer pointer = {};
    pointer.size = sizeof(HarmonyRdpPointer);
    pointer.New = cbPointerNew;
    pointer.Free = cbPointerFree;
    pointer.Set = cbPointerSet;
    pointer.SetPosition = cbPointerSetPosition;
    pointer.SetNull = cbPointerSetNull;
    pointer.SetDefault = cbPointerSetDefault;
    graphics_register_pointer(callbackLease.context->graphics, &pointer);

    instance->update->BeginPaint = cbBeginPaint;
    instance->update->EndPaint = cbEndPaint;
    instance->update->DesktopResize = cbDesktopResize;
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
    const Render::DecoderSessionIdentity owner = callbackLease.owner;
    if (owner.valid()) {
        RendererNapi::ReenableActivePresentation(owner);
    } else {
        RendererNapi::ReenableActivePresentation();
    }
    self->impl_->presentationEnabled.store(true, std::memory_order_release);
    self->impl_->startSessionWorkers(self);
    OH_LOG_INFO(LOG_APP, "[RDP] GDI initialized: BGRA32 primary buffer ready");
    return TRUE;
}

void FreeRdpAdapter::cbPostDisconnect(freerdp* instance) {
    // PostDisconnect is a platform callback too.  It must retain the same
    // admission/owner lease as EndPaint until teardown has scheduled the
    // final retire, otherwise it can free GDI while an older paint callback
    // is still reading the exact same context.
    auto callbackLease = acquireRdpCallbackInstance(instance);
    if (!callbackLease) return;
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) return;
    auto* ctx = reinterpret_cast<FreeRdpContext*>(callbackLease.context);
    auto* self = callbackLease.adapter;
    if (!ctx || !self) return;

    const Render::DecoderSessionIdentity owner = callbackLease.owner;
    // PostDisconnect has the same source-read/teardown ownership rule as
    // EndPaint. Keep the exact session owner lease through presentation
    // invalidation and cleanup scheduling, so S1 cannot tear down S2 after a
    // reconnect even though the FreeRDP callback still carries the old
    // context address.
    auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!ownerLease) {
        return;
    }
    const uint64_t currentGeneration =
        self->impl_->sessionGeneration.load(std::memory_order_acquire);
    {
        std::lock_guard<std::mutex> cursorLock(self->impl_->cursorLifecycleMutex);
        if (ctx->generation == 0 || ctx->generation != currentGeneration ||
            !self->impl_->cursorStore.setVisibleIfGeneration(ctx->generation, false)) {
            OH_LOG_INFO(LOG_APP,
                "[RDP-CURSOR] stale post-disconnect generation=%{public}llu current=%{public}llu ignored",
                static_cast<unsigned long long>(ctx->generation),
                static_cast<unsigned long long>(currentGeneration));
            return;
        }
    }
    if (!Render::SharedSessionSinkOwnerLease().accepts(owner)) {
        OH_LOG_INFO(LOG_APP,
            "[RDP-CURSOR] stale post-disconnect generation=%{public}llu current=%{public}llu ignored",
            static_cast<unsigned long long>(ctx->generation),
            static_cast<unsigned long long>(currentGeneration));
        return;
    }
    self->impl_->traceShutdown("post-disconnect", "begin");
    self->impl_->presentationEnabled.store(false, std::memory_order_release);
    if (owner.valid()) {
        RendererNapi::InvalidateActivePresentation(owner);
    } else {
        OH_LOG_INFO(LOG_APP,
            "[RDP] ignore unowned post-disconnect presentation invalidation");
    }
    self->impl_->framePump->invalidatePending();
    // The callback itself owns one admission lease.  Queue teardown on the
    // app-scope worker instead of calling closeAndWait here; otherwise this
    // callback would wait on its own lease for the full 500 ms budget.
    self->queuePostDisconnectTeardown();
    self->impl_->traceShutdown("post-disconnect", "complete");
}

BOOL FreeRdpAdapter::cbBeginPaint(rdpContext* context) {
    auto callbackLease = acquireRdpCallbackContext(context);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) return FALSE;
    auto* ctx = reinterpret_cast<FreeRdpContext*>(callbackLease.context);
    if (!ctx || !callbackLease.adapter) return FALSE;
    // FreeRDP 3.x: GDI 已在 rdpContext 中, primary buffer 就绪
    return TRUE;
}

BOOL FreeRdpAdapter::cbEndPaint(rdpContext* context) {
    return cbEndPaintWithExpectedToken(context, 0);
}

BOOL FreeRdpAdapter::cbEndPaintWithExpectedToken(
    rdpContext* context, uint64_t expectedToken) {
    const int64_t callbackBeginUs = steadyNowUs();
    // Do not dereference the platform-owned rdpContext before admission.
    // Cleanup removes this raw address from the registry and waits for every
    // acquired lease before freeing the context/GDI storage.
    auto callbackLease = acquireRdpCallbackContext(context, expectedToken);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) return FALSE;
    auto* ctx = reinterpret_cast<FreeRdpContext*>(context);
    auto* self = callbackLease.adapter;
    if (!ctx || !self) return FALSE;

    const Render::DecoderSessionIdentity owner = callbackLease.owner;
    if (!owner.valid() || ctx->owner != owner ||
        !Render::SharedSessionSinkOwnerLease().accepts(owner)) {
        return FALSE;
    }
    // Keep the same owner lease across GDI source reads, damage staging, and
    // queue submission. Teardown/owner switch waits for this callback; the
    // frame-pump worker carries the same owner and takes its own sink lease
    // before the eventual renderer write.
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return FALSE;
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING) && defined(USE_REAL_FREERDP)
    std::function<void()> endPaintBarrier;
    {
        std::lock_guard<std::mutex> testLock(self->impl_->callbackTestMutex);
        endPaintBarrier = self->impl_->endPaintBarrier;
    }
    if (endPaintBarrier) {
        endPaintBarrier();
    }
#endif
    RdpVideoTelemetryCallback telemetry;
    int telemetryWidth = 0;
    int telemetryHeight = 0;
    size_t telemetryBytes = 0;
    bool telemetrySubmitted = false;
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
        const RdpPresentationTarget target =
            RendererNapi::GetActivePresentationTargetUnderOwnerLease(owner);
        const bool stagingAllowed =
            self->impl_->presentationEnabled.load(std::memory_order_acquire) &&
            target.generation != 0;
        const bool presentationAllowed = stagingAllowed && target.ready();
        const bool frameSizeChanged = self->impl_->lastFrameWidth != 0 &&
            (self->impl_->lastFrameWidth != w || self->impl_->lastFrameHeight != h);
        const bool forceFullDamage = self->impl_->forceNextFullFrame || frameSizeChanged ||
            self->impl_->framePump->consumeFullResyncRequired();
        RdpDamageUpdateResult damageUpdate;
        if (stagingAllowed) {
            const int64_t copyBeginUs = steadyNowUs();
            damageUpdate = self->impl_->damageAccumulator->update(
                data, size, w, h, stride, invalidX, invalidY, invalidW, invalidH,
                target.generation, forceFullDamage);
            self->impl_->framePump->recordCopy(
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
                submission.owner = owner;
                submission.callbackUs = steadyNowUs() - callbackBeginUs;
                submission.enqueuedAtUs = steadyNowUs();
                queued = self->impl_->framePump->submitLatest(std::move(submission));
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
        self->impl_->framePump->recordInvalid(
            dirtyRect.valid ? static_cast<uint64_t>(dirtyRect.width) *
                static_cast<uint64_t>(dirtyRect.height) : 0,
            steadyNowUs() - callbackBeginUs, steadyNowUs());

        const int64_t firstPaintUs = self->impl_->firstPaintUs.load(std::memory_order_acquire);
        const int64_t sinceFirstMs = firstPaintUs > 0 ? (nowUs - firstPaintUs) / 1000 : 0;
        const bool diagDue = self->impl_->lastRenderDiagUs == 0 ||
            nowUs - self->impl_->lastRenderDiagUs >= 1000000;
        if (diagDue) {
            self->impl_->lastRenderDiagUs = nowUs;
            OH_LOG_INFO(LOG_APP,
                "[RDP] GDI EndPaint #%{public}d rendered=%{public}d skipped=%{public}d"
                " elapsed=%{public}lldms invalid=%{public}d rect=%{public}d,%{public}d %{public}dx%{public}d"
                " frame=%{public}dx%{public}d stride=%{public}d ret=%{public}d"
                " renderCost=%{public}lldus interval=%{public}lldus adaptations=%{public}d mode=%{public}s bytes=%{public}llu"
                " submitted=%{public}s",
                self->impl_->paintCount.load(std::memory_order_acquire),
                static_cast<int>(self->impl_->framePump->rendered()),
                static_cast<int>(self->impl_->framePump->replaced()),
                static_cast<long long>(sinceFirstMs),
                ninvalid, invalidX, invalidY, invalidW, invalidH, w, h, stride, ret,
                static_cast<long long>(self->impl_->framePump->lastWorkerCostUs()),
                static_cast<long long>(self->impl_->framePump->targetIntervalUs()),
                static_cast<int>(self->impl_->framePump->adaptationCount()),
                dirtyPresentation ? "dirty" : "full",
                static_cast<unsigned long long>(renderBytes),
                queued ? "yes" : "no");
        }
        telemetry = self->impl_->videoTelemetryCallbackSnapshot();
        telemetryWidth = w;
        telemetryHeight = h;
        telemetryBytes = renderBytes;
        telemetrySubmitted = queued;
    }
    // The owner lease must cover source read, damage staging, and queue
    // submission, but the extension telemetry callback is an external
    // callback that may synchronously query/tear down the same owner. Invoke
    // it only after releasing this callback's lease.
    sinkLease = {};
    if (telemetry) {
        telemetry(telemetryWidth, telemetryHeight, telemetryBytes, telemetrySubmitted);
    }
    return TRUE;
}

BOOL FreeRdpAdapter::cbDesktopResize(rdpContext* context) {
    // Do not inspect the platform-owned context before admission.  Cleanup
    // removes the token before retiring settings/GDI, so a stale resize is a
    // cheap fail-closed no-op rather than a use-after-free.
    auto callbackLease = acquireRdpCallbackContext(context);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return FALSE;
    }
    context = callbackLease.context;
    if (!context || !context->settings || !context->gdi) {
        OH_LOG_ERROR(LOG_APP, "[RDP-RESIZE] missing context, settings, or GDI [E-RDP-RESIZE-CONTEXT]");
        return FALSE;
    }
    FreeRdpAdapter* adapter = callbackLease.adapter;
    if (!adapter || !adapter->impl_) {
        OH_LOG_ERROR(LOG_APP, "[RDP-RESIZE] adapter owner missing [E-RDP-RESIZE-OWNER]");
        return FALSE;
    }

    const UINT32 requestedWidth =
        freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    const UINT32 requestedHeight =
        freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    const bool dimensionsValid =
        requestedWidth <= static_cast<UINT32>(RdpGraphicsLifecycle::kMaxDesktopDimension) &&
        requestedHeight <= static_cast<UINT32>(RdpGraphicsLifecycle::kMaxDesktopDimension);
    const RdpResizeTicket ticket = dimensionsValid ?
        adapter->impl_->graphicsLifecycle.beginResize(
            static_cast<int>(requestedWidth), static_cast<int>(requestedHeight)) :
        RdpResizeTicket();
    if (!ticket.accepted) {
        const RdpGraphicsLifecycleSnapshot lifecycle =
            adapter->impl_->graphicsLifecycle.snapshot();
        if (lifecycle.gfxRequested) {
            g_nextConnectionGfxFallback.mark();
        }
        OH_LOG_ERROR(LOG_APP,
            "[RDP-RESIZE] rejected size=%{public}ux%{public}u inProgress=%{public}s [E-RDP-RESIZE-INVALID]",
            requestedWidth, requestedHeight,
            lifecycle.resizeInProgress ? "true" : "false");
        adapter->impl_->setState(ConnectionState::ERROR,
            "RDP desktop resize rejected [E-RDP-RESIZE-INVALID]");
        adapter->queuePostDisconnectTeardown();
        return FALSE;
    }

    OH_LOG_INFO(LOG_APP,
        "[RDP-RESIZE] begin epoch=%{public}llu size=%{public}dx%{public}d",
        static_cast<unsigned long long>(ticket.epoch), ticket.width, ticket.height);
    adapter->impl_->presentationEnabled.store(false, std::memory_order_release);
    adapter->impl_->framePump->invalidatePending();

    bool resized = false;
    bool pumpStarted = false;
    {
        std::lock_guard<std::mutex> lifecycleLock(adapter->impl_->workerLifecycleMutex);
        auto pump = std::move(adapter->impl_->framePump);
        if (pump && !pump->stopWithin(std::chrono::milliseconds(500))) {
            RdpFramePump::deferStopAndJoin(std::move(pump));
        }
        adapter->impl_->framePump = std::make_shared<RdpFramePump>();
        if (!isRdpCallbackLeaseCurrent(callbackLease)) {
            adapter->impl_->graphicsLifecycle.completeResize(ticket.epoch, false);
            return FALSE;
        }
        resized = gdi_resize(context->gdi, requestedWidth, requestedHeight) == TRUE;
        adapter->impl_->damageAccumulator->clear();
        if (resized) {
            adapter->impl_->lastFrameWidth = 0;
            adapter->impl_->lastFrameHeight = 0;
            adapter->impl_->lastRenderBytes.store(0, std::memory_order_release);
            adapter->impl_->forceNextFullFrame = true;
            const Render::DecoderSessionIdentity owner = adapter->impl_->ownerSnapshot();
            if (owner.valid()) {
                RendererNapi::SetActiveSourceSize(owner, ticket.width, ticket.height);
            } else {
                RendererNapi::SetActiveSourceSize(ticket.width, ticket.height);
            }
            pumpStarted = adapter->impl_->framePump->start();
        }
    }

    const bool success = resized && pumpStarted;
    adapter->impl_->graphicsLifecycle.completeResize(ticket.epoch, success);
    adapter->impl_->presentationEnabled.store(success, std::memory_order_release);
    if (!success) {
        const RdpGraphicsLifecycleSnapshot lifecycle =
            adapter->impl_->graphicsLifecycle.snapshot();
        if (lifecycle.gfxRequested) {
            g_nextConnectionGfxFallback.mark();
        }
        OH_LOG_ERROR(LOG_APP,
            "[RDP-RESIZE] failed epoch=%{public}llu gdi=%{public}s pump=%{public}s [E-RDP-RESIZE-FAILED]",
            static_cast<unsigned long long>(ticket.epoch),
            resized ? "true" : "false", pumpStarted ? "true" : "false");
        adapter->impl_->setState(ConnectionState::ERROR,
            "RDP desktop resize failed [E-RDP-RESIZE-FAILED]");
        adapter->queuePostDisconnectTeardown();
        return FALSE;
    }

    OH_LOG_INFO(LOG_APP,
        "[RDP-RESIZE] complete epoch=%{public}llu size=%{public}dx%{public}d fullResync=true",
        static_cast<unsigned long long>(ticket.epoch), ticket.width, ticket.height);
    return TRUE;
}

// ---- 事件循环线程 ----
void FreeRdpAdapter::startEventLoop() {
    std::shared_ptr<FreeRdpAdapter> retained;
    try {
        retained = shared_from_this();
    } catch (const std::bad_weak_ptr&) {
        OH_LOG_ERROR(LOG_APP, "[RDP] event worker requires shared adapter lifetime");
        return;
    }
    if (!retained) {
        return;
    }
    eventLoopRunning_.store(true, std::memory_order_release);
    auto done = std::make_shared<std::atomic<bool>>(false);
    std::atomic_store_explicit(&impl_->eventThreadDone, done, std::memory_order_release);
    try {
        impl_->eventThread = std::thread([retained, done]() {
            retained->processEventLoop();
            done->store(true, std::memory_order_release);
            retained->impl_->workerDoneCv.notify_all();
        });
    } catch (const std::exception& e) {
        eventLoopRunning_.store(false, std::memory_order_release);
        done->store(true, std::memory_order_release);
        OH_LOG_ERROR(LOG_APP,
            "[RDP] event loop worker start failed: %{public}s", e.what());
    } catch (...) {
        eventLoopRunning_.store(false, std::memory_order_release);
        done->store(true, std::memory_order_release);
        OH_LOG_ERROR(LOG_APP, "[RDP] event loop worker start failed");
    }
}

void FreeRdpAdapter::stopEventLoop(RdpShutdownDeadline deadline) {
    impl_->traceShutdown("event-stop", "begin");
    eventLoopRunning_.store(false, std::memory_order_release);
    const auto doneFence = std::atomic_load_explicit(
        &impl_->eventThreadDone, std::memory_order_acquire);
    if (impl_->eventThread.joinable()) {
        if (impl_->eventThread.get_id() == std::this_thread::get_id()) {
            deferRdpWorker(std::move(impl_->eventThread),
                           impl_->lifetime.lock(), doneFence);
        } else {
            std::unique_lock<std::mutex> lock(impl_->workerDoneMutex);
            const bool done = impl_->workerDoneCv.wait_for(
                lock, remainingRdpShutdownBudget(deadline), [doneFence]() {
                    return doneFence == nullptr || doneFence->load(std::memory_order_acquire);
                });
            lock.unlock();
            if (done) {
                impl_->eventThread.join();
            } else {
                OH_LOG_WARN(LOG_APP,
                    "[RDP] event worker exceeded shutdown budget; deferring join");
                deferRdpWorker(std::move(impl_->eventThread),
                               impl_->lifetime.lock(), doneFence);
            }
        }
    }
    impl_->traceShutdown("event-stop", "complete");
}

void FreeRdpAdapter::processEventLoop() {
    HANDLE handles[64];
    while (eventLoopRunning_.load(std::memory_order_acquire)) {
        bool noHandles = false;
        {
            // The FreeRDP event-handle array and context are owned by the
            // instance. Keep the instance lease across both the wait and the
            // check so a bounded disconnect cannot free the context while a
            // deferred event worker still holds a raw pointer to it.
            std::unique_lock<std::mutex> lock(impl_->instanceMutex);
            if (!instance_ || !instance_->context) {
                break;
            }
            const DWORD count = freerdp_get_event_handles(instance_->context, handles, 64);
            if (count == 0) {
                noHandles = true;
            } else {
                const DWORD ret = WaitForMultipleObjects(count, handles, FALSE, 100);
                if (!eventLoopRunning_.load(std::memory_order_acquire)) {
                    break;
                }
                if (ret >= WAIT_OBJECT_0 && ret < WAIT_OBJECT_0 + count) {
                    if (!freerdp_check_event_handles(instance_->context)) {
                        OH_LOG_WARN(LOG_APP,
                            "[RDP] freerdp_check_event_handles returned false, stopping event loop");
                        eventLoopRunning_.store(false, std::memory_order_release);
                        break;
                    }
                }
            }
        }
        if (noHandles) {
            usleep(10000); // 10ms
        }
    }
}

// ---- 构造/析构 ----
void FreeRdpAdapter::joinConnectThread(RdpShutdownDeadline deadline) {
    impl_->traceShutdown("connect-join", "begin");
    const auto doneFence = std::atomic_load_explicit(
        &impl_->connectThreadDone, std::memory_order_acquire);
    if (!impl_->connectThread.joinable()) {
        impl_->traceShutdown("connect-join", "not-started");
        return;
    }
    if (impl_->connectThread.get_id() == std::this_thread::get_id()) {
        deferRdpWorker(std::move(impl_->connectThread),
                       impl_->lifetime.lock(), doneFence);
        impl_->connectThreadStarted.store(false, std::memory_order_release);
        impl_->traceShutdown("connect-join", "self-deferred");
        return;
    }
    std::unique_lock<std::mutex> lock(impl_->workerDoneMutex);
    const bool done = impl_->workerDoneCv.wait_for(
        lock, remainingRdpShutdownBudget(deadline), [doneFence]() {
            return doneFence == nullptr || doneFence->load(std::memory_order_acquire);
        });
    lock.unlock();
    if (done) {
        impl_->connectThread.join();
    } else {
        OH_LOG_WARN(LOG_APP,
            "[RDP] connect worker exceeded shutdown budget; deferring join");
        deferRdpWorker(std::move(impl_->connectThread),
                       impl_->lifetime.lock(), doneFence);
    }
    impl_->connectThreadStarted.store(false, std::memory_order_release);
    impl_->traceShutdown("connect-join", "complete");
}

void FreeRdpAdapter::joinDriveThread(RdpShutdownDeadline deadline) {
    impl_->traceShutdown("drive-join", "begin");
    const auto doneFence = std::atomic_load_explicit(
        &impl_->driveThreadDone, std::memory_order_acquire);
    if (!impl_->driveThread.joinable()) {
        impl_->traceShutdown("drive-join", "not-started");
        return;
    }
    if (impl_->driveThread.get_id() == std::this_thread::get_id()) {
        deferRdpWorker(std::move(impl_->driveThread),
                       impl_->lifetime.lock(), doneFence);
        impl_->driveThreadStarted.store(false, std::memory_order_release);
        impl_->traceShutdown("drive-join", "self-deferred");
        return;
    }
    std::unique_lock<std::mutex> lock(impl_->workerDoneMutex);
    const bool done = impl_->workerDoneCv.wait_for(
        lock, remainingRdpShutdownBudget(deadline), [doneFence]() {
            return doneFence == nullptr || doneFence->load(std::memory_order_acquire);
        });
    lock.unlock();
    if (done) {
        impl_->driveThread.join();
    } else {
        OH_LOG_WARN(LOG_APP,
            "[RDP] drive worker exceeded shutdown budget; deferring join");
        deferRdpWorker(std::move(impl_->driveThread),
                       impl_->lifetime.lock(), doneFence);
    }
    impl_->driveThreadStarted.store(false, std::memory_order_release);
    impl_->traceShutdown("drive-join", "complete");
}

void FreeRdpAdapter::startDriveMountAfterConnected(const std::string& driveName, const std::string& drivePath) {
    if (drivePath.empty()) {
        return;
    }
    joinDriveThread(std::chrono::steady_clock::now() + std::chrono::milliseconds(500));

    std::shared_ptr<FreeRdpAdapter> retained;
    try {
        retained = shared_from_this();
    } catch (const std::bad_weak_ptr&) {
        OH_LOG_WARN(LOG_APP,
            "[RDP] redirected drive worker requires shared adapter lifetime");
        return;
    }
    if (!retained) return;
    auto done = std::make_shared<std::atomic<bool>>(false);
    std::atomic_store_explicit(&impl_->driveThreadDone, done, std::memory_order_release);
    try {
        impl_->driveThread = std::thread([retained, done, driveName, drivePath]() {
            retained->mountDriveAfterConnected(driveName, drivePath);
            done->store(true, std::memory_order_release);
            retained->impl_->workerDoneCv.notify_all();
        });
    } catch (const std::exception& e) {
        done->store(true, std::memory_order_release);
        OH_LOG_WARN(LOG_APP,
            "[RDP] redirected drive async mount thread failed: %{public}s", e.what());
        return;
    } catch (...) {
        done->store(true, std::memory_order_release);
        OH_LOG_WARN(LOG_APP,
            "[RDP] redirected drive async mount thread failed");
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
    {
        // A deferred drive worker must not carry a raw rdpContext past the
        // instance lease. Cleanup can otherwise free the context immediately
        // after the shutdown budget expires and leave this call dereferencing
        // freed FreeRDP storage.
        std::lock_guard<std::mutex> lock(impl_->instanceMutex);
        if (impl_->stopRequested || !instance_ || !instance_->context) {
            OH_LOG_INFO(LOG_APP, "[RDP] redirected drive async mount skipped: instance unavailable");
            return;
        }
        driveRc = freerdp_ohos_rdpdr_register_drive(
            instance_->context, driveName.c_str(), drivePath.c_str(), &driveId);
    }

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

void FreeRdpAdapter::disconnectActiveInstance(RdpShutdownDeadline deadline) {
    if (remainingRdpShutdownBudget(deadline).count() <= 0) {
        impl_->traceShutdown("freerdp-disconnect", "budget-exhausted");
        return;
    }
    freerdp* activeInstance = nullptr;
    {
        std::lock_guard<std::mutex> lock(impl_->instanceMutex);
        activeInstance = instance_;
    }
    if (!activeInstance) {
        impl_->traceShutdown("freerdp-disconnect", "no-instance");
        return;
    }
    const auto retained = impl_->lifetime.lock();
    if (!retained) {
        OH_LOG_WARN(LOG_APP,
            "[RDP] cannot defer FreeRDP disconnect without shared adapter lifetime");
        return;
    }
    auto done = std::make_shared<std::atomic<bool>>(false);
    impl_->disconnectWorkerDone = done;
    impl_->traceShutdown("freerdp-disconnect", "begin");
    std::thread disconnectWorker;
    try {
        disconnectWorker = std::thread([retained, activeInstance, done]() {
            if (activeInstance->context) {
                freerdp_abort_connect_context(activeInstance->context);
            }
            freerdp_disconnect(activeInstance);
            done->store(true, std::memory_order_release);
            retained->impl_->workerDoneCv.notify_all();
        });
    } catch (const std::exception& e) {
        done->store(true, std::memory_order_release);
        OH_LOG_ERROR(LOG_APP,
            "[RDP] FreeRDP disconnect worker start failed: %{public}s", e.what());
        return;
    } catch (...) {
        done->store(true, std::memory_order_release);
        OH_LOG_ERROR(LOG_APP,
            "[RDP] FreeRDP disconnect worker start failed");
        return;
    }
    const auto waitBudget = remainingRdpShutdownBudget(deadline);
    std::unique_lock<std::mutex> lock(impl_->workerDoneMutex);
    const bool completed = impl_->workerDoneCv.wait_for(lock, waitBudget, [done]() {
        return done->load(std::memory_order_acquire);
    });
    lock.unlock();
    if (completed) {
        disconnectWorker.join();
    } else {
        OH_LOG_WARN(LOG_APP,
            "[RDP] FreeRDP disconnect exceeded total deadline; deferring worker");
        deferRdpWorker(std::move(disconnectWorker), retained, done);
    }
    impl_->traceShutdown("freerdp-disconnect", "complete");
}

void FreeRdpAdapter::cleanupInstance(RdpShutdownDeadline deadline) {
    if (deadline == RdpShutdownDeadline::max()) {
        deadline = impl_->getOrCreateShutdownTicket()->deadline;
    }
    const auto connectDoneFence = std::atomic_load_explicit(
        &impl_->connectThreadDone, std::memory_order_acquire);
    const bool runningOnConnectWorker = impl_->connectThread.joinable() &&
        impl_->connectThread.get_id() == std::this_thread::get_id();
    if (connectDoneFence &&
        !connectDoneFence->load(std::memory_order_acquire) &&
        !runningOnConnectWorker) {
        // A timed-out connect worker still uses the FreeRDP instance through
        // its own callback/config path. Do not detach the instance from
        // underneath it; hand cleanup to the same bounded reaper and wait on
        // the worker's immutable fence before touching the raw context.
        if (!impl_->cleanupDeferredForWorker.exchange(true, std::memory_order_acq_rel)) {
            const auto retained = impl_->lifetime.lock();
            if (retained) {
                auto retireDone = std::make_shared<std::atomic<bool>>(false);
                try {
                    std::thread retire([retained, connectDoneFence, deadline, retireDone]() {
                        std::unique_lock<std::mutex> lock(retained->impl_->workerDoneMutex);
                        retained->impl_->workerDoneCv.wait(lock, [connectDoneFence]() {
                            return connectDoneFence->load(std::memory_order_acquire);
                        });
                        lock.unlock();
                        retained->impl_->cleanupDeferredForWorker.store(
                            false, std::memory_order_release);
                        retained->cleanupInstance(deadline);
                        retireDone->store(true, std::memory_order_release);
                        retained->impl_->workerDoneCv.notify_all();
                    });
                    deferRdpWorker(std::move(retire), retained, retireDone);
                } catch (...) {
                    impl_->cleanupDeferredForWorker.store(false, std::memory_order_release);
                    OH_LOG_ERROR(LOG_APP,
                        "[RDP] failed to defer cleanup until connect worker completion");
                }
            } else {
                impl_->cleanupDeferredForWorker.store(false, std::memory_order_release);
                OH_LOG_ERROR(LOG_APP,
                    "[RDP] cannot defer cleanup without shared adapter lifetime");
            }
        }
        return;
    }
    {
        std::lock_guard<std::mutex> lock(impl_->configMutex);
        secureClearString(impl_->config.rdpRestrictedAdminHash);
    }
    impl_->presentationEnabled.store(false, std::memory_order_release);
    const Render::DecoderSessionIdentity owner = impl_->ownerSnapshot();
    if (owner.valid()) {
        RendererNapi::InvalidateActivePresentation(owner);
    } else {
        OH_LOG_INFO(LOG_APP,
            "[RDP] ignore unowned cleanup presentation invalidation");
    }
    impl_->framePump->invalidatePending();
    impl_->stopSessionWorkers(deadline);
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
    // Close callback admission before GDI/context destruction. If a callback
    // is already inside cbEndPaint, a 500 ms caller budget is not permission
    // to free the platform objects underneath it. The final retire owner is
    // the admission context itself and runs this ordered cleanup exactly once
    // after the last callback lease releases.
    auto admission = takeRdpCallbackContext(doomedInstance->context);
    const auto retainedAdapter = impl_->lifetime.lock();
    rdpContext* doomedContext = doomedInstance->context;
    CliprdrClientContext* doomedCliprdr =
        retainedAdapter ? retainedAdapter->impl_->cliprdr : nullptr;
    // The raw ABI has no epoch. Unsubscribe every PubSub family and clear
    // every callback slot while the instance/context are still retained;
    // only then may admission drain and the final retire owner release the
    // quarantine. A failed/partial revoke leaves the address quarantined.
    if (doomedContext && doomedContext->pubSub) {
        PubSub_UnsubscribeErrorInfo(doomedContext->pubSub, cbErrorInfo);
        PubSub_UnsubscribeChannelConnected(
            doomedContext->pubSub, cbChannelConnected);
        PubSub_UnsubscribeChannelDisconnected(
            doomedContext->pubSub, cbChannelDisconnected);
    }
    if (!revokeRdpCallbackSources(doomedInstance, doomedContext, doomedCliprdr)) {
        OH_LOG_ERROR(LOG_APP,
                     "[RDP] callback source revoke failed; retaining raw-address quarantine");
    }
    const auto disconnectDone = impl_->disconnectWorkerDone;
    const auto eventDone = std::atomic_load_explicit(
        &impl_->eventThreadDone, std::memory_order_acquire);
    const auto driveDone = std::atomic_load_explicit(
        &impl_->driveThreadDone, std::memory_order_acquire);
    const bool releaseGdi = impl_->gdiInitialized.exchange(false, std::memory_order_acq_rel);
    auto platformCleanup = [doomedInstance, retainedAdapter, releaseGdi]() {
        rdpContext* doomedContext = doomedInstance->context;
        // PubSub is part of the FreeRDP instance and may be touched by the
        // disconnect worker.  Removing the registry carrier above makes late
        // dispatch fail closed; unsubscribe only in this final owner, after
        // the disconnect and every callback-family lease have quiesced.
        if (doomedContext && doomedContext->pubSub) {
            PubSub_UnsubscribeErrorInfo(doomedContext->pubSub, cbErrorInfo);
            PubSub_UnsubscribeChannelConnected(
                doomedContext->pubSub, cbChannelConnected);
            PubSub_UnsubscribeChannelDisconnected(
                doomedContext->pubSub, cbChannelDisconnected);
        }
        if (retainedAdapter && retainedAdapter->impl_->fileClipboard) {
            // Clipboard callbacks use the same parent admission.  Detaching
            // here prevents channel_->custom teardown from racing a callback
            // that has already been admitted.
            retainedAdapter->impl_->fileClipboard->detach();
            retainedAdapter->impl_->cliprdr = nullptr;
        }
        secureClearFreeRdpPasswordHash(doomedInstance->settings);
        if (releaseGdi && doomedContext && doomedContext->gdi) {
            gdi_free(doomedInstance);
        }
        if (doomedContext) {
            freerdp_context_free(doomedInstance);
        }
        freerdp_free(doomedInstance);
        // Only now may a future FreeRDP allocation reuse these raw addresses.
        if (!releaseRdpCallbackSourceQuarantine(doomedContext, doomedInstance)) {
            OH_LOG_ERROR(LOG_APP,
                         "[RDP] callback quarantine release refused before confirmed source revoke");
        }
    };
    // A timed-out freerdp_disconnect may still be unwinding the same context.
    // Never wait for it on the callback/teardown caller (the callback may be
    // the disconnect worker itself); hand the ordered platform cleanup to a
    // second bounded-owner job that waits only on the worker done fence.
    auto finalCleanup = [platformCleanup, retainedAdapter, disconnectDone,
                         eventDone, driveDone]() mutable {
        const auto allWorkersDone = [disconnectDone, eventDone, driveDone]() {
            return (!disconnectDone || disconnectDone->load(std::memory_order_acquire)) &&
                (!eventDone || eventDone->load(std::memory_order_acquire)) &&
                (!driveDone || driveDone->load(std::memory_order_acquire));
        };
        if (allWorkersDone()) {
            platformCleanup();
            return;
        }
        if (!retainedAdapter) {
            OH_LOG_ERROR(LOG_APP,
                "[RDP] refusing platform cleanup while worker fences are live");
            return;
        }
        auto retireDone = std::make_shared<std::atomic<bool>>(false);
        try {
            std::thread retire([platformCleanup, retainedAdapter, allWorkersDone,
                                retireDone]() mutable {
                std::unique_lock<std::mutex> lock(retainedAdapter->impl_->workerDoneMutex);
                retainedAdapter->impl_->workerDoneCv.wait(lock, allWorkersDone);
                lock.unlock();
                platformCleanup();
                retireDone->store(true, std::memory_order_release);
                retainedAdapter->impl_->workerDoneCv.notify_all();
            });
            deferRdpWorker(std::move(retire), retainedAdapter, retireDone);
        } catch (...) {
            // If a retire thread cannot be created, do not free a live
            // FreeRDP context. The original worker owner remains responsible
            // for a subsequent explicit drain attempt.
            OH_LOG_ERROR(LOG_APP,
                "[RDP] failed to start deferred platform cleanup owner");
        }
    };
    if (admission) {
        const bool drained = admission->closeAndWait();
        (void)admission->deferCleanupAfterDrain(std::move(finalCleanup));
        OH_LOG_INFO(LOG_APP, "[RDP] callback retire admission drained=%{public}d",
                    drained ? 1 : 0);
    } else {
        finalCleanup();
    }
    impl_->traceShutdown("context-free", "complete");
}

void FreeRdpAdapter::queuePostDisconnectTeardown() {
    if (impl_->postDisconnectTeardownQueued.exchange(true, std::memory_order_acq_rel)) {
        return;
    }
    // An explicit disconnect publishes its ticket before the platform call,
    // so a synchronous PostDisconnect callback shares that exact deadline.
    // A platform-initiated PostDisconnect with no prior teardown creates the
    // initial ticket here; subsequent/reentrant callbacks never mint a new
    // budget or owner.
    const auto ticket = impl_->getOrCreateShutdownTicket();
    const auto retained = impl_->lifetime.lock();
    if (!retained) {
        impl_->postDisconnectTeardownQueued.store(false, std::memory_order_release);
        OH_LOG_WARN(LOG_APP,
                    "[RDP] PostDisconnect teardown deferred without shared adapter owner");
        return;
    }
    auto done = std::make_shared<std::atomic<bool>>(false);
    try {
        std::thread teardown([retained, ticket, done]() {
            if (ticket) {
                retained->cleanupInstance(ticket->deadline);
            }
            done->store(true, std::memory_order_release);
            retained->impl_->workerDoneCv.notify_all();
        });
        deferRdpWorker(std::move(teardown), retained, done);
    } catch (const std::exception& e) {
        impl_->postDisconnectTeardownQueued.store(false, std::memory_order_release);
        OH_LOG_ERROR(LOG_APP,
                     "[RDP] PostDisconnect teardown worker start failed: %{public}s",
                     e.what());
    } catch (...) {
        impl_->postDisconnectTeardownQueued.store(false, std::memory_order_release);
        OH_LOG_ERROR(LOG_APP,
                     "[RDP] PostDisconnect teardown worker start failed");
    }
}

FreeRdpAdapter::FreeRdpAdapter() : impl_(std::make_unique<Impl>()) {
    ensureFreeRdpStaticAddinProvider();
    impl_->fileClipboard = std::make_unique<RdpFileClipboardBridge>(this);
    OH_LOG_INFO(LOG_APP, "[RDP] FreeRdpAdapter created (FreeRDP 3.x)");
}

void FreeRdpAdapter::setSessionIdentity(uint64_t sessionId) {
    const uint64_t generation =
        g_nextRdpSessionGeneration.fetch_add(1, std::memory_order_relaxed);
    std::lock_guard<std::mutex> shutdownLock(impl_->shutdownMutex);
    std::lock_guard<std::mutex> cursorLock(impl_->cursorLifecycleMutex);
    impl_->sessionGeneration.store(generation, std::memory_order_release);
    {
        std::lock_guard<std::mutex> ownerLock(impl_->ownerMutex);
        impl_->owner = Render::DecoderSessionIdentity {sessionId, 0, 0};
    }
    impl_->cursorStore.reset(sessionId, "rdp", generation);
    impl_->cursorStore.setDefaultShape();
    impl_->cursorStore.setVisible(true);
}

void FreeRdpAdapter::setSessionOwner(const Render::DecoderSessionIdentity& owner) {
    if (impl_->ownerSnapshot() != owner) {
        // Publish a new owner only after every callback admission belonging to
        // the old owner has been closed and drained.  This makes the callback
        // lease a real generation transition rather than a diagnostic tag.
        closeRdpCallbackAdmissionsForAdapter(this);
    }
    // Admission close rejects new callbacks, while the shared owner barrier
    // also covers a callback that already passed admission and is in a
    // platform/sink side effect.  Keep the lock order owner-barrier ->
    // adapter-owner; isCallbackOwnerCurrent checks the barrier first, so no
    // ownerMutex -> shared_mutex cycle is possible.
    auto ownerBarrier = Render::SharedSessionSinkOwnerLease().acquireExclusive();
    if (!ownerBarrier) {
        return;
    }
    std::lock_guard<std::mutex> ownerLock(impl_->ownerMutex);
    impl_->owner = owner;
}

bool FreeRdpAdapter::isCallbackOwnerCurrent(
    const Render::DecoderSessionIdentity& owner, uint64_t callbackGeneration) const {
    if (!Render::SharedSessionSinkOwnerLease().accepts(owner)) {
        return false;
    }
    return impl_->ownerSnapshot() == owner &&
        impl_->sessionGeneration.load(std::memory_order_acquire) == callbackGeneration;
}

#if defined(RDP_NATIVE_CALLBACK_TESTING) && defined(USE_REAL_FREERDP)
void FreeRdpAdapter::SetEndPaintBarrierForTesting(std::function<void()> barrier) {
    std::lock_guard<std::mutex> testLock(impl_->callbackTestMutex);
    impl_->endPaintBarrier = std::move(barrier);
}

bool FreeRdpAdapter::RegisterCallbackContextForTesting(
    rdpContext* context, FreeRdpAdapter* adapter,
    const Render::DecoderSessionIdentity& owner, uint64_t generation) {
    return registerRdpCallbackContext(context, adapter, owner, generation);
}

bool FreeRdpAdapter::RegisterCallbackContextForTesting(
    freerdp* instance, rdpContext* context, FreeRdpAdapter* adapter,
    const Render::DecoderSessionIdentity& owner, uint64_t generation) {
    return registerRdpCallbackContext(
        instance, context, adapter, nullptr, owner, generation);
}

void FreeRdpAdapter::UnregisterCallbackContextForTesting(rdpContext* context) {
    unregisterRdpCallbackContext(context);
}

bool FreeRdpAdapter::InstallCallbackSourcesForTesting(freerdp* instance) {
    if (instance == nullptr) {
        return false;
    }
    instance->VerifyCertificate = cbVerifyCertificate;
    instance->VerifyChangedCertificate = nullptr;
    instance->VerifyCertificateEx = cbVerifyCertificateEx;
    instance->VerifyChangedCertificateEx = cbVerifyChangedCertificateEx;
    instance->VerifyX509Certificate = cbVerifyX509Certificate;
    instance->LogonErrorInfo = cbLogonErrorInfo;
    instance->PostConnect = cbPostConnect;
    instance->PostDisconnect = cbPostDisconnect;
    instance->LoadChannels = cbLoadChannels;
    instance->PostFinalDisconnect = nullptr;
    return instance->VerifyCertificate != nullptr &&
        instance->VerifyCertificateEx != nullptr &&
        instance->VerifyChangedCertificateEx != nullptr &&
        instance->VerifyX509Certificate != nullptr &&
        instance->LogonErrorInfo != nullptr &&
        instance->PostConnect != nullptr &&
        instance->PostDisconnect != nullptr &&
        instance->LoadChannels != nullptr;
}

bool FreeRdpAdapter::RevokeCallbackSourcesForTesting(rdpContext* context) {
    if (context == nullptr) {
        return false;
    }
    // The carrier-only fixture has no real freerdp allocation, but this is
    // still the production source-slot revoke helper used by cleanup.  The
    // test then drives every static raw ABI entry while the quarantine is
    // retained, proving that address reuse is gated by source revocation.
    return revokeRdpCallbackSources(nullptr, context, nullptr);
}

bool FreeRdpAdapter::RevokeCallbackSourcesForTesting(
    freerdp* instance, rdpContext* context, CliprdrClientContext* cliprdr) {
    return revokeRdpCallbackSources(instance, context, cliprdr);
}

bool FreeRdpAdapter::ReleaseCallbackSourceQuarantineForTesting(rdpContext* context) {
    return releaseRdpCallbackSourceQuarantine(
        context, reinterpret_cast<freerdp*>(context));
}

bool FreeRdpAdapter::ReleaseCallbackSourceQuarantineForTesting(
    freerdp* instance, rdpContext* context) {
    return releaseRdpCallbackSourceQuarantine(context, instance);
}

uint64_t FreeRdpAdapter::ShutdownTicketSerialForTesting() const {
    const auto ticket = std::atomic_load_explicit(
        &impl_->shutdownTicket, std::memory_order_acquire);
    return ticket ? ticket->serial : 0;
}

void FreeRdpAdapter::SetRdpsndCallbackForTesting(
    AudioDataCallback callback, const Render::DecoderSessionIdentity& owner) {
    std::shared_ptr<Render::CallbackAdmissionContext> oldAdmission;
    std::shared_ptr<Render::CallbackAdmissionContext> newAdmission;
    uint64_t newToken = 0;
    if (callback && owner.valid() && owner.generation != 0) {
        newAdmission = std::make_shared<Render::CallbackAdmissionContext>();
        newToken = static_cast<uint64_t>(
            g_rdpCallbackToken.fetch_add(1, std::memory_order_relaxed));
        if (!newAdmission->bind(newToken,
                                owner, owner.generation)) {
            newAdmission.reset();
            callback = nullptr;
            newToken = 0;
        }
    }
    {
        std::lock_guard<std::mutex> lock(g_rdpAudioCallbackMutex);
        oldAdmission = std::move(g_rdpAudioAdmission);
        g_rdpAudioCallbackOwner = owner;
        g_rdpAudioCallback = std::move(callback);
        g_rdpAudioAdmission = std::move(newAdmission);
        g_rdpAudioCallbackToken = newToken;
    }
    if (oldAdmission) {
        // Do not wait while holding the callback mutex: the platform entry
        // snapshots the admission under this mutex before closing it.
        (void)closeRdpCallbackAdmission(oldAdmission, "rdpsnd-rebind");
    }
}

void FreeRdpAdapter::ClearRdpsndCallbackForTesting(
    const Render::DecoderSessionIdentity& owner) {
    std::shared_ptr<Render::CallbackAdmissionContext> oldAdmission;
    {
        std::lock_guard<std::mutex> lock(g_rdpAudioCallbackMutex);
        if (g_rdpAudioCallbackOwner == owner) {
            g_rdpAudioCallbackOwner = Render::DecoderSessionIdentity {};
            g_rdpAudioCallback = nullptr;
            oldAdmission = std::move(g_rdpAudioAdmission);
            g_rdpAudioCallbackToken = 0;
        }
    }
    if (oldAdmission) {
        (void)closeRdpCallbackAdmission(oldAdmission, "rdpsnd-clear");
    }
}

uint64_t FreeRdpAdapter::CallbackContextTokenForTesting(rdpContext* context) {
    std::lock_guard<std::mutex> lock(g_rdpCallbackRegistryMutex);
    const auto it = g_rdpCallbackRegistry.find(context);
    return it == g_rdpCallbackRegistry.end() ? 0 : it->second.token;
}

uint64_t FreeRdpAdapter::RdpsndCallbackTokenForTesting() {
    std::lock_guard<std::mutex> lock(g_rdpAudioCallbackMutex);
    return g_rdpAudioCallbackToken;
}

UINT FreeRdpAdapter::InvokeRdpsndCallbackForTestingWithToken(
    uint64_t capturedToken, const BYTE* data, size_t size,
    UINT32 sampleRate, UINT16 channels, UINT16 bitsPerSample) {
    return invokeRdpSoundWithExpectedToken(
        capturedToken, data, size, sampleRate, channels, bitsPerSample);
}

std::shared_ptr<std::atomic<bool>> FreeRdpAdapter::QueueBlockedWorkerForTesting() {
    auto release = std::make_shared<std::atomic<bool>>(false);
    auto done = std::make_shared<std::atomic<bool>>(false);
    std::thread worker([release, done]() {
        while (!release->load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        done->store(true, std::memory_order_release);
    });
    deferRdpWorker(std::move(worker), nullptr, done);
    return release;
}

bool FreeRdpAdapter::DrainDeferredWorkersWithinForTesting(uint32_t timeoutMs) {
    return rdpWorkerOwner().drainWithin(std::chrono::milliseconds(timeoutMs));
}

bool FreeRdpAdapter::ShutdownDeferredWorkersWithinForTesting(uint32_t timeoutMs) {
    return shutdownRdpWorkersWithin(std::chrono::milliseconds(timeoutMs));
}

std::size_t FreeRdpAdapter::DeferredWorkerRemainingForTesting() {
    return rdpWorkerRemaining();
}
#endif

RemoteCursorSnapshot FreeRdpAdapter::getRemoteCursorSnapshot(bool includePixels) {
    return impl_->cursorStore.snapshot(includePixels);
}

FreeRdpAdapter::~FreeRdpAdapter() {
    // 断开活跃连接或等待连接线程结束
    disconnect();
    (void)RdpFramePump::shutdownDeferredJoinsWithin(std::chrono::milliseconds(500));
    (void)shutdownRdpWorkersWithin(std::chrono::milliseconds(500));
}

// ---- 协议元信息 ----
std::string FreeRdpAdapter::protocolName() { return "RDP"; }
int FreeRdpAdapter::defaultPort() { return RDP_TCP_PORT; }
std::string FreeRdpAdapter::protocolVersion() { return FREERDP_VERSION_FULL; }

// ---- 连接管理 (异步, 不阻塞 NAPI 线程) ----
int FreeRdpAdapter::connect(const ConnectionConfig& cfg) {
    std::shared_ptr<FreeRdpAdapter> retained;
    try {
        retained = shared_from_this();
    } catch (const std::bad_weak_ptr&) {
        OH_LOG_ERROR(LOG_APP,
            "[RDP] connect requires a shared adapter lifetime");
        return -12;
    }
    if (!retained) {
        return -12;
    }
    impl_->lifetime = retained;
    // A failed asynchronous attempt still leaves its std::thread object
    // joinable until the next teardown.  Replacing that object directly would
    // invoke std::terminate even though the public state is already ERROR.
    // Route every joinable/connecting attempt through the idempotent shutdown
    // path before publishing a new generation.
    if (getState() == ConnectionState::CONNECTED ||
        impl_->connecting.load(std::memory_order_acquire) ||
        impl_->connectThread.joinable()) {
        disconnect();
    }
    {
        std::lock_guard<std::mutex> shutdownLock(impl_->shutdownMutex);
        std::lock_guard<std::mutex> cursorLock(impl_->cursorLifecycleMutex);
        impl_->shutdownState.reset();
        // A failed connect can call cleanupInstance() without passing through
        // disconnect(), which mints a ticket for that failed session. A new
        // session must never inherit that expired absolute deadline.
        std::atomic_store_explicit(
            &impl_->shutdownTicket, std::shared_ptr<RdpShutdownTicket> {},
            std::memory_order_release);
        impl_->postDisconnectTeardownQueued.store(false, std::memory_order_release);
        const uint64_t generation =
            g_nextRdpSessionGeneration.fetch_add(1, std::memory_order_relaxed);
        impl_->sessionGeneration.store(generation, std::memory_order_release);
        // The cursor store and the frame/input workers share the same
        // connection generation. A late FreeRDP pointer callback must not be
        // presented as if it belonged to a newer ArkUI surface attachment.
        impl_->cursorStore.setGeneration(generation);
        impl_->shutdownStartedUs.store(0, std::memory_order_release);
    }
    {
        std::lock_guard<std::mutex> lock(impl_->configMutex);
        impl_->config = cfg;
    }
    impl_->connecting = true;
    impl_->stopRequested = false;
    std::shared_ptr<Render::CallbackAdmissionContext> oldAudioAdmission;
    {
        std::lock_guard<std::mutex> lock(g_rdpAudioCallbackMutex);
        oldAudioAdmission = std::move(g_rdpAudioAdmission);
        if (cfg.rdAudioEnabled && impl_->audioCallback) {
            g_rdpAudioCallbackOwner = impl_->ownerSnapshot();
            g_rdpAudioCallback = impl_->audioCallback;
            g_rdpAudioAdmission = std::make_shared<Render::CallbackAdmissionContext>();
            if (!g_rdpAudioAdmission->bind(
                    g_rdpCallbackToken.fetch_add(1, std::memory_order_relaxed),
                    g_rdpAudioCallbackOwner, g_rdpAudioCallbackOwner.generation)) {
                g_rdpAudioAdmission.reset();
                g_rdpAudioCallback = nullptr;
            }
        } else if (g_rdpAudioCallbackOwner == impl_->ownerSnapshot()) {
            g_rdpAudioCallbackOwner = Render::DecoderSessionIdentity {};
            g_rdpAudioCallback = nullptr;
            g_rdpAudioAdmission.reset();
        }
    }
    if (oldAudioAdmission) {
        (void)closeRdpCallbackAdmission(oldAudioAdmission, "connect-rebind");
    }
    impl_->setState(ConnectionState::CONNECTING, "Connecting...");

    // 在独立线程中执行 freerdp_connect(), 避免阻塞 NAPI/ArkTS UI
    const uint64_t connectGeneration =
        impl_->sessionGeneration.load(std::memory_order_acquire);
    auto connectDone = std::make_shared<std::atomic<bool>>(false);
    std::atomic_store_explicit(&impl_->connectThreadDone, connectDone,
                               std::memory_order_release);
    try {
        impl_->connectThread = std::thread([retained, connectDone, connectGeneration]() {
            try {
                retained->connectThreadFunc(connectGeneration);
            } catch (...) {
                retained->impl_->connecting.store(false, std::memory_order_release);
                retained->impl_->setState(
                    ConnectionState::ERROR, "RDP connect worker failed [E-RDP-WORKER]");
            }
            connectDone->store(true, std::memory_order_release);
            retained->impl_->workerDoneCv.notify_all();
        });
    } catch (const std::exception& e) {
        impl_->connecting = false;
        connectDone->store(true, std::memory_order_release);
        {
            std::lock_guard<std::mutex> lock(impl_->configMutex);
            secureClearString(impl_->config.rdpRestrictedAdminHash);
        }
        impl_->setState(ConnectionState::ERROR,
            std::string("thread start failed [E-RDP-THREAD]: ") + e.what());
        return -11;
    } catch (...) {
        impl_->connecting = false;
        connectDone->store(true, std::memory_order_release);
        {
            std::lock_guard<std::mutex> lock(impl_->configMutex);
            secureClearString(impl_->config.rdpRestrictedAdminHash);
        }
        impl_->setState(ConnectionState::ERROR, "thread start failed [E-RDP-THREAD]");
        return -11;
    }
    impl_->connectThreadStarted = true;

    // connect() 立即返回 — 连接结果通过 ConnectionStateCallback 异步报告
    return 0;
}

void FreeRdpAdapter::connectThreadFunc(uint64_t expectedGeneration) {
    const auto isCurrentAttempt = [this, expectedGeneration]() {
        return impl_->sessionGeneration.load(std::memory_order_acquire) ==
                expectedGeneration &&
            !impl_->stopRequested.load(std::memory_order_acquire);
    };
    if (!isCurrentAttempt()) {
        return;
    }
    ConnectionConfig cfg;
    {
        std::lock_guard<std::mutex> lock(impl_->configMutex);
        cfg = impl_->config;
        // The worker owns its private copy from this point onward. Do not
        // leave the restricted-admin secret in the reconnect-shared config.
        secureClearString(impl_->config.rdpRestrictedAdminHash);
    }

    freerdp* newInstance = freerdp_new();
    if (!newInstance) {
        secureClearString(cfg.rdpRestrictedAdminHash);
        impl_->setState(ConnectionState::ERROR, "freerdp_new() 失败 [E-FREERDP-NEW]");
        impl_->connecting = false;
        return;
    }
    if (!isCurrentAttempt()) {
        freerdp_free(newInstance);
        secureClearString(cfg.rdpRestrictedAdminHash);
        return;
    }

    // FreeRDP 3.x: ContextSize 模式
    {
        // Serialize the generation check with connect()/disconnect() so a
        // stale bounded worker cannot publish its instance into a new
        // session after the old instance was detached.
        std::lock_guard<std::mutex> shutdownLock(impl_->shutdownMutex);
        if (!isCurrentAttempt()) {
            freerdp_free(newInstance);
            secureClearString(cfg.rdpRestrictedAdminHash);
            return;
        }
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
    ctx->generation = impl_->sessionGeneration.load(std::memory_order_acquire);
    ctx->owner = impl_->ownerSnapshot();
    if (!registerRdpCallbackContext(
            instance_, instance_->context, this, impl_->lifetime.lock(),
            ctx->owner, ctx->generation)) {
        impl_->setState(ConnectionState::ERROR,
                        "FreeRDP callback admission registration failed [E-RDP-CALLBACK]");
        cleanupInstance();
        impl_->connecting = false;
        return;
    }
    if (!isCurrentAttempt()) {
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
    const bool restrictedAdmin = cfg.rdpAuthMode == RdpAuthenticationMode::RestrictedAdmin;
    const bool blankPassword = cfg.rdpAuthMode == RdpAuthenticationMode::BlankPassword;
    const char* authModeName = restrictedAdmin ? "restricted_admin" :
        (blankPassword ? "blank_password" : "password");
    const char* restrictedAdminSecretSource = "ntlm_hash";
    RdpAuthenticationPolicy authPolicy = ParseRdpAuthenticationPolicy(
        authModeName, restrictedAdminSecretSource, cfg.rdpRestrictedAdminHash);
    if (!authPolicy.valid) {
        secureClearString(cfg.rdpRestrictedAdminHash);
        secureClearString(authPolicy.normalizedNtlmHash);
        impl_->setState(ConnectionState::ERROR,
                        restrictedAdmin ? "Restricted Admin NTLM Hash 无效 [E-RDP-AUTH-HASH]" :
                            "RDP 认证配置无效 [E-RDP-AUTH-CONFIG]");
        cleanupInstance();
        impl_->connecting = false;
        return;
    }
    std::string restrictedAdminHash = authPolicy.normalizedNtlmHash;
    const size_t restrictedAdminHashLength = restrictedAdminHash.length();
    secureClearString(authPolicy.normalizedNtlmHash);
    // The adapter only needs the normalized local copy while configuring the
    // FreeRDP instance.  Do not retain the ArkTS/NAPI copy in ConnectionConfig.
    secureClearString(cfg.rdpRestrictedAdminHash);
    freerdp_settings_set_string(s, FreeRDP_Username, effectiveUsername.c_str());
    freerdp_settings_set_string(s, FreeRDP_Password,
                                (restrictedAdmin || blankPassword) ? "" : cfg.password.c_str());
    if (restrictedAdmin) {
        if (!freerdp_settings_set_string(s, FreeRDP_PasswordHash, restrictedAdminHash.c_str())) {
            secureClearString(restrictedAdminHash);
            impl_->setState(ConnectionState::ERROR,
                            "RDP Restricted Admin Hash 配置失败 [E-RDP-AUTH-HASH]");
            cleanupInstance();
            impl_->connecting = false;
            return;
        }
    } else {
        freerdp_settings_set_string(s, FreeRDP_PasswordHash, "");
    }
    secureClearString(restrictedAdminHash);
    if (!effectiveDomain.empty()) {
        freerdp_settings_set_string(s, FreeRDP_Domain, effectiveDomain.c_str());
    }

    // 桌面尺寸
    freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth,
                                static_cast<UINT32>(cfg.width > 0 ? cfg.width : 1920));
    freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight,
                                static_cast<UINT32>(cfg.height > 0 ? cfg.height : 1080));
    freerdp_settings_set_bool(s, FreeRDP_DesktopResize, TRUE);
    // FreeRDP only dispatches protocol pointer-position updates to
    // pointer.SetPosition when mouse grabbing is enabled.  The ArkTS cursor
    // overlay consumes the callback; it does not change the system pointer.
    freerdp_settings_set_bool(s, FreeRDP_GrabMouse, TRUE);

    // Input capability set: advertise an enhanced keyboard and a concrete
    // layout before the RDP handshake. Scan-code input then follows the same
    // controller layout used by the remote Windows IME instead of server-side
    // guessing from an all-zero KeyboardLayout.
    const UINT32 keyboardLayout = resolveRdpKeyboardLayoutFromSystemLocale();
    if (!freerdp_settings_set_uint32(s, FreeRDP_KeyboardType,
                                     WINPR_KBD_TYPE_IBM_ENHANCED) ||
        !freerdp_settings_set_uint32(s, FreeRDP_KeyboardSubType, 0) ||
        !freerdp_settings_set_uint32(s, FreeRDP_KeyboardFunctionKey, 24) ||
        !freerdp_settings_set_uint32(s, FreeRDP_KeyboardLayout, keyboardLayout)) {
        impl_->setState(ConnectionState::ERROR,
                        "RDP keyboard capability configuration failed [E-RDP-KBD-CAPS]");
        cleanupInstance();
        impl_->connecting = false;
        return;
    }
    OH_LOG_INFO(LOG_APP,
                "[RDP] keyboard capabilities type=%{public}u subtype=0 functionKeys=24 layout=0x%{public}08x",
                static_cast<UINT32>(WINPR_KBD_TYPE_IBM_ENHANCED), keyboardLayout);

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
    // Match FreeRDP's official /restricted-admin path: it pairs the
    // console-session request with RestrictedAdminModeRequired.  /pth uses
    // the same combination in the upstream command-line client.
    freerdp_settings_set_bool(s, FreeRDP_ConsoleSession, restrictedAdmin ? TRUE : FALSE);
    freerdp_settings_set_bool(s, FreeRDP_RemoteCredentialGuard, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_RestrictedAdminModeRequired, restrictedAdmin ? TRUE : FALSE);
    freerdp_settings_set_bool(s, FreeRDP_RestrictedAdminModeSupported, restrictedAdmin ? TRUE : FALSE);
    freerdp_settings_set_bool(s, FreeRDP_SupportErrorInfoPdu, TRUE);
    const RdpPerformancePolicy::GraphicsMode graphicsMode = applyRdpPerformanceSettings(s);
    {
        std::lock_guard<std::mutex> renderLock(impl_->renderMutex);
        impl_->graphicsMode = RdpPerformancePolicy::GraphicsModeName(graphicsMode);
    }
    impl_->graphicsLifecycle.reset(
        static_cast<int>(freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth)),
        static_cast<int>(freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight)),
        graphicsMode != RdpPerformancePolicy::GraphicsMode::GdiFallback);

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
    const UINT32 clipboardFeatureMask = cfg.rdClipboardEnabled ?
        (CLIPRDR_FLAG_LOCAL_TO_REMOTE | CLIPRDR_FLAG_REMOTE_TO_LOCAL |
         CLIPRDR_FLAG_LOCAL_TO_REMOTE_FILES) : 0;
    freerdp_settings_set_uint32(s, FreeRDP_ClipboardFeatureMask, clipboardFeatureMask);
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
                " gateway=%{public}s targetName=%{public}s authIdentityMode=%{public}d rdpAuthMode=%{public}s restrictedSource=%{public}s user=%{public}s domain=%{public}s"
                " audio=%{public}s driveName=%{public}s drivePathId=%{public}s"
                " passwordLen=%{public}zu restrictedHashLen=%{public}zu encrypted=%{public}s",
                logHost.c_str(), port, cfg.width, cfg.height, cfg.colorDepth,
                logGatewayHost.c_str(),
                logTargetName.c_str(),
                cfg.rdpAuthIdentityMode,
                authModeName,
                restrictedAdminSecretSource,
                logUser.c_str(), logDomain.c_str(),
                cfg.rdAudioEnabled ? "on" : "off",
                driveEnabled ? driveName.c_str() : "off",
                logDrivePath.c_str(),
                cfg.password.length(), restrictedAdminHashLength,
                cfg.password.rfind("1:", 0) == 0 ? "true" : "false");
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
    if (!isCurrentAttempt()) {
        impl_->traceShutdown("connect-cancel", "before-connect");
        cleanupInstance();
        impl_->connecting = false;
        return;
    }
    OH_LOG_INFO(LOG_APP, "[RDP] 开始 freerdp_connect...");
    BOOL ok = freerdp_connect(instance_);
    if (!isCurrentAttempt()) {
        cleanupInstance();
        impl_->connecting = false;
        return;
    }
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
    if (!isCurrentAttempt()) {
        cleanupInstance();
        impl_->connecting = false;
        return;
    }
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
    std::unique_lock<std::mutex> shutdownLock(impl_->shutdownMutex);
    if (!impl_->shutdownState.requestDisconnect()) {
        impl_->traceShutdown("request", "duplicate");
        return;
    }
    impl_->beginShutdownTrace();
    const auto ticket = impl_->getOrCreateShutdownTicket();
    const RdpShutdownDeadline deadline = ticket->deadline;
    impl_->stopRequested.store(true, std::memory_order_release);
    const uint64_t disconnectGeneration =
        impl_->sessionGeneration.load(std::memory_order_acquire);
    {
        std::lock_guard<std::mutex> cursorLock(impl_->cursorLifecycleMutex);
        impl_->cursorStore.setVisibleIfGeneration(disconnectGeneration, false);
    }
    impl_->presentationEnabled.store(false, std::memory_order_release);
    const Render::DecoderSessionIdentity owner = impl_->ownerSnapshot();
    if (owner.valid()) {
        RendererNapi::InvalidateActivePresentation(owner);
    } else {
        OH_LOG_INFO(LOG_APP,
            "[RDP] ignore unowned disconnect presentation invalidation");
    }
    impl_->framePump->invalidatePending();

    impl_->stopSessionWorkers(deadline);

    // The connect thread can start both event and drive workers. Join the producer
    // first so no worker can appear after the corresponding stop/join returns.
    joinConnectThread(deadline);
    stopEventLoop(deadline);
    joinDriveThread(deadline);

    impl_->shutdownState.advance(RdpShutdown::Phase::Quiescing,
                                 RdpShutdown::Phase::TransportDisconnecting);
    disconnectActiveInstance(deadline);
    impl_->shutdownState.advance(RdpShutdown::Phase::TransportDisconnecting,
                                 RdpShutdown::Phase::Releasing);
    impl_->connecting = false;
    cleanupInstance(deadline);
    std::shared_ptr<Render::CallbackAdmissionContext> oldAudioAdmission;
    {
        std::lock_guard<std::mutex> lock(g_rdpAudioCallbackMutex);
        if (g_rdpAudioCallbackOwner == impl_->ownerSnapshot()) {
            g_rdpAudioCallbackOwner = Render::DecoderSessionIdentity {};
            g_rdpAudioCallback = nullptr;
            oldAudioAdmission = std::move(g_rdpAudioAdmission);
        }
    }
    if (oldAudioAdmission) {
        (void)closeRdpCallbackAdmission(oldAudioAdmission, "disconnect-clear");
    }

    const ConnectionState state = getState();
    // Do not invoke application code while the teardown mutex is held.  A
    // state callback is allowed to request another disconnect or connect; the
    // shutdown state above already makes that re-entry idempotent.
    shutdownLock.unlock();
    if (state != ConnectionState::DISCONNECTED &&
        state != ConnectionState::ERROR) {
        impl_->setState(ConnectionState::DISCONNECTED, "Disconnected");
    }
    impl_->shutdownState.advance(RdpShutdown::Phase::Releasing,
                                 RdpShutdown::Phase::Complete);
    impl_->traceShutdown("complete", "success");
    std::atomic_store_explicit(
        &impl_->shutdownTicket, std::shared_ptr<RdpShutdownTicket> {},
        std::memory_order_release);
    OH_LOG_INFO(LOG_APP, "[RDP] FreeRDP session disconnected/cleaned");
    return;
}

ConnectionState FreeRdpAdapter::getState() {
    std::lock_guard<std::mutex> lock(impl_->stateMutex);
    return impl_->state;
}

void FreeRdpAdapter::requestFrameRefresh() {
    if (!impl_->presentationEnabled.load(std::memory_order_acquire)) {
        return;
    }
    const Render::DecoderSessionIdentity owner = impl_->ownerSnapshot();
    const RdpPresentationTarget target = owner.valid() ?
        RendererNapi::GetActivePresentationTarget(owner) :
        RendererNapi::GetActivePresentationTarget();
    if (!target.ready()) {
        return;
    }

    if (!impl_->damageAccumulator->requestFullSnapshot(target.generation)) {
        OH_LOG_WARN(LOG_APP, "[RDP] requestFrameRefresh skipped: owned frame not ready");
        return;
    }

    RdpFrameSubmission submission;
    submission.damageSource = impl_->damageAccumulator;
    submission.owner = owner;
    submission.enqueuedAtUs = steadyNowUs();
    if (!impl_->framePump->submitLatest(std::move(submission))) {
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
    stats.renderedPaintCount = static_cast<int>(impl_->framePump->rendered());
    const int64_t firstPaintUs = impl_->firstPaintUs.load(std::memory_order_acquire);
    const int64_t lastPaintUs = impl_->lastPaintUs.load(std::memory_order_acquire);
    stats.firstPaintMs = firstPaintUs > 0 ? firstPaintUs / 1000 : 0;
    stats.lastPaintMs = lastPaintUs > 0 ? lastPaintUs / 1000 : 0;
    stats.skippedPaintCount = static_cast<int>(impl_->framePump->replaced());
    stats.slowRenderCount = static_cast<int>(impl_->framePump->adaptationCount());
    stats.minRenderIntervalUs = impl_->framePump->targetIntervalUs();
    stats.lastRenderCostUs = impl_->framePump->lastWorkerCostUs();
    stats.lastRenderBytes = impl_->lastRenderBytes.load(std::memory_order_acquire);
    stats.pumpSubmitted = impl_->framePump->submitted();
    stats.pumpRendered = impl_->framePump->rendered();
    stats.pumpReplaced = impl_->framePump->replaced();
    stats.pumpRejected = impl_->framePump->rejected();
    const RdpPresentationMetricsSnapshot presentation =
        impl_->framePump->metricsSnapshot(steadyNowUs());
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
    const RdpGlUploadGateSnapshot uploadGate = impl_->framePump->glUploadGateSnapshot();
    stats.glUploadGateDecision = static_cast<int>(uploadGate.decision);
    stats.glUploadEvaluatedSamples = uploadGate.evaluatedSamples;
    stats.glUploadSwapP95Us = uploadGate.uploadSwapP95Us;
    stats.glUploadSharePermille = uploadGate.uploadSwapSharePermille;
    const RdpGraphicsLifecycleSnapshot graphics = impl_->graphicsLifecycle.snapshot();
    stats.desktopWidth = graphics.desktopWidth;
    stats.desktopHeight = graphics.desktopHeight;
    stats.graphicsEpoch = graphics.epoch;
    stats.desktopResizeCount = graphics.resizeCount;
    stats.desktopResizeFailures = graphics.resizeFailures;
    stats.gfxChannelConnected = graphics.gfxInitialized;
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
    const Render::DecoderSessionIdentity owner = impl_->ownerSnapshot();
    const RdpPresentationTarget target = owner.valid() ?
        RendererNapi::GetActivePresentationTarget(owner) :
        RendererNapi::GetActivePresentationTarget();
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
        impl_->framePump->recordCopy(
            update.copiedBytes, steadyNowUs() - copyBeginUs, steadyNowUs());
        if (!update.accepted) {
            return false;
        }
    }
    RdpFrameSubmission submission;
    submission.damageSource = impl_->damageAccumulator;
    submission.owner = owner;
    submission.enqueuedAtUs = steadyNowUs();
    return impl_->framePump->submitLatest(std::move(submission));
}

// ---- 输入事件 ----
void FreeRdpAdapter::sendKey(uint32_t scancode, bool pressed) {
    if (!impl_) {
        return;
    }
    if (isHarmonyPauseKeyCode(scancode)) {
        // FreeRDP emits the required atomic Ctrl+NumLock-compatible Pause
        // sequence. There is intentionally no corresponding key-up event.
        if (pressed) {
            impl_->enqueueInputEvent(RdpQueuedInputEvent::Pause());
            OH_LOG_DEBUG(LOG_APP, "[RDP] queued special Pause/Break event");
        }
        return;
    }
    // 将 HarmonyOS keyCode 映射到 Windows RDP scancode
    uint32_t rdpScancode = mapHarmonyKeyCodeToRdpScancode(scancode);
    if (rdpScancode == 0) {
        // 未映射的键 — 直接传递原始值 (可能已经是正确的 scancode)
        rdpScancode = scancode;
        static std::atomic<int> unhandledCount {0};
        const int unhandled = unhandledCount.fetch_add(1, std::memory_order_relaxed);
        if (unhandled < 20 || unhandled % 50 == 0) {
            OH_LOG_DEBUG(LOG_APP, "[RDP] 键码未映射: harmonyKeyCode=%{public}u → pass-through scancode=%{public}u",
                        scancode, rdpScancode);
        }
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
void FreeRdpAdapter::setVideoTelemetryCallback(RdpVideoTelemetryCallback callback) {
    std::lock_guard<std::mutex> lock(impl_->videoTelemetryMutex);
    impl_->videoTelemetryCallback = std::move(callback);
}
void FreeRdpAdapter::setAudioCallback(AudioDataCallback cb) {
    impl_->audioCallback = std::move(cb);
    bool audioEnabled = false;
    {
        std::lock_guard<std::mutex> lock(impl_->configMutex);
        audioEnabled = impl_->config.rdAudioEnabled;
    }
    if (audioEnabled) {
        std::shared_ptr<Render::CallbackAdmissionContext> oldAudioAdmission;
        {
            std::lock_guard<std::mutex> lock(g_rdpAudioCallbackMutex);
            oldAudioAdmission = std::move(g_rdpAudioAdmission);
            if (impl_->audioCallback) {
                g_rdpAudioCallbackOwner = impl_->ownerSnapshot();
                g_rdpAudioCallback = impl_->audioCallback;
                g_rdpAudioAdmission = std::make_shared<Render::CallbackAdmissionContext>();
                if (!g_rdpAudioAdmission->bind(
                        g_rdpCallbackToken.fetch_add(1, std::memory_order_relaxed),
                        g_rdpAudioCallbackOwner, g_rdpAudioCallbackOwner.generation)) {
                    g_rdpAudioAdmission.reset();
                    g_rdpAudioCallback = nullptr;
                }
            } else if (g_rdpAudioCallbackOwner == impl_->ownerSnapshot()) {
                g_rdpAudioCallbackOwner = Render::DecoderSessionIdentity {};
                g_rdpAudioCallback = nullptr;
                g_rdpAudioAdmission.reset();
            }
        }
        if (oldAudioAdmission) {
            (void)closeRdpCallbackAdmission(oldAudioAdmission, "audio-callback-rebind");
        }
    }
}
void FreeRdpAdapter::setConnectionStateCallback(ConnectionStateCallback cb) {
    std::lock_guard<std::mutex> lock(impl_->stateMutex);
    impl_->stateCallback = std::move(cb);
}

void FreeRdpAdapter::setClipboardText(const std::string& t) {
    impl_->clipboardText = t;
    if (impl_->fileClipboard) {
        impl_->fileClipboard->clearLocalFiles();
        if (impl_->cliprdr) {
            impl_->fileClipboard->sendCurrentFormatList(true);
        }
    }
}
bool FreeRdpAdapter::setClipboardFiles(const std::vector<std::string>& paths) {
    if (!impl_->fileClipboard || !impl_->cliprdr) {
        return false;
    }
    return impl_->fileClipboard->publishLocalFiles(paths) ==
        RdpFileClipboardOfferResult::Ready;
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
    RemoteCursorStore       cursorStore;
    mutable std::mutex      ownerMutex;
    Render::DecoderSessionIdentity owner;
    mutable std::mutex videoTelemetryMutex;
    RdpVideoTelemetryCallback videoTelemetryCallback;
#if defined(RDP_NATIVE_CALLBACK_TESTING) && defined(USE_REAL_FREERDP)
    mutable std::mutex callbackTestMutex;
    std::function<void()> endPaintBarrier;
#endif

    Render::DecoderSessionIdentity ownerSnapshot() const {
        std::lock_guard<std::mutex> lock(ownerMutex);
        return owner;
    }

    RdpVideoTelemetryCallback videoTelemetryCallbackSnapshot() const {
        std::lock_guard<std::mutex> lock(videoTelemetryMutex);
        return videoTelemetryCallback;
    }

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

void FreeRdpAdapter::setSessionIdentity(uint64_t sessionId) {
    impl_->cursorStore.reset(sessionId, "rdp");
    impl_->cursorStore.setDefaultShape();
    impl_->cursorStore.setVisible(true);
}

void FreeRdpAdapter::setSessionOwner(const Render::DecoderSessionIdentity& owner) {
    std::lock_guard<std::mutex> ownerLock(impl_->ownerMutex);
    impl_->owner = owner;
}

RemoteCursorSnapshot FreeRdpAdapter::getRemoteCursorSnapshot(bool includePixels) {
    return impl_->cursorStore.snapshot(includePixels);
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
    {
        std::lock_guard<std::mutex> lock(impl_->configMutex);
        impl_->config = cfg;
    }
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
    impl_->cursorStore.setVisible(false);
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
void FreeRdpAdapter::setVideoTelemetryCallback(RdpVideoTelemetryCallback callback) {
    std::lock_guard<std::mutex> lock(impl_->videoTelemetryMutex);
    impl_->videoTelemetryCallback = std::move(callback);
}
void FreeRdpAdapter::setAudioCallback(AudioDataCallback cb) { impl_->audioCallback = std::move(cb); }
void FreeRdpAdapter::setConnectionStateCallback(ConnectionStateCallback cb) { impl_->stateCallback = std::move(cb); }

void FreeRdpAdapter::setClipboardText(const std::string& t) { impl_->clipboardText = t; }
bool FreeRdpAdapter::setClipboardFiles(const std::vector<std::string>&) { return false; }
void FreeRdpAdapter::sendClipboardData(const uint8_t* data, uint32_t len) {
    if (data == nullptr || len == 0) return;
    setClipboardText(std::string(reinterpret_cast<const char*>(data), len));
}
std::string FreeRdpAdapter::getClipboardText() { return impl_->clipboardText; }
bool FreeRdpAdapter::isClipboardReceiveReady() { return false; }
bool FreeRdpAdapter::supportsFileTransfer() { return false; }
SessionTransferStatus FreeRdpAdapter::getSessionTransferStatus() {
    // The no-real build has no cliprdr/rdpdr channel; report the neutral
    // status instead of claiming a transfer capability it cannot service.
    return SessionTransferStatus();
}

void registerFreeRdpAdapter() {
    auto adapter = std::shared_ptr<FreeRdpAdapter>(new FreeRdpAdapter());
    ExtensionSystem::instance().protocols.registerExt("protocol", "rdp", adapter);
    OH_LOG_INFO(LOG_APP, "[RDP] FreeRDP skeleton adapter registered");
}

#endif // USE_REAL_FREERDP
