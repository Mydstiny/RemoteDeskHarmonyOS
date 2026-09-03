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
#include "common/happy_eyeballs_connector.h"
#include "common/endpoint_address_policy.h"
#include "common/network_generation_fence.h"
#include "rdp_audio_policy.h"
#include "rdp_auth_identity_policy.h"
#include "rdp_auth_mode_policy.h"
#include "rdp_connection_identity_policy.h"
#include "rdp_background_frame_cache.h"
#include "rdp_certificate_validation.h"
#include "rdp_certificate_policy.h"
#include "rdp_display_layout_policy.h"
#include "rdp_frame_pump.h"
#include "rdp_file_clipboard_bridge.h"
#include "rdp_graphics_lifecycle.h"
#include "rdp_keymap.h"
#include "rdp_negotiation_parser.h"
#include "rdp_network_action_gate.h"
#include "rdp_network_recovery_policy.h"
#include "rdp_platform_retirement_gate.h"
#include "rdp_reconnect_credential_policy.h"
#include "rdp_teardown_retirement_fence.h"
#include "rdp_performance_policy.h"
#include "rdp_redraw_notifier.h"
#include "rdp_input_queue.h"
#include "rdp_shutdown_state.h"
#ifdef USE_REAL_FREERDP
#if defined(CHANNEL_DISP_CLIENT)
#include <freerdp/channels/disp.h>
#endif
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/codec/color.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/message.h>
#include <winpr/collections.h>
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
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <ctime>
#include <cstring>
#include <deque>
#include <functional>
#include <iomanip>
#include <limits>
#include <optional>
#include <sstream>
#include <thread>
#include <utility>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "RDP_ADAPTER"

namespace {

bool isIpAddressLiteral(const std::string& input) {
    std::string value = input;
    if (value.size() >= 2U && value.front() == '[' && value.back() == ']') {
        value = value.substr(1U, value.size() - 2U);
    }
    const std::size_t scope = value.find('%');
    if (scope != std::string::npos) { value.resize(scope); }
    in_addr ipv4{};
    in6_addr ipv6{};
    return inet_pton(AF_INET, value.c_str(), &ipv4) == 1 ||
        inet_pton(AF_INET6, value.c_str(), &ipv6) == 1;
}

constexpr int kDefaultRdpPort = 3389;
constexpr int kRdpCertFlagUntrustedRoot = 0x01;
constexpr int kRdpCertFlagHostMismatch = 0x02;

struct RdpNetworkWorkerCompletionGuard final {
    std::shared_ptr<std::atomic<bool>> done;
    std::condition_variable& completion;

    ~RdpNetworkWorkerCompletionGuard() {
        if (done) {
            done->store(true, std::memory_order_release);
        }
        completion.notify_all();
    }
};

bool resolveRdpEndpointRoute(const ConnectionConfig& cfg,
                             RdpEndpointRoute& route,
                             std::string& errorCode,
                             std::string& errorMessage) {
    RdpEndpointMode mode = RdpEndpointMode::DirectRdp;
    if (!RdpGatewayPolicy::parseEndpointMode(cfg.rdpEndpointMode, mode)) {
        errorCode = "E-RDP-ENDPOINT";
        errorMessage = "RDP endpoint mode is unknown";
        return false;
    }
    // Empty mode is reserved for legacy handoffs.  A legacy gateway field is
    // migrated to the standard Microsoft route; it is never treated as a
    // transparent TCP endpoint or as an arbitrary HTTPS proxy.
    if (cfg.rdpEndpointMode.empty() && !cfg.gatewayHost.empty()) {
        mode = RdpEndpointMode::MicrosoftRdGateway;
    }
    RdpGatewayTransport transport = RdpGatewayTransport::Auto;
    if (!RdpGatewayPolicy::parseGatewayTransport(cfg.rdpGatewayTransport, transport)) {
        errorCode = "E-RDP-ENDPOINT";
        errorMessage = "RDP Gateway transport is unknown";
        return false;
    }

    if (!cfg.targetServerName.empty() && !cfg.customHostname.empty() &&
        cfg.targetServerName != cfg.customHostname) {
        errorCode = "E-RDP-IDENTITY";
        errorMessage = "RDP target server identity is ambiguous";
        return false;
    }
    if (!RdpConnectionIdentityPolicy::clientHostnameIsValid(cfg.clientHostname)) {
        errorCode = "E-RDP-CLIENT-HOSTNAME";
        errorMessage = "RDP client hostname is invalid";
        return false;
    }

    route.endpointMode = mode;
    route.targetPort = cfg.port > 0 ? cfg.port : kDefaultRdpPort;
    route.gatewayPort = cfg.gatewayPort > 0 ? cfg.gatewayPort : 443;
    if (route.targetPort <= 0 || route.targetPort > 65535 ||
        route.gatewayPort <= 0 || route.gatewayPort > 65535) {
        errorCode = "E-RDP-ENDPOINT";
        errorMessage = "RDP endpoint port is invalid";
        return false;
    }
    const auto targetEndpoint = remotedesk::endpoint::ParseFields(
        cfg.host, static_cast<std::uint16_t>(route.targetPort),
        remotedesk::endpoint::ParseMode::Persisted);
    if (!targetEndpoint.ok) {
        errorCode = "E-RDP-ENDPOINT";
        errorMessage = "RDP target endpoint is invalid";
        return false;
    }
    if (!RdpGatewayPolicy::targetInterfaceScopeIsAllowed(
            mode, !targetEndpoint.endpoint.scope().empty())) {
        errorCode = "E-RDP-GATEWAY-TARGET-SCOPE";
        errorMessage = "RD Gateway target cannot use this device's interface scope";
        return false;
    }
    route.targetHost = remotedesk::endpoint::TransportHost(targetEndpoint.endpoint);
    const std::string configuredTargetName = cfg.targetServerName.empty()
        ? cfg.customHostname : cfg.targetServerName;
    const auto targetIdentity = remotedesk::endpoint::ParseServerIdentity(
        configuredTargetName.empty() ? targetEndpoint.endpoint.canonicalHost() :
            configuredTargetName);
    if (!targetIdentity.ok ||
        targetIdentity.identity.kind() == remotedesk::endpoint::ServerIdentityKind::None) {
        errorCode = "E-RDP-IDENTITY";
        errorMessage = "RDP target server identity is invalid";
        return false;
    }
    route.targetServerName = targetIdentity.identity.canonicalName();
    route.gatewayTransport = transport;

    if (route.targetHost.empty()) {
        errorCode = "E-RDP-ENDPOINT";
        errorMessage = "RDP target host is empty";
        return false;
    }
    if (mode == RdpEndpointMode::MicrosoftRdGateway) {
        if (cfg.gatewayHost.empty()) {
            errorCode = "E-RDP-ENDPOINT";
            errorMessage = "Microsoft RD Gateway requires gatewayHost";
            return false;
        }
        const auto gatewayEndpoint = remotedesk::endpoint::ParseFields(
            cfg.gatewayHost, static_cast<std::uint16_t>(route.gatewayPort),
            remotedesk::endpoint::ParseMode::Persisted);
        if (!gatewayEndpoint.ok) {
            errorCode = "E-RDP-ENDPOINT";
            errorMessage = "RDP Gateway endpoint is invalid";
            return false;
        }
        route.gatewayHost = remotedesk::endpoint::TransportHost(gatewayEndpoint.endpoint);
        const auto gatewayIdentity = remotedesk::endpoint::ParseServerIdentity(
            cfg.rdpGatewayServerName.empty() ? gatewayEndpoint.endpoint.canonicalHost() :
                cfg.rdpGatewayServerName);
        if (!gatewayIdentity.ok ||
            gatewayIdentity.identity.kind() == remotedesk::endpoint::ServerIdentityKind::None) {
            errorCode = "E-RDP-GATEWAY-SNI";
            errorMessage = "RDP Gateway server identity is invalid";
            return false;
        }
        route.gatewayServerName = gatewayIdentity.identity.canonicalName();
        if (!RdpGatewayPolicy::restrictedAdminGatewayRouteIsSupported(
                mode, cfg.rdpAuthMode == RdpAuthenticationMode::RestrictedAdmin)) {
            errorCode = "E-RDP-GATEWAY-AUTH";
            errorMessage = "Restricted Admin requires a separate RD Gateway password credential";
            return false;
        }
    } else if (RdpGatewayPolicy::isGatewayRoute(mode)) {
        errorCode = "E-RDP-BASTION-UNSUPPORTED";
        errorMessage = std::string("RDP endpoint mode is not supported: ") +
            RdpGatewayPolicy::endpointModeName(mode);
        return false;
    } else if (!cfg.gatewayHost.empty() || !cfg.rdpGatewayServerName.empty()) {
        errorCode = "E-RDP-ENDPOINT";
        errorMessage = "gatewayHost cannot be used with a direct RDP route";
        return false;
    }
    return true;
}

RdpPreflightResult makeRdpPreflightError(const RdpPreflightRequest& request,
                                         const std::string& stage,
                                         const std::string& errorCode,
                                         const std::string& errorMessage) {
    RdpPreflightResult result;
    result.endpointMode = request.route.endpointMode;
    result.routeIdentity = RdpGatewayPolicy::routeIdentity(request.route);
    result.generation = request.generation;
    result.requestId = request.requestId;
    result.stage = stage;
    result.errorCode = errorCode;
    result.errorMessage = errorMessage;
    const RdpPreflightPolicy::ProbeFailureClassification classification =
        RdpPreflightPolicy::classifyErrorCode(errorCode, errorMessage);
    result.preflightStatus = classification.status;
    result.riskFlags = classification.riskFlags;
    if (stage == "gateway" || stage == "tunnel") {
        result.gatewayRiskFlags = classification.riskFlags;
    } else if (stage == "target" || stage == "target_cert" || stage == "negotiation") {
        result.targetRiskFlags = classification.riskFlags;
    }
    if (stage == "gateway" && !classification.riskFlags.empty()) {
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.riskFlags, RdpPreflightPolicy::kRiskGatewayCertificate);
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.gatewayRiskFlags, RdpPreflightPolicy::kRiskGatewayCertificate);
    }
    if ((stage == "target" || stage == "target_cert" || stage == "negotiation") &&
        !classification.riskFlags.empty()) {
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.riskFlags, RdpPreflightPolicy::kRiskTargetCertificate);
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.targetRiskFlags, RdpPreflightPolicy::kRiskTargetCertificate);
    }
    RdpGatewayPolicy::initializeGatewayTransportResult(
        result, request.route.gatewayTransport);
    result.requiresUserDecision = RdpPreflightPolicy::preflightAllowsRealConnection(
        result.preflightStatus, errorCode, result.riskFlags);
    return result;
}

const char* directRdpPreflightStage(int errorCode) {
    switch (errorCode) {
        case -39:
            return "network";
        case -10:
        case -11:
            return "endpoint";
        case -12:
            return "target_tcp";
        case -13:
            return "negotiation";
        case -14:
            return "target_tcp";
        case -18:
        case -19:
        case -20:
        case -21:
            return "negotiation";
        case -15:
        case -16:
        case -22:
        case -23:
        case -24:
            return "target";
        case -17:
        case -25:
            return "target_cert";
        default:
            return "target";
    }
}

const char* directRdpPreflightErrorCode(int errorCode) {
    switch (errorCode) {
        case -39:
            return "E-RDP-NETWORK-CHANGED";
        case -10:
            return "E-RDP-ENDPOINT";
        case -11:
            return "E-RDP-TARGET-DNS";
        case -12:
            return "E-RDP-TARGET-TCP";
        case -13:
            return "E-RDP-NEGOTIATION";
        case -14:
            return "E-RDP-TARGET-TIMEOUT";
        case -18:
        case -19:
        case -20:
        case -21:
            return "E-RDP-NEGOTIATION";
        case -15:
        case -16:
        case -22:
        case -23:
        case -24:
            return "E-RDP-TARGET-TLS";
        case -17:
        case -25:
            return "E-RDP-TARGET-CERT";
        default:
            return "E-RDP-TARGET-TLS";
    }
}

bool directRdpPreflightCanTryRealConnection(const RdpCertificateInfo& info) {
    if (info.errorCode == -39) {
        return false;
    }
    return RdpPreflightPolicy::preflightAllowsRealConnection(
        info.preflightStatus, directRdpPreflightErrorCode(info.errorCode), info.riskFlags);
}

using RdpShutdownDeadline = std::chrono::steady_clock::time_point;
constexpr auto kRdpNetworkTeardownRetirementTimeout =
    std::chrono::seconds(5);

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
    RdpReconnectCredentialPolicy::secureClear(value);
}

struct RdpReconnectSecretGuard final {
    ConnectionConfig& config;

    ~RdpReconnectSecretGuard() {
        secureClearString(config.password);
        secureClearString(config.rdpRestrictedAdminHash);
    }
};

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

void secureClearFreeRdpSettingString(
    rdpSettings* settings, FreeRDP_Settings_Keys_String key) {
    if (!settings) {
        return;
    }
    char* value = freerdp_settings_get_string_writable(settings, key);
    if (value) {
        volatile char* bytes = value;
        const size_t length = std::strlen(value);
        for (size_t index = 0; index < length; ++index) {
            bytes[index] = '\0';
        }
    }
    // Release the settings-owned allocation only after its visible bytes have
    // been overwritten. Ignore a replacement allocation failure during final
    // teardown: the original buffer has already been cleared.
    (void)freerdp_settings_set_string(settings, key, "");
}

void secureClearFreeRdpCredentials(rdpSettings* settings) {
    secureClearFreeRdpSettingString(settings, FreeRDP_Username);
    secureClearFreeRdpSettingString(settings, FreeRDP_Password);
    secureClearFreeRdpSettingString(settings, FreeRDP_Domain);
    secureClearFreeRdpSettingString(settings, FreeRDP_GatewayUsername);
    secureClearFreeRdpSettingString(settings, FreeRDP_GatewayPassword);
    secureClearFreeRdpSettingString(settings, FreeRDP_GatewayDomain);
    secureClearFreeRdpPasswordHash(settings);
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

bool asn1TimeToMillis(const ASN1_TIME* value, int64_t& output) {
    if (value == nullptr) {
        return false;
    }
    struct tm calendarTime {};
    if (ASN1_TIME_to_tm(value, &calendarTime) != 1) {
        return false;
    }
    const time_t seconds = timegm(&calendarTime);
    if (seconds < 0 || static_cast<int64_t>(seconds) >
        (std::numeric_limits<int64_t>::max() / 1000)) {
        return false;
    }
    output = static_cast<int64_t>(seconds) * 1000;
    return true;
}

bool x509ValidityToMillis(X509* cert, int64_t& notBeforeMs, int64_t& notAfterMs) {
    return cert != nullptr &&
        asn1TimeToMillis(X509_get0_notBefore(cert), notBeforeMs) &&
        asn1TimeToMillis(X509_get0_notAfter(cert), notAfterMs) &&
        notAfterMs > notBeforeMs;
}

[[maybe_unused]] bool x509ValidityIsCurrent(X509* cert) {
    int64_t notBeforeMs = 0;
    int64_t notAfterMs = 0;
    if (!x509ValidityToMillis(cert, notBeforeMs, notAfterMs)) {
        return false;
    }
    const int64_t nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    return nowMs >= notBeforeMs && nowMs <= notAfterMs;
}

void annotateCertificateValidity(X509* cert, RdpCertificateInfo& info) {
    const bool notBeforeParsed = cert != nullptr &&
        asn1TimeToMillis(X509_get0_notBefore(cert), info.notBeforeMs);
    const bool notAfterParsed = cert != nullptr &&
        asn1TimeToMillis(X509_get0_notAfter(cert), info.notAfterMs);
    if (!notBeforeParsed || !notAfterParsed || info.notAfterMs <= info.notBeforeMs) {
        RdpPreflightPolicy::addUniqueRiskFlag(
            info.riskFlags, RdpPreflightPolicy::kRiskCertificateTimeInvalid);
        info.errorCode = -25;
        info.errorMessage = "RDP certificate validity metadata is unavailable";
        return;
    }
    const int64_t nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    if (nowMs < info.notBeforeMs || nowMs > info.notAfterMs) {
        RdpPreflightPolicy::addUniqueRiskFlag(
            info.riskFlags, RdpPreflightPolicy::kRiskCertificateTimeInvalid);
        info.errorCode = -25;
        info.errorMessage = "RDP certificate is expired or not yet valid";
    }
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
    const RdpPreflightPolicy::ProbeFailureClassification classification =
        RdpPreflightPolicy::classifyProbeFailure(code, message);
    info.preflightStatus = classification.status;
    info.riskFlags = classification.riskFlags;
    OH_LOG_WARN(LOG_APP, "[RDP-CERT] probe failed host=%{public}s:%{public}d code=%{public}d msg=%{public}s",
                SafeLog::MaskHost(host).c_str(), info.port, code, message.c_str());
    return info;
}

bool rdpProbeCancelled(const std::function<bool()>& cancelled) {
    return cancelled && cancelled();
}

RdpCertificateInfo makeNetworkChangedProbeError(
    const std::string& host, int port) {
    return makeProbeError(
        host, port, -39,
        "RDP preflight cancelled because the default network changed "
        "[E-RDP-NETWORK-CHANGED]");
}

std::string openSslErrorStack() {
    std::ostringstream details;
    bool first = true;
    for (unsigned long error = ERR_get_error(); error != 0; error = ERR_get_error()) {
        char buffer[256] = {0};
        ERR_error_string_n(error, buffer, sizeof(buffer));
        if (!first) {
            details << "; ";
        }
        details << buffer;
        first = false;
    }
    return details.str();
}

const char* sslErrorName(int sslError) {
    switch (sslError) {
        case SSL_ERROR_NONE:
            return "SSL_ERROR_NONE";
        case SSL_ERROR_WANT_READ:
            return "SSL_ERROR_WANT_READ";
        case SSL_ERROR_WANT_WRITE:
            return "SSL_ERROR_WANT_WRITE";
        case SSL_ERROR_WANT_X509_LOOKUP:
            return "SSL_ERROR_WANT_X509_LOOKUP";
        case SSL_ERROR_SYSCALL:
            return "SSL_ERROR_SYSCALL";
        case SSL_ERROR_SSL:
            return "SSL_ERROR_SSL";
        case SSL_ERROR_ZERO_RETURN:
            return "SSL_ERROR_ZERO_RETURN";
        default:
            return "SSL_ERROR_UNKNOWN";
    }
}

bool waitForFdUntil(int fd, bool writable,
                    std::chrono::steady_clock::time_point deadline,
                    int& errorCode,
                    const std::function<bool()>& cancelled) {
    for (;;) {
        if (rdpProbeCancelled(cancelled)) {
            errorCode = ECANCELED;
            return false;
        }
        const auto now = std::chrono::steady_clock::now();
        if (now >= deadline) {
            errorCode = ETIMEDOUT;
            return false;
        }
        const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
            deadline - now);
        const auto slice = std::min(remaining, std::chrono::milliseconds(50));
        const auto sliceUs = std::max<int64_t>(
            1, std::chrono::duration_cast<std::chrono::microseconds>(slice).count());
        timeval timeout {};
        timeout.tv_sec = static_cast<long>(sliceUs / 1000000);
        timeout.tv_usec = static_cast<long>(sliceUs % 1000000);
        fd_set readSet;
        fd_set writeSet;
        FD_ZERO(&readSet);
        FD_ZERO(&writeSet);
        if (writable) {
            FD_SET(fd, &writeSet);
        } else {
            FD_SET(fd, &readSet);
        }
        const int result = select(
            fd + 1, writable ? nullptr : &readSet,
            writable ? &writeSet : nullptr, nullptr, &timeout);
        if (result > 0) {
            return true;
        }
        if (result == 0 || errno == EINTR) {
            continue;
        }
        errorCode = errno;
        return false;
    }
}

bool sendAll(int fd, const uint8_t* data, size_t size,
             std::chrono::steady_clock::time_point deadline,
             int& errorCode, const std::function<bool()>& cancelled) {
    errorCode = 0;
    size_t sent = 0;
    while (sent < size) {
        if (rdpProbeCancelled(cancelled)) {
            errorCode = ECANCELED;
            return false;
        }
        const ssize_t n = send(fd, data + sent, size - sent, 0);
        if (n > 0) {
            sent += static_cast<size_t>(n);
            continue;
        }
        if (n == 0) {
            errorCode = ECONNRESET;
            return false;
        }
        if (errno == EINTR) {
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            if (waitForFdUntil(fd, true, deadline, errorCode, cancelled)) {
                continue;
            }
            return false;
        }
        errorCode = errno;
        return false;
    }
    return true;
}

bool waitForReadableUntil(int fd, std::chrono::steady_clock::time_point deadline,
                          int& errorCode,
                          const std::function<bool()>& cancelled) {
    return waitForFdUntil(fd, false, deadline, errorCode, cancelled);
}

bool recvExactWithDeadline(int fd, uint8_t* data, size_t size, int timeoutMs,
                           int& errorCode,
                           const std::function<bool()>& cancelled) {
    const auto deadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(timeoutMs);
    size_t received = 0;
    while (received < size) {
        if (!waitForReadableUntil(fd, deadline, errorCode, cancelled)) {
            return false;
        }
        const ssize_t count = recv(fd, data + received, size - received, 0);
        if (count > 0) {
            received += static_cast<size_t>(count);
            continue;
        }
        if (count == 0) {
            errorCode = ECONNRESET;
            return false;
        }
        if (errno != EINTR) {
            errorCode = errno;
            return false;
        }
    }
    return true;
}

RdpCertificateInfo probeGatewayCertificateOverTls(const std::string& host, int port,
                                                   const std::string& serverName,
                                                   const std::function<bool()>& cancelled) {
    const int effectivePort = port > 0 ? port : 443;
    const std::string verifyName = serverName.empty() ? host : serverName;
    if (rdpProbeCancelled(cancelled)) {
        return makeNetworkChangedProbeError(host, effectivePort);
    }
    if (host.empty()) {
        return makeProbeError(host, effectivePort, -30, "RD Gateway host is empty");
    }

    const std::string portText = std::to_string(effectivePort);
    remotedesk::net::ConnectOptions connectOptions;
    connectOptions.deadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(5000);
    connectOptions.cancelled = cancelled;
    connectOptions.restoreBlocking = false;
    remotedesk::net::ConnectResult connection;
    const remotedesk::net::ResolveResult resolution =
        remotedesk::net::ResolveAndConnectTcp(
            host, portText, connectOptions, connection);
    if (resolution.status != remotedesk::net::ResolveStatus::Ready) {
        if (resolution.status == remotedesk::net::ResolveStatus::Cancelled ||
            rdpProbeCancelled(cancelled)) {
            return makeNetworkChangedProbeError(host, effectivePort);
        }
        return makeProbeError(host, effectivePort, -31, "Unable to resolve RD Gateway host");
    }
    if (connection.status != remotedesk::net::ConnectStatus::Connected ||
        connection.descriptor < 0) {
        if (connection.status == remotedesk::net::ConnectStatus::Cancelled ||
            rdpProbeCancelled(cancelled)) {
            return makeNetworkChangedProbeError(host, effectivePort);
        }
        return makeProbeError(host, effectivePort, -32, "Unable to connect to RD Gateway");
    }
    const int fd = connection.descriptor;
    timeval timeout {};
    timeout.tv_sec = 8;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    SSL_CTX* sslCtx = SSL_CTX_new(TLS_client_method());
    if (sslCtx == nullptr) {
        close(fd);
        return makeProbeError(host, effectivePort, -33,
                              "Unable to create RD Gateway TLS context");
    }
    SSL_CTX_set_verify(sslCtx, SSL_VERIFY_NONE, nullptr);
    SSL* ssl = SSL_new(sslCtx);
    if (ssl == nullptr) {
        SSL_CTX_free(sslCtx);
        close(fd);
        return makeProbeError(host, effectivePort, -34,
                              "Unable to create RD Gateway TLS session");
    }
    if (SSL_set_fd(ssl, fd) != 1 ||
        (!verifyName.empty() && !isIpAddressLiteral(verifyName) &&
         SSL_set_tlsext_host_name(ssl, verifyName.c_str()) != 1)) {
        SSL_free(ssl);
        SSL_CTX_free(sslCtx);
        close(fd);
        return makeProbeError(host, effectivePort, -35,
                              "Unable to configure RD Gateway TLS session");
    }
    const auto tlsDeadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(8000);
    int tlsResult = -1;
    int sslError = SSL_ERROR_NONE;
    int waitError = 0;
    while (!rdpProbeCancelled(cancelled) &&
           std::chrono::steady_clock::now() < tlsDeadline) {
        ERR_clear_error();
        errno = 0;
        tlsResult = SSL_connect(ssl);
        if (tlsResult == 1) {
            break;
        }
        sslError = SSL_get_error(ssl, tlsResult);
        if (sslError == SSL_ERROR_WANT_READ) {
            if (!waitForFdUntil(fd, false, tlsDeadline, waitError, cancelled)) {
                break;
            }
            continue;
        }
        if (sslError == SSL_ERROR_WANT_WRITE) {
            if (!waitForFdUntil(fd, true, tlsDeadline, waitError, cancelled)) {
                break;
            }
            continue;
        }
        break;
    }
    if (tlsResult != 1) {
        if (rdpProbeCancelled(cancelled) || waitError == ECANCELED) {
            SSL_free(ssl);
            SSL_CTX_free(sslCtx);
            close(fd);
            return makeNetworkChangedProbeError(host, effectivePort);
        }
        if (sslError == SSL_ERROR_NONE) {
            sslError = SSL_get_error(ssl, tlsResult);
        }
        const int socketError = sslError == SSL_ERROR_SYSCALL ? errno : 0;
        const std::string opensslDetails = openSslErrorStack();
        std::ostringstream message;
        message << "RD Gateway TLS handshake failed (sslError="
                << sslErrorName(sslError) << ":" << sslError;
        if (!opensslDetails.empty()) {
            message << ", openssl=" << opensslDetails;
        }
        if (socketError != 0) {
            message << ", errno=" << socketError << ":" << std::strerror(socketError);
        }
        message << ")";
        SSL_free(ssl);
        SSL_CTX_free(sslCtx);
        close(fd);
        return makeProbeError(host, effectivePort, -36, message.str());
    }

    if (rdpProbeCancelled(cancelled)) {
        SSL_free(ssl);
        SSL_CTX_free(sslCtx);
        close(fd);
        return makeNetworkChangedProbeError(host, effectivePort);
    }

    X509* certificate = SSL_get_peer_certificate(ssl);
    if (certificate == nullptr) {
        SSL_free(ssl);
        SSL_CTX_free(sslCtx);
        close(fd);
        return makeProbeError(host, effectivePort, -37,
                              "RD Gateway did not provide a certificate");
    }

    RdpCertificateInfo info;
    info.ok = true;
    info.host = host;
    info.port = effectivePort;
    info.serverName = verifyName;
    info.commonName = x509CommonName(certificate);
    info.subject = x509NameToString(X509_get_subject_name(certificate));
    info.issuer = x509NameToString(X509_get_issuer_name(certificate));
    info.fingerprintSha256 = sha256FingerprintFromCert(certificate);
    if (info.fingerprintSha256.empty()) {
        X509_free(certificate);
        SSL_shutdown(ssl);
        SSL_free(ssl);
        SSL_CTX_free(sslCtx);
        close(fd);
        return makeProbeError(host, effectivePort, -38,
                              "RD Gateway certificate metadata is unavailable");
    }
    annotateCertificateValidity(certificate, info);
    info.hostMismatch = !RdpCertificateValidation::hostnameMatches(
        certificate, verifyName);

    X509_STORE* store = X509_STORE_new();
    X509_STORE_CTX* storeCtx = X509_STORE_CTX_new();
    STACK_OF(X509)* peerChain = SSL_get_peer_cert_chain(ssl);
    if (store != nullptr && storeCtx != nullptr &&
        X509_STORE_set_default_paths(store) == 1 &&
        X509_STORE_CTX_init(storeCtx, store, certificate, peerChain) == 1) {
        info.rootTrusted = X509_verify_cert(storeCtx) == 1;
    }
    if (!info.rootTrusted) {
        info.flags |= kRdpCertFlagUntrustedRoot;
        RdpPreflightPolicy::addUniqueRiskFlag(
            info.riskFlags, RdpPreflightPolicy::kRiskUntrustedRoot);
    }
    if (info.hostMismatch) {
        info.flags |= kRdpCertFlagHostMismatch;
        RdpPreflightPolicy::addUniqueRiskFlag(
            info.riskFlags, RdpPreflightPolicy::kRiskHostnameMismatch);
    }
    info.preflightStatus = RdpPreflightPolicy::kCompleted;
    if (storeCtx != nullptr) {
        X509_STORE_CTX_free(storeCtx);
    }
    if (store != nullptr) {
        X509_STORE_free(store);
    }
    X509_free(certificate);
    SSL_shutdown(ssl);
    SSL_free(ssl);
    SSL_CTX_free(sslCtx);
    close(fd);
    if (rdpProbeCancelled(cancelled)) {
        return makeNetworkChangedProbeError(host, effectivePort);
    }
    return info;
}

RdpCertificateInfo probeRdpCertificateOverTls(const std::string& host, int port,
                                              const std::string& serverName,
                                              const std::function<bool()>& cancelled) {
    const int effectivePort = port > 0 ? port : kDefaultRdpPort;
    const std::string verifyName = serverName.empty() ? host : serverName;
    const std::string logHost = SafeLog::MaskHost(host);
    const std::string logServerName = serverName.empty() ? "<host>" : SafeLog::MaskHost(serverName);
    const int64_t startedUs = probeNowUs();
    OH_LOG_INFO(LOG_APP, "[RDP-CERT] probe start host=%{public}s:%{public}d targetName=%{public}s",
                logHost.c_str(), effectivePort, logServerName.c_str());
    if (rdpProbeCancelled(cancelled)) {
        return makeNetworkChangedProbeError(host, effectivePort);
    }
    if (host.empty()) {
        return makeProbeError(host, effectivePort, -10, "RDP host is empty");
    }

    const std::string portText = std::to_string(effectivePort);
    remotedesk::net::ConnectOptions connectOptions;
    connectOptions.deadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(5000);
    connectOptions.cancelled = cancelled;
    connectOptions.restoreBlocking = false;
    remotedesk::net::ConnectResult connection;
    const remotedesk::net::ResolveResult resolution =
        remotedesk::net::ResolveAndConnectTcp(
            host, portText, connectOptions, connection);
    if (resolution.status != remotedesk::net::ResolveStatus::Ready) {
        if (resolution.status == remotedesk::net::ResolveStatus::Cancelled ||
            rdpProbeCancelled(cancelled)) {
            return makeNetworkChangedProbeError(host, effectivePort);
        }
        OH_LOG_WARN(LOG_APP, "[RDP-CERT] resolve failed host=%{public}s:%{public}d gai=%{public}d",
                    logHost.c_str(), effectivePort, resolution.gaiError);
        return makeProbeError(host, effectivePort, -11, "Unable to resolve RDP host");
    }
    OH_LOG_INFO(LOG_APP, "[RDP-CERT] resolve ok host=%{public}s:%{public}d", logHost.c_str(), effectivePort);

    if (connection.status != remotedesk::net::ConnectStatus::Connected ||
        connection.descriptor < 0) {
        if (connection.status == remotedesk::net::ConnectStatus::Cancelled ||
            rdpProbeCancelled(cancelled)) {
            return makeNetworkChangedProbeError(host, effectivePort);
        }
        OH_LOG_WARN(LOG_APP, "[RDP-CERT] tcp connect failed host=%{public}s:%{public}d err=%{public}d elapsedMs=%{public}lld",
                    logHost.c_str(), effectivePort, connection.lastError,
                    static_cast<long long>((probeNowUs() - startedUs) / 1000));
        return makeProbeError(host, effectivePort, -12, "Unable to connect to RDP host");
    }
    const int fd = connection.descriptor;
    timeval tv {};
    tv.tv_sec = 8;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    OH_LOG_INFO(LOG_APP, "[RDP-CERT] tcp connected host=%{public}s:%{public}d elapsedMs=%{public}lld",
                logHost.c_str(), effectivePort,
                static_cast<long long>((probeNowUs() - startedUs) / 1000));

    static const uint8_t kNegotiateTls[] = {
        0x03, 0x00, 0x00, 0x13,
        0x0e, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x08, 0x00,
        0x03, 0x00, 0x00, 0x00
    };
    int sendError = 0;
    const auto negotiationDeadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(8000);
    if (!sendAll(fd, kNegotiateTls, sizeof(kNegotiateTls),
                 negotiationDeadline, sendError, cancelled)) {
        close(fd);
        if (sendError == ECANCELED || rdpProbeCancelled(cancelled)) {
            return makeNetworkChangedProbeError(host, effectivePort);
        }
        std::ostringstream message;
        message << "Unable to send RDP negotiation request";
        if (sendError != 0) {
            message << " (errno=" << sendError << ":" << std::strerror(sendError) << ")";
        }
        return makeProbeError(host, effectivePort, -13, message.str());
    }
    OH_LOG_INFO(LOG_APP, "[RDP-CERT] negotiation request sent host=%{public}s:%{public}d",
                logHost.c_str(), effectivePort);

    constexpr int kNegotiationReadTimeoutMs = 8000;
    RdpNegotiation::RdpTpktAccumulator accumulator;
    uint8_t tpktHeader[RdpNegotiation::RdpTpktAccumulator::kHeaderSize] = {0};
    int readError = 0;
    if (!recvExactWithDeadline(fd, tpktHeader, sizeof(tpktHeader),
                               kNegotiationReadTimeoutMs, readError, cancelled) ||
        !accumulator.append(tpktHeader, sizeof(tpktHeader))) {
        close(fd);
        if (readError == ECANCELED || rdpProbeCancelled(cancelled)) {
            return makeNetworkChangedProbeError(host, effectivePort);
        }
        std::ostringstream message;
        message << "Unable to read RDP negotiation response";
        if (readError != 0) {
            message << " (errno=" << readError << ":" << std::strerror(readError) << ")";
        }
        return makeProbeError(host, effectivePort, -14, message.str());
    }

    const size_t expectedLength = accumulator.expectedLength();
    const auto headerResult = accumulator.parse();
    if (headerResult.status == RdpNegotiation::ParseStatus::Invalid ||
        expectedLength < RdpNegotiation::RdpTpktAccumulator::kHeaderSize) {
        close(fd);
        return makeProbeError(host, effectivePort, -21,
                              "RDP negotiation TPKT header is invalid: " + headerResult.error);
    }
    if (expectedLength > RdpNegotiation::RdpTpktAccumulator::kHeaderSize) {
        std::vector<uint8_t> body(expectedLength -
                                  RdpNegotiation::RdpTpktAccumulator::kHeaderSize);
        if (!recvExactWithDeadline(fd, body.data(), body.size(),
                                   kNegotiationReadTimeoutMs, readError, cancelled) ||
            !accumulator.append(body.data(), body.size())) {
            close(fd);
            if (readError == ECANCELED || rdpProbeCancelled(cancelled)) {
                return makeNetworkChangedProbeError(host, effectivePort);
            }
            std::ostringstream message;
            message << "Unable to read complete RDP negotiation response";
            if (readError != 0) {
                message << " (errno=" << readError << ":" << std::strerror(readError) << ")";
            }
            return makeProbeError(host, effectivePort, -14, message.str());
        }
    }

    const auto negotiation = accumulator.parse();
    if (negotiation.status != RdpNegotiation::ParseStatus::Complete) {
        close(fd);
        return makeProbeError(host, effectivePort, -21,
                              "RDP negotiation response is invalid: " + negotiation.error);
    }
    OH_LOG_INFO(LOG_APP,
                "[RDP-CERT] negotiation response received host=%{public}s:%{public}d bytes=%{public}zu kind=%{public}d",
                logHost.c_str(), effectivePort, accumulator.size(),
                static_cast<int>(negotiation.kind));

    if (negotiation.kind == RdpNegotiation::ResponseKind::NoNegotiationData) {
        close(fd);
        return makeProbeError(
            host, effectivePort, -18,
            "RDP server selected Standard RDP Security; TLS certificate probe is unavailable");
    }
    if (negotiation.kind == RdpNegotiation::ResponseKind::NegotiationFailure) {
        std::ostringstream message;
        message << "RDP security negotiation failed: "
                << RdpNegotiation::failureCodeName(negotiation.failureCode)
                << " (0x" << std::hex << negotiation.failureCode << ")";
        close(fd);
        return makeProbeError(host, effectivePort, -19, message.str());
    }
    if (negotiation.kind != RdpNegotiation::ResponseKind::NegotiationResponse) {
        close(fd);
        return makeProbeError(host, effectivePort, -21,
                              "RDP negotiation response has an unsupported type");
    }
    OH_LOG_INFO(LOG_APP,
                "[RDP-CERT] selected security protocol host=%{public}s:%{public}d protocol=0x%{public}08X name=%{public}s",
                logHost.c_str(), effectivePort, negotiation.selectedProtocol,
                RdpNegotiation::selectedProtocolName(negotiation.selectedProtocol));
    if (!RdpNegotiation::isTlsProtocol(negotiation.selectedProtocol)) {
        std::ostringstream message;
        if (negotiation.selectedProtocol == RdpNegotiation::kProtocolRdp) {
            message << "RDP server selected Standard RDP Security; TLS certificate probe is unavailable";
        } else {
            message << "RDP server selected unsupported security protocol "
                    << RdpNegotiation::selectedProtocolName(negotiation.selectedProtocol)
                    << " (0x" << std::hex << negotiation.selectedProtocol << ")";
        }
        close(fd);
        return makeProbeError(host, effectivePort,
                              negotiation.selectedProtocol == RdpNegotiation::kProtocolRdp ? -18 : -20,
                              message.str());
    }

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
    ERR_clear_error();
    errno = 0;
    if (SSL_set_fd(ssl, fd) != 1) {
        const std::string opensslDetails = openSslErrorStack();
        SSL_free(ssl);
        SSL_CTX_free(sslCtx);
        close(fd);
        const std::string message = opensslDetails.empty()
            ? "Unable to bind RDP TLS socket"
            : "Unable to bind RDP TLS socket (openssl=" + opensslDetails + ")";
        return makeProbeError(host, effectivePort, -23, message);
    }
    if (!verifyName.empty() && !isIpAddressLiteral(verifyName)) {
        ERR_clear_error();
        errno = 0;
        if (SSL_set_tlsext_host_name(ssl, verifyName.c_str()) != 1) {
            const std::string opensslDetails = openSslErrorStack();
            SSL_free(ssl);
            SSL_CTX_free(sslCtx);
            close(fd);
            const std::string message = opensslDetails.empty()
                ? "Unable to set RDP TLS server name"
                : "Unable to set RDP TLS server name (openssl=" + opensslDetails + ")";
            return makeProbeError(host, effectivePort, -24, message);
        }
    }
    const auto tlsDeadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(8000);
    int tlsResult = -1;
    int sslError = SSL_ERROR_NONE;
    int waitError = 0;
    while (!rdpProbeCancelled(cancelled) &&
           std::chrono::steady_clock::now() < tlsDeadline) {
        ERR_clear_error();
        errno = 0;
        tlsResult = SSL_connect(ssl);
        if (tlsResult == 1) {
            break;
        }
        sslError = SSL_get_error(ssl, tlsResult);
        if (sslError == SSL_ERROR_WANT_READ) {
            if (!waitForFdUntil(fd, false, tlsDeadline, waitError, cancelled)) {
                break;
            }
            continue;
        }
        if (sslError == SSL_ERROR_WANT_WRITE) {
            if (!waitForFdUntil(fd, true, tlsDeadline, waitError, cancelled)) {
                break;
            }
            continue;
        }
        break;
    }
    if (tlsResult != 1) {
        if (rdpProbeCancelled(cancelled) || waitError == ECANCELED) {
            SSL_free(ssl);
            SSL_CTX_free(sslCtx);
            close(fd);
            return makeNetworkChangedProbeError(host, effectivePort);
        }
        if (sslError == SSL_ERROR_NONE) {
            sslError = SSL_get_error(ssl, tlsResult);
        }
        const int socketError = sslError == SSL_ERROR_SYSCALL ? errno : 0;
        const std::string opensslDetails = openSslErrorStack();
        std::ostringstream message;
        message << "RDP TLS handshake failed (sslError=" << sslErrorName(sslError)
                << ":" << sslError;
        if (!opensslDetails.empty()) {
            message << ", openssl=" << opensslDetails;
        }
        if (socketError != 0) {
            message << ", errno=" << socketError << ":" << std::strerror(socketError);
        }
        message << ")";
        SSL_free(ssl);
        SSL_CTX_free(sslCtx);
        close(fd);
        OH_LOG_WARN(LOG_APP,
                    "[RDP-CERT] tls handshake failed host=%{public}s:%{public}d sslError=%{public}d errno=%{public}d detail=%{public}s",
                    logHost.c_str(), effectivePort, sslError, socketError,
                    message.str().c_str());
        return makeProbeError(host, effectivePort, -22, message.str());
    }
    if (rdpProbeCancelled(cancelled)) {
        SSL_free(ssl);
        SSL_CTX_free(sslCtx);
        close(fd);
        return makeNetworkChangedProbeError(host, effectivePort);
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
    info.serverName = verifyName;
    info.commonName = x509CommonName(cert);
    info.subject = x509NameToString(X509_get_subject_name(cert));
    info.issuer = x509NameToString(X509_get_issuer_name(cert));
    info.fingerprintSha256 = sha256FingerprintFromCert(cert);
    if (info.fingerprintSha256.empty()) {
        X509_free(cert);
        SSL_shutdown(ssl);
        SSL_free(ssl);
        SSL_CTX_free(sslCtx);
        close(fd);
        return makeProbeError(host, effectivePort, -25,
                              "RDP certificate validity metadata is unavailable");
    }
    annotateCertificateValidity(cert, info);

    info.hostMismatch = !RdpCertificateValidation::hostnameMatches(cert, verifyName);

    X509_STORE* store = X509_STORE_new();
    X509_STORE_CTX* storeCtx = X509_STORE_CTX_new();
    STACK_OF(X509)* peerChain = SSL_get_peer_cert_chain(ssl);
    if (store && storeCtx && X509_STORE_set_default_paths(store) == 1 &&
        X509_STORE_CTX_init(storeCtx, store, cert, peerChain) == 1) {
        info.rootTrusted = X509_verify_cert(storeCtx) == 1;
    }
    if (!info.rootTrusted) {
        info.flags |= kRdpCertFlagUntrustedRoot;
        RdpPreflightPolicy::addUniqueRiskFlag(
            info.riskFlags, RdpPreflightPolicy::kRiskUntrustedRoot);
    }
    if (info.hostMismatch) {
        info.flags |= kRdpCertFlagHostMismatch;
        RdpPreflightPolicy::addUniqueRiskFlag(
            info.riskFlags, RdpPreflightPolicy::kRiskHostnameMismatch);
    }

    info.preflightStatus = RdpPreflightPolicy::kCompleted;

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
    if (rdpProbeCancelled(cancelled)) {
        return makeNetworkChangedProbeError(host, effectivePort);
    }
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
#include <freerdp/client/rdpdr.h>
#include <freerdp/addin.h>
#include <freerdp/codec/color.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/event.h>
#include <freerdp/input.h>
#include <freerdp/locale/locale.h>
#include <freerdp/settings.h>
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

static void updateAtomicMax(std::atomic<int64_t>& target, int64_t value) {
    int64_t current = target.load(std::memory_order_relaxed);
    while (current < value && !target.compare_exchange_weak(
        current, value, std::memory_order_relaxed, std::memory_order_relaxed)) {
    }
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

class RdpWorkerLifecycleOwner;

class RdpWorkerReservation final {
public:
    RdpWorkerReservation() noexcept = default;
    ~RdpWorkerReservation();
    RdpWorkerReservation(RdpWorkerReservation&& other) noexcept;
    RdpWorkerReservation& operator=(RdpWorkerReservation&& other) noexcept;

    RdpWorkerReservation(const RdpWorkerReservation&) = delete;
    RdpWorkerReservation& operator=(const RdpWorkerReservation&) = delete;

    explicit operator bool() const noexcept { return owner_ != nullptr; }
    void release() noexcept;

private:
    friend class RdpWorkerLifecycleOwner;
    friend bool deferRdpWorker(
        RdpWorkerReservation&, std::thread&, std::shared_ptr<void>,
        std::shared_ptr<std::atomic<bool>>) noexcept;

    RdpWorkerReservation(
        RdpWorkerLifecycleOwner* owner, size_t slot) noexcept
        : owner_(owner), slot_(slot) {}

    RdpWorkerLifecycleOwner* owner_ = nullptr;
    size_t slot_ = 0;
};

RdpWorkerReservation reserveRdpWorker() noexcept;
bool deferRdpWorker(
    RdpWorkerReservation& reservation, std::thread& worker,
    std::shared_ptr<void> keepAlive,
    std::shared_ptr<std::atomic<bool>> done) noexcept;

struct FreeRdpAdapter::Impl {
    TransferRuntimeStatus transferStatus;
    ConnectionConfig        config;
    ConnectionState         state = ConnectionState::DISCONNECTED;
    VideoFrameCallback      videoCallback;
    AudioDataCallback       audioCallback;
    ConnectionStateCallback stateCallback;
    // FreeRDP ErrorInfo PDUs are advisory while the transport is alive.  A
    // server can emit informational codes (including 0x01 RPC initiated
    // disconnect) before the event loop has actually ended; publishing ERROR
    // from that callback creates a false dialog over an otherwise live RDP
    // session.  Keep the latest code until transport termination decides it
    // is actionable.
    std::mutex              errorInfoMutex;
    UINT32                  pendingErrorInfoCode = 0;
    std::string             pendingErrorInfoMessage;
    std::mutex              clipboardMutex;
    // cliprdr is owned by FreeRDP and may be replaced by a reconnect while
    // UI clipboard operations are still in flight.  Protect the carrier
    // pointer and channel attach/detach transition separately from the text
    // payload lock; bridge methods retain their own internal lock.
    mutable std::mutex      cliprdrMutex;
    mutable std::mutex      rdpdrMutex;
    std::string             clipboardText;
    CliprdrClientContext*   cliprdr = nullptr;
    RdpdrClientContext*     rdpdr = nullptr;
    std::unique_ptr<RdpFileClipboardBridge> fileClipboard;
    std::thread             eventThread;
    std::thread             connectThread;
    std::thread             driveThread;
    RdpWorkerReservation   eventThreadReservation;
    RdpWorkerReservation   connectThreadReservation;
    RdpWorkerReservation   driveThreadReservation;
    // Every admitted connection reserves the complete asynchronous teardown
    // chain before its connect worker can create a FreeRDP transport. The
    // shared owner is captured by deferred cleanup so a newer generation may
    // replace this slot without dropping the old instance's cleanup rights.
    mutable std::mutex      teardownReservationMutex;
    uint64_t                teardownReservationGeneration = 0;
    std::shared_ptr<RdpTeardownReservations> teardownReservations;
    RdpTeardownRetirementFence teardownRetirementFence;
    std::mutex              stateMutex;
    std::mutex              instanceMutex;
    uint64_t                instanceGeneration = 0;
    std::mutex              shutdownMutex;
    // Network callbacks schedule bounded recovery work. Public connect and
    // disconnect take the same recursive lane so a stale recovery cannot
    // start after an explicit disconnect has completed.
    RdpNetworkActionGate    networkActionGate;
    RdpNetworkRecoveryPolicy networkRecovery;
    // Serialize RDP drive status with reset/commit so a deferred mount worker
    // cannot publish stale state after a reconnect starts.
    std::mutex              transferStatusMutex;
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
    mutable std::mutex      displayControlMutex;
#if defined(CHANNEL_DISP_CLIENT)
    DispClientContext*      displayControl = nullptr;
#endif
    bool                    displayControlReady = false;
    bool                    displayControlDisabled = false;
    bool                    displayLayoutPending = false;
    bool                    displayLayoutInFlight = false;
    uint32_t                displayMaxNumMonitors = 0;
    uint32_t                displayMaxAreaFactorA = 0;
    uint32_t                displayMaxAreaFactorB = 0;
    int64_t                 displayLastSendUs = 0;
    int64_t                 displayInFlightSinceUs = 0;
    RdpDisplayLayoutRequest pendingDisplayLayout;
    int                     displayRequestedWidth = 0;
    int                     displayRequestedHeight = 0;
    int                     displayEffectiveWidth = 0;
    int                     displayEffectiveHeight = 0;
    int                     displayScaleFactor = 100;
    uint64_t                displayRequestCount = 0;
    uint64_t                displayFailureCount = 0;
    std::string             displayLastResult = "not_negotiated";
    mutable std::mutex      ownerMutex;
    mutable std::mutex      videoTelemetryMutex;
    RdpShutdown::State      shutdownState;
    std::atomic<uint64_t>   sessionGeneration {0};
    Render::DecoderSessionIdentity owner;
    RdpVideoTelemetryCallback videoTelemetryCallback;

    void clearPendingErrorInfo() {
        std::lock_guard<std::mutex> lock(errorInfoMutex);
        pendingErrorInfoCode = 0;
        pendingErrorInfoMessage.clear();
    }

    void rememberPendingErrorInfo(UINT32 code, std::string message) {
        if (code == 0) {
            return;
        }
        std::lock_guard<std::mutex> lock(errorInfoMutex);
        pendingErrorInfoCode = code;
        pendingErrorInfoMessage = std::move(message);
    }

    std::string takePendingErrorInfo() {
        std::lock_guard<std::mutex> lock(errorInfoMutex);
        std::string message = std::move(pendingErrorInfoMessage);
        pendingErrorInfoCode = 0;
        pendingErrorInfoMessage.clear();
        return message;
    }
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
    RdpWorkerReservation   inputQueueThreadReservation;
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
    // These timestamps/counters are deliberately independent of renderer
    // metrics. They tell the watchdog whether FreeRDP itself is still making
    // progress when the remote desktop is quiet or the presentation surface
    // is unavailable.
    std::atomic<int64_t>    lastInputPostedUs {0};
    std::atomic<int64_t>    lastEventLoopTickUs {0};
    std::atomic<int64_t>    eventLoopBlockMaxUs {0};
    std::atomic<uint64_t>   eventLoopTicks {0};
    std::atomic<uint64_t>   networkCheckCount {0};
    std::atomic<uint64_t>   networkCheckFailures {0};
    std::atomic<uint64_t>   inputPostFailures {0};
    int64_t                 lastRenderDiagUs = 0;
    std::atomic<uint64_t>   lastRenderBytes {0};
    int                     lastFrameWidth = 0;
    int                     lastFrameHeight = 0;

    void installTeardownReservations(
        uint64_t generation,
        const std::shared_ptr<RdpTeardownReservations>& reservations) {
        {
            std::lock_guard<std::mutex> lock(teardownReservationMutex);
            teardownReservationGeneration = generation;
            teardownReservations = reservations;
        }
        teardownRetirementFence.admit(generation);
    }

    std::shared_ptr<RdpTeardownReservations> snapshotTeardownReservations(
        uint64_t expectedGeneration = 0) const {
        std::lock_guard<std::mutex> lock(teardownReservationMutex);
        if (expectedGeneration != 0 &&
            teardownReservationGeneration != expectedGeneration) {
            return nullptr;
        }
        return teardownReservations;
    }

    void clearTeardownReservationsIfCurrent(
        uint64_t generation,
        const std::shared_ptr<RdpTeardownReservations>& reservations) {
        bool cleared = false;
        {
            std::lock_guard<std::mutex> lock(teardownReservationMutex);
            if (teardownReservationGeneration == generation &&
                teardownReservations.get() == reservations.get()) {
                teardownReservations.reset();
                teardownReservationGeneration = 0;
                cleared = true;
            }
        }
        if (cleared) {
            (void)teardownRetirementFence.retire(generation);
        }
    }

    void interruptTeardownRetirementWait() noexcept {
        teardownRetirementFence.interrupt();
    }

    RdpTeardownRetirementWaitResult waitForTeardownRetirement(
        uint64_t sessionGeneration, uint64_t networkActionToken,
        std::chrono::steady_clock::time_point deadline) {
        return teardownRetirementFence.waitUntilRetired(
            sessionGeneration, deadline, [this, networkActionToken]() {
                return networkRecovery.isCurrent(networkActionToken, true);
            });
    }
    bool                    forceNextFullFrame = false;
    std::string             graphicsMode = "gdi";

    void resetRdpTransferStatus() {
        std::lock_guard<std::mutex> lock(transferStatusMutex);
        transferStatus.reset();
        driveDeviceId = 0;
    }

    bool publishRdpDriveMounted(uint64_t generation, uint32_t deviceId) {
        std::lock_guard<std::mutex> lock(transferStatusMutex);
        if (sessionGeneration.load(std::memory_order_acquire) != generation ||
            stopRequested.load(std::memory_order_acquire)) {
            return false;
        }
        driveDeviceId = deviceId;
        transferStatus.markRdpDriveMounted();
        return true;
    }

    bool publishRdpDriveUnavailable(uint64_t generation, const std::string& diagnosticCode) {
        std::lock_guard<std::mutex> lock(transferStatusMutex);
        if (sessionGeneration.load(std::memory_order_acquire) != generation ||
            stopRequested.load(std::memory_order_acquire)) {
            return false;
        }
        transferStatus.markRdpDriveUnavailable(diagnosticCode);
        return true;
    }

    bool rdpClipboardEnabled() const {
        std::lock_guard<std::mutex> lock(configMutex);
        return config.rdClipboardEnabled;
    }

    void clearClipboardState() {
        {
            std::lock_guard<std::mutex> lock(clipboardMutex);
            clipboardText.clear();
        }
        if (fileClipboard) {
            fileClipboard->clearLocalFiles();
        }
    }

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
        // The worker only posts to FreeRDP's official input message queue. It
        // never calls a transport-writing callback itself, so the event loop
        // remains the sole FreeRDP execution context for input and graphics.
        // stopInputQueueWorker invalidates this generation before joining, so
        // this second check prevents a stale worker from posting after it has
        // waited for instanceMutex.
        if (!isInputQueueWorkerCurrent(workerGeneration) || !owner || !owner->instance_ ||
            !owner->instance_->input) {
            return;
        }
        wMessageQueue* queue = freerdp_get_message_queue(
            owner->instance_, FREERDP_INPUT_MESSAGE_QUEUE);
        rdpContext* context = owner->instance_->context;
        if (!queue || !context) {
            inputPostFailures.fetch_add(1, std::memory_order_relaxed);
            OH_LOG_WARN(LOG_APP, "[RDP] input queue unavailable while posting event");
            return;
        }
        const auto post = [this, queue, context](UINT32 messageId, uintptr_t wParam,
                                                 uintptr_t lParam) {
            const bool posted = MessageQueue_Post(
                queue, context, messageId, reinterpret_cast<void*>(wParam),
                reinterpret_cast<void*>(lParam)) == TRUE;
            if (posted) {
                lastInputPostedUs.store(steadyNowUs(), std::memory_order_release);
            } else {
                inputPostFailures.fetch_add(1, std::memory_order_relaxed);
            }
            return posted;
        };
        switch (event.type) {
            case RdpInputEventType::Key:
                (void)post(FREERDP_INPUT_KEYBOARD_EVENT,
                           static_cast<uintptr_t>(event.flags),
                           static_cast<uintptr_t>(event.code & 0xFFU));
                break;
            case RdpInputEventType::Pause:
                (void)post(FREERDP_INPUT_KEYBOARD_PAUSE_EVENT, 0, 0);
                break;
            case RdpInputEventType::TextBatch:
                DispatchTextBatch(event.text, KBD_FLAGS_RELEASE,
                    [post](uint16_t flags, uint16_t code) {
                        (void)post(FREERDP_INPUT_UNICODE_KEYBOARD_EVENT,
                                   static_cast<uintptr_t>(flags),
                                   static_cast<uintptr_t>(code));
                    });
                break;
            case RdpInputEventType::Mouse:
            case RdpInputEventType::MouseWheel:
            {
                const UINT32 packedPosition =
                    (static_cast<UINT32>(static_cast<UINT16>(event.x)) << 16) |
                    static_cast<UINT32>(static_cast<UINT16>(event.y));
                (void)post(FREERDP_INPUT_MOUSE_EVENT,
                           static_cast<uintptr_t>(event.flags),
                           static_cast<uintptr_t>(packedPosition));
                break;
            }
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

    bool startInputQueueWorker(FreeRdpAdapter* owner) {
        std::lock_guard<std::mutex> lock(inputQueueMutex);
        if (inputQueueRunning.load(std::memory_order_acquire)) {
            return true;
        }
        std::shared_ptr<FreeRdpAdapter> retained;
        try {
            retained = owner ? owner->shared_from_this() : nullptr;
        } catch (const std::bad_weak_ptr&) {
            OH_LOG_ERROR(LOG_APP,
                "[RDP] input worker requires shared adapter lifetime");
            return false;
        }
        if (!retained) {
            OH_LOG_ERROR(LOG_APP,
                "[RDP] input worker missing adapter lifetime");
            return false;
        }
        RdpWorkerReservation workerReservation = reserveRdpWorker();
        if (!workerReservation) {
            OH_LOG_ERROR(LOG_APP,
                "[RDP] input worker rejected: deferred-owner capacity exhausted");
            return false;
        }
        std::shared_ptr<std::atomic<bool>> done;
        try {
            done = std::make_shared<std::atomic<bool>>(false);
        } catch (...) {
            OH_LOG_ERROR(LOG_APP,
                "[RDP] input worker rejected: completion fence unavailable");
            return false;
        }
        inputQueueStop.store(false, std::memory_order_release);
        inputQueue.clear();
        inputQueue.resetMetrics();
        const uint64_t workerGeneration =
            inputQueueGeneration.fetch_add(1, std::memory_order_acq_rel) + 1;
        inputQueueRunning.store(true, std::memory_order_release);
        std::atomic_store_explicit(&inputQueueDone, done, std::memory_order_release);
        try {
            inputQueueThreadReservation = std::move(workerReservation);
            inputQueueThread = std::thread([this, retained, done, workerGeneration]() {
                inputQueueWorkerLoop(retained.get(), workerGeneration);
                inputQueueRunning.store(false, std::memory_order_release);
                done->store(true, std::memory_order_release);
                inputQueueCv.notify_all();
            });
        } catch (const std::exception& e) {
            inputQueueThreadReservation.release();
            inputQueueRunning.store(false, std::memory_order_release);
            inputQueueStop.store(true, std::memory_order_release);
            inputQueue.clear();
            done->store(true, std::memory_order_release);
            OH_LOG_WARN(LOG_APP, "[RDP] input queue worker start failed: %{public}s", e.what());
            return false;
        } catch (...) {
            inputQueueThreadReservation.release();
            inputQueueRunning.store(false, std::memory_order_release);
            inputQueueStop.store(true, std::memory_order_release);
            inputQueue.clear();
            done->store(true, std::memory_order_release);
            OH_LOG_WARN(LOG_APP, "[RDP] input queue worker start failed: unknown");
            return false;
        }
        return true;
    }

    void stopInputQueueWorker(RdpShutdownDeadline deadline) {
        {
            std::lock_guard<std::mutex> lock(inputQueueMutex);
            if (!inputQueueThread.joinable()) {
                inputQueueThreadReservation.release();
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
                inputQueueThreadReservation.release();
            } else {
                OH_LOG_WARN(LOG_APP,
                    "[RDP] input worker exceeded shutdown budget; deferring join");
                (void)deferRdpWorker(
                    inputQueueThreadReservation, inputQueueThread,
                    lifetime.lock(), doneFence);
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

    bool startSessionWorkers(FreeRdpAdapter* owner) {
        std::lock_guard<std::mutex> lifecycleLock(workerLifecycleMutex);
        if (!startInputQueueWorker(owner)) {
            presentationEnabled.store(false, std::memory_order_release);
            OH_LOG_ERROR(LOG_APP,
                "[RDP] input worker unavailable; presentation remains disabled [E-RDP-INPUT-WORKER]");
            return false;
        }
        if (!framePump->start()) {
            stopInputQueueWorker(RdpShutdownDeadline::max());
            presentationEnabled.store(false, std::memory_order_release);
            OH_LOG_ERROR(LOG_APP,
                "[RDP] frame pump unavailable; presentation remains disabled [E-RDP-FRAME-PUMP]");
            return false;
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
        if (redrawCallbackToken == 0) {
            redrawNotifier.reset();
            auto pump = std::move(framePump);
            if (pump && !pump->stopWithin(std::chrono::milliseconds(500))) {
                RdpFramePump::deferStopAndJoin(std::move(pump));
            }
            framePump = std::make_shared<RdpFramePump>();
            stopInputQueueWorker(RdpShutdownDeadline::max());
            presentationEnabled.store(false, std::memory_order_release);
            OH_LOG_ERROR(LOG_APP,
                "[RDP] redraw callback unavailable; presentation remains disabled [E-RDP-REDRAW-CALLBACK]");
            return false;
        }
        return true;
    }

    void stopSessionWorkers(RdpShutdownDeadline deadline) {
        std::lock_guard<std::mutex> lifecycleLock(workerLifecycleMutex);
        const uint64_t callbackToken = redrawCallbackToken;
        redrawCallbackToken = 0;
        auto notifier = std::move(redrawNotifier);
        RendererNapi::UnregisterActiveRedrawCallback(callbackToken);
        if (notifier) {
            if (!notifier->disableAndWaitWithin(remainingRdpShutdownBudget(deadline))) {
                RdpWorkerReservation workerReservation = reserveRdpWorker();
                if (!workerReservation) {
                    OH_LOG_WARN(LOG_APP,
                        "[RDP] redraw drain rejected: deferred-owner capacity exhausted");
                } else {
                    auto retained = lifetime.lock();
                    try {
                        auto drained = std::make_shared<std::atomic<bool>>(false);
                        std::thread drainThread([notifier, drained]() {
                            // The notifier's callback state is shared with every
                            // in-flight notify call, so the deferred owner does
                            // not need an unbounded retry loop to keep a raw gate
                            // alive. One bounded drain attempt is sufficient.
                            (void)notifier->disableAndWaitWithin(
                                std::chrono::milliseconds(500));
                            drained->store(true, std::memory_order_release);
                        });
                        (void)deferRdpWorker(
                            workerReservation, drainThread, retained, drained);
                    } catch (const std::exception& e) {
                        OH_LOG_WARN(LOG_APP,
                            "[RDP] redraw drain worker start failed: %{public}s", e.what());
                    } catch (...) {
                        OH_LOG_WARN(LOG_APP, "[RDP] redraw drain worker start failed");
                    }
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
    DeferredRdpWorker() = default;
    DeferredRdpWorker(
        std::thread&& workerValue, std::shared_ptr<void> keepAliveValue,
        std::shared_ptr<std::atomic<bool>> doneValue) noexcept
        : worker(std::move(workerValue)),
          keepAlive(std::move(keepAliveValue)), done(std::move(doneValue)) {}

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

    RdpWorkerReservation reserve() noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (stopping_ || workerDone_ || reservedCount_ >= slots_.size()) {
                return {};
            }
            for (size_t index = 0; index < slots_.size(); ++index) {
                if (!slots_[index].reserved) {
                    slots_[index].reserved = true;
                    ++reservedCount_;
                    return RdpWorkerReservation(this, index);
                }
            }
        } catch (...) {
            return {};
        }
        return {};
    }

    bool drainWithin(std::chrono::milliseconds timeout) {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, timeout, [this]() {
            return reservedCount_ == 0 && pendingCount_ == 0 && active_ == 0;
        });
    }

    std::size_t remaining() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return reservedCount_;
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
    friend class RdpWorkerReservation;
    friend bool deferRdpWorker(
        RdpWorkerReservation&, std::thread&, std::shared_ptr<void>,
        std::shared_ptr<std::atomic<bool>>) noexcept;

    struct Slot final {
        bool reserved = false;
        std::optional<DeferredRdpWorker> item;
    };

    bool commit(
        size_t slotIndex, std::thread& worker,
        std::shared_ptr<void> keepAlive,
        std::shared_ptr<std::atomic<bool>> done) noexcept {
        if (!worker.joinable()) {
            release(slotIndex);
            return true;
        }
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (slotIndex >= slots_.size() || !slots_[slotIndex].reserved ||
                slots_[slotIndex].item.has_value() || workerDone_) {
                return false;
            }
            slots_[slotIndex].item.emplace(
                std::move(worker), std::move(keepAlive), std::move(done));
            ++pendingCount_;
            cv_.notify_one();
            return true;
        } catch (...) {
            // A valid reserved slot performs only noexcept moves. The caller
            // still owns the joinable thread if the platform mutex fails;
            // deferRdpWorker treats that as a fatal lifecycle invariant.
            return false;
        }
    }

    void release(size_t slotIndex) noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            if (slotIndex >= slots_.size() || !slots_[slotIndex].reserved ||
                slots_[slotIndex].item.has_value()) {
                return;
            }
            slots_[slotIndex].reserved = false;
            if (reservedCount_ > 0) {
                --reservedCount_;
            }
            cv_.notify_all();
        } catch (...) {
            std::abort();
        }
    }

    void run() {
        for (;;) {
            DeferredRdpWorker item;
            size_t activeSlot = slots_.size();
            {
                std::unique_lock<std::mutex> lock(mutex_);
                cv_.wait(lock, [this]() { return stopping_ || pendingCount_ != 0; });
                if (pendingCount_ == 0 && reservedCount_ == 0 && stopping_) {
                    workerDone_ = true;
                    cv_.notify_all();
                    return;
                }
                for (size_t index = 0; index < slots_.size(); ++index) {
                    if (!slots_[index].item.has_value()) {
                        continue;
                    }
                    const auto& done = slots_[index].item->done;
                    if (!done || done->load(std::memory_order_acquire)) {
                        activeSlot = index;
                        break;
                    }
                }
                if (activeSlot == slots_.size()) {
                    lock.unlock();
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    continue;
                }
                item = std::move(slots_[activeSlot].item.value());
                slots_[activeSlot].item.reset();
                --pendingCount_;
                ++active_;
            }
            item.worker.join();
            item.keepAlive.reset();
            {
                std::lock_guard<std::mutex> lock(mutex_);
                slots_[activeSlot].reserved = false;
                if (reservedCount_ > 0) {
                    --reservedCount_;
                }
                --active_;
                cv_.notify_all();
            }
        }
    }

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    // Every protocol worker reserves one fixed slot before std::thread is
    // started. Capacity exhaustion therefore rejects admission before a
    // joinable object exists; commit is allocation-free and cannot overflow.
    static constexpr size_t kMaximumDeferredWorkers = 64;
    std::array<Slot, kMaximumDeferredWorkers> slots_;
    size_t reservedCount_ = 0;
    size_t pendingCount_ = 0;
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

RdpWorkerReservation::~RdpWorkerReservation() {
    release();
}

RdpWorkerReservation::RdpWorkerReservation(
    RdpWorkerReservation&& other) noexcept
    : owner_(other.owner_), slot_(other.slot_) {
    other.owner_ = nullptr;
    other.slot_ = 0;
}

RdpWorkerReservation& RdpWorkerReservation::operator=(
    RdpWorkerReservation&& other) noexcept {
    if (this == &other) {
        return *this;
    }
    release();
    owner_ = other.owner_;
    slot_ = other.slot_;
    other.owner_ = nullptr;
    other.slot_ = 0;
    return *this;
}

void RdpWorkerReservation::release() noexcept {
    if (!owner_) {
        return;
    }
    RdpWorkerLifecycleOwner* owner = owner_;
    const size_t slot = slot_;
    owner_ = nullptr;
    slot_ = 0;
    owner->release(slot);
}

RdpWorkerReservation reserveRdpWorker() noexcept {
    try {
        return rdpWorkerOwner().reserve();
    } catch (...) {
        return {};
    }
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

bool deferRdpWorker(
    RdpWorkerReservation& reservation, std::thread& worker,
    std::shared_ptr<void> keepAlive,
    std::shared_ptr<std::atomic<bool>> done) noexcept {
    if (!worker.joinable()) {
        reservation.release();
        return true;
    }
    if (!reservation.owner_) {
        OH_LOG_ERROR(LOG_APP,
            "[RDP] refusing deferred handoff without a pre-start reservation");
        std::abort();
    }
    RdpWorkerLifecycleOwner* owner = reservation.owner_;
    const size_t slot = reservation.slot_;
    if (!owner->commit(
            slot, worker, std::move(keepAlive), std::move(done))) {
        OH_LOG_ERROR(LOG_APP,
            "[RDP] reserved deferred worker handoff invariant failed");
        std::abort();
    }
    reservation.owner_ = nullptr;
    reservation.slot_ = 0;
    return true;
}

enum class RdpTeardownWorkerRole : size_t {
    DisconnectTransport = 0,
    WaitForConnectWorker,
    RetirePlatformInstance,
    PostDisconnectCallback,
    Count,
};

class RdpTeardownReservations final
    : public std::enable_shared_from_this<RdpTeardownReservations> {
public:
    static std::shared_ptr<RdpTeardownReservations> Create(
        uint64_t generation) noexcept {
        try {
            auto owner = std::shared_ptr<RdpTeardownReservations>(
                new RdpTeardownReservations(generation));
            for (Carrier& carrier : owner->carriers_) {
                carrier.done = std::make_shared<std::atomic<bool>>(false);
                carrier.reservation = reserveRdpWorker();
                if (!carrier.reservation) {
                    return nullptr;
                }
            }
            try {
                for (size_t roleIndex = 0;
                     roleIndex < owner->carriers_.size(); ++roleIndex) {
                    owner->carriers_[roleIndex].worker = std::thread(
                        [owner, roleIndex]() {
                            owner->runCarrier(roleIndex);
                        });
                }
            } catch (...) {
                owner->cancelAndJoinFailedAdmission();
                return nullptr;
            }
            return owner;
        } catch (...) {
            return nullptr;
        }
    }

    uint64_t generation() const noexcept { return generation_; }

    void markPlatformRetirementPending() noexcept {
        platformRetirementGate_.markPending();
    }

    bool canReleaseAbsentInstanceOwner() const noexcept {
        return platformRetirementGate_.canReleaseAbsentInstanceOwner();
    }

    bool submit(
        RdpTeardownWorkerRole role, std::function<void()> task) noexcept {
        if (!task) {
            return false;
        }
        std::shared_ptr<RdpTeardownReservations> keepAlive;
        try {
            keepAlive = shared_from_this();
        } catch (...) {
            return false;
        }
        Carrier& carrier = carriers_[index(role)];
        std::thread worker;
        RdpWorkerReservation reservation;
        std::shared_ptr<std::atomic<bool>> done;
        try {
            std::lock_guard<std::mutex> lock(carrier.mutex);
            if (carrier.submitted || carrier.cancelled ||
                !carrier.worker.joinable() || !carrier.reservation) {
                return false;
            }
            carrier.task = std::move(task);
            carrier.submitted = true;
            worker = std::move(carrier.worker);
            reservation = std::move(carrier.reservation);
            done = carrier.done;
        } catch (...) {
            return false;
        }
        carrier.cv.notify_all();
        (void)deferRdpWorker(
            reservation, worker, std::move(keepAlive), std::move(done));
        return true;
    }

    void retireUnusedCarriers() noexcept {
        std::shared_ptr<RdpTeardownReservations> keepAlive;
        try {
            keepAlive = shared_from_this();
        } catch (...) {
            std::abort();
        }
        for (Carrier& carrier : carriers_) {
            std::thread worker;
            RdpWorkerReservation reservation;
            std::shared_ptr<std::atomic<bool>> done;
            try {
                std::lock_guard<std::mutex> lock(carrier.mutex);
                if (carrier.submitted || carrier.cancelled ||
                    !carrier.worker.joinable()) {
                    continue;
                }
                carrier.cancelled = true;
                worker = std::move(carrier.worker);
                reservation = std::move(carrier.reservation);
                done = carrier.done;
            } catch (...) {
                std::abort();
            }
            carrier.cv.notify_all();
            (void)deferRdpWorker(
                reservation, worker, keepAlive, std::move(done));
        }
    }

private:
    struct Carrier final {
        std::mutex mutex;
        std::condition_variable cv;
        std::function<void()> task;
        std::thread worker;
        RdpWorkerReservation reservation;
        std::shared_ptr<std::atomic<bool>> done;
        bool submitted = false;
        bool cancelled = false;
    };

    explicit RdpTeardownReservations(uint64_t generation) noexcept
        : generation_(generation) {}

    static constexpr size_t index(RdpTeardownWorkerRole role) noexcept {
        return static_cast<size_t>(role);
    }

    static constexpr size_t kReservationCount =
        static_cast<size_t>(RdpTeardownWorkerRole::Count);

    void runCarrier(size_t roleIndex) noexcept {
        Carrier& carrier = carriers_[roleIndex];
        std::function<void()> task;
        try {
            std::unique_lock<std::mutex> lock(carrier.mutex);
            carrier.cv.wait(lock, [&carrier]() {
                return carrier.submitted || carrier.cancelled;
            });
            if (!carrier.cancelled) {
                task = std::move(carrier.task);
            }
        } catch (...) {
            std::abort();
        }
        if (task) {
            try {
                task();
            } catch (...) {
                // Every carrier owns one essential raw-resource transition.
                // Continuing after it throws would silently lose teardown.
                std::abort();
            }
        }
        carrier.done->store(true, std::memory_order_release);
    }

    void cancelAndJoinFailedAdmission() noexcept {
        for (Carrier& carrier : carriers_) {
            try {
                {
                    std::lock_guard<std::mutex> lock(carrier.mutex);
                    carrier.cancelled = true;
                }
                carrier.cv.notify_all();
                if (carrier.worker.joinable()) {
                    carrier.worker.join();
                }
            } catch (...) {
                std::abort();
            }
        }
    }

    uint64_t generation_ = 0;
    RdpPlatformRetirementGate platformRetirementGate_;
    std::array<Carrier, kReservationCount> carriers_;
};

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
    // The vendored FreeRDP GDI pipeline installs the official ResetGraphics
    // callback.  It routes RESET_GRAPHICS through the same guarded desktop
    // resize transaction used by classic GDI, so resize/reconnect failures
    // can mark the next connection for a bounded GDI fallback.
#if defined(CHANNEL_RDPGFX_CLIENT)
    return true;
#else
    return false;
#endif
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

static bool rootTrustedFromPem(const BYTE* data, size_t length) {
    return RdpCertificateValidation::rootTrustedFromPem(data, length);
}

struct RdpPreflightCallbackState {
    explicit RdpPreflightCallbackState(RdpPreflightRequest value)
        : request(std::move(value)) {}

    RdpPreflightRequest request;
    RdpPreflightResult result;
    bool unsupportedFlags = false;
    bool gatewayCertificateMetadataInvalid = false;
    bool targetCertificateMetadataInvalid = false;
    bool gatewayCertificateRejected = false;
};

static RdpCertificateRecord rdpCertificateRecordFromInfo(
    const RdpCertificateInfo& info, const std::string& stage) {
    RdpCertificateRecord record;
    record.present = info.ok && !info.fingerprintSha256.empty();
    record.rootTrusted = info.rootTrusted;
    record.hostMismatch = info.hostMismatch;
    record.flags = info.flags;
    record.host = info.host;
    record.port = info.port;
    record.stage = stage;
    record.serverName = info.serverName;
    record.commonName = info.commonName;
    record.subject = info.subject;
    record.issuer = info.issuer;
    record.fingerprintSha256 = info.fingerprintSha256;
    record.notBeforeMs = info.notBeforeMs;
    record.notAfterMs = info.notAfterMs;
    record.riskFlags = info.riskFlags;
    if (!record.riskFlags.empty()) {
        RdpPreflightPolicy::addUniqueRiskFlag(
            record.riskFlags, stage == "gateway"
                ? RdpPreflightPolicy::kRiskGatewayCertificate
                : RdpPreflightPolicy::kRiskTargetCertificate);
    }
    return record;
}

static std::mutex g_rdpPreflightMutex;
static std::unordered_map<freerdp*, std::shared_ptr<RdpPreflightCallbackState>>
    g_rdpPreflightStates;

static std::shared_ptr<RdpPreflightCallbackState> findRdpPreflightState(freerdp* instance) {
    if (!instance) {
        return nullptr;
    }
    std::lock_guard<std::mutex> lock(g_rdpPreflightMutex);
    const auto it = g_rdpPreflightStates.find(instance);
    return it == g_rdpPreflightStates.end() ? nullptr : it->second;
}

static void releaseRdpPreflightInstance(freerdp* instance) {
    if (!instance) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(g_rdpPreflightMutex);
        g_rdpPreflightStates.erase(instance);
    }
    instance->VerifyCertificate = nullptr;
    instance->VerifyX509Certificate = nullptr;
    instance->VerifyCertificateEx = nullptr;
    instance->VerifyChangedCertificateEx = nullptr;
    secureClearFreeRdpCredentials(instance->settings);
    if (instance->context) {
        freerdp_context_free(instance);
    }
    freerdp_free(instance);
}

static bool preflightUsesGateway(const RdpPreflightCallbackState& /*state*/, DWORD flags) {
    return (flags & VERIFY_CERT_FLAG_GATEWAY) != 0;
}

static bool preflightFlagsAreSupported(DWORD flags) {
    constexpr DWORD kKnownFlags = VERIFY_CERT_FLAG_LEGACY |
        VERIFY_CERT_FLAG_GATEWAY | VERIFY_CERT_FLAG_CHANGED |
        VERIFY_CERT_FLAG_MISMATCH | VERIFY_CERT_FLAG_MATCH_LEGACY_SHA1 |
        VERIFY_CERT_FLAG_FP_IS_PEM;
    return (flags & ~kKnownFlags) == 0 &&
        (flags & VERIFY_CERT_FLAG_REDIRECT) == 0;
}

static bool rdpCertificateTextLooksLikePem(const char* value) {
    return value != nullptr &&
        std::strstr(value, "-----BEGIN CERTIFICATE-----") != nullptr;
}

static int captureRdpPreflightCertificate(freerdp* instance, const BYTE* data,
                                          size_t length, const char* hostname,
                                          UINT16 port, DWORD flags,
                                          const char* fingerprintText = nullptr) {
    (void)port;
    const auto state = findRdpPreflightState(instance);
    if (!state) {
        return 0;
    }
    if (rdpProbeCancelled(state->request.cancelled)) {
        (void)freerdp_abort_connect_context(
            instance ? instance->context : nullptr);
        return 0;
    }
    if (!preflightFlagsAreSupported(flags)) {
        state->unsupportedFlags = true;
        return 0;
    }
    const bool gateway = preflightUsesGateway(*state, flags);
    const RdpEndpointRoute& route = state->request.route;
    if (gateway && route.endpointMode != RdpEndpointMode::MicrosoftRdGateway) {
        state->unsupportedFlags = true;
        return 0;
    }
    const bool pemAvailable = data != nullptr && length > 0;
    if (!pemAvailable && fingerprintText == nullptr) {
        state->unsupportedFlags = true;
        return 0;
    }
    RdpCertificateRecord record;
    record.present = true;
    record.stage = gateway ? "gateway" : "target";
    record.host = gateway ? route.gatewayHost : route.targetHost;
    record.port = gateway ? route.gatewayPort : route.targetPort;
    record.serverName = gateway ? route.gatewayServerName : route.targetServerName;
    if (record.serverName.empty()) {
        record.serverName = hostname ? hostname : record.host;
    }
    record.fingerprintSha256 = pemAvailable
        ? fingerprintFromPem(data, length)
        : RdpCertificatePolicy::NormalizeFingerprint(fingerprintText);
    if (record.fingerprintSha256.empty()) {
        // A callback with malformed PEM is not a certificate observation. Do
        // not publish a present record that a refresh path could persist as an
        // empty pin; the preflight must fail closed at the relevant stage.
        if (gateway) {
            state->gatewayCertificateMetadataInvalid = true;
        } else {
            state->targetCertificateMetadataInvalid = true;
        }
        return 0;
    }
    const std::string& expectedFingerprint = gateway
        ? state->request.expectedGatewayFingerprintSha256
        : state->request.expectedTargetFingerprintSha256;
    if (!expectedFingerprint.empty() &&
        !RdpCertificatePolicy::FingerprintMatches(
            expectedFingerprint, record.fingerprintSha256)) {
        RdpPreflightPolicy::addUniqueRiskFlag(
            record.riskFlags, RdpPreflightPolicy::kRiskCertificateChanged);
    }
    if ((flags & VERIFY_CERT_FLAG_CHANGED) != 0) {
        RdpPreflightPolicy::addUniqueRiskFlag(
            record.riskFlags, RdpPreflightPolicy::kRiskCertificateChanged);
    }
    if (pemAvailable) {
        BIO* bio = BIO_new_mem_buf(data, static_cast<int>(length));
        X509* cert = bio ? PEM_read_bio_X509(bio, nullptr, nullptr, nullptr) : nullptr;
        if (bio) {
            BIO_free(bio);
        }
        if (!cert) {
            if (gateway) {
                state->gatewayCertificateMetadataInvalid = true;
            } else {
                state->targetCertificateMetadataInvalid = true;
            }
            return 0;
        }
        const std::string commonName = x509CommonName(cert);
        record.commonName = commonName;
        record.subject = x509NameToString(X509_get_subject_name(cert));
        record.issuer = x509NameToString(X509_get_issuer_name(cert));
        const bool notBeforeParsed = asn1TimeToMillis(
            X509_get0_notBefore(cert), record.notBeforeMs);
        const bool notAfterParsed = asn1TimeToMillis(
            X509_get0_notAfter(cert), record.notAfterMs);
        if (!notBeforeParsed || !notAfterParsed ||
            record.notAfterMs <= record.notBeforeMs) {
            RdpPreflightPolicy::addUniqueRiskFlag(
                record.riskFlags, RdpPreflightPolicy::kRiskCertificateTimeInvalid);
        } else {
            const int64_t nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            if (nowMs < record.notBeforeMs || nowMs > record.notAfterMs) {
                RdpPreflightPolicy::addUniqueRiskFlag(
                    record.riskFlags, RdpPreflightPolicy::kRiskCertificateTimeInvalid);
            }
        }
        record.hostMismatch = !RdpCertificateValidation::hostnameMatches(
            cert, record.serverName);
        record.rootTrusted = rootTrustedFromPem(data, length);
        if (!record.rootTrusted) {
            record.flags |= kRdpCertFlagUntrustedRoot;
            RdpPreflightPolicy::addUniqueRiskFlag(
                record.riskFlags, RdpPreflightPolicy::kRiskUntrustedRoot);
        }
        if (record.hostMismatch) {
            record.flags |= kRdpCertFlagHostMismatch;
            RdpPreflightPolicy::addUniqueRiskFlag(
                record.riskFlags, RdpPreflightPolicy::kRiskHostnameMismatch);
        }
        X509_free(cert);
    } else {
        // Some FreeRDP builds expose only a fingerprint (or call the legacy
        // callback without VERIFY_CERT_FLAG_FP_IS_PEM). Keep that identity so
        // an explicit pin or Continue Once can bind the real callback, but do
        // not claim that chain, hostname, or validity checks were completed.
        RdpPreflightPolicy::addUniqueRiskFlag(
            record.riskFlags, RdpPreflightPolicy::kRiskCertificateMetadataUnavailable);
        record.hostMismatch = (flags & VERIFY_CERT_FLAG_MISMATCH) != 0;
        if (record.hostMismatch) {
            record.flags |= kRdpCertFlagHostMismatch;
            RdpPreflightPolicy::addUniqueRiskFlag(
                record.riskFlags, RdpPreflightPolicy::kRiskHostnameMismatch);
        }
    }
    if (!record.riskFlags.empty()) {
        RdpPreflightPolicy::addUniqueRiskFlag(
            record.riskFlags, gateway
                ? RdpPreflightPolicy::kRiskGatewayCertificate
                : RdpPreflightPolicy::kRiskTargetCertificate);
    }
    // record.flags is the app-level certificate-risk namespace. FreeRDP's
    // VERIFY_CERT_FLAG_LEGACY is also 0x02, so raw callback flags must not be
    // merged with kRdpCertFlagHostMismatch.
    if (gateway) {
        const bool gatewayAllowed = RdpGatewayPolicy::trustAllowsStage(
            record, state->request.expectedGatewayFingerprintSha256,
            state->request.gatewayAllowUntrustedRoot,
            state->request.gatewayAllowHostMismatch,
            state->request.gatewayAllowTimeAnomaly);
        state->result.gatewayCertificate = std::move(record);
        if (!gatewayAllowed) {
            // The raw TLS inspection and the authenticated Gateway connection
            // are separate sockets. Pin the second socket to the inspected
            // certificate so a TOCTOU certificate change is rejected before
            // FreeRDP can send Gateway credentials.
            state->gatewayCertificateRejected = true;
        }
    } else {
        state->result.targetCertificate = std::move(record);
    }

    if (gateway) {
        // The preflight is an inspection operation.  It must accept the
        // gateway certificate temporarily so FreeRDP can reach the tunneled
        // target; the final connection still re-checks the staged pin.
        return state->gatewayCertificateMetadataInvalid ||
            state->gatewayCertificateRejected ? 0 : 1;
    }

    // Stop after the target TLS certificate. Returning 0 also prevents
    // FreeRDP from entering CredSSP, channel setup, or the desktop session.
    // The enclosing preflight treats the captured certificate as a successful
    // inspection result even though the intentionally aborted connect fails.
    (void)freerdp_abort_connect_context(instance ? instance->context : nullptr);
    return 0;
}

static int probeVerifyRdpPreflightX509(freerdp* instance, const BYTE* data,
                                      size_t length, const char* hostname,
                                      UINT16 port, DWORD flags) {
    return captureRdpPreflightCertificate(instance, data, length, hostname, port, flags);
}

static DWORD probeVerifyRdpPreflightEx(freerdp* instance, const char* host, UINT16 port,
                                       const char* commonName, const char* subject,
                                       const char* issuer, const char* fingerprint,
                                       DWORD flags) {
    (void)commonName;
    (void)subject;
    (void)issuer;
    const bool fingerprintIsPem = (flags & VERIFY_CERT_FLAG_FP_IS_PEM) != 0 ||
        rdpCertificateTextLooksLikePem(fingerprint);
    if (fingerprintIsPem && fingerprint) {
        return static_cast<DWORD>(captureRdpPreflightCertificate(
            instance, reinterpret_cast<const BYTE*>(fingerprint), strlen(fingerprint),
            host, port, flags));
    }
    if (fingerprint) {
        return static_cast<DWORD>(captureRdpPreflightCertificate(
            instance, nullptr, 0, host, port, flags, fingerprint));
    }
    return 0;
}

static DWORD probeVerifyChangedRdpPreflightEx(
    freerdp* instance, const char* host, UINT16 port, const char* commonName,
    const char* subject, const char* issuer, const char* newFingerprint,
    const char* /*oldSubject*/, const char* /*oldIssuer*/,
    const char* /*oldFingerprint*/, DWORD flags) {
    (void)commonName;
    (void)subject;
    (void)issuer;
    const DWORD effectiveFlags = flags | VERIFY_CERT_FLAG_CHANGED;
    if (!newFingerprint) {
        return 0;
    }
    const bool fingerprintIsPem = (effectiveFlags & VERIFY_CERT_FLAG_FP_IS_PEM) != 0 ||
        rdpCertificateTextLooksLikePem(newFingerprint);
    if (fingerprintIsPem) {
        return static_cast<DWORD>(captureRdpPreflightCertificate(
            instance, reinterpret_cast<const BYTE*>(newFingerprint),
            strlen(newFingerprint), host, port, effectiveFlags));
    }
    return static_cast<DWORD>(captureRdpPreflightCertificate(
        instance, nullptr, 0, host, port, effectiveFlags, newFingerprint));
}

static DWORD WINAPI probeVerifyRdpPreflightCertificate(
    freerdp* instance, const char* commonName, const char* subject,
    const char* issuer, const char* fingerprint, BOOL hostMismatch) {
    (void)commonName;
    (void)subject;
    (void)issuer;
    const DWORD flags = hostMismatch ? VERIFY_CERT_FLAG_MISMATCH : VERIFY_CERT_FLAG_NONE;
    if (!fingerprint) {
        return 0;
    }
    if (rdpCertificateTextLooksLikePem(fingerprint)) {
        return static_cast<DWORD>(captureRdpPreflightCertificate(
            instance, reinterpret_cast<const BYTE*>(fingerprint), strlen(fingerprint),
            nullptr, 0, flags | VERIFY_CERT_FLAG_FP_IS_PEM));
    }
    return static_cast<DWORD>(captureRdpPreflightCertificate(
        instance, nullptr, 0, nullptr, 0, flags, fingerprint));
}

static RdpPreflightResult probeRdpCertificateRouteWithFreeRdp(
    const RdpPreflightRequest& request) {
    if (rdpProbeCancelled(request.cancelled)) {
        return makeRdpPreflightError(
            request, "network", "E-RDP-NETWORK-CHANGED",
            "RDP route preflight cancelled because the default network changed");
    }
    RdpPreflightResult result = makeRdpPreflightError(
        request, "gateway", "E-RDP-GATEWAY-TLS", "Microsoft RD Gateway preflight failed");
    RdpGatewayPolicy::initializeGatewayTransportResult(
        result, request.route.gatewayTransport);

    // Inspect the HTTPS Gateway certificate on a credential-free TLS socket.
    // No HTTP/RPC/WebSocket request and no RDP X.224 bytes are sent here.
    const RdpCertificateInfo inspectedGateway = probeGatewayCertificateOverTls(
        request.route.gatewayHost, request.route.gatewayPort,
        request.route.gatewayServerName, request.cancelled);
    if (inspectedGateway.errorCode == -39 || rdpProbeCancelled(request.cancelled)) {
        return makeRdpPreflightError(
            request, "network", "E-RDP-NETWORK-CHANGED",
            "RDP route preflight cancelled because the default network changed");
    }
    result.gatewayCertificate = rdpCertificateRecordFromInfo(
        inspectedGateway, "gateway");
    if (!request.expectedGatewayFingerprintSha256.empty() &&
        !RdpCertificatePolicy::FingerprintMatches(
            request.expectedGatewayFingerprintSha256,
            result.gatewayCertificate.fingerprintSha256)) {
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.gatewayCertificate.riskFlags,
            RdpPreflightPolicy::kRiskCertificateChanged);
    }
    result.preflightStatus = inspectedGateway.ok ? RdpPreflightPolicy::kCompleted :
        (inspectedGateway.preflightStatus.empty() ? RdpPreflightPolicy::kUnavailable :
            inspectedGateway.preflightStatus);
    result.gatewayRiskFlags = result.gatewayCertificate.riskFlags;
    result.riskFlags = result.gatewayRiskFlags;
    if (!result.gatewayRiskFlags.empty()) {
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.gatewayRiskFlags, RdpPreflightPolicy::kRiskGatewayCertificate);
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.riskFlags, RdpPreflightPolicy::kRiskGatewayCertificate);
    }
    if (!result.gatewayCertificate.present) {
        result.stage = "gateway";
        result.errorCode = inspectedGateway.errorCode == -31 ? "E-RDP-GATEWAY-DNS" :
            (inspectedGateway.errorCode == -32 ? "E-RDP-GATEWAY-TCP" :
                "E-RDP-GATEWAY-TLS");
        result.errorMessage = inspectedGateway.errorMessage.empty()
            ? "RD Gateway TLS certificate was not received"
            : inspectedGateway.errorMessage;
        result.requiresUserDecision = result.preflightStatus ==
            RdpPreflightPolicy::kInconclusive ||
            (result.preflightStatus == RdpPreflightPolicy::kUnavailable &&
             inspectedGateway.errorCode != -30 && inspectedGateway.errorCode != -31 &&
             inspectedGateway.errorCode != -32);
        if (result.preflightStatus == RdpPreflightPolicy::kInconclusive) {
            RdpPreflightPolicy::addUniqueRiskFlag(
                result.gatewayRiskFlags, RdpPreflightPolicy::kRiskGatewayCertificate);
            RdpPreflightPolicy::addUniqueRiskFlag(
                result.riskFlags, RdpPreflightPolicy::kRiskGatewayCertificate);
        }
        return result;
    }
    if (!RdpGatewayPolicy::gatewayCertificateAllowsCredentialUse(
        request, result.gatewayCertificate)) {
        // Return a gateway-only decision point. The caller must confirm or pin
        // this certificate and rerun preflight before credentials are used.
        result.ok = true;
        result.stage = "gateway";
        result.errorCode.clear();
        result.errorMessage.clear();
        result.requiresUserDecision = true;
        return result;
    }
    if (rdpProbeCancelled(request.cancelled)) {
        return makeRdpPreflightError(
            request, "network", "E-RDP-NETWORK-CHANGED",
            "RDP route preflight cancelled because the default network changed");
    }

    RdpPreflightRequest authenticatedRequest = request;
    authenticatedRequest.expectedGatewayFingerprintSha256 =
        result.gatewayCertificate.fingerprintSha256;
    authenticatedRequest.gatewayAllowUntrustedRoot =
        !result.gatewayCertificate.rootTrusted;
    authenticatedRequest.gatewayAllowHostMismatch =
        result.gatewayCertificate.hostMismatch;

    freerdp* instance = freerdp_new();
    if (!instance) {
        result.errorCode = "E-RDP-GATEWAY-TLS";
        result.errorMessage = "Unable to create FreeRDP preflight instance";
        const RdpPreflightPolicy::ProbeFailureClassification classification =
            RdpPreflightPolicy::classifyErrorCode(result.errorCode, result.errorMessage);
        result.preflightStatus = classification.status;
        result.riskFlags = classification.riskFlags;
        result.gatewayRiskFlags = classification.riskFlags;
        return result;
    }
    if (!freerdp_context_new(instance)) {
        freerdp_free(instance);
        result.errorCode = "E-RDP-GATEWAY-TLS";
        result.errorMessage = "Unable to create FreeRDP preflight context";
        const RdpPreflightPolicy::ProbeFailureClassification classification =
            RdpPreflightPolicy::classifyErrorCode(result.errorCode, result.errorMessage);
        result.preflightStatus = classification.status;
        result.riskFlags = classification.riskFlags;
        result.gatewayRiskFlags = classification.riskFlags;
        return result;
    }
    const auto instanceDeleter = [](freerdp* value) {
        releaseRdpPreflightInstance(value);
    };
    std::unique_ptr<freerdp, decltype(instanceDeleter)> instanceOwner(
        instance, instanceDeleter);

    auto state = std::make_shared<RdpPreflightCallbackState>(authenticatedRequest);
    {
        std::lock_guard<std::mutex> lock(g_rdpPreflightMutex);
        g_rdpPreflightStates.emplace(instance, state);
    }

    auto* settings = instance->settings;
    const RdpGatewayTransportFlags transportFlags =
        RdpGatewayPolicy::transportFlags(request.route.gatewayTransport);
    freerdp_settings_set_string(settings, FreeRDP_ServerHostname,
                                request.route.targetHost.c_str());
    freerdp_settings_set_uint32(settings, FreeRDP_ServerPort,
                                static_cast<UINT32>(request.route.targetPort));
    freerdp_settings_set_string(settings, FreeRDP_GatewayHostname,
                                request.route.gatewayServerName.c_str());
    freerdp_settings_set_string(settings, FreeRDP_GatewayConnectHostname,
                                request.route.gatewayHost.c_str());
    freerdp_settings_set_uint32(settings, FreeRDP_GatewayPort,
                                static_cast<UINT32>(request.route.gatewayPort));
    freerdp_settings_set_bool(settings, FreeRDP_GatewayEnabled, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_GatewayRpcTransport,
                              transportFlags.rpc ? TRUE : FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_GatewayHttpTransport,
                              transportFlags.http ? TRUE : FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_GatewayHttpUseWebsockets,
                              transportFlags.websockets ? TRUE : FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_GatewayUseSameCredentials, TRUE);
    freerdp_settings_set_string(settings, FreeRDP_Username, request.username.c_str());
    freerdp_settings_set_string(settings, FreeRDP_Password, request.password.c_str());
    freerdp_settings_set_string(settings, FreeRDP_Domain, request.domain.c_str());
    freerdp_settings_set_string(settings, FreeRDP_GatewayUsername, request.username.c_str());
    freerdp_settings_set_string(settings, FreeRDP_GatewayPassword, request.password.c_str());
    freerdp_settings_set_string(settings, FreeRDP_GatewayDomain, request.domain.c_str());
    freerdp_settings_set_bool(settings, FreeRDP_ExternalCertificateManagement, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_CertificateCallbackPreferPEM, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_IgnoreCertificate, FALSE);
    // Keep the inspection route identical to the production connection's
    // TLS/NLA-only policy. FreeRDP defaults RdpSecurity to enabled, which
    // would otherwise let preflight accept a Standard RDP Security fallback
    // that the real connection intentionally rejects.
    freerdp_settings_set_bool(settings, FreeRDP_NegotiateSecurityLayer, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_UseRdpSecurityLayer, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_ExtSecurity, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_AadSecurity, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_RdstlsSecurity, FALSE);
    freerdp_settings_set_uint32(settings, FreeRDP_RequestedProtocols, 0x00000003);
    freerdp_settings_set_bool(settings, FreeRDP_Authentication, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_AutoLogonEnabled, TRUE);
    freerdp_settings_set_bool(settings, FreeRDP_RestrictedAdminModeRequired, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_RestrictedAdminModeSupported, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_RemoteCredentialGuard, FALSE);
    freerdp_settings_set_bool(settings, FreeRDP_AuthenticationOnly, TRUE);
    freerdp_settings_set_uint32(settings, FreeRDP_TcpConnectTimeout, 15000);
    freerdp_settings_set_string(settings, FreeRDP_AuthenticationPackageList, "ntlm");
    if (!request.route.targetServerName.empty()) {
        freerdp_settings_set_string(settings, FreeRDP_UserSpecifiedServerName,
                                    request.route.targetServerName.c_str());
        freerdp_settings_set_string(settings, FreeRDP_CertificateName,
                                    request.route.targetServerName.c_str());
    }

    instance->VerifyCertificate = probeVerifyRdpPreflightCertificate;
    instance->VerifyX509Certificate = probeVerifyRdpPreflightX509;
    instance->VerifyCertificateEx = probeVerifyRdpPreflightEx;
    instance->VerifyChangedCertificateEx = probeVerifyChangedRdpPreflightEx;
    std::mutex cancellationMutex;
    std::condition_variable cancellationCv;
    bool connectComplete = false;
    std::thread cancellationWatcher;
    if (request.cancelled) {
        try {
            cancellationWatcher = std::thread([
                &request, instance, &cancellationMutex,
                &cancellationCv, &connectComplete]() {
                for (;;) {
                    if (rdpProbeCancelled(request.cancelled)) {
                        if (instance->context) {
                            (void)freerdp_abort_connect_context(instance->context);
                        }
                        return;
                    }
                    std::unique_lock<std::mutex> lock(cancellationMutex);
                    if (cancellationCv.wait_for(
                            lock, std::chrono::milliseconds(25),
                            [&connectComplete]() { return connectComplete; })) {
                        return;
                    }
                }
            });
        } catch (...) {
            return makeRdpPreflightError(
                request, "network", "E-RDP-NETWORK-WATCHER",
                "Unable to start the RDP preflight cancellation watcher");
        }
    }
    BOOL connected = freerdp_connect(instance);
    {
        std::lock_guard<std::mutex> lock(cancellationMutex);
        connectComplete = true;
    }
    cancellationCv.notify_all();
    if (cancellationWatcher.joinable()) {
        cancellationWatcher.join();
    }

    {
        std::lock_guard<std::mutex> lock(g_rdpPreflightMutex);
        g_rdpPreflightStates.erase(instance);
    }
    instance->VerifyCertificate = nullptr;
    instance->VerifyX509Certificate = nullptr;
    instance->VerifyCertificateEx = nullptr;
    instance->VerifyChangedCertificateEx = nullptr;
    if (connected) {
        // A preflight must never return a live FreeRDP session.  This branch
        // is defensive: target callback normally aborts before post-connect.
        freerdp_disconnect(instance);
    }
    const bool networkCancelled = rdpProbeCancelled(request.cancelled);
    const DWORD lastError = instance->context ? freerdp_get_last_error(instance->context) : 0;
    const bool standardRdpSecuritySelected = instance->settings != nullptr &&
        freerdp_settings_get_bool(instance->settings, FreeRDP_UseRdpSecurityLayer) &&
        freerdp_settings_get_uint32(instance->settings, FreeRDP_SelectedProtocol) ==
            RdpNegotiation::kProtocolRdp;
    const bool gatewaySeen = state->result.gatewayCertificate.present;
    const bool targetSeen = state->result.targetCertificate.present;
    const bool targetMetadataInvalid = state->targetCertificateMetadataInvalid;
    const bool gatewayMetadataInvalid = state->gatewayCertificateMetadataInvalid;
    if (networkCancelled) {
        result = makeRdpPreflightError(
            request, "network", "E-RDP-NETWORK-CHANGED",
            "RDP route preflight cancelled because the default network changed");
    } else if (targetMetadataInvalid || gatewayMetadataInvalid) {
        const bool targetStage = targetMetadataInvalid;
        result.stage = targetStage ? "target" : "gateway";
        result.errorCode = targetStage ? "E-RDP-TARGET-CERT" : "E-RDP-GATEWAY-CERT";
        result.preflightStatus = RdpPreflightPolicy::kInconclusive;
        result.errorMessage = targetStage
            ? "FreeRDP returned a target certificate without usable metadata"
            : "FreeRDP returned a Gateway certificate without usable metadata";
        result.requiresUserDecision = true;
        if (gatewayMetadataInvalid) {
            RdpPreflightPolicy::addUniqueRiskFlag(
                result.gatewayRiskFlags,
                RdpPreflightPolicy::kRiskCertificateMetadataUnavailable);
            RdpPreflightPolicy::addUniqueRiskFlag(
                result.gatewayRiskFlags, RdpPreflightPolicy::kRiskGatewayCertificate);
        }
        if (targetMetadataInvalid) {
            RdpPreflightPolicy::addUniqueRiskFlag(
                result.targetRiskFlags,
                RdpPreflightPolicy::kRiskCertificateMetadataUnavailable);
            RdpPreflightPolicy::addUniqueRiskFlag(
                result.targetRiskFlags, RdpPreflightPolicy::kRiskTargetCertificate);
        }
        RdpPreflightPolicy::mergeRiskFlags(result.riskFlags, result.gatewayRiskFlags);
        RdpPreflightPolicy::mergeRiskFlags(result.riskFlags, result.targetRiskFlags);
    } else if (targetSeen && gatewaySeen && !state->unsupportedFlags &&
        !state->gatewayCertificateRejected) {
        result.ok = true;
        result.preflightStatus = RdpPreflightPolicy::kCompleted;
        result.stage = "target";
        result.errorCode.clear();
        result.errorMessage.clear();
        result.gatewayCertificate = state->result.gatewayCertificate;
        result.targetCertificate = state->result.targetCertificate;
        result.gatewayRiskFlags = result.gatewayCertificate.riskFlags;
        result.targetRiskFlags = result.targetCertificate.riskFlags;
        result.riskFlags.clear();
        RdpPreflightPolicy::mergeRiskFlags(result.riskFlags, result.gatewayRiskFlags);
        RdpPreflightPolicy::mergeRiskFlags(result.riskFlags, result.targetRiskFlags);
        result.requiresGatewayAuth = false;
        result.requiresUserDecision =
            !RdpGatewayPolicy::gatewayTrustAllowsRoute(
                request, result.gatewayCertificate, result.targetCertificate);
    } else if (state->gatewayCertificateRejected) {
        result.stage = "gateway";
        result.errorCode = "E-RDP-GATEWAY-CERT";
        result.preflightStatus = RdpPreflightPolicy::kInconclusive;
        result.errorMessage =
            "RD Gateway certificate changed after credential-free TLS inspection";
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.gatewayRiskFlags, RdpPreflightPolicy::kRiskCertificateChanged);
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.gatewayRiskFlags, RdpPreflightPolicy::kRiskGatewayCertificate);
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.riskFlags, RdpPreflightPolicy::kRiskCertificateChanged);
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.riskFlags, RdpPreflightPolicy::kRiskGatewayCertificate);
        result.requiresUserDecision = true;
    } else if (state->unsupportedFlags) {
        result.stage = gatewaySeen ? "gateway" : "target";
        result.errorCode = "E-RDP-CERT";
        result.preflightStatus = RdpPreflightPolicy::kInconclusive;
        result.errorMessage = "FreeRDP returned an unsupported certificate callback flag";
        result.requiresUserDecision = true;
    } else if (gatewaySeen) {
        if (standardRdpSecuritySelected) {
            // The Gateway tunnel reached the target, which explicitly selected
            // Standard RDP Security. There is no TLS certificate to inspect,
            // so this is an advisory target-security risk, not a tunnel error.
            result.stage = "negotiation";
            result.errorCode = "E-RDP-NEGOTIATION";
            result.preflightStatus = RdpPreflightPolicy::kInconclusive;
            result.errorMessage =
                "Target RDP server selected Standard RDP Security; TLS certificate probe is unavailable";
            result.requiresUserDecision = true;
            RdpPreflightPolicy::addUniqueRiskFlag(
                result.targetRiskFlags, RdpPreflightPolicy::kRiskStandardRdpSecurity);
            RdpPreflightPolicy::addUniqueRiskFlag(
                result.targetRiskFlags, RdpPreflightPolicy::kRiskTargetCertificate);
            RdpPreflightPolicy::addUniqueRiskFlag(
                result.riskFlags, RdpPreflightPolicy::kRiskStandardRdpSecurity);
            RdpPreflightPolicy::addUniqueRiskFlag(
                result.riskFlags, RdpPreflightPolicy::kRiskTargetCertificate);
        } else {
            result.stage = "tunnel";
            result.errorCode = request.username.empty() ? "E-RDP-GATEWAY-AUTH-REQUIRED" :
                "E-RDP-GATEWAY-TUNNEL";
            result.preflightStatus = request.username.empty()
                ? RdpPreflightPolicy::kInconclusive
                : RdpPreflightPolicy::kTransportFailed;
            result.errorMessage = request.username.empty()
                ? "RD Gateway authentication is required before the target certificate can be read"
                : "RD Gateway did not provide the tunneled target RDP certificate";
            result.requiresGatewayAuth = request.username.empty();
            result.requiresUserDecision = request.username.empty();
        }
    } else {
        result.stage = "gateway";
        result.errorCode = "E-RDP-GATEWAY-TLS";
        result.preflightStatus = RdpPreflightPolicy::kInconclusive;
        result.errorMessage = lastError == 0 ?
            "RD Gateway TLS certificate was not received" :
            std::string("RD Gateway connection failed: ") +
                freerdpErrorName(lastError);
        result.requiresUserDecision = true;
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.gatewayRiskFlags, RdpPreflightPolicy::kRiskGatewayCertificate);
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.riskFlags, RdpPreflightPolicy::kRiskGatewayCertificate);
    }
    result.gatewayCertificate = state->result.gatewayCertificate;
    result.targetCertificate = state->result.targetCertificate;
    if (result.gatewayRiskFlags.empty()) {
        result.gatewayRiskFlags = result.gatewayCertificate.riskFlags;
    }
    if (result.targetRiskFlags.empty()) {
        result.targetRiskFlags = result.targetCertificate.riskFlags;
    }
    RdpPreflightPolicy::mergeRiskFlags(result.riskFlags, result.gatewayRiskFlags);
    RdpPreflightPolicy::mergeRiskFlags(result.riskFlags, result.targetRiskFlags);
    return result;
}

DWORD FreeRdpAdapter::evaluateCertificate(const char* host, UINT16 port,
                                          const char* commonName, const char* subject,
                                          const char* issuer, const std::string& fingerprint,
                                          DWORD flags, const BYTE* pemData,
                                          size_t pemLength) {
    const std::string logHost = SafeLog::MaskHost(host ? host : "");
    const std::string logCommonName = SafeLog::MaskHost(commonName ? commonName : "");
    const bool gatewayCertificate = (flags & VERIFY_CERT_FLAG_GATEWAY) != 0;
    bool hostMismatch = (flags & VERIFY_CERT_FLAG_MISMATCH) != 0;

    std::string expectedFingerprint;
    std::string verificationName;
    bool allowHostMismatch = false;
    bool allowUntrustedRoot = false;
    bool allowUnpinnedOnce = false;
    bool allowTimeAnomalyOnce = false;
    std::string endpointMode;
    {
        std::lock_guard<std::mutex> lock(impl_->configMutex);
        expectedFingerprint = gatewayCertificate
            ? impl_->config.expectedRdpGatewayCertificateFingerprintSha256
            : impl_->config.expectedRdpCertificateFingerprintSha256;
        allowHostMismatch = gatewayCertificate
            ? impl_->config.rdpGatewayAllowHostMismatch
            : impl_->config.rdpAllowHostMismatch;
        allowUntrustedRoot = gatewayCertificate
            ? impl_->config.rdpGatewayAllowUntrustedRoot
            : impl_->config.rdpAllowUntrustedRoot;
        allowUnpinnedOnce = gatewayCertificate
            ? impl_->config.rdpGatewayCertificateAllowUnpinnedOnce
            : impl_->config.rdpCertificateAllowUnpinnedOnce;
        allowTimeAnomalyOnce = gatewayCertificate
            ? impl_->config.rdpGatewayCertificateAllowTimeAnomalyOnce
            : impl_->config.rdpCertificateAllowTimeAnomalyOnce;
        verificationName = gatewayCertificate
            ? (impl_->config.rdpGatewayServerName.empty()
                ? impl_->config.gatewayHost : impl_->config.rdpGatewayServerName)
            : (impl_->config.targetServerName.empty()
                ? impl_->config.host : impl_->config.targetServerName);
        endpointMode = impl_->config.rdpEndpointMode;
    }
    constexpr DWORD kKnownFlags = VERIFY_CERT_FLAG_LEGACY |
        VERIFY_CERT_FLAG_GATEWAY | VERIFY_CERT_FLAG_CHANGED |
        VERIFY_CERT_FLAG_MISMATCH | VERIFY_CERT_FLAG_MATCH_LEGACY_SHA1 |
        VERIFY_CERT_FLAG_FP_IS_PEM;
    const bool unsupportedFlags = (flags & ~kKnownFlags) != 0 ||
        (flags & VERIFY_CERT_FLAG_REDIRECT) != 0;
    RdpEndpointMode configuredMode = RdpEndpointMode::DirectRdp;
    const bool routeModeKnown = RdpGatewayPolicy::parseEndpointMode(endpointMode, configuredMode);
    if (gatewayCertificate && (!routeModeKnown ||
        configuredMode != RdpEndpointMode::MicrosoftRdGateway)) {
        OH_LOG_ERROR(LOG_APP,
            "[RDP] gateway certificate callback received for non-gateway route mode=%{public}s",
            endpointMode.c_str());
        impl_->setState(ConnectionState::ERROR,
                        "RDP Gateway certificate was received on an invalid route [E-RDP-GATEWAY-CERT]");
        return 0;
    }
    if (unsupportedFlags) {
        OH_LOG_ERROR(LOG_APP,
            "[RDP] certificate callback rejected unsupported flags=0x%{public}08X",
            flags);
        impl_->setState(ConnectionState::ERROR,
                        gatewayCertificate
                            ? "RDP Gateway certificate callback flags are unsupported [E-RDP-GATEWAY-CERT]"
                            : "RDP certificate callback flags are unsupported [E-RDP-TARGET-CERT]");
        return 0;
    }
    const bool rootKnown = pemData != nullptr && pemLength > 0;
    if (!rootKnown) {
        // Older FreeRDP builds can call only the fingerprint callback. A
        // fingerprint is sufficient for an explicit pin or a route-bound
        // Continue Once, but it cannot prove CA chain or certificate time.
        // Never turn missing metadata into an implicit trust decision.
        const bool fingerprintKnown =
            !RdpCertificatePolicy::NormalizeFingerprint(fingerprint).empty();
        if (!fingerprintKnown) {
            impl_->setState(ConnectionState::ERROR,
                            gatewayCertificate
                                ? "RDP Gateway certificate identity is unavailable [E-RDP-GATEWAY-CERT-METADATA]"
                                : "RDP target certificate identity is unavailable [E-RDP-TARGET-CERT-METADATA]");
            return 0;
        }
        const bool fingerprintOk = RdpCertificatePolicy::FingerprintMatches(
            expectedFingerprint, fingerprint) || allowUnpinnedOnce;
        const bool hostOk = !hostMismatch || allowHostMismatch || allowUnpinnedOnce;
        if (fingerprintOk && hostOk) {
            OH_LOG_WARN(LOG_APP,
                "[RDP] %s certificate accepted by fingerprint-only callback; chain/time metadata unavailable host=%{public}s:%{public}u flags=0x%{public}08X",
                gatewayCertificate ? "gateway" : "target", logHost.c_str(), port, flags);
            return 2;
        }
        OH_LOG_ERROR(LOG_APP,
            "[RDP] %s fingerprint-only certificate rejected host=%{public}s:%{public}u flags=0x%{public}08X fingerprintMatch=%{public}s hostOk=%{public}s",
            gatewayCertificate ? "gateway" : "target", logHost.c_str(), port, flags,
            fingerprintOk ? "true" : "false", hostOk ? "true" : "false");
        impl_->setState(ConnectionState::ERROR,
                        gatewayCertificate
                            ? "RDP Gateway certificate was not explicitly trusted [E-RDP-GATEWAY-CERT]"
                            : "RDP target certificate was not explicitly trusted [E-RDP-TARGET-CERT]");
        return 0;
    }
    bool pemParsed = false;
    const bool pemHostMatches = RdpCertificateValidation::hostnameMatchesPem(
        pemData, pemLength,
        verificationName.empty() ? (host ? host : "") : verificationName,
        pemParsed);
    if (!pemParsed) {
        impl_->setState(ConnectionState::ERROR,
                        gatewayCertificate
                            ? "RDP Gateway certificate PEM is invalid [E-RDP-GATEWAY-CERT]"
                            : "RDP target certificate PEM is invalid [E-RDP-TARGET-CERT]");
        return 0;
    }
    // ExternalCertificateManagement may invoke the PEM callback before
    // FreeRDP's own hostname-mismatch flag is produced. Recompute SAN/CN
    // matching from the certificate instead of trusting that flag alone.
    hostMismatch = !pemHostMatches;
    // This flag is set only by an explicit, route-bound Continue Once handoff
    // from the preflight UI. It remains valid even when an older saved pin is
    // present: the user is explicitly choosing to evaluate the live callback
    // certificate once rather than silently accepting the old pin.
    const bool unpinnedOnceForCurrentRoute = allowUnpinnedOnce;
    const bool fingerprintOk = RdpCertificatePolicy::FingerprintMatches(
        expectedFingerprint, fingerprint) || unpinnedOnceForCurrentRoute;
    const bool hostOk = !hostMismatch || allowHostMismatch || unpinnedOnceForCurrentRoute;
    const bool rootTrusted = rootTrustedFromPem(pemData, pemLength);
    const bool rootOk = rootTrusted || allowUntrustedRoot || unpinnedOnceForCurrentRoute;
    bool validityOk = true;
    if (pemData != nullptr && pemLength > 0) {
        BIO* bio = BIO_new_mem_buf(pemData, static_cast<int>(pemLength));
        X509* cert = bio ? PEM_read_bio_X509(bio, nullptr, nullptr, nullptr) : nullptr;
        if (bio) {
            BIO_free(bio);
        }
        validityOk = cert != nullptr && x509ValidityIsCurrent(cert);
        if (cert) {
            X509_free(cert);
        }
    }
    if (!validityOk && !allowTimeAnomalyOnce && !unpinnedOnceForCurrentRoute) {
        OH_LOG_ERROR(LOG_APP,
            "[RDP] %s certificate validity is not current or cannot be parsed flags=0x%{public}08X",
            gatewayCertificate ? "gateway" : "target", flags);
        impl_->setState(ConnectionState::ERROR,
                        gatewayCertificate
                            ? "RDP Gateway certificate is expired or not yet valid [E-RDP-GATEWAY-CERT]"
                            : "RDP target certificate is expired or not yet valid [E-RDP-TARGET-CERT]");
        return 0;
    }
    if (fingerprintOk && hostOk && rootOk) {
        OH_LOG_WARN(LOG_APP,
            "[RDP] %s certificate accepted host=%{public}s:%{public}u common_name=%{public}s flags=0x%{public}08X fingerprintMatch=%{public}s hostOk=%{public}s rootOk=%{public}s",
            gatewayCertificate ? "gateway" : "target",
            logHost.c_str(), port, logCommonName.c_str(), flags,
            fingerprintOk ? "true" : "false", hostOk ? "true" : "false",
            rootOk ? "true" : "false");
        return 2;
    }

    OH_LOG_ERROR(LOG_APP,
        "[RDP] %s certificate rejected host=%{public}s:%{public}u common_name=%{public}s flags=0x%{public}08X hostMismatch=%{public}s fingerprintMatch=%{public}s hostOk=%{public}s rootOk=%{public}s",
        gatewayCertificate ? "gateway" : "target",
        logHost.c_str(), port, logCommonName.c_str(), flags,
        hostMismatch ? "true" : "false", fingerprintOk ? "true" : "false",
        hostOk ? "true" : "false", rootOk ? "true" : "false");
    impl_->setState(ConnectionState::ERROR,
                    gatewayCertificate
                        ? "RDP Gateway certificate was not trusted or changed [E-RDP-GATEWAY-CERT]"
                        : "RDP target certificate was not trusted or changed [E-RDP-TARGET-CERT]");
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
    const bool fingerprintIsPem = rdpCertificateTextLooksLikePem(fingerprint);
    DWORD flags = host_mismatch ? VERIFY_CERT_FLAG_MISMATCH : VERIFY_CERT_FLAG_NONE;
    if (fingerprintIsPem) {
        flags |= VERIFY_CERT_FLAG_FP_IS_PEM;
    }
    const BYTE* pemData = fingerprintIsPem
        ? reinterpret_cast<const BYTE*>(fingerprint) : nullptr;
    const size_t pemLength = fingerprintIsPem && fingerprint ? strlen(fingerprint) : 0;
    const std::string actualFingerprint = fingerprintIsPem
        ? fingerprintFromPem(pemData, pemLength)
        : (fingerprint ? fingerprint : "");
    FreeRdpAdapter* self = callbackLease.adapter;
    return self ? self->evaluateCertificate(nullptr, 0, common_name, subject, issuer,
                                            actualFingerprint, flags, pemData, pemLength) : 0;
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
    if (!self) {
        return 0;
    }
    const bool fingerprintIsPem = (flags & VERIFY_CERT_FLAG_FP_IS_PEM) != 0 ||
        rdpCertificateTextLooksLikePem(fingerprint);
    const BYTE* pemData = fingerprintIsPem ?
        reinterpret_cast<const BYTE*>(fingerprint) : nullptr;
    const size_t pemLength = fingerprintIsPem && fingerprint ? strlen(fingerprint) : 0;
    const std::string actualFingerprint = fingerprintIsPem
        ? fingerprintFromPem(pemData, pemLength)
        : (fingerprint ? fingerprint : "");
    return self->evaluateCertificate(host, port, common_name, subject, issuer,
                                     actualFingerprint, flags, pemData, pemLength);
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
    if (!self) {
        return 0;
    }
    const DWORD effectiveFlags = flags | VERIFY_CERT_FLAG_CHANGED;
    const bool fingerprintIsPem = (effectiveFlags & VERIFY_CERT_FLAG_FP_IS_PEM) != 0 ||
        rdpCertificateTextLooksLikePem(new_fingerprint);
    const BYTE* pemData = fingerprintIsPem ?
        reinterpret_cast<const BYTE*>(new_fingerprint) : nullptr;
    const size_t pemLength = fingerprintIsPem && new_fingerprint ? strlen(new_fingerprint) : 0;
    const std::string actualFingerprint = fingerprintIsPem
        ? fingerprintFromPem(pemData, pemLength)
        : (new_fingerprint ? new_fingerprint : "");
    return self->evaluateCertificate(host, port, common_name, subject, issuer,
                                     actualFingerprint, effectiveFlags, pemData, pemLength);
}

int FreeRdpAdapter::cbVerifyX509Certificate(freerdp* instance, const BYTE* data, size_t length,
                                            const char* hostname, UINT16 port, DWORD flags) {
    auto callbackLease = acquireRdpCallbackInstance(instance);
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return 0;
    }
    FreeRdpAdapter* self = callbackLease.adapter;
    if (!self) {
        return 0;
    }
    const std::string fingerprint = fingerprintFromPem(data, length);
    return static_cast<int>(self->evaluateCertificate(hostname, port, nullptr, nullptr,
                                                       nullptr, fingerprint, flags, data, length));
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
    const std::string message = rdpErrorInfoMessage(code);
    adapter->impl_->rememberPendingErrorInfo(code, message);
    OH_LOG_WARN(LOG_APP,
                "[RDP] ErrorInfo retained as advisory until transport termination: raw=0x%{public}08X state=%{public}d",
                code, static_cast<int>(adapter->getState()));
}

#if defined(CHANNEL_DISP_CLIENT)
UINT FreeRdpAdapter::cbDisplayControlCaps(DispClientContext* context,
                                         UINT32 maxNumMonitors,
                                         UINT32 maxMonitorAreaFactorA,
                                         UINT32 maxMonitorAreaFactorB) {
    if (!context || !context->custom) {
        return CHANNEL_RC_OK;
    }
    auto callbackLease = acquireRdpCallbackContext(
        static_cast<::rdpContext*>(context->custom));
    if (!acquireCurrentRdpCallbackOwnerLease(callbackLease)) {
        return CHANNEL_RC_OK;
    }
    FreeRdpAdapter* owner = callbackLease.adapter;
    if (!owner || !owner->impl_) {
        return CHANNEL_RC_OK;
    }
    std::lock_guard<std::mutex> displayLock(owner->impl_->displayControlMutex);
    if (owner->impl_->displayControl != context) {
        return CHANNEL_RC_OK;
    }
    owner->impl_->displayMaxNumMonitors = maxNumMonitors;
    owner->impl_->displayMaxAreaFactorA = maxMonitorAreaFactorA;
    owner->impl_->displayMaxAreaFactorB = maxMonitorAreaFactorB;
    const bool usable = maxNumMonitors >= 1 &&
        maxMonitorAreaFactorA >= DISPLAY_CONTROL_MIN_MONITOR_WIDTH &&
        maxMonitorAreaFactorB >= DISPLAY_CONTROL_MIN_MONITOR_HEIGHT;
    owner->impl_->displayControlDisabled = owner->impl_->displayControlDisabled || !usable;
    owner->impl_->displayControlReady = usable && !owner->impl_->displayControlDisabled;
    owner->impl_->displayLastResult = owner->impl_->displayControlReady ?
        "caps_ready" : "caps_invalid";
    OH_LOG_INFO(LOG_APP,
        "[RDP-DISP] caps monitors=%{public}u area=%{public}ux%{public}u usable=%{public}s",
        maxNumMonitors, maxMonitorAreaFactorA, maxMonitorAreaFactorB,
        usable ? "true" : "false");
    return CHANNEL_RC_OK;
}
#endif

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
#if defined(CHANNEL_DISP_CLIENT)
    if (std::strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0 && e->pInterface) {
        std::lock_guard<std::mutex> displayLock(owner->impl_->displayControlMutex);
        auto* displayControl = reinterpret_cast<DispClientContext*>(e->pInterface);
        if (owner->impl_->displayControl && owner->impl_->displayControl != displayControl) {
            owner->impl_->displayControl->DisplayControlCaps = nullptr;
            owner->impl_->displayControl->custom = nullptr;
        }
        owner->impl_->displayControl = displayControl;
        displayControl->custom = rdpContext;
        displayControl->DisplayControlCaps = cbDisplayControlCaps;
        owner->impl_->displayControlReady = false;
        owner->impl_->displayControlDisabled = false;
        owner->impl_->displayLayoutInFlight = false;
        owner->impl_->displayInFlightSinceUs = 0;
        owner->impl_->displayMaxNumMonitors = 0;
        owner->impl_->displayMaxAreaFactorA = 0;
        owner->impl_->displayMaxAreaFactorB = 0;
        owner->impl_->displayLastResult = "caps_pending";
        OH_LOG_INFO(LOG_APP, "[RDP-DISP] display-control channel connected; waiting for caps");
    }
#endif
    if (std::strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0 && e->pInterface) {
        auto* cliprdr = reinterpret_cast<CliprdrClientContext*>(e->pInterface);
        if (!isRdpCallbackLeaseRegistered(callbackLease) ||
            !owner->isCallbackOwnerCurrent(callbackLease.owner,
                                           callbackLease.generation)) {
            return;
        }
        std::lock_guard<std::mutex> channelLock(owner->impl_->cliprdrMutex);
        if (!owner->impl_->rdpClipboardEnabled()) {
            const auto previous = owner->impl_->cliprdr;
            owner->impl_->cliprdr = nullptr;
            if (previous) {
                unregisterRdpChannelCallbackContext(previous);
            }
            if (owner->impl_->fileClipboard) {
                owner->impl_->fileClipboard->detach();
            }
            OH_LOG_WARN(LOG_APP,
                        "[RDP] cliprdr channel arrived while clipboard setting is disabled; callbacks not installed");
            return;
        }
        const auto previous = owner->impl_->cliprdr;
        if (previous && previous != cliprdr) {
            unregisterRdpChannelCallbackContext(previous);
            owner->impl_->cliprdr = nullptr;
            if (owner->impl_->fileClipboard) {
                owner->impl_->fileClipboard->detach();
            }
        }
        const bool attached = owner->impl_->fileClipboard &&
            owner->impl_->fileClipboard->attach(cliprdr);
        const bool registered = attached &&
            registerRdpChannelCallbackContext(cliprdr, callbackLease);
        if (registered) {
            owner->impl_->cliprdr = cliprdr;
            cliprdr->ServerCapabilities = cbCliprdrServerCapabilities;
            cliprdr->MonitorReady = cbCliprdrMonitorReady;
            cliprdr->ServerFormatList = cbCliprdrServerFormatList;
            cliprdr->ServerFormatDataRequest = cbCliprdrServerFormatDataRequest;
            cliprdr->ServerFormatDataResponse = cbCliprdrServerFormatDataResponse;
        } else {
            if (attached && owner->impl_->fileClipboard) {
                owner->impl_->fileClipboard->detach();
            }
            OH_LOG_WARN(LOG_APP,
                        "[RDP] file clipboard bridge unavailable; clipboard disabled for this session");
        }
    }
    if (std::strcmp(e->name, RDPDR_SVC_CHANNEL_NAME) == 0 && e->pInterface) {
        std::lock_guard<std::mutex> rdpdrLock(owner->impl_->rdpdrMutex);
        owner->impl_->rdpdr = reinterpret_cast<RdpdrClientContext*>(e->pInterface);
        OH_LOG_INFO(LOG_APP, "[RDP] device-redirection channel interface attached");
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
    if (!owner->impl_->rdpClipboardEnabled()) {
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
    if (!owner->impl_->rdpClipboardEnabled()) {
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
    if (!owner->impl_->rdpClipboardEnabled()) {
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
    if (!owner->impl_->rdpClipboardEnabled()) {
        return ERROR_INVALID_PARAMETER;
    }
    if (owner->impl_->fileClipboard &&
        owner->impl_->fileClipboard->isFileFormat(request->requestedFormatId)) {
        return owner->impl_->fileClipboard->respondToFileFormatRequest(request);
    }
    if (request->requestedFormatId != CF_UNICODETEXT) {
        return ERROR_INVALID_PARAMETER;
    }
    std::string clipboardText;
    {
        std::lock_guard<std::mutex> lock(owner->impl_->clipboardMutex);
        clipboardText = owner->impl_->clipboardText;
    }
    std::vector<uint16_t> wide = utf8ToUtf16(clipboardText);
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
    if (!owner->impl_->rdpClipboardEnabled()) {
        return ERROR_INVALID_PARAMETER;
    }
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
    {
        std::lock_guard<std::mutex> lock(owner->impl_->clipboardMutex);
        owner->impl_->clipboardText = std::move(text);
    }
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
#if defined(CHANNEL_DISP_CLIENT)
    if (std::strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        std::lock_guard<std::mutex> displayLock(owner->impl_->displayControlMutex);
        auto* displayControl = reinterpret_cast<DispClientContext*>(e->pInterface);
        if (RdpDisplayLayoutPolicy::ShouldDetachDisplayChannel(
                owner->impl_->displayControl, displayControl)) {
            displayControl->DisplayControlCaps = nullptr;
            displayControl->custom = nullptr;
            owner->impl_->displayControl = nullptr;
            owner->impl_->displayControlReady = false;
            owner->impl_->displayLayoutPending = false;
            owner->impl_->displayLayoutInFlight = false;
            owner->impl_->displayMaxNumMonitors = 0;
            owner->impl_->displayMaxAreaFactorA = 0;
            owner->impl_->displayMaxAreaFactorB = 0;
            owner->impl_->displayLastSendUs = 0;
            owner->impl_->displayInFlightSinceUs = 0;
            owner->impl_->displayLastResult = "channel_disconnected";
            OH_LOG_INFO(LOG_APP, "[RDP-DISP] display-control channel disconnected");
        } else {
            if (displayControl) {
                displayControl->DisplayControlCaps = nullptr;
                displayControl->custom = nullptr;
            }
            OH_LOG_INFO(LOG_APP,
                "[RDP-DISP] ignored stale display-control disconnect interface=%{public}p current=%{public}p",
                displayControl, owner->impl_->displayControl);
        }
    }
#endif
    if (std::strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        if (owner && owner->impl_) {
            std::lock_guard<std::mutex> channelLock(owner->impl_->cliprdrMutex);
            const auto channel = owner->impl_->cliprdr;
            owner->impl_->cliprdr = nullptr;
            if (channel) {
                unregisterRdpChannelCallbackContext(channel);
            }
            if (owner->impl_->fileClipboard) {
                owner->impl_->fileClipboard->detach();
            }
        }
    }
    if (std::strcmp(e->name, RDPDR_SVC_CHANNEL_NAME) == 0) {
        std::lock_guard<std::mutex> rdpdrLock(owner->impl_->rdpdrMutex);
        if (!e->pInterface ||
            owner->impl_->rdpdr == reinterpret_cast<RdpdrClientContext*>(e->pInterface)) {
            owner->impl_->rdpdr = nullptr;
        }
        OH_LOG_INFO(LOG_APP, "[RDP] device-redirection channel interface detached");
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
    self->impl_->lastInputPostedUs.store(0, std::memory_order_release);
    self->impl_->lastEventLoopTickUs.store(0, std::memory_order_release);
    self->impl_->eventLoopBlockMaxUs.store(0, std::memory_order_release);
    self->impl_->eventLoopTicks.store(0, std::memory_order_release);
    self->impl_->networkCheckCount.store(0, std::memory_order_release);
    self->impl_->networkCheckFailures.store(0, std::memory_order_release);
    self->impl_->inputPostFailures.store(0, std::memory_order_release);
    self->impl_->lastRenderDiagUs = 0;
    self->impl_->lastRenderBytes.store(0, std::memory_order_release);
    self->impl_->lastFrameWidth = 0;
    self->impl_->lastFrameHeight = 0;
    self->impl_->forceNextFullFrame = true;
    self->impl_->damageAccumulator->clear();
    if (!self->impl_->startSessionWorkers(self)) {
        self->impl_->presentationEnabled.store(false, std::memory_order_release);
        const Render::DecoderSessionIdentity failedOwner = callbackLease.owner;
        if (failedOwner.valid()) {
            RendererNapi::InvalidateActivePresentation(failedOwner);
        } else {
            RendererNapi::InvalidateActivePresentation();
        }
        // Do not free GDI from this callback.  If a worker stop exceeded its
        // bounded budget, the deferred worker still owns the instance lease;
        // the normal freerdp_connect failure path will run cleanupInstance()
        // after that fence and retire GDI in the ordered platform cleanup.
        OH_LOG_ERROR(LOG_APP,
            "[RDP] post-connect worker startup failed; refusing CONNECTED session [E-RDP-WORKER-START]");
        return FALSE;
    }
    const Render::DecoderSessionIdentity presentationOwner = callbackLease.owner;
    if (presentationOwner.valid()) {
        RendererNapi::ReenableActivePresentation(presentationOwner);
        (void)RendererNapi::SetActivePboUpload(presentationOwner, false);
    } else {
        RendererNapi::ReenableActivePresentation();
        (void)RendererNapi::SetActivePboUpload(false);
    }
    self->impl_->presentationEnabled.store(true, std::memory_order_release);
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
    {
        std::lock_guard<std::mutex> displayLock(adapter->impl_->displayControlMutex);
        adapter->impl_->displayEffectiveWidth = ticket.width;
        adapter->impl_->displayEffectiveHeight = ticket.height;
        adapter->impl_->displayLayoutInFlight = false;
        adapter->impl_->displayInFlightSinceUs = 0;
        if (adapter->impl_->displayRequestedWidth > 0 &&
            adapter->impl_->displayRequestedHeight > 0) {
            const bool exact = adapter->impl_->displayRequestedWidth == ticket.width &&
                adapter->impl_->displayRequestedHeight == ticket.height;
            adapter->impl_->displayLastResult = exact ? "applied" : "server_adjusted";
        } else {
            adapter->impl_->displayLastResult = "initial_geometry";
        }
    }
    return TRUE;
}

// ---- 事件循环线程 ----
bool FreeRdpAdapter::startEventLoop() {
    std::shared_ptr<FreeRdpAdapter> retained;
    try {
        retained = shared_from_this();
    } catch (const std::bad_weak_ptr&) {
        OH_LOG_ERROR(LOG_APP, "[RDP] event worker requires shared adapter lifetime");
        return false;
    }
    if (!retained) {
        return false;
    }
    RdpWorkerReservation workerReservation = reserveRdpWorker();
    if (!workerReservation) {
        OH_LOG_ERROR(LOG_APP,
            "[RDP] event worker rejected: deferred-owner capacity exhausted");
        return false;
    }
    std::shared_ptr<std::atomic<bool>> done;
    try {
        done = std::make_shared<std::atomic<bool>>(false);
    } catch (...) {
        OH_LOG_ERROR(LOG_APP,
            "[RDP] event worker rejected: completion fence unavailable");
        return false;
    }
    eventLoopRunning_.store(true, std::memory_order_release);
    std::atomic_store_explicit(&impl_->eventThreadDone, done, std::memory_order_release);
    try {
        impl_->eventThreadReservation = std::move(workerReservation);
        impl_->eventThread = std::thread([retained, done]() {
            retained->processEventLoop();
            done->store(true, std::memory_order_release);
            retained->impl_->workerDoneCv.notify_all();
        });
    } catch (const std::exception& e) {
        impl_->eventThreadReservation.release();
        eventLoopRunning_.store(false, std::memory_order_release);
        done->store(true, std::memory_order_release);
        OH_LOG_ERROR(LOG_APP,
            "[RDP] event loop worker start failed: %{public}s", e.what());
        return false;
    } catch (...) {
        impl_->eventThreadReservation.release();
        eventLoopRunning_.store(false, std::memory_order_release);
        done->store(true, std::memory_order_release);
        OH_LOG_ERROR(LOG_APP, "[RDP] event loop worker start failed");
        return false;
    }
    return true;
}

void FreeRdpAdapter::stopEventLoop(RdpShutdownDeadline deadline) {
    impl_->traceShutdown("event-stop", "begin");
    eventLoopRunning_.store(false, std::memory_order_release);
    const auto doneFence = std::atomic_load_explicit(
        &impl_->eventThreadDone, std::memory_order_acquire);
    if (!impl_->eventThread.joinable()) {
        impl_->eventThreadReservation.release();
        impl_->traceShutdown("event-stop", "not-started");
        return;
    }
    if (impl_->eventThread.joinable()) {
        if (impl_->eventThread.get_id() == std::this_thread::get_id()) {
            (void)deferRdpWorker(
                impl_->eventThreadReservation, impl_->eventThread,
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
                impl_->eventThreadReservation.release();
            } else {
                OH_LOG_WARN(LOG_APP,
                    "[RDP] event worker exceeded shutdown budget; deferring join");
                (void)deferRdpWorker(
                    impl_->eventThreadReservation, impl_->eventThread,
                    impl_->lifetime.lock(), doneFence);
            }
        }
    }
    impl_->traceShutdown("event-stop", "complete");
}

void FreeRdpAdapter::processEventLoop() {
    HANDLE handles[64];
    bool transportEnded = false;
    constexpr DWORD kInvalidHandleIndex = static_cast<DWORD>(-1);
    constexpr DWORD kHandleCapacity = 64;

    // FreeRDP exposes its input message queue as the supported cross-thread
    // handoff.  The vendored client queue's private proxy is not initialized
    // by the regular freerdp_new() path, so consume the already-serialized
    // messages here and call the public input entry points on this one event
    // loop thread.  This preserves the official queue/event ordering without
    // making the UI worker call into transport code.
    auto processInputQueue = [this]() {
        std::lock_guard<std::mutex> lock(impl_->instanceMutex);
        if (!instance_ || !instance_->context || !instance_->input) {
            return;
        }
        wMessageQueue* queue = freerdp_get_message_queue(
            instance_, FREERDP_INPUT_MESSAGE_QUEUE);
        if (!queue) {
            return;
        }
        wMessage message{};
        while (MessageQueue_Peek(queue, &message, TRUE)) {
            switch (message.id) {
                case FREERDP_INPUT_KEYBOARD_EVENT:
                    (void)freerdp_input_send_keyboard_event(
                        instance_->input,
                        static_cast<UINT16>(reinterpret_cast<uintptr_t>(message.wParam)),
                        static_cast<UINT8>(reinterpret_cast<uintptr_t>(message.lParam)));
                    break;
                case FREERDP_INPUT_UNICODE_KEYBOARD_EVENT:
                    (void)freerdp_input_send_unicode_keyboard_event(
                        instance_->input,
                        static_cast<UINT16>(reinterpret_cast<uintptr_t>(message.wParam)),
                        static_cast<UINT16>(reinterpret_cast<uintptr_t>(message.lParam)));
                    break;
                case FREERDP_INPUT_MOUSE_EVENT:
                case FREERDP_INPUT_EXTENDED_MOUSE_EVENT:
                {
                    const UINT32 packed = static_cast<UINT32>(
                        reinterpret_cast<uintptr_t>(message.lParam));
                    const UINT16 x = static_cast<UINT16>((packed >> 16) & 0xFFFFU);
                    const UINT16 y = static_cast<UINT16>(packed & 0xFFFFU);
                    const UINT16 flags = static_cast<UINT16>(
                        reinterpret_cast<uintptr_t>(message.wParam));
                    if (message.id == FREERDP_INPUT_EXTENDED_MOUSE_EVENT) {
                        (void)freerdp_input_send_extended_mouse_event(
                            instance_->input, flags, x, y);
                    } else {
                        (void)freerdp_input_send_mouse_event(
                            instance_->input, flags, x, y);
                    }
                    break;
                }
                case FREERDP_INPUT_KEYBOARD_PAUSE_EVENT:
                    (void)freerdp_input_send_keyboard_pause_event(instance_->input);
                    break;
                case FREERDP_INPUT_SYNCHRONIZE_EVENT:
                    (void)freerdp_input_send_synchronize_event(
                        instance_->input,
                        static_cast<UINT32>(reinterpret_cast<uintptr_t>(message.wParam)));
                    break;
                case FREERDP_INPUT_FOCUS_IN_EVENT:
                    (void)freerdp_input_send_focus_in_event(
                        instance_->input,
                        static_cast<UINT16>(reinterpret_cast<uintptr_t>(message.wParam)));
                    break;
                default:
                    OH_LOG_WARN(LOG_APP,
                        "[RDP] ignoring unknown input queue message id=0x%{public}08x",
                        message.id);
                    break;
            }
            message = {};
        }
    };

    auto processDisplayControlQueue = [this]() {
#if defined(CHANNEL_DISP_CLIENT)
        RdpDisplayLayoutRequest request;
        const int64_t nowUs = steadyNowUs();
        std::lock_guard<std::mutex> displayLock(impl_->displayControlMutex);
        if (RdpDisplayLayoutPolicy::HasInFlightTimedOut(
                impl_->displayLayoutInFlight, impl_->displayInFlightSinceUs, nowUs)) {
            impl_->displayLayoutInFlight = false;
            impl_->displayInFlightSinceUs = 0;
            impl_->displayFailureCount++;
            impl_->displayLastResult = "apply_timeout";
        }
        if (!impl_->displayControlReady ||
            impl_->displayControlDisabled || !impl_->displayControl) {
            return;
        }
        if (!RdpDisplayLayoutPolicy::IsSendDue(
                impl_->displayLayoutPending, impl_->displayLayoutInFlight,
                impl_->displayLastSendUs, nowUs)) {
            return;
        }
        request = impl_->pendingDisplayLayout;
        impl_->displayLayoutPending = false;
        impl_->displayLastSendUs = nowUs;
        DispClientContext* displayControl = impl_->displayControl;
        DISPLAY_CONTROL_MONITOR_LAYOUT monitor {};
        monitor.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
        monitor.Left = 0;
        monitor.Top = 0;
        monitor.Width = static_cast<UINT32>(request.width);
        monitor.Height = static_cast<UINT32>(request.height);
        monitor.PhysicalWidth = static_cast<UINT32>(request.physicalWidthMm);
        monitor.PhysicalHeight = static_cast<UINT32>(request.physicalHeightMm);
        monitor.Orientation = static_cast<UINT32>(request.orientation);
        monitor.DesktopScaleFactor = static_cast<UINT32>(request.desktopScaleFactor);
        monitor.DeviceScaleFactor = static_cast<UINT32>(request.deviceScaleFactor);
        const UINT rc = displayControl->SendMonitorLayout
            ? displayControl->SendMonitorLayout(displayControl, 1, &monitor)
            : ERROR_INVALID_FUNCTION;
        if (rc == CHANNEL_RC_OK) {
            impl_->displayLayoutInFlight = true;
            impl_->displayInFlightSinceUs = nowUs;
            impl_->displayScaleFactor = request.desktopScaleFactor;
            impl_->displayLastResult = "sent";
            OH_LOG_INFO(LOG_APP,
                "[RDP-DISP] layout sent size=%{public}dx%{public}d scale=%{public}d orientation=%{public}d",
                request.width, request.height, request.desktopScaleFactor, request.orientation);
        } else {
            impl_->displayLayoutInFlight = false;
            impl_->displayInFlightSinceUs = 0;
            impl_->displayFailureCount++;
            impl_->displayControlDisabled = true;
            impl_->displayLastResult = "send_failed:" + std::to_string(rc);
            OH_LOG_WARN(LOG_APP,
                "[RDP-DISP] layout send failed rc=%{public}u; dynamic layout disabled for this session",
                rc);
        }
#endif
    };

    const auto markEventLoopTick = [this]() {
        impl_->lastEventLoopTickUs.store(steadyNowUs(), std::memory_order_release);
        impl_->eventLoopTicks.fetch_add(1, std::memory_order_relaxed);
    };

    while (eventLoopRunning_.load(std::memory_order_acquire)) {
        processDisplayControlQueue();
        DWORD networkCount = 0;
        DWORD handleCount = 0;
        DWORD inputHandleIndex = kInvalidHandleIndex;
        HANDLE inputEvent = nullptr;
        {
            // The disconnect path stops and joins this event worker before it
            // can free the FreeRDP instance.  Only hold the instance lease
            // while building the handle list; never hold it during the wait.
            std::lock_guard<std::mutex> lock(impl_->instanceMutex);
            if (!instance_ || !instance_->context) {
                break;
            }
            networkCount = freerdp_get_event_handles(
                instance_->context, handles, kHandleCapacity - 1);
            handleCount = networkCount;
            inputEvent = freerdp_get_message_queue_event_handle(
                instance_, FREERDP_INPUT_MESSAGE_QUEUE);
            if (inputEvent && handleCount < kHandleCapacity) {
                inputHandleIndex = handleCount;
                handles[handleCount++] = inputEvent;
            }
        }

        if (handleCount == 0) {
            usleep(10000); // 10ms
            markEventLoopTick();
            continue;
        }

        const DWORD ret = WaitForMultipleObjects(handleCount, handles, FALSE, 50);
        if (!eventLoopRunning_.load(std::memory_order_acquire)) {
            break;
        }
        if (ret == WAIT_FAILED) {
            OH_LOG_WARN(LOG_APP, "[RDP] WaitForMultipleObjects failed; retrying event loop");
            usleep(1000);
            markEventLoopTick();
            continue;
        }

        const bool inputReady = inputEvent &&
            (ret == WAIT_OBJECT_0 + inputHandleIndex ||
             WaitForSingleObject(inputEvent, 0) == WAIT_OBJECT_0);
        if (inputReady) {
            // Input is intentionally drained before network/GDI callbacks so
            // a click cannot sit behind a burst of paint work already queued
            // by the server.
            processInputQueue();
        }

        const bool networkReady = ret >= WAIT_OBJECT_0 &&
            ret < WAIT_OBJECT_0 + networkCount;
        if (networkReady) {
            const int64_t checkBeginUs = steadyNowUs();
            bool checkOk = false;
            {
                std::lock_guard<std::mutex> lock(impl_->instanceMutex);
                checkOk = instance_ && instance_->context &&
                    freerdp_check_event_handles(instance_->context);
            }
            const int64_t checkElapsedUs = steadyNowUs() - checkBeginUs;
            impl_->networkCheckCount.fetch_add(1, std::memory_order_relaxed);
            updateAtomicMax(impl_->eventLoopBlockMaxUs, checkElapsedUs);
            if (!checkOk) {
                impl_->networkCheckFailures.fetch_add(1, std::memory_order_relaxed);
                OH_LOG_WARN(LOG_APP,
                    "[RDP] freerdp_check_event_handles returned false, stopping event loop");
                eventLoopRunning_.store(false, std::memory_order_release);
                transportEnded = true;
                break;
            }
        }
        markEventLoopTick();
    }
    if (transportEnded && !impl_->stopRequested.load(std::memory_order_acquire) &&
        getState() == ConnectionState::CONNECTED) {
        const std::string pendingError = impl_->takePendingErrorInfo();
        if (!pendingError.empty()) {
            // ErrorInfo is promoted only after the actual FreeRDP event loop
            // has ended.  This prevents a benign 0x01 advisory from opening a
            // false graphics failure dialog over a live connection.
            impl_->setState(ConnectionState::ERROR, pendingError);
            queuePostDisconnectTeardown();
        }
    }
}

// ---- 构造/析构 ----
void FreeRdpAdapter::joinConnectThread(RdpShutdownDeadline deadline) {
    impl_->traceShutdown("connect-join", "begin");
    const auto doneFence = std::atomic_load_explicit(
        &impl_->connectThreadDone, std::memory_order_acquire);
    if (!impl_->connectThread.joinable()) {
        impl_->connectThreadReservation.release();
        impl_->traceShutdown("connect-join", "not-started");
        return;
    }
    if (impl_->connectThread.get_id() == std::this_thread::get_id()) {
        (void)deferRdpWorker(
            impl_->connectThreadReservation, impl_->connectThread,
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
        impl_->connectThreadReservation.release();
    } else {
        OH_LOG_WARN(LOG_APP,
            "[RDP] connect worker exceeded shutdown budget; deferring join");
        (void)deferRdpWorker(
            impl_->connectThreadReservation, impl_->connectThread,
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
        impl_->driveThreadReservation.release();
        impl_->traceShutdown("drive-join", "not-started");
        return;
    }
    if (impl_->driveThread.get_id() == std::this_thread::get_id()) {
        (void)deferRdpWorker(
            impl_->driveThreadReservation, impl_->driveThread,
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
        impl_->driveThreadReservation.release();
    } else {
        OH_LOG_WARN(LOG_APP,
            "[RDP] drive worker exceeded shutdown budget; deferring join");
        (void)deferRdpWorker(
            impl_->driveThreadReservation, impl_->driveThread,
            impl_->lifetime.lock(), doneFence);
    }
    impl_->driveThreadStarted.store(false, std::memory_order_release);
    impl_->traceShutdown("drive-join", "complete");
}

void FreeRdpAdapter::startDriveMountAfterConnected(const std::string& driveName,
                                                   const std::string& drivePath,
                                                   uint64_t generation) {
    if (drivePath.empty()) {
        return;
    }
    if (impl_->sessionGeneration.load(std::memory_order_acquire) != generation ||
        impl_->stopRequested.load(std::memory_order_acquire)) {
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
    RdpWorkerReservation workerReservation = reserveRdpWorker();
    if (!workerReservation) {
        OH_LOG_WARN(LOG_APP,
            "[RDP] redirected drive worker rejected: deferred-owner capacity exhausted");
        return;
    }
    std::shared_ptr<std::atomic<bool>> done;
    try {
        done = std::make_shared<std::atomic<bool>>(false);
        std::atomic_store_explicit(
            &impl_->driveThreadDone, done, std::memory_order_release);
        impl_->driveThreadReservation = std::move(workerReservation);
        impl_->driveThread = std::thread([retained, done, driveName, drivePath, generation]() {
            retained->mountDriveAfterConnected(driveName, drivePath, generation);
            done->store(true, std::memory_order_release);
            retained->impl_->workerDoneCv.notify_all();
        });
    } catch (const std::exception& e) {
        impl_->driveThreadReservation.release();
        if (done) {
            done->store(true, std::memory_order_release);
        }
        OH_LOG_WARN(LOG_APP,
            "[RDP] redirected drive async mount thread failed: %{public}s", e.what());
        return;
    } catch (...) {
        impl_->driveThreadReservation.release();
        if (done) {
            done->store(true, std::memory_order_release);
        }
        OH_LOG_WARN(LOG_APP,
            "[RDP] redirected drive async mount thread failed");
        return;
    }
    impl_->driveThreadStarted = true;
    const std::string drivePathId = SafeLog::HashForLog(drivePath);
    OH_LOG_INFO(LOG_APP, "[RDP] redirected drive async mount scheduled: \\\\tsclient\\%{public}s drivePathId=%{public}s",
                driveName.c_str(), drivePathId.c_str());
}

void FreeRdpAdapter::mountDriveAfterConnected(const std::string& driveName,
                                              const std::string& drivePath,
                                              uint64_t generation) {
    // Give the event loop and rdpdr plugin a short window to finish post-connect setup.
    for (int i = 0; i < 10; i++) {
        if (impl_->stopRequested.load(std::memory_order_acquire) ||
            impl_->sessionGeneration.load(std::memory_order_acquire) != generation) {
            OH_LOG_INFO(LOG_APP, "[RDP] redirected drive async mount canceled before start");
            return;
        }
        usleep(100000);
    }
    if (impl_->stopRequested.load(std::memory_order_acquire) ||
        impl_->sessionGeneration.load(std::memory_order_acquire) != generation ||
        getState() != ConnectionState::CONNECTED) {
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
        if (impl_->stopRequested.load(std::memory_order_acquire) ||
            impl_->sessionGeneration.load(std::memory_order_acquire) != generation ||
            !instance_ || !instance_->context) {
            OH_LOG_INFO(LOG_APP, "[RDP] redirected drive async mount skipped: instance unavailable");
            return;
        }
        std::lock_guard<std::mutex> rdpdrLock(impl_->rdpdrMutex);
        RdpdrClientContext* rdpdr = impl_->rdpdr;
        if (!rdpdr || !rdpdr->RdpdrRegisterDevice) {
            OH_LOG_WARN(LOG_APP,
                        "[RDP] redirected drive unavailable: rdpdr channel interface not ready");
        } else {
            const char* driveArgs[] = { driveName.c_str(), drivePath.c_str() };
            RDPDR_DEVICE* drive = freerdp_device_new(
                RDPDR_DTYP_FILESYSTEM,
                sizeof(driveArgs) / sizeof(driveArgs[0]), driveArgs);
            if (!drive) {
                driveRc = CHANNEL_RC_NO_MEMORY;
            } else {
                driveRc = rdpdr->RdpdrRegisterDevice(rdpdr, drive, &driveId);
                freerdp_device_free(drive);
            }
        }
    }

    if (driveRc == CHANNEL_RC_OK) {
        if (!impl_->publishRdpDriveMounted(generation, driveId)) {
            OH_LOG_INFO(LOG_APP,
                        "[RDP] redirected drive mount completed for stale session; result discarded");
            return;
        }
        const std::string drivePathId = SafeLog::HashForLog(drivePath);
        OH_LOG_INFO(LOG_APP,
                    "[RDP] redirected drive mounted asynchronously: \\\\tsclient\\%{public}s drivePathId=%{public}s id=%{public}u",
                    driveName.c_str(), drivePathId.c_str(), driveId);
        impl_->setState(ConnectionState::CONNECTED, "RDP session established; drive redirection mounted");
    } else {
        if (!impl_->publishRdpDriveUnavailable(generation, "drive_unavailable")) {
            return;
        }
        const std::string drivePathId = SafeLog::HashForLog(drivePath);
        OH_LOG_WARN(LOG_APP,
                    "[RDP] redirected drive async mount unavailable rc=%{public}u name=%{public}s drivePathId=%{public}s",
                    driveRc, driveName.c_str(), drivePathId.c_str());
        impl_->setState(ConnectionState::CONNECTED, "RDP session established; drive redirection unavailable");
    }
}

bool FreeRdpAdapter::disconnectActiveInstance(
    RdpShutdownDeadline deadline,
    const std::shared_ptr<RdpTeardownReservations>& teardownReservations) {
    if (remainingRdpShutdownBudget(deadline).count() <= 0) {
        // Transport teardown still needs an owner. Start it below and hand it
        // to the deferred reaper immediately instead of freeing a live context.
        impl_->traceShutdown("freerdp-disconnect", "budget-exhausted-defer");
    }
    freerdp* activeInstance = nullptr;
    {
        std::lock_guard<std::mutex> lock(impl_->instanceMutex);
        activeInstance = instance_;
    }
    if (!activeInstance) {
        impl_->traceShutdown("freerdp-disconnect", "no-instance");
        return true;
    }
    const auto retained = impl_->lifetime.lock();
    if (!retained) {
        OH_LOG_WARN(LOG_APP,
            "[RDP] cannot defer FreeRDP disconnect without shared adapter lifetime");
        return false;
    }
    if (!teardownReservations) {
        OH_LOG_ERROR(LOG_APP,
            "[RDP] disconnect task missing its pre-admitted teardown owner");
        return false;
    }
    const auto eventDone = std::atomic_load_explicit(
        &impl_->eventThreadDone, std::memory_order_acquire);
    impl_->traceShutdown("freerdp-disconnect", "begin");
    std::shared_ptr<std::atomic<bool>> done;
    try {
        done = std::make_shared<std::atomic<bool>>(false);
        impl_->disconnectWorkerDone = done;
        std::function<void()> disconnectTask = [
            retained, activeInstance, eventDone, done]() {
            if (eventDone &&
                !RdpShutdown::CanStartTransportDisconnect(
                    eventDone->load(std::memory_order_acquire))) {
                std::unique_lock<std::mutex> lock(retained->impl_->workerDoneMutex);
                retained->impl_->workerDoneCv.wait(lock, [eventDone]() {
                    return RdpShutdown::CanStartTransportDisconnect(
                        eventDone->load(std::memory_order_acquire));
                });
            }
            if (activeInstance->context) {
                freerdp_abort_connect_context(activeInstance->context);
            }
            freerdp_disconnect(activeInstance);
            done->store(true, std::memory_order_release);
            retained->impl_->workerDoneCv.notify_all();
        };
        if (!teardownReservations->submit(
                RdpTeardownWorkerRole::DisconnectTransport,
                std::move(disconnectTask))) {
            done->store(true, std::memory_order_release);
            OH_LOG_ERROR(LOG_APP,
                "[RDP] disconnect carrier was unavailable");
            return false;
        }
    } catch (const std::exception& e) {
        if (done) {
            done->store(true, std::memory_order_release);
        }
        OH_LOG_ERROR(LOG_APP,
            "[RDP] FreeRDP disconnect task materialization failed: %{public}s",
            e.what());
        return false;
    } catch (...) {
        if (done) {
            done->store(true, std::memory_order_release);
        }
        OH_LOG_ERROR(LOG_APP,
            "[RDP] FreeRDP disconnect task materialization failed");
        return false;
    }
    const auto waitBudget = remainingRdpShutdownBudget(deadline);
    std::unique_lock<std::mutex> lock(impl_->workerDoneMutex);
    const bool completed = impl_->workerDoneCv.wait_for(lock, waitBudget, [done]() {
        return done->load(std::memory_order_acquire);
    });
    lock.unlock();
    if (completed) {
        impl_->traceShutdown("freerdp-disconnect", "completed-within-budget");
    } else {
        OH_LOG_WARN(LOG_APP,
            "[RDP] FreeRDP disconnect exceeded total deadline; "
            "fixed teardown owner remains active");
    }
    impl_->traceShutdown("freerdp-disconnect", "complete");
    return true;
}

void FreeRdpAdapter::cleanupInstance(
    RdpShutdownDeadline deadline, uint64_t expectedGeneration,
    std::shared_ptr<RdpTeardownReservations> teardownReservations) {
    std::lock_guard<std::recursive_mutex> operationLock(
        impl_->networkActionGate.mutex());
    if (expectedGeneration != 0 &&
        impl_->sessionGeneration.load(std::memory_order_acquire) !=
            expectedGeneration) {
        OH_LOG_INFO(LOG_APP,
            "[RDP] stale instance cleanup ignored generation=%{public}llu",
            static_cast<unsigned long long>(expectedGeneration));
        return;
    }
    if (!teardownReservations) {
        teardownReservations = impl_->snapshotTeardownReservations(
            expectedGeneration);
    }
    const uint64_t teardownGeneration = expectedGeneration != 0
        ? expectedGeneration
        : (teardownReservations
            ? teardownReservations->generation()
            : impl_->sessionGeneration.load(std::memory_order_acquire));
    if (teardownReservations &&
        teardownReservations->generation() != teardownGeneration) {
        OH_LOG_ERROR(LOG_APP,
            "[RDP] refusing cleanup with a mismatched teardown reservation owner");
        return;
    }
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
                if (!teardownReservations) {
                    impl_->cleanupDeferredForWorker.store(false, std::memory_order_release);
                    OH_LOG_ERROR(LOG_APP,
                        "[RDP] deferred cleanup missing its pre-admitted carrier owner");
                    return;
                }
                try {
                    std::function<void()> retire = [
                        retained, connectDoneFence, deadline,
                        teardownGeneration, teardownReservations]() {
                        std::unique_lock<std::mutex> lock(retained->impl_->workerDoneMutex);
                        retained->impl_->workerDoneCv.wait(lock, [connectDoneFence]() {
                            return connectDoneFence->load(std::memory_order_acquire);
                        });
                        lock.unlock();
                        retained->impl_->cleanupDeferredForWorker.store(
                            false, std::memory_order_release);
                        retained->cleanupInstance(
                            deadline, teardownGeneration,
                            teardownReservations);
                        retained->impl_->workerDoneCv.notify_all();
                    };
                    if (!teardownReservations->submit(
                            RdpTeardownWorkerRole::WaitForConnectWorker,
                            std::move(retire))) {
                        OH_LOG_ERROR(LOG_APP,
                            "[RDP] connect-worker cleanup carrier was unavailable");
                        std::abort();
                    }
                } catch (...) {
                    impl_->cleanupDeferredForWorker.store(false, std::memory_order_release);
                    OH_LOG_ERROR(LOG_APP,
                        "[RDP] failed to materialize connect-worker cleanup task");
                    std::abort();
                }
            } else {
                impl_->cleanupDeferredForWorker.store(false, std::memory_order_release);
                OH_LOG_ERROR(LOG_APP,
                    "[RDP] cannot defer cleanup without shared adapter lifetime");
            }
        }
        return;
    }
    if (!teardownReservations) {
        std::lock_guard<std::mutex> lock(impl_->instanceMutex);
        if (instance_ != nullptr) {
            OH_LOG_ERROR(LOG_APP,
                "[RDP] refusing to release an instance without its pre-admitted teardown owner");
        }
        return;
    }
    {
        std::lock_guard<std::mutex> lock(impl_->configMutex);
        secureClearString(impl_->config.rdpRestrictedAdminHash);
    }
    impl_->resetRdpTransferStatus();
    impl_->clearClipboardState();
    {
        std::lock_guard<std::mutex> rdpdrLock(impl_->rdpdrMutex);
        impl_->rdpdr = nullptr;
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
    {
        std::lock_guard<std::mutex> displayLock(impl_->displayControlMutex);
#if defined(CHANNEL_DISP_CLIENT)
        if (impl_->displayControl) {
            impl_->displayControl->DisplayControlCaps = nullptr;
            impl_->displayControl->custom = nullptr;
        }
        impl_->displayControl = nullptr;
#endif
        impl_->displayControlReady = false;
        impl_->displayLayoutPending = false;
        impl_->displayLayoutInFlight = false;
        impl_->displayMaxNumMonitors = 0;
        impl_->displayMaxAreaFactorA = 0;
        impl_->displayMaxAreaFactorB = 0;
        impl_->displayLastSendUs = 0;
        impl_->displayInFlightSinceUs = 0;
        impl_->displayLastResult = "session_closed";
    }
    freerdp* doomedInstance = nullptr;
    {
        std::lock_guard<std::mutex> lock(impl_->instanceMutex);
        if (instance_ != nullptr && teardownGeneration != 0 &&
            impl_->instanceGeneration != teardownGeneration) {
            OH_LOG_INFO(LOG_APP,
                "[RDP] stale instance detach ignored generation=%{public}llu current=%{public}llu",
                static_cast<unsigned long long>(teardownGeneration),
                static_cast<unsigned long long>(impl_->instanceGeneration));
            return;
        }
        doomedInstance = instance_;
        if (doomedInstance) {
            // From this point the raw instance is owned by the final platform
            // retire path, even after it is detached from the public slot.
            // The connect-worker epilogue must not clear this generation's
            // reservation while callback/worker fences are still draining.
            teardownReservations->markPlatformRetirementPending();
        }
        instance_ = nullptr;
        impl_->instanceGeneration = 0;
    }
    if (!doomedInstance) {
        if (!teardownReservations->canReleaseAbsentInstanceOwner()) {
            impl_->traceShutdown(
                "context-free", "platform-retirement-pending");
            return;
        }
        teardownReservations->retireUnusedCarriers();
        impl_->clearTeardownReservationsIfCurrent(
            teardownGeneration, teardownReservations);
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
    CliprdrClientContext* doomedCliprdr = nullptr;
    std::unique_lock<std::mutex> cliprdrLock;
    if (retainedAdapter) {
        cliprdrLock = std::unique_lock<std::mutex>(retainedAdapter->impl_->cliprdrMutex);
        doomedCliprdr = retainedAdapter->impl_->cliprdr;
        retainedAdapter->impl_->cliprdr = nullptr;
    }
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
    if (cliprdrLock.owns_lock()) {
        cliprdrLock.unlock();
    }
    const auto disconnectDone = impl_->disconnectWorkerDone;
    const auto eventDone = std::atomic_load_explicit(
        &impl_->eventThreadDone, std::memory_order_acquire);
    const auto driveDone = std::atomic_load_explicit(
        &impl_->driveThreadDone, std::memory_order_acquire);
    const bool releaseGdi = impl_->gdiInitialized.exchange(false, std::memory_order_acq_rel);
    auto platformCleanup = [
        doomedInstance, retainedAdapter, releaseGdi,
        teardownGeneration, teardownReservations]() {
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
            std::lock_guard<std::mutex> channelLock(retainedAdapter->impl_->cliprdrMutex);
            retainedAdapter->impl_->fileClipboard->detach();
        }
        secureClearFreeRdpCredentials(doomedInstance->settings);
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
        if (retainedAdapter) {
            teardownReservations->retireUnusedCarriers();
            retainedAdapter->impl_->clearTeardownReservationsIfCurrent(
                teardownGeneration, teardownReservations);
        }
    };
    // A timed-out freerdp_disconnect may still be unwinding the same context.
    // Never wait for it on the callback/teardown caller (the callback may be
    // the disconnect worker itself); hand the ordered platform cleanup to a
    // second bounded-owner job that waits only on the worker done fence.
    auto finalCleanup = [
        platformCleanup, retainedAdapter, disconnectDone, eventDone, driveDone,
        teardownReservations]() mutable {
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
        if (!teardownReservations) {
            OH_LOG_ERROR(LOG_APP,
                "[RDP] deferred platform cleanup missing its pre-admitted carrier owner");
            return;
        }
        try {
            std::function<void()> retire = [
                platformCleanup, retainedAdapter, allWorkersDone]() mutable {
                std::unique_lock<std::mutex> lock(retainedAdapter->impl_->workerDoneMutex);
                retainedAdapter->impl_->workerDoneCv.wait(lock, allWorkersDone);
                lock.unlock();
                platformCleanup();
                retainedAdapter->impl_->workerDoneCv.notify_all();
            };
            if (!teardownReservations->submit(
                    RdpTeardownWorkerRole::RetirePlatformInstance,
                    std::move(retire))) {
                OH_LOG_ERROR(LOG_APP,
                    "[RDP] platform cleanup carrier was unavailable");
                std::abort();
            }
        } catch (...) {
            // The fixed reservation already owns the raw platform context.
            // Continuing after failure to materialize its allocation-only
            // type erasure would discard that owner, so fail-stop instead.
            OH_LOG_ERROR(LOG_APP,
                "[RDP] failed to materialize deferred platform cleanup task");
            std::abort();
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
    const uint64_t teardownGeneration =
        impl_->sessionGeneration.load(std::memory_order_acquire);
    const auto teardownReservations =
        impl_->snapshotTeardownReservations(teardownGeneration);
    const auto retained = impl_->lifetime.lock();
    if (!retained) {
        impl_->postDisconnectTeardownQueued.store(false, std::memory_order_release);
        OH_LOG_WARN(LOG_APP,
                    "[RDP] PostDisconnect teardown deferred without shared adapter owner");
        return;
    }
    if (!teardownReservations) {
        impl_->postDisconnectTeardownQueued.store(false, std::memory_order_release);
        OH_LOG_ERROR(LOG_APP,
            "[RDP] PostDisconnect teardown missing its pre-admitted carrier owner");
        return;
    }
    try {
        std::function<void()> teardown = [
            retained, ticket, teardownGeneration,
            teardownReservations]() {
            if (ticket) {
                retained->cleanupInstance(
                    ticket->deadline, teardownGeneration,
                    teardownReservations);
            }
            retained->impl_->workerDoneCv.notify_all();
        };
        if (!teardownReservations->submit(
                RdpTeardownWorkerRole::PostDisconnectCallback,
                std::move(teardown))) {
            impl_->postDisconnectTeardownQueued.store(
                false, std::memory_order_release);
            OH_LOG_ERROR(LOG_APP,
                "[RDP] PostDisconnect teardown carrier was unavailable");
            std::abort();
        }
    } catch (const std::exception& e) {
        impl_->postDisconnectTeardownQueued.store(false, std::memory_order_release);
        OH_LOG_ERROR(LOG_APP,
                     "[RDP] PostDisconnect teardown task materialization failed: %{public}s",
                     e.what());
        std::abort();
    } catch (...) {
        impl_->postDisconnectTeardownQueued.store(false, std::memory_order_release);
        OH_LOG_ERROR(LOG_APP,
                     "[RDP] PostDisconnect teardown task materialization failed");
        std::abort();
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
    RdpWorkerReservation workerReservation = reserveRdpWorker();
    if (!workerReservation) {
        return nullptr;
    }
    std::thread worker([release, done]() {
        while (!release->load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        done->store(true, std::memory_order_release);
    });
    (void)deferRdpWorker(workerReservation, worker, nullptr, done);
    return release;
}

bool FreeRdpAdapter::VerifyTeardownCarrierIsolationForTesting() {
    const auto carriers = RdpTeardownReservations::Create(
        g_nextRdpSessionGeneration.fetch_add(1, std::memory_order_relaxed));
    if (!carriers) {
        return false;
    }
    auto releaseBlocked = std::make_shared<std::atomic<bool>>(false);
    auto blockedEntered = std::make_shared<std::atomic<bool>>(false);
    auto siblingRan = std::make_shared<std::atomic<bool>>(false);
    std::function<void()> blocked = [releaseBlocked, blockedEntered]() {
        blockedEntered->store(true, std::memory_order_release);
        while (!releaseBlocked->load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    };
    std::function<void()> sibling = [siblingRan]() {
        siblingRan->store(true, std::memory_order_release);
    };
    const bool blockedSubmitted = carriers->submit(
        RdpTeardownWorkerRole::DisconnectTransport, std::move(blocked));
    const bool siblingSubmitted = carriers->submit(
        RdpTeardownWorkerRole::RetirePlatformInstance, std::move(sibling));
    carriers->retireUnusedCarriers();

    const auto observationDeadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(1);
    while ((!blockedEntered->load(std::memory_order_acquire) ||
            !siblingRan->load(std::memory_order_acquire)) &&
           std::chrono::steady_clock::now() < observationDeadline) {
        std::this_thread::yield();
    }
    const bool isolated =
        blockedEntered->load(std::memory_order_acquire) &&
        siblingRan->load(std::memory_order_acquire) &&
        !releaseBlocked->load(std::memory_order_acquire);
    const bool blockedStillOwned =
        !rdpWorkerOwner().drainWithin(std::chrono::milliseconds(20));
    releaseBlocked->store(true, std::memory_order_release);
    const bool drained =
        rdpWorkerOwner().drainWithin(std::chrono::milliseconds(1000));
    return blockedSubmitted && siblingSubmitted && isolated &&
        blockedStillOwned && drained;
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
    // Deferred join owners are process-scoped. Stopping either owner from an
    // individual adapter destructor can reject work for another live RDP
    // session, especially while that session owns teardown reservations.
}

// ---- 协议元信息 ----
std::string FreeRdpAdapter::protocolName() { return "RDP"; }
int FreeRdpAdapter::defaultPort() { return RDP_TCP_PORT; }
std::string FreeRdpAdapter::protocolVersion() { return FREERDP_VERSION_FULL; }

// ---- 连接管理 (异步, 不阻塞 NAPI 线程) ----
int FreeRdpAdapter::connect(const ConnectionConfig& cfg) {
    std::lock_guard<std::recursive_mutex> operationLock(
        impl_->networkActionGate.mutex());
    impl_->networkRecovery.admitConnectionOwner();
    impl_->interruptTeardownRetirementWait();
    return connectInternal(cfg, 0);
}

int FreeRdpAdapter::connectInternal(
    const ConnectionConfig& cfg, uint64_t networkActionToken) {
    if (networkActionToken != 0 &&
        !impl_->networkRecovery.isCurrent(networkActionToken, true)) {
        return -125;
    }
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
    bool hasPreviousTransport = false;
    {
        std::lock_guard<std::mutex> lock(impl_->instanceMutex);
        hasPreviousTransport = instance_ != nullptr;
    }
    if (getState() == ConnectionState::CONNECTED ||
        impl_->connecting.load(std::memory_order_acquire) ||
        impl_->connectThread.joinable() || hasPreviousTransport) {
        disconnectInternal(networkActionToken == 0);
    }
    bool previousTransportRetiring = false;
    {
        std::lock_guard<std::mutex> lock(impl_->instanceMutex);
        previousTransportRetiring = instance_ != nullptr;
    }
    const bool previousPlatformCleanupPending =
        impl_->snapshotTeardownReservations() != nullptr;
    if (previousTransportRetiring || previousPlatformCleanupPending) {
        impl_->setState(
            ConnectionState::ERROR,
            "The previous RDP transport or platform context is still retiring "
            "[E-RDP-TEARDOWN-PENDING]");
        return -103;
    }
    if (networkActionToken != 0 &&
        !impl_->networkRecovery.isCurrent(networkActionToken, true)) {
        return -125;
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
        impl_->resetRdpTransferStatus();
        impl_->clearClipboardState();
        // The cursor store and the frame/input workers share the same
        // connection generation. A late FreeRDP pointer callback must not be
        // presented as if it belonged to a newer ArkUI surface attachment.
        impl_->cursorStore.setGeneration(generation);
        impl_->shutdownStartedUs.store(0, std::memory_order_release);
        impl_->clearPendingErrorInfo();
        {
            std::lock_guard<std::mutex> displayLock(impl_->displayControlMutex);
#if defined(CHANNEL_DISP_CLIENT)
            impl_->displayControl = nullptr;
#endif
            impl_->displayControlReady = false;
            impl_->displayControlDisabled = false;
            impl_->displayLayoutPending = false;
            impl_->displayLayoutInFlight = false;
            impl_->displayMaxNumMonitors = 0;
            impl_->displayMaxAreaFactorA = 0;
            impl_->displayMaxAreaFactorB = 0;
            impl_->displayLastSendUs = 0;
            impl_->displayInFlightSinceUs = 0;
            impl_->displayRequestedWidth = 0;
            impl_->displayRequestedHeight = 0;
            impl_->displayEffectiveWidth = 0;
            impl_->displayEffectiveHeight = 0;
            impl_->displayScaleFactor = cfg.rdpDesktopScaleFactor;
            impl_->displayRequestCount = 0;
            impl_->displayFailureCount = 0;
            impl_->displayLastResult = "not_negotiated";
        }
    }
    ConnectionConfig normalizedConfig = cfg;
    if (normalizedConfig.targetServerName.empty()) {
        normalizedConfig.targetServerName = normalizedConfig.customHostname;
    }
    {
        std::lock_guard<std::mutex> lock(impl_->configMutex);
        RdpReconnectCredentialPolicy::replace(
            impl_->config, normalizedConfig);
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
    impl_->setState(
        networkActionToken == 0
            ? ConnectionState::CONNECTING
            : ConnectionState::RECONNECTING,
        networkActionToken == 0
            ? "Connecting..."
            : "RDP network changed; resolving the endpoint again");
    if (networkActionToken != 0 &&
        !impl_->networkRecovery.isCurrent(networkActionToken, true)) {
        return -125;
    }

    // 在独立线程中执行 freerdp_connect(), 避免阻塞 NAPI/ArkTS UI
    const uint64_t connectGeneration =
        impl_->sessionGeneration.load(std::memory_order_acquire);
    const remotedesk::net::NetworkGenerationSnapshot networkSnapshot =
        remotedesk::net::ProcessNetworkGenerationFence().snapshot();
    if (!networkSnapshot.available) {
        impl_->connecting.store(false, std::memory_order_release);
        impl_->setState(
            ConnectionState::ERROR,
            "RDP default network is unavailable [E-RDP-NETWORK-UNAVAILABLE]");
        return -101;
    }
    const auto teardownReservations =
        RdpTeardownReservations::Create(connectGeneration);
    if (!teardownReservations) {
        impl_->connecting.store(false, std::memory_order_release);
        impl_->setState(
            ConnectionState::ERROR,
            "RDP teardown capacity is exhausted "
            "[E-RDP-TEARDOWN-CAPACITY]");
        return -102;
    }
    impl_->installTeardownReservations(
        connectGeneration, teardownReservations);
    RdpWorkerReservation workerReservation = reserveRdpWorker();
    if (!workerReservation) {
        teardownReservations->retireUnusedCarriers();
        impl_->clearTeardownReservationsIfCurrent(
            connectGeneration, teardownReservations);
        impl_->connecting.store(false, std::memory_order_release);
        impl_->setState(
            ConnectionState::ERROR,
            "RDP connect worker capacity is exhausted [E-RDP-WORKER-CAPACITY]");
        return -102;
    }
    std::shared_ptr<std::atomic<bool>> connectDone;
    try {
        connectDone = std::make_shared<std::atomic<bool>>(false);
        std::atomic_store_explicit(
            &impl_->connectThreadDone, connectDone, std::memory_order_release);
        impl_->connectThreadReservation = std::move(workerReservation);
        impl_->connectThread = std::thread([
            retained, connectDone, connectGeneration, networkSnapshot,
            teardownReservations]() {
            try {
                retained->connectThreadFunc(
                    connectGeneration, networkSnapshot.generation,
                    teardownReservations);
            } catch (...) {
                retained->impl_->connecting.store(false, std::memory_order_release);
                if (!retained->impl_->stopRequested.load(std::memory_order_acquire) &&
                    !remotedesk::net::ProcessNetworkGenerationFence().shouldCancel(
                        networkSnapshot)) {
                    retained->impl_->setState(
                        ConnectionState::ERROR,
                        "RDP connect worker failed [E-RDP-WORKER]");
                }
            }
            bool ownsInstance = false;
            {
                std::lock_guard<std::mutex> lock(
                    retained->impl_->instanceMutex);
                ownsInstance = retained->instance_ != nullptr &&
                    retained->impl_->instanceGeneration == connectGeneration;
            }
            if (!ownsInstance &&
                teardownReservations->canReleaseAbsentInstanceOwner()) {
                teardownReservations->retireUnusedCarriers();
                retained->impl_->clearTeardownReservationsIfCurrent(
                    connectGeneration, teardownReservations);
            }
            connectDone->store(true, std::memory_order_release);
            retained->impl_->workerDoneCv.notify_all();
        });
    } catch (const std::exception& e) {
        impl_->connectThreadReservation.release();
        teardownReservations->retireUnusedCarriers();
        impl_->clearTeardownReservationsIfCurrent(
            connectGeneration, teardownReservations);
        impl_->connecting = false;
        if (connectDone) {
            connectDone->store(true, std::memory_order_release);
        }
        {
            std::lock_guard<std::mutex> lock(impl_->configMutex);
            secureClearString(impl_->config.rdpRestrictedAdminHash);
        }
        impl_->setState(ConnectionState::ERROR,
            std::string("thread start failed [E-RDP-THREAD]: ") + e.what());
        return -11;
    } catch (...) {
        impl_->connectThreadReservation.release();
        teardownReservations->retireUnusedCarriers();
        impl_->clearTeardownReservationsIfCurrent(
            connectGeneration, teardownReservations);
        impl_->connecting = false;
        if (connectDone) {
            connectDone->store(true, std::memory_order_release);
        }
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

void FreeRdpAdapter::connectThreadFunc(
    uint64_t expectedGeneration, uint64_t expectedNetworkGeneration,
    const std::shared_ptr<RdpTeardownReservations>& teardownReservations) {
    const auto isCurrentAttempt = [
        this, expectedGeneration, expectedNetworkGeneration]() {
        return impl_->sessionGeneration.load(std::memory_order_acquire) ==
                expectedGeneration &&
            !impl_->stopRequested.load(std::memory_order_acquire) &&
            !remotedesk::net::ProcessNetworkGenerationFence().shouldCancel(
                remotedesk::net::NetworkGenerationSnapshot {
                    expectedNetworkGeneration, true});
    };
    const auto cleanupAttempt = [this, expectedGeneration,
                                 teardownReservations]() {
        cleanupInstance(
            RdpShutdownDeadline::max(), expectedGeneration,
            teardownReservations);
    };
    if (!isCurrentAttempt()) {
        impl_->connecting.store(false, std::memory_order_release);
        return;
    }
    ConnectionConfig cfg;
    RdpReconnectSecretGuard secretGuard {cfg};
    {
        std::lock_guard<std::mutex> lock(impl_->configMutex);
        cfg = impl_->config;
        // The worker owns its private copy from this point onward. Do not
        // leave the restricted-admin secret in the reconnect-shared config.
        secureClearString(impl_->config.rdpRestrictedAdminHash);
    }

    RdpEndpointRoute route;
    std::string routeErrorCode;
    std::string routeErrorMessage;
    if (!resolveRdpEndpointRoute(cfg, route, routeErrorCode, routeErrorMessage)) {
        secureClearString(cfg.rdpRestrictedAdminHash);
        impl_->setState(ConnectionState::ERROR,
                        routeErrorMessage + " [" + routeErrorCode + "]");
        impl_->connecting = false;
        return;
    }
    RdpGatewayPolicy::normalizeRouteConfig(cfg, route);
    // Certificate callbacks read the active route from the shared config.
    // Publish only the normalized route fields; credentials remain owned by
    // the worker copy and are cleared independently below.
    {
        std::lock_guard<std::mutex> lock(impl_->configMutex);
        RdpGatewayPolicy::normalizeRouteConfig(impl_->config, route);
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
        impl_->instanceGeneration = expectedGeneration;
    }
    instance_->ContextSize = sizeof(FreeRdpContext);
    if (!freerdp_context_new(instance_)) {
        impl_->setState(ConnectionState::ERROR, "freerdp_context_new() 失败 [E-FREERDP-CTX]");
        cleanupAttempt();
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
        cleanupAttempt();
        impl_->connecting = false;
        return;
    }
    if (!isCurrentAttempt()) {
        impl_->traceShutdown("connect-cancel", "after-context");
        cleanupAttempt();
        impl_->connecting = false;
        return;
    }

    const int port = route.targetPort;

    // ---- 配置 FreeRDP settings (完整映射 ConnectionConfig) ----
    auto* s = instance_->settings;

    // 基础连接
    const RdpAuthIdentity authIdentity =
        NormalizeRdpAuthIdentity(cfg.username, cfg.domain, cfg.rdpAuthIdentityMode);
    std::string effectiveUsername = authIdentity.username;
    std::string effectiveDomain = authIdentity.domain;
    OH_LOG_INFO(LOG_APP, "[RDP] auth identity normalized mode=%{public}s",
                authIdentity.modeName.c_str());
    freerdp_settings_set_string(s, FreeRDP_ServerHostname, route.targetHost.c_str());
    freerdp_settings_set_uint32(s, FreeRDP_ServerPort, static_cast<UINT32>(port));
    if (!cfg.clientHostname.empty()) {
        freerdp_settings_set_string(s, FreeRDP_ClientHostname, cfg.clientHostname.c_str());
    }
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
        cleanupAttempt();
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
            cleanupAttempt();
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
    const UINT32 desktopScaleFactor = static_cast<UINT32>(
        RdpDisplayLayoutPolicy::IsScaleFactorValid(cfg.rdpDesktopScaleFactor)
            ? cfg.rdpDesktopScaleFactor : 100);
    const UINT32 deviceScaleFactor = static_cast<UINT32>(
        RdpDisplayLayoutPolicy::IsScaleFactorValid(cfg.rdpDeviceScaleFactor)
            ? cfg.rdpDeviceScaleFactor : desktopScaleFactor);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopScaleFactor, desktopScaleFactor);
    freerdp_settings_set_uint32(s, FreeRDP_DeviceScaleFactor, deviceScaleFactor);
    if (cfg.rdpDesktopPhysicalWidthMm >= 10 && cfg.rdpDesktopPhysicalHeightMm >= 10) {
        freerdp_settings_set_uint32(s, FreeRDP_DesktopPhysicalWidth,
                                    static_cast<UINT32>(cfg.rdpDesktopPhysicalWidthMm));
        freerdp_settings_set_uint32(s, FreeRDP_DesktopPhysicalHeight,
                                    static_cast<UINT32>(cfg.rdpDesktopPhysicalHeightMm));
    }
    freerdp_settings_set_uint16(s, FreeRDP_DesktopOrientation,
                                static_cast<UINT16>(
                                    RdpDisplayLayoutPolicy::IsOrientationValid(cfg.rdpDesktopOrientation)
                                        ? cfg.rdpDesktopOrientation : 0));
    freerdp_settings_set_uint64(s, FreeRDP_MonitorOverrideFlags,
        FREERDP_MONITOR_OVERRIDE_ORIENTATION |
        FREERDP_MONITOR_OVERRIDE_DESKTOP_SCALE |
        FREERDP_MONITOR_OVERRIDE_DEVICE_SCALE);
#if defined(CHANNEL_DISP_CLIENT)
    freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_DynamicResolutionUpdate, TRUE);
#else
    freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_DynamicResolutionUpdate, FALSE);
#endif
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
        cleanupAttempt();
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

    // Authentication and transport security are independent. The default is
    // unchanged TLS/NLA. An explicit direct-password compatibility request can
    // select certificate-validated TLS without NLA, but never Gateway,
    // Restricted Admin, blank-password, or Standard RDP Security.
    const bool gatewayRoute = route.endpointMode == RdpEndpointMode::MicrosoftRdGateway;
    const RdpTransportSecurityPolicy transportSecurity = ResolveRdpTransportSecurityPolicy(
        cfg.rdpTlsWithoutNla, route.endpointMode != RdpEndpointMode::DirectRdp, authPolicy.mode);
    if (!transportSecurity.valid) {
        const std::string code = transportSecurity.errorCode && transportSecurity.errorCode[0] != '\0'
            ? transportSecurity.errorCode : "E-RDP-TLS-COMPAT";
        impl_->setState(ConnectionState::ERROR,
                        "RDP TLS 兼容模式不支持当前路由或认证方式 [" + code + "]");
        cleanupAttempt();
        impl_->connecting = false;
        return;
    }
    const bool tlsWithoutNla =
        transportSecurity.mode == RdpTransportSecurityMode::TlsWithoutNla;
    const bool allowStandardSecurityOnce =
        !tlsWithoutNla && cfg.rdpAllowStandardSecurityOnce;
    freerdp_settings_set_bool(s, FreeRDP_NegotiateSecurityLayer, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_UseRdpSecurityLayer, FALSE);
    // Standard RDP Security is enabled only by the route-bound Continue Once
    // handoff. The preflight never enables this fallback itself.
    freerdp_settings_set_bool(s, FreeRDP_RdpSecurity,
                              (transportSecurity.rdpSecurity || allowStandardSecurityOnce)
                                  ? TRUE : FALSE);
    freerdp_settings_set_bool(s, FreeRDP_TlsSecurity,
                              transportSecurity.tlsSecurity ? TRUE : FALSE);
    freerdp_settings_set_bool(s, FreeRDP_ExtSecurity, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_AadSecurity, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_NlaSecurity,
                              transportSecurity.nlaSecurity ? TRUE : FALSE);
    freerdp_settings_set_uint32(s, FreeRDP_RequestedProtocols,
                                transportSecurity.requestedProtocols);
    freerdp_settings_set_bool(s, FreeRDP_Authentication, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_AutoLogonEnabled, TRUE);
    // Certificate decisions are made by the stage-aware callbacks below.
    // Keeping this enabled is what makes Gateway TLS and tunneled target TLS
    // use the same explicit trust contract as preflight.
    freerdp_settings_set_bool(s, FreeRDP_ExternalCertificateManagement, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_CertificateCallbackPreferPEM, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_IgnoreCertificate, FALSE);
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

    // 目标服务器名: 连接仍走目标 host/port, NLA/CredSSP 使用该名称生成
    // TERMSRV/<name>；Gateway TLS/SNI uses GatewayHostname while the patched
    // GatewayConnectHostname remains the transport-only peer.
    if (!route.targetServerName.empty()) {
        freerdp_settings_set_string(s, FreeRDP_UserSpecifiedServerName,
                                    route.targetServerName.c_str());
        freerdp_settings_set_string(s, FreeRDP_CertificateName,
                                    route.targetServerName.c_str());
        const std::string logTargetName = SafeLog::MaskHost(route.targetServerName);
        OH_LOG_INFO(LOG_APP, "[RDP] target server name override: %{public}s", logTargetName.c_str());
    }

    // RD Gateway transport. A Gateway route is never allowed to fall through
    // to the target socket, and a direct route is explicitly kept disabled.
    const RdpGatewayTransportFlags gatewayTransportFlags =
        RdpGatewayPolicy::transportFlags(route.gatewayTransport);
    freerdp_settings_set_bool(s, FreeRDP_GatewayEnabled, gatewayRoute ? TRUE : FALSE);
    if (gatewayRoute) {
        freerdp_settings_set_string(s, FreeRDP_GatewayHostname,
                                    route.gatewayServerName.c_str());
        freerdp_settings_set_string(s, FreeRDP_GatewayConnectHostname,
                                    route.gatewayHost.c_str());
        freerdp_settings_set_uint32(s, FreeRDP_GatewayPort,
                                    static_cast<UINT32>(route.gatewayPort));
        freerdp_settings_set_bool(s, FreeRDP_GatewayRpcTransport,
                                  gatewayTransportFlags.rpc ? TRUE : FALSE);
        freerdp_settings_set_bool(s, FreeRDP_GatewayHttpTransport,
                                  gatewayTransportFlags.http ? TRUE : FALSE);
        freerdp_settings_set_bool(s, FreeRDP_GatewayHttpUseWebsockets,
                                  gatewayTransportFlags.websockets ? TRUE : FALSE);
        freerdp_settings_set_bool(s, FreeRDP_GatewayUseSameCredentials, TRUE);
        freerdp_settings_set_string(s, FreeRDP_GatewayUsername, effectiveUsername.c_str());
        freerdp_settings_set_string(s, FreeRDP_GatewayPassword,
                                    (restrictedAdmin || blankPassword) ? "" : cfg.password.c_str());
        freerdp_settings_set_string(s, FreeRDP_GatewayDomain, effectiveDomain.c_str());
        const std::string logGatewayHost = SafeLog::MaskHost(route.gatewayHost);
        OH_LOG_INFO(LOG_APP,
                    "[RDP] RD Gateway: %{public}s:%{public}d transport=%{public}s",
                    logGatewayHost.c_str(), route.gatewayPort,
                    RdpGatewayPolicy::gatewayTransportName(route.gatewayTransport));
    }

    // 多显示器当前会导致部分 Windows 会话只建连不出首帧, 先固定单屏稳定路径。
    if (cfg.multiMonitor) {
        OH_LOG_WARN(LOG_APP, "[RDP] 多显示器配置已忽略, 使用单屏稳定视频路径 (requested monitorCount=%{public}d)",
                    cfg.monitorCount);
    }

    const std::string logHost = SafeLog::MaskHost(cfg.host);
    const std::string logGatewayHost = cfg.gatewayHost.empty() ? "无" : SafeLog::MaskHost(cfg.gatewayHost);
    const std::string logTargetName = cfg.targetServerName.empty() ?
        "未设置" : SafeLog::MaskHost(cfg.targetServerName);
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
                " requested=0x%{public}08X authPkg=%{public}s transportSecurity=%{public}s",
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
                authPackageList ? authPackageList : "无",
                tlsWithoutNla ? "tls_without_nla" : "nla");

    // 证书验证回调: 只接受 ArkTS 预检确认并传入的阶段对应指纹。
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
        cleanupAttempt();
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
        cleanupAttempt();
        impl_->connecting = false;
        return;
    }
    OH_LOG_INFO(LOG_APP, "[RDP] 开始 freerdp_connect...");
    BOOL ok = freerdp_connect(instance_);
    if (!isCurrentAttempt()) {
        cleanupAttempt();
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
        cleanupAttempt();
        impl_->connecting = false;
        return;
    }

    // 连接成功 — 启动事件循环
    if (!isCurrentAttempt()) {
        cleanupAttempt();
        impl_->connecting = false;
        return;
    }
    if (!startEventLoop()) {
        impl_->stopRequested.store(true, std::memory_order_release);
        impl_->setState(ConnectionState::ERROR,
                        "RDP event loop worker start failed [E-RDP-EVENT-WORKER]");
        const auto ticket = impl_->getOrCreateShutdownTicket();
        if (disconnectActiveInstance(
                ticket->deadline, teardownReservations)) {
            cleanupInstance(
                ticket->deadline, expectedGeneration,
                teardownReservations);
        }
        impl_->connecting = false;
        OH_LOG_ERROR(LOG_APP,
            "[RDP] event loop unavailable; refusing CONNECTED session [E-RDP-EVENT-WORKER]");
        return;
    }

    if (!isCurrentAttempt()) {
        impl_->connecting.store(false, std::memory_order_release);
        return;
    }

    if (getState() == ConnectionState::ERROR) {
        impl_->connecting = false;
        OH_LOG_WARN(LOG_APP, "[RDP] connection reached ERROR before CONNECTED publish");
        return;
    }
    // ErrorInfo received during negotiation is folded into the connect result
    // above.  A successful session starts with a clean advisory slot so an
    // old code cannot be promoted after a later, unrelated transport stop.
    impl_->clearPendingErrorInfo();
    impl_->setState(ConnectionState::CONNECTED, "RDP session established (FreeRDP)");
    impl_->connecting = false;
    OH_LOG_INFO(LOG_APP, "[RDP] ✓ FreeRDP session: %{public}s:%{public}d (user=%{public}s)",
                logHost.c_str(), port, logUser.c_str());
    if (driveEnabled) {
        startDriveMountAfterConnected(driveName, cfg.rdDrivePath, expectedGeneration);
    }
}

void FreeRdpAdapter::disconnect() {
    std::lock_guard<std::recursive_mutex> operationLock(
        impl_->networkActionGate.mutex());
    const uint64_t retirementToken =
        impl_->networkRecovery.retireConnectionOwner();
    impl_->interruptTeardownRetirementWait();
    disconnectInternal();
    std::lock_guard<std::mutex> lock(impl_->configMutex);
    (void)RdpReconnectCredentialPolicy::clearIfStillRetired(
        impl_->config, impl_->networkRecovery, retirementToken);
}

void FreeRdpAdapter::disconnectInternal(bool publishDisconnected) {
    std::unique_lock<std::mutex> shutdownLock(impl_->shutdownMutex);
    if (!impl_->shutdownState.requestDisconnect()) {
        impl_->traceShutdown("request", "duplicate");
        const bool teardownComplete = impl_->shutdownState.phase() ==
            RdpShutdown::Phase::Complete;
        shutdownLock.unlock();
        if (publishDisconnected && teardownComplete) {
            const ConnectionState state = getState();
            if (state != ConnectionState::DISCONNECTED &&
                state != ConnectionState::ERROR) {
                impl_->setState(ConnectionState::DISCONNECTED, "Disconnected");
            }
        }
        return;
    }
    impl_->beginShutdownTrace();
    const auto ticket = impl_->getOrCreateShutdownTicket();
    const RdpShutdownDeadline deadline = ticket->deadline;
    impl_->stopRequested.store(true, std::memory_order_release);
    impl_->resetRdpTransferStatus();
    impl_->clearClipboardState();
    const uint64_t disconnectGeneration =
        impl_->sessionGeneration.load(std::memory_order_acquire);
    const auto teardownReservations =
        impl_->snapshotTeardownReservations(disconnectGeneration);
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
    if (!disconnectActiveInstance(deadline, teardownReservations)) {
        impl_->connecting = false;
        impl_->shutdownState.reset();
        std::atomic_store_explicit(
            &impl_->shutdownTicket, std::shared_ptr<RdpShutdownTicket> {},
            std::memory_order_release);
        shutdownLock.unlock();
        impl_->setState(
            ConnectionState::ERROR,
            "RDP transport teardown could not start; the instance was retained "
            "for retry [E-RDP-TEARDOWN-RETRY]");
        return;
    }
    impl_->shutdownState.advance(RdpShutdown::Phase::TransportDisconnecting,
                                 RdpShutdown::Phase::Releasing);
    impl_->connecting = false;
    cleanupInstance(
        deadline, disconnectGeneration, teardownReservations);
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
    if (publishDisconnected && state != ConnectionState::DISCONNECTED &&
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

void FreeRdpAdapter::onNetworkChanged(
    bool available, uint64_t networkGeneration) {
    const RdpNetworkRecoveryAction action =
        impl_->networkRecovery.onNetworkChanged(available, networkGeneration);
    if (!action.accepted) {
        return;
    }
    // Wake a waiter owned by the previous action token. It will observe the
    // token change and leave without publishing state or starting transport.
    impl_->interruptTeardownRetirementWait();

    // The token check and transport cancellation share the same lane as
    // explicit connect/disconnect. Without this boundary, a connect could
    // admit a newer owner after onNetworkChanged() minted its action but
    // before the old action aborted the active FreeRDP context.
    if (!impl_->networkActionGate.runIfCurrent(
            impl_->networkRecovery, action.token, false, [this]() {
                impl_->stopRequested.store(true, std::memory_order_release);
                std::lock_guard<std::mutex> lock(impl_->instanceMutex);
                if (instance_ && instance_->context) {
                    (void)freerdp_abort_connect_context(instance_->context);
                }
            })) {
        return;
    }

    std::shared_ptr<FreeRdpAdapter> retained;
    try {
        retained = shared_from_this();
    } catch (...) {
        retained.reset();
    }
    if (!retained) {
        try {
            std::lock_guard<std::recursive_mutex> operationLock(
                impl_->networkActionGate.mutex());
            if (impl_->networkRecovery.isCurrent(action.token)) {
                const uint64_t retirementToken =
                    impl_->networkRecovery.retireConnectionOwner();
                {
                    std::lock_guard<std::mutex> lock(impl_->configMutex);
                    (void)RdpReconnectCredentialPolicy::clearIfStillRetired(
                        impl_->config, impl_->networkRecovery, retirementToken);
                }
                impl_->setState(
                    ConnectionState::ERROR,
                    "RDP network recovery lost its session owner "
                    "[E-RDP-NETWORK-OWNER]");
            }
        } catch (...) {
            OH_LOG_ERROR(LOG_APP,
                "[RDP] failed to publish missing network recovery owner");
        }
        return;
    }
    RdpWorkerReservation workerReservation = reserveRdpWorker();
    if (!workerReservation) {
        try {
            std::lock_guard<std::recursive_mutex> operationLock(
                impl_->networkActionGate.mutex());
            if (impl_->networkRecovery.isCurrent(action.token)) {
                const uint64_t retirementToken =
                    impl_->networkRecovery.retireConnectionOwner();
                {
                    std::lock_guard<std::mutex> lock(impl_->configMutex);
                    (void)RdpReconnectCredentialPolicy::clearIfStillRetired(
                        impl_->config, impl_->networkRecovery, retirementToken);
                }
                impl_->setState(
                    ConnectionState::ERROR,
                    "RDP network recovery worker capacity is exhausted "
                    "[E-RDP-NETWORK-WORKER-CAPACITY]");
            }
        } catch (...) {
            OH_LOG_ERROR(LOG_APP,
                "[RDP] network worker capacity failure publication failed");
        }
        return;
    }
    std::shared_ptr<std::atomic<bool>> done;
    std::thread worker;
    try {
        done = std::make_shared<std::atomic<bool>>(false);
        worker = std::thread([retained, action, done]() {
            RdpNetworkWorkerCompletionGuard completion {
                done, retained->impl_->workerDoneCv};
            try {
                uint64_t retiringSessionGeneration = 0;
                {
                    std::lock_guard<std::recursive_mutex> operationLock(
                        retained->impl_->networkActionGate.mutex());
                    if (!retained->impl_->networkRecovery.isCurrent(
                            action.token)) {
                        return;
                    }

                    retained->impl_->setState(
                        ConnectionState::RECONNECTING,
                        action.reconnectNow
                            ? "RDP network changed; resolving the endpoint again"
                            : "RDP is waiting for the default network");
                    // State callbacks may synchronously request an explicit
                    // connect/disconnect. Revalidate before transport teardown.
                    if (!retained->impl_->networkRecovery.isCurrent(
                            action.token)) {
                        return;
                    }

                    retiringSessionGeneration = retained->impl_
                        ->sessionGeneration.load(std::memory_order_acquire);
                    // A network migration is not a terminal user disconnect.
                    // Keep RECONNECTING visible while the old transport is
                    // quiesced.
                    retained->disconnectInternal(
                        action.publishDisconnectedOnTeardown);
                    if (!retained->impl_->networkRecovery.isCurrent(
                            action.token)) {
                        return;
                    }

                    if (!action.reconnectNow) {
                        retained->impl_->setState(
                            ConnectionState::RECONNECTING,
                            "RDP is waiting for the default network");
                        return;
                    }
                }

                // disconnectInternal() deliberately returns after its bounded
                // caller budget. The raw FreeRDP context can still be owned by
                // a deferred carrier, so wait outside the user-action lane.
                // A newer network/user token interrupts this exact wait; a
                // successful retirement admits exactly one reconnect below.
                const auto retirementWait = retained->impl_
                    ->waitForTeardownRetirement(
                        retiringSessionGeneration, action.token,
                        std::chrono::steady_clock::now() +
                            kRdpNetworkTeardownRetirementTimeout);
                if (retirementWait ==
                    RdpTeardownRetirementWaitResult::Cancelled) {
                    return;
                }
                if (retirementWait ==
                    RdpTeardownRetirementWaitResult::TimedOut) {
                    std::lock_guard<std::recursive_mutex> operationLock(
                        retained->impl_->networkActionGate.mutex());
                    if (retained->impl_->networkRecovery.isCurrent(
                            action.token, true)) {
                        const uint64_t retirementToken = retained->impl_
                            ->networkRecovery.retireConnectionOwner();
                        retained->impl_->interruptTeardownRetirementWait();
                        {
                            std::lock_guard<std::mutex> lock(
                                retained->impl_->configMutex);
                            (void)RdpReconnectCredentialPolicy::clearIfStillRetired(
                                retained->impl_->config,
                                retained->impl_->networkRecovery,
                                retirementToken);
                        }
                        retained->impl_->setState(
                            ConnectionState::ERROR,
                            "RDP network recovery timed out waiting for the "
                            "previous transport [E-RDP-NETWORK-TEARDOWN-TIMEOUT]");
                    }
                    return;
                }

                std::lock_guard<std::recursive_mutex> operationLock(
                    retained->impl_->networkActionGate.mutex());
                if (!retained->impl_->networkRecovery.isCurrent(
                        action.token, true)) {
                    return;
                }
                ConnectionConfig reconnectConfig;
                RdpReconnectSecretGuard secretGuard {reconnectConfig};
                {
                    std::lock_guard<std::mutex> lock(
                        retained->impl_->configMutex);
                    reconnectConfig = retained->impl_->config;
                }
                if (RdpReconnectCredentialPolicy::requiresUserResubmission(
                        reconnectConfig)) {
                    const uint64_t retirementToken = retained->impl_
                        ->networkRecovery.retireConnectionOwner();
                    retained->impl_->interruptTeardownRetirementWait();
                    {
                        std::lock_guard<std::mutex> lock(
                            retained->impl_->configMutex);
                        (void)RdpReconnectCredentialPolicy::clearIfStillRetired(
                            retained->impl_->config,
                            retained->impl_->networkRecovery, retirementToken);
                    }
                    retained->impl_->setState(
                        ConnectionState::ERROR,
                        "RDP network changed; Restricted Admin credentials "
                        "must be submitted again [E-RDP-NETWORK-REAUTH]");
                    return;
                }

                const int result = retained->connectInternal(
                    reconnectConfig, action.token);
                if (result != 0 &&
                    retained->impl_->networkRecovery.isCurrent(action.token)) {
                    retained->impl_->setState(
                        ConnectionState::ERROR,
                        "RDP network recovery failed [E-RDP-NETWORK-RECOVERY]");
                }
            } catch (...) {
                try {
                    std::lock_guard<std::recursive_mutex> operationLock(
                        retained->impl_->networkActionGate.mutex());
                    if (retained->impl_->networkRecovery.isCurrent(action.token)) {
                        const uint64_t retirementToken = retained->impl_
                            ->networkRecovery.retireConnectionOwner();
                        {
                            std::lock_guard<std::mutex> lock(
                                retained->impl_->configMutex);
                            (void)RdpReconnectCredentialPolicy::clearIfStillRetired(
                                retained->impl_->config,
                                retained->impl_->networkRecovery,
                                retirementToken);
                        }
                        retained->impl_->setState(
                            ConnectionState::ERROR,
                            "RDP network recovery failed unexpectedly "
                            "[E-RDP-NETWORK-EXCEPTION]");
                    }
                } catch (...) {
                    OH_LOG_ERROR(LOG_APP,
                        "[RDP] network recovery exception publication failed");
                }
            }
        });
    } catch (...) {
        if (done) {
            done->store(true, std::memory_order_release);
        }
        impl_->workerDoneCv.notify_all();
        try {
            std::lock_guard<std::recursive_mutex> operationLock(
                impl_->networkActionGate.mutex());
            if (impl_->networkRecovery.isCurrent(action.token)) {
                const uint64_t retirementToken =
                    impl_->networkRecovery.retireConnectionOwner();
                {
                    std::lock_guard<std::mutex> lock(impl_->configMutex);
                    (void)RdpReconnectCredentialPolicy::clearIfStillRetired(
                        impl_->config, impl_->networkRecovery, retirementToken);
                }
                impl_->setState(
                    ConnectionState::ERROR,
                    "RDP network recovery worker could not start "
                    "[E-RDP-NETWORK-WORKER]");
            }
        } catch (...) {
            OH_LOG_ERROR(LOG_APP,
                "[RDP] network worker failure publication failed");
        }
        return;
    }
    (void)deferRdpWorker(workerReservation, worker, retained, done);
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

RdpCertificateInfo FreeRdpAdapter::probeRdpCertificate(
    const std::string& host, int port, const std::string& serverName,
    const std::function<bool()>& cancelled) {
    return probeRdpCertificateOverTls(host, port, serverName, cancelled);
}

RdpPreflightResult FreeRdpAdapter::probeRdpCertificateRoute(
    const RdpPreflightRequest& request) {
    ConnectionConfig cfg;
    cfg.host = request.route.targetHost;
    cfg.port = request.route.targetPort;
    cfg.targetServerName = request.route.targetServerName;
    cfg.gatewayHost = request.route.gatewayHost;
    cfg.gatewayPort = request.route.gatewayPort;
    cfg.rdpAuthMode = request.targetRestrictedAdmin
        ? RdpAuthenticationMode::RestrictedAdmin
        : RdpAuthenticationMode::Password;
    cfg.rdpEndpointMode = RdpGatewayPolicy::endpointModeName(request.route.endpointMode);
    cfg.rdpGatewayTransport = RdpGatewayPolicy::gatewayTransportName(request.route.gatewayTransport);
    cfg.rdpGatewayServerName = request.route.gatewayServerName;
    RdpEndpointRoute route;
    std::string routeErrorCode;
    std::string routeErrorMessage;
    if (!resolveRdpEndpointRoute(cfg, route, routeErrorCode, routeErrorMessage)) {
        return makeRdpPreflightError(
            request, "endpoint", routeErrorCode, routeErrorMessage);
    }
    RdpPreflightRequest normalized = request;
    normalized.route = route;
    if (route.endpointMode == RdpEndpointMode::MicrosoftRdGateway) {
        return probeRdpCertificateRouteWithFreeRdp(normalized);
    }

    const RdpCertificateInfo info = probeRdpCertificateOverTls(
        route.targetHost, route.targetPort, route.targetServerName,
        normalized.cancelled);
    RdpPreflightResult result;
    result.ok = info.ok;
    result.preflightStatus = info.ok ? RdpPreflightPolicy::kCompleted :
        (info.preflightStatus.empty() ? RdpPreflightPolicy::kUnavailable : info.preflightStatus);
    result.riskFlags = info.riskFlags;
    result.targetRiskFlags = info.riskFlags;
    if (!info.riskFlags.empty()) {
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.riskFlags, RdpPreflightPolicy::kRiskTargetCertificate);
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.targetRiskFlags, RdpPreflightPolicy::kRiskTargetCertificate);
    }
    result.endpointMode = route.endpointMode;
    result.routeIdentity = RdpGatewayPolicy::routeIdentity(route);
    result.generation = normalized.generation;
    result.requestId = normalized.requestId;
    result.stage = info.ok ? "target" : directRdpPreflightStage(info.errorCode);
    result.errorCode = info.ok ? "" : directRdpPreflightErrorCode(info.errorCode);
    result.errorMessage = info.errorMessage;
    RdpGatewayPolicy::initializeGatewayTransportResult(
        result, normalized.route.gatewayTransport);
    result.requiresUserDecision = info.ok || directRdpPreflightCanTryRealConnection(info);
    result.targetCertificate.present = info.ok && !info.fingerprintSha256.empty();
    result.targetCertificate.stage = "target";
    result.targetCertificate.host = info.host;
    result.targetCertificate.port = info.port;
    result.targetCertificate.serverName = route.targetServerName;
    result.targetCertificate.commonName = info.commonName;
    result.targetCertificate.subject = info.subject;
    result.targetCertificate.issuer = info.issuer;
    result.targetCertificate.fingerprintSha256 = info.fingerprintSha256;
    result.targetCertificate.notBeforeMs = info.notBeforeMs;
    result.targetCertificate.notAfterMs = info.notAfterMs;
    result.targetCertificate.flags = info.flags;
    result.targetCertificate.rootTrusted = info.rootTrusted;
    result.targetCertificate.hostMismatch = info.hostMismatch;
    result.targetCertificate.riskFlags = info.riskFlags;
    if (!normalized.expectedTargetFingerprintSha256.empty() &&
        !RdpCertificatePolicy::FingerprintMatches(
            normalized.expectedTargetFingerprintSha256,
            result.targetCertificate.fingerprintSha256)) {
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.targetCertificate.riskFlags, RdpPreflightPolicy::kRiskCertificateChanged);
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.targetRiskFlags, RdpPreflightPolicy::kRiskCertificateChanged);
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.riskFlags, RdpPreflightPolicy::kRiskCertificateChanged);
    }
    if (info.ok && RdpGatewayPolicy::trustAllowsStage(
            result.targetCertificate, normalized.expectedTargetFingerprintSha256,
            normalized.targetAllowUntrustedRoot, normalized.targetAllowHostMismatch,
            normalized.targetAllowTimeAnomaly)) {
        result.requiresUserDecision = false;
    }
    return result;
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
    const int64_t nowUs = steadyNowUs();
    const auto ageMs = [nowUs](int64_t timestampUs) -> int64_t {
        return timestampUs > 0 && nowUs >= timestampUs ?
            (nowUs - timestampUs) / 1000 : -1;
    };
    stats.firstPaintMs = firstPaintUs > 0 ? firstPaintUs / 1000 : 0;
    stats.lastPaintMs = lastPaintUs > 0 ? lastPaintUs / 1000 : 0;
    stats.lastRemoteUpdateAgeMs = ageMs(lastPaintUs);
    stats.eventLoopAgeMs = ageMs(
        impl_->lastEventLoopTickUs.load(std::memory_order_acquire));
    stats.eventLoopBlockMaxUs = impl_->eventLoopBlockMaxUs.load(
        std::memory_order_acquire);
    stats.lastInputPostAgeMs = ageMs(
        impl_->lastInputPostedUs.load(std::memory_order_acquire));
    stats.eventLoopTicks = impl_->eventLoopTicks.load(std::memory_order_acquire);
    stats.networkCheckCount = impl_->networkCheckCount.load(std::memory_order_acquire);
    stats.networkCheckFailures = impl_->networkCheckFailures.load(std::memory_order_acquire);
    stats.inputPostFailures = impl_->inputPostFailures.load(std::memory_order_acquire);
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
        std::lock_guard<std::mutex> displayLock(impl_->displayControlMutex);
        stats.displayControlReady = impl_->displayControlReady;
        stats.displayControlDisabled = impl_->displayControlDisabled;
        stats.displayRequestedWidth = impl_->displayRequestedWidth;
        stats.displayRequestedHeight = impl_->displayRequestedHeight;
        stats.displayEffectiveWidth = impl_->displayEffectiveWidth;
        stats.displayEffectiveHeight = impl_->displayEffectiveHeight;
        stats.displayScaleFactor = impl_->displayScaleFactor;
        stats.displayRequestCount = impl_->displayRequestCount;
        stats.displayFailureCount = impl_->displayFailureCount;
        stats.displayLastResult = impl_->displayLastResult;
    }
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

RdpDisplayLayoutResult FreeRdpAdapter::requestDisplayLayout(
    const RdpDisplayLayoutRequest& request) {
    const RdpDisplayLayoutResult validation = RdpDisplayLayoutPolicy::Validate(request);
    if (!validation.accepted) {
        return validation;
    }
    if (!impl_ || getState() != ConnectionState::CONNECTED) {
        return {false, "not_connected", "RDP session is not connected"};
    }
#if defined(CHANNEL_DISP_CLIENT)
    std::lock_guard<std::mutex> displayLock(impl_->displayControlMutex);
    if (impl_->displayControlDisabled) {
        return {false, "disabled", "Dynamic display layout is disabled for this session"};
    }
    if (!impl_->displayControlReady || !impl_->displayControl) {
        return {false, "not_ready", "RDP display-control channel is not ready"};
    }
    if (impl_->displayMaxNumMonitors < 1 ||
        !RdpDisplayLayoutPolicy::IsWithinServerAreaCaps(
            request, impl_->displayMaxAreaFactorA, impl_->displayMaxAreaFactorB)) {
        impl_->displayRequestCount++;
        impl_->displayFailureCount++;
        impl_->displayLastResult = "server_caps_exceeded";
        return {false, "server_caps_exceeded",
                "RDP display layout exceeds the negotiated server caps"};
    }
    impl_->pendingDisplayLayout = request;
    impl_->displayLayoutPending = true;
    impl_->displayRequestedWidth = request.width;
    impl_->displayRequestedHeight = request.height;
    impl_->displayScaleFactor = request.desktopScaleFactor;
    impl_->displayRequestCount++;
    impl_->displayLastResult = "queued";
    return validation;
#else
    return {false, "unsupported", "FreeRDP display-control support is not built"};
#endif
}

bool FreeRdpAdapter::cancelDisplayLayout() {
    if (!impl_) {
        return false;
    }
    std::lock_guard<std::mutex> displayLock(impl_->displayControlMutex);
    const bool cancelled = impl_->displayLayoutPending;
    impl_->displayLayoutPending = false;
    if (cancelled) {
        impl_->displayLastResult = "cancelled";
    }
    return cancelled;
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
    if (!impl_->rdpClipboardEnabled()) {
        OH_LOG_INFO(LOG_APP, "[RDP] clipboard send ignored because the setting is disabled");
        return;
    }
    {
        std::lock_guard<std::mutex> lock(impl_->clipboardMutex);
        impl_->clipboardText = t;
    }
    if (impl_->fileClipboard) {
        impl_->fileClipboard->clearLocalFiles();
        if (impl_->rdpClipboardEnabled() && impl_->fileClipboard->attached()) {
            impl_->fileClipboard->sendCurrentFormatList(true);
        }
    }
}
bool FreeRdpAdapter::setClipboardFiles(const std::vector<std::string>& paths) {
    if (!impl_->rdpClipboardEnabled() || !impl_->fileClipboard ||
        !impl_->fileClipboard->attached()) {
        return false;
    }
    return impl_->fileClipboard->publishLocalFiles(paths) ==
        RdpFileClipboardOfferResult::Ready;
}
void FreeRdpAdapter::sendClipboardData(const uint8_t* data, uint32_t len) {
    if (data == nullptr || len == 0) return;
    setClipboardText(std::string(reinterpret_cast<const char*>(data), len));
}
std::string FreeRdpAdapter::getClipboardText() {
    if (!impl_->rdpClipboardEnabled()) {
        return {};
    }
    std::lock_guard<std::mutex> lock(impl_->clipboardMutex);
    return impl_->clipboardText;
}
bool FreeRdpAdapter::isClipboardReceiveReady() {
    return impl_->rdpClipboardEnabled() && impl_->fileClipboard &&
        impl_->fileClipboard->attached();
}
bool FreeRdpAdapter::setSessionClipboardEnabled(bool enabled) {
    const ConnectionState state = getState();
    if (state != ConnectionState::CONNECTING && state != ConnectionState::CONNECTED) {
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(impl_->configMutex);
        impl_->config.rdClipboardEnabled = enabled;
    }
    if (!enabled) {
        // Keep the negotiated cliprdr carrier attached so a later enable can
        // resume without renegotiating the session. Every callback checks the
        // setting before reading or writing channel data, and clearing the
        // bridge removes already-offered local file/text state.
        impl_->clearClipboardState();
    }
    OH_LOG_INFO(LOG_APP, "[RDP] session clipboard setting=%{public}s",
                enabled ? "enabled" : "disabled");
    return true;
}
bool FreeRdpAdapter::supportsFileTransfer() { return true; }
SessionTransferStatus FreeRdpAdapter::getSessionTransferStatus() {
    std::lock_guard<std::mutex> lock(impl_->transferStatusMutex);
    return impl_->transferStatus.snapshot();
}

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
    mutable std::mutex      configMutex;
    RdpNetworkActionGate    networkActionGate;
    RdpNetworkRecoveryPolicy networkRecovery;
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
    disconnect();
}

// ---- 协议元信息 ----
std::string FreeRdpAdapter::protocolName() { return "RDP"; }
int FreeRdpAdapter::defaultPort() { return RDP_TCP_PORT; }
std::string FreeRdpAdapter::protocolVersion() { return "3.7.0-skeleton"; }

// ---- 连接管理 ----
int FreeRdpAdapter::connect(const ConnectionConfig& cfg) {
    std::lock_guard<std::recursive_mutex> operationLock(
        impl_->networkActionGate.mutex());
    impl_->networkRecovery.admitConnectionOwner();
    impl_->interruptTeardownRetirementWait();
    return connectInternal(cfg, 0);
}

int FreeRdpAdapter::connectInternal(
    const ConnectionConfig& cfg, uint64_t networkActionToken) {
    if (networkActionToken != 0 &&
        !impl_->networkRecovery.isCurrent(networkActionToken, true)) {
        return -125;
    }
    if (impl_->state == ConnectionState::CONNECTED) {
        disconnectInternal(networkActionToken == 0);
    }
    ConnectionConfig normalizedConfig = cfg;
    if (normalizedConfig.targetServerName.empty()) {
        normalizedConfig.targetServerName = normalizedConfig.customHostname;
    }
    {
        std::lock_guard<std::mutex> lock(impl_->configMutex);
        RdpReconnectCredentialPolicy::replace(
            impl_->config, normalizedConfig);
    }

    RdpEndpointRoute route;
    std::string routeErrorCode;
    std::string routeErrorMessage;
    if (!resolveRdpEndpointRoute(normalizedConfig, route, routeErrorCode, routeErrorMessage)) {
        impl_->setState(ConnectionState::ERROR,
                        routeErrorMessage + " [" + routeErrorCode + "]");
        return -70;
    }
    RdpGatewayPolicy::normalizeRouteConfig(normalizedConfig, route);
    {
        std::lock_guard<std::mutex> lock(impl_->configMutex);
        RdpGatewayPolicy::normalizeRouteConfig(impl_->config, route);
    }
    if (route.endpointMode == RdpEndpointMode::MicrosoftRdGateway) {
        // The skeleton has no HTTP/RPC/WebSocket tunnel implementation. It
        // must never send an RDP X.224 packet to the Gateway TLS port.
        impl_->setState(ConnectionState::ERROR,
                        "Microsoft RD Gateway requires the FreeRDP runtime [E-RDP-GATEWAY-AWARE-UNAVAILABLE]");
        return -71;
    }
    impl_->setState(
        networkActionToken == 0
            ? ConnectionState::CONNECTING
            : ConnectionState::RECONNECTING,
        networkActionToken == 0
            ? "Connecting..."
            : "RDP network changed; resolving the endpoint again");
    if (networkActionToken != 0 &&
        !impl_->networkRecovery.isCurrent(networkActionToken, true)) {
        return -125;
    }

    const int port = route.targetPort;
    int ret;

    ret = rdpTcpConnect(route.targetHost, port, impl_->sockFd);
    if (ret < 0) { impl_->setState(ConnectionState::ERROR, "TCP connection failed"); return ret; }
    ret = rdpSendX224ConnectionRequest(impl_->sockFd);
    if (ret < 0) { impl_->setState(ConnectionState::ERROR, "X.224 failed"); disconnectInternal(); return -22; }
    ret = rdpRecvX224ConnectionConfirm(impl_->sockFd);
    if (ret < 0) { impl_->setState(ConnectionState::ERROR, "X.224 confirm failed"); disconnectInternal(); return -23; }
    ret = rdpSendNegotiationRequest(impl_->sockFd);
    if (ret < 0) { impl_->setState(ConnectionState::ERROR, "RDP neg req failed"); disconnectInternal(); return -24; }
    ret = rdpRecvNegotiationResponse(impl_->sockFd, impl_->selectedProtocol, impl_->tlsEnabled);
    if (ret < 0) { impl_->setState(ConnectionState::ERROR, "RDP neg resp failed"); disconnectInternal(); return -25; }
    ret = rdpSendMcsConnectInitial(impl_->sockFd);
    if (ret < 0) { impl_->setState(ConnectionState::ERROR, "MCS init failed"); disconnectInternal(); return -26; }
    ret = rdpRecvMcsConnectResponse(impl_->sockFd);
    if (ret < 0) { impl_->setState(ConnectionState::ERROR, "MCS resp failed"); disconnectInternal(); return -27; }

    impl_->setState(ConnectionState::CONNECTED, "RDP session established (skeleton)");
    const std::string logHost = SafeLog::MaskHost(cfg.host);
    OH_LOG_INFO(LOG_APP, "[RDP] RDP skeleton session: %{public}s:%{public}d (TLS=%{public}s)",
                logHost.c_str(), port, impl_->tlsEnabled ? "yes" : "no");
    return 0;
}

void FreeRdpAdapter::disconnect() {
    std::lock_guard<std::recursive_mutex> operationLock(
        impl_->networkActionGate.mutex());
    const uint64_t retirementToken =
        impl_->networkRecovery.retireConnectionOwner();
    impl_->interruptTeardownRetirementWait();
    disconnectInternal();
    std::lock_guard<std::mutex> lock(impl_->configMutex);
    (void)RdpReconnectCredentialPolicy::clearIfStillRetired(
        impl_->config, impl_->networkRecovery, retirementToken);
}

void FreeRdpAdapter::disconnectInternal(bool publishDisconnected) {
    impl_->cursorStore.setVisible(false);
    if (impl_->sockFd >= 0) {
        shutdown(impl_->sockFd, SHUT_RDWR);
        close(impl_->sockFd);
        impl_->sockFd = -1;
    }
    impl_->selectedProtocol = 0;
    impl_->tlsEnabled = false;
    if (publishDisconnected) {
        impl_->setState(ConnectionState::DISCONNECTED, "Disconnected");
        OH_LOG_INFO(LOG_APP, "[RDP] Disconnected");
    }
}

void FreeRdpAdapter::onNetworkChanged(
    bool available, uint64_t networkGeneration) {
    const RdpNetworkRecoveryAction action =
        impl_->networkRecovery.onNetworkChanged(available, networkGeneration);
    if (!action.accepted) {
        return;
    }
    impl_->interruptTeardownRetirementWait();
    std::lock_guard<std::recursive_mutex> operationLock(
        impl_->networkActionGate.mutex());
    if (!impl_->networkRecovery.isCurrent(action.token)) {
        return;
    }
    impl_->setState(ConnectionState::RECONNECTING,
                    "RDP network changed; stopping the old transport");
    if (!impl_->networkRecovery.isCurrent(action.token)) {
        return;
    }
    disconnectInternal(action.publishDisconnectedOnTeardown);
    {
        std::lock_guard<std::mutex> lock(impl_->configMutex);
        (void)RdpReconnectCredentialPolicy::retireOwnerAndClear(
            impl_->config, impl_->networkRecovery);
    }
    impl_->setState(
        ConnectionState::ERROR,
        available
            ? "RDP network recovery requires the FreeRDP runtime "
              "[E-RDP-NETWORK-RECOVERY-UNAVAILABLE]"
            : "RDP default network is unavailable "
              "[E-RDP-NETWORK-UNAVAILABLE]");
}

ConnectionState FreeRdpAdapter::getState() { return impl_->state; }

void FreeRdpAdapter::requestFrameRefresh() {
    OH_LOG_WARN(LOG_APP, "[RDP] requestFrameRefresh skipped: skeleton adapter has no video surface");
}

RdpCertificateInfo FreeRdpAdapter::probeRdpCertificate(
    const std::string& host, int port, const std::string& serverName,
    const std::function<bool()>& cancelled) {
    return probeRdpCertificateOverTls(host, port, serverName, cancelled);
}

RdpPreflightResult FreeRdpAdapter::probeRdpCertificateRoute(
    const RdpPreflightRequest& request) {
    ConnectionConfig cfg;
    cfg.host = request.route.targetHost;
    cfg.port = request.route.targetPort;
    cfg.targetServerName = request.route.targetServerName;
    cfg.gatewayHost = request.route.gatewayHost;
    cfg.gatewayPort = request.route.gatewayPort;
    cfg.rdpAuthMode = request.targetRestrictedAdmin
        ? RdpAuthenticationMode::RestrictedAdmin
        : RdpAuthenticationMode::Password;
    cfg.rdpEndpointMode = RdpGatewayPolicy::endpointModeName(request.route.endpointMode);
    cfg.rdpGatewayTransport = RdpGatewayPolicy::gatewayTransportName(request.route.gatewayTransport);
    cfg.rdpGatewayServerName = request.route.gatewayServerName;
    RdpEndpointRoute normalizedRoute;
    std::string routeErrorCode;
    std::string routeErrorMessage;
    if (!resolveRdpEndpointRoute(cfg, normalizedRoute, routeErrorCode, routeErrorMessage)) {
        return makeRdpPreflightError(
            request, "endpoint", routeErrorCode, routeErrorMessage);
    }
    RdpPreflightRequest normalized = request;
    normalized.route = normalizedRoute;
    if (normalizedRoute.endpointMode == RdpEndpointMode::MicrosoftRdGateway) {
        return makeRdpPreflightError(
            normalized, "gateway", "E-RDP-GATEWAY-AWARE-UNAVAILABLE",
            "Microsoft RD Gateway certificate preflight requires the FreeRDP runtime");
    }
    const RdpCertificateInfo info = probeRdpCertificateOverTls(
        normalizedRoute.targetHost, normalizedRoute.targetPort,
        normalizedRoute.targetServerName, normalized.cancelled);
    RdpPreflightResult result;
    result.ok = info.ok;
    result.preflightStatus = info.ok ? RdpPreflightPolicy::kCompleted :
        (info.preflightStatus.empty() ? RdpPreflightPolicy::kUnavailable : info.preflightStatus);
    result.riskFlags = info.riskFlags;
    result.targetRiskFlags = info.riskFlags;
    if (!info.riskFlags.empty()) {
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.riskFlags, RdpPreflightPolicy::kRiskTargetCertificate);
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.targetRiskFlags, RdpPreflightPolicy::kRiskTargetCertificate);
    }
    result.endpointMode = normalizedRoute.endpointMode;
    result.routeIdentity = RdpGatewayPolicy::routeIdentity(normalizedRoute);
    result.generation = normalized.generation;
    result.requestId = normalized.requestId;
    result.stage = info.ok ? "target" : directRdpPreflightStage(info.errorCode);
    result.errorCode = info.ok ? "" : directRdpPreflightErrorCode(info.errorCode);
    result.errorMessage = info.errorMessage;
    RdpGatewayPolicy::initializeGatewayTransportResult(
        result, normalized.route.gatewayTransport);
    result.requiresUserDecision = info.ok || directRdpPreflightCanTryRealConnection(info);
    result.targetCertificate.present = info.ok && !info.fingerprintSha256.empty();
    result.targetCertificate.stage = "target";
    result.targetCertificate.host = info.host;
    result.targetCertificate.port = info.port;
    result.targetCertificate.serverName = normalizedRoute.targetServerName;
    result.targetCertificate.commonName = info.commonName;
    result.targetCertificate.subject = info.subject;
    result.targetCertificate.issuer = info.issuer;
    result.targetCertificate.fingerprintSha256 = info.fingerprintSha256;
    result.targetCertificate.notBeforeMs = info.notBeforeMs;
    result.targetCertificate.notAfterMs = info.notAfterMs;
    result.targetCertificate.flags = info.flags;
    result.targetCertificate.rootTrusted = info.rootTrusted;
    result.targetCertificate.hostMismatch = info.hostMismatch;
    result.targetCertificate.riskFlags = info.riskFlags;
    if (!request.expectedTargetFingerprintSha256.empty() &&
        !RdpCertificatePolicy::FingerprintMatches(
            request.expectedTargetFingerprintSha256,
            result.targetCertificate.fingerprintSha256)) {
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.targetCertificate.riskFlags, RdpPreflightPolicy::kRiskCertificateChanged);
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.targetRiskFlags, RdpPreflightPolicy::kRiskCertificateChanged);
        RdpPreflightPolicy::addUniqueRiskFlag(
            result.riskFlags, RdpPreflightPolicy::kRiskCertificateChanged);
    }
    if (info.ok && RdpGatewayPolicy::trustAllowsStage(
            result.targetCertificate, request.expectedTargetFingerprintSha256,
            request.targetAllowUntrustedRoot, request.targetAllowHostMismatch,
            request.targetAllowTimeAnomaly)) {
        result.requiresUserDecision = false;
    }
    return result;
}

RdpRenderStats FreeRdpAdapter::getRdpRenderStats() {
    return RdpRenderStats();
}

RdpDisplayLayoutResult FreeRdpAdapter::requestDisplayLayout(
    const RdpDisplayLayoutRequest& request) {
    const RdpDisplayLayoutResult validation = RdpDisplayLayoutPolicy::Validate(request);
    if (!validation.accepted) {
        return validation;
    }
    return {false, "unsupported", "Dynamic RDP display layout requires real FreeRDP"};
}

bool FreeRdpAdapter::cancelDisplayLayout() {
    return false;
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
bool FreeRdpAdapter::setSessionClipboardEnabled(bool enabled) {
    (void)enabled;
    return false;
}
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
