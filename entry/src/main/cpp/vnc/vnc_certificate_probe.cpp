/**
 * vnc_certificate_probe.cpp - bounded POSIX/OpenSSL VNC TLS probe.
 */
#include "vnc_certificate_probe.h"

#include "common/safe_log.h"
#include "common/happy_eyeballs_connector.h"
#include "vnc_transport_policy.h"

#include <arpa/inet.h>
#include <cerrno>
#include <chrono>
#include <climits>
#include <cstring>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <cctype>
#include <ctime>
#include <iomanip>
#include <limits>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#if !defined(RDP_TESTS_ONLY)
#include <hilog/log.h>
#else
// Host native tests do not link the OHOS logging SDK. Keep production log
// calls compiled out without changing the probe's network/TLS behavior.
#define LOG_APP 0
#define OH_LOG_INFO(...) ((void)0)
#define OH_LOG_WARN(...) ((void)0)
#define OH_LOG_ERROR(...) ((void)0)
#endif
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0008
#define LOG_TAG "VNC_CERT_PROBE"

namespace {

constexpr size_t kMaxHostBytes = 255;
constexpr size_t kMaxCommonNameBytes = 256;
constexpr size_t kMaxNameBytes = 2048;
constexpr size_t kMaxNameEntries = 64;
constexpr size_t kMaxResolvedAddresses = 16;
constexpr int kMaxPeerChainDepth = 8;
constexpr int kMinTimeoutMs = 100;
constexpr int kMaxTimeoutMs = 120000;

using Clock = std::chrono::steady_clock;

struct ProbeDeadline {
    Clock::time_point value;
};

bool isCancelled(const std::shared_ptr<std::atomic_bool>& token) {
    return token && token->load(std::memory_order_acquire);
}

int boundedTimeout(int value) {
    return value <= 0 ? 10000 : std::min(value, kMaxTimeoutMs);
}

bool validAsciiEndpoint(const std::string& value) {
    if (value.empty() || value.size() > kMaxHostBytes) {
        return false;
    }
    for (unsigned char ch : value) {
        if (ch < 0x21 || ch > 0x7e || ch == '/' || ch == '\\') {
            return false;
        }
    }
    return true;
}

bool hasTimeRemaining(const ProbeDeadline& deadline, int& remainingMs) {
    const auto now = Clock::now();
    if (now >= deadline.value) {
        remainingMs = 0;
        return false;
    }
    const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
        deadline.value - now).count();
    remainingMs = static_cast<int>(std::min<int64_t>(remaining, INT_MAX));
    if (remainingMs <= 0) {
        remainingMs = 1;
    }
    return true;
}

enum class WaitStatus {
    Ready,
    Failed,
    TimedOut,
    Cancelled,
};

WaitStatus waitForFd(int fd, short events, const ProbeDeadline& deadline,
                     const std::shared_ptr<std::atomic_bool>& token) {
    if (fd < 0) {
        return WaitStatus::Failed;
    }
    while (true) {
        if (isCancelled(token)) {
            return WaitStatus::Cancelled;
        }
        int remainingMs = 0;
        if (!hasTimeRemaining(deadline, remainingMs)) {
            return WaitStatus::TimedOut;
        }
        struct pollfd descriptor {fd, events, 0};
        // Keep cancellation responsive while retaining a bounded syscall.
        const int pollMs = std::min(remainingMs, 50);
        const int result = ::poll(&descriptor, 1, pollMs);
        if (result > 0) {
            if ((descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                return WaitStatus::Failed;
            }
            if ((descriptor.revents & events) != 0) {
                return WaitStatus::Ready;
            }
            continue;
        }
        if (result == 0) {
            continue;
        }
        if (errno == EINTR) {
            continue;
        }
        return WaitStatus::Failed;
    }
}

WaitStatus resolveAddresses(const std::string& host, const std::string& port,
                            const ProbeDeadline& deadline,
                            const std::shared_ptr<std::atomic_bool>& token,
                            std::vector<remotedesk::net::ResolvedAddress>& addresses,
                            int& lookupResult) {
    auto resolved = remotedesk::net::ResolveTcpAddresses(
        host, port, deadline.value, [token]() { return isCancelled(token); },
        AF_UNSPEC, kMaxResolvedAddresses);
    lookupResult = resolved.gaiError;
    addresses = std::move(resolved.addresses);
    switch (resolved.status) {
    case remotedesk::net::ResolveStatus::Ready:
        return addresses.empty() ? WaitStatus::Failed : WaitStatus::Ready;
    case remotedesk::net::ResolveStatus::Cancelled:
        return WaitStatus::Cancelled;
    case remotedesk::net::ResolveStatus::TimedOut:
        return WaitStatus::TimedOut;
    case remotedesk::net::ResolveStatus::Failed:
    case remotedesk::net::ResolveStatus::ResourceExhausted:
        return WaitStatus::Failed;
    }
    return WaitStatus::Failed;
}

void appendBoundedPrintable(std::string& output, const unsigned char* data, size_t length,
                            size_t maxBytes) {
    if (data == nullptr || maxBytes == 0) {
        return;
    }
    const size_t available = maxBytes > output.size() ? maxBytes - output.size() : 0;
    const size_t count = std::min(length, available);
    for (size_t index = 0; index < count; ++index) {
        const unsigned char ch = data[index];
        output.push_back(ch >= 0x20 && ch <= 0x7e ? static_cast<char>(ch) : '?');
    }
}

void appendBoundedPrintable(std::string& output, const char* data, size_t length,
                            size_t maxBytes) {
    appendBoundedPrintable(output, reinterpret_cast<const unsigned char*>(data), length,
                           maxBytes);
}

std::string boundedX509Name(const X509_NAME* name) {
    if (name == nullptr) {
        return "";
    }
    std::string output;
    output.reserve(kMaxNameBytes);
    const int entryCount = X509_NAME_entry_count(name);
    if (entryCount < 0) {
        return output;
    }
    const int boundedEntryCount = std::min(entryCount, static_cast<int>(kMaxNameEntries));
    for (int index = 0; index < boundedEntryCount && output.size() < kMaxNameBytes; ++index) {
        X509_NAME_ENTRY* entry = X509_NAME_get_entry(const_cast<X509_NAME*>(name), index);
        ASN1_OBJECT* object = entry == nullptr ? nullptr : X509_NAME_ENTRY_get_object(entry);
        ASN1_STRING* value = entry == nullptr ? nullptr : X509_NAME_ENTRY_get_data(entry);
        if (object == nullptr || value == nullptr) {
            continue;
        }
        if (!output.empty()) {
            output.push_back('/');
        }
        char objectName[128] = {0};
        const int objectLength = OBJ_obj2txt(objectName, sizeof(objectName), object, 1);
        if (objectLength > 0) {
            appendBoundedPrintable(output, objectName,
                                   static_cast<size_t>(std::min(objectLength,
                                                                static_cast<int>(sizeof(objectName) - 1))),
                                   kMaxNameBytes);
        }
        if (output.size() < kMaxNameBytes) {
            output.push_back('=');
        }
        const unsigned char* data = ASN1_STRING_get0_data(value);
        const int length = ASN1_STRING_length(value);
        if (data != nullptr && length > 0) {
            appendBoundedPrintable(output, data, static_cast<size_t>(length), kMaxNameBytes);
        }
    }
    return output;
}

std::string boundedCommonName(const X509* certificate) {
    if (certificate == nullptr) {
        return "";
    }
    X509_NAME* subject = X509_get_subject_name(const_cast<X509*>(certificate));
    if (subject == nullptr) {
        return "";
    }
    const int index = X509_NAME_get_index_by_NID(subject, NID_commonName, -1);
    if (index < 0) {
        return "";
    }
    X509_NAME_ENTRY* entry = X509_NAME_get_entry(subject, index);
    ASN1_STRING* value = entry == nullptr ? nullptr : X509_NAME_ENTRY_get_data(entry);
    if (value == nullptr) {
        return "";
    }
    const unsigned char* data = ASN1_STRING_get0_data(value);
    const int length = ASN1_STRING_length(value);
    if (data == nullptr || length <= 0) {
        return "";
    }
    std::string output;
    output.reserve(std::min(static_cast<size_t>(length), kMaxCommonNameBytes));
    appendBoundedPrintable(output, data, static_cast<size_t>(length), kMaxCommonNameBytes);
    return output;
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

std::string tlsVersionCategory(const char* version) {
    if (version == nullptr) {
        return "unknown";
    }
    const std::string value(version);
    if (value == "TLSv1.2") {
        return "TLS1.2";
    }
    if (value == "TLSv1.3") {
        return "TLS1.3";
    }
    return "unsupported";
}

bool tlsHandshakeErrorIsVersionFailure(unsigned long error) {
    if (error == 0) {
        return false;
    }
    const int reason = ERR_GET_REASON(error);
#ifdef SSL_R_UNSUPPORTED_PROTOCOL
    if (reason == SSL_R_UNSUPPORTED_PROTOCOL) return true;
#endif
#ifdef SSL_R_VERSION_TOO_LOW
    if (reason == SSL_R_VERSION_TOO_LOW) return true;
#endif
#ifdef SSL_R_TLSV1_ALERT_PROTOCOL_VERSION
    if (reason == SSL_R_TLSV1_ALERT_PROTOCOL_VERSION) return true;
#endif
#ifdef SSL_R_PROTOCOL_VERSION
    if (reason == SSL_R_PROTOCOL_VERSION) return true;
#endif
    return false;
}

std::string cipherCategory(const SSL_CIPHER* cipher) {
    if (cipher == nullptr) {
        return "unknown";
    }
    const std::string name = SSL_CIPHER_get_name(cipher);
    if (name.find("CHACHA20") != std::string::npos) {
        return "chacha20";
    }
    if (name.find("AES") != std::string::npos) {
        return "aes";
    }
    return "other";
}

bool verifyHostName(X509* certificate, const std::string& name) {
    if (certificate == nullptr || name.empty()) {
        return true;
    }
    if (vncEndpointIsIpLiteral(name)) {
        return X509_check_ip_asc(certificate, name.c_str(), 0) == 1;
    }
    return X509_check_host(certificate, name.c_str(), name.size(), 0, nullptr) == 1;
}

VncCertificateInfo errorResult(const VncCertificateProbeConfig& config,
                               VncCertificateProbeErrorCode code) {
    VncCertificateInfo result;
    result.host = config.host;
    result.port = config.port;
    result.serverName = config.serverName;
    result.errorCode = static_cast<int>(code);
    result.errorMessageCategory = vncCertificateProbeErrorCategory(result.errorCode);
    result.errorMessage = vncCertificateProbeErrorMessage(result.errorCode);
    return result;
}

void closeSocket(int& fd) {
    if (fd >= 0) {
        ::shutdown(fd, SHUT_RDWR);
        ::close(fd);
        fd = -1;
    }
}

} // namespace

bool vncNormalizeCertificateFingerprint(const std::string& value, std::string& normalized) {
    normalized.clear();
    std::string candidate = value;
    if (candidate.size() >= 7 && candidate.compare(0, 7, "sha256:") == 0) {
        candidate.erase(0, 7);
    }
    for (unsigned char ch : candidate) {
        if (ch == ':' || ch == '-' || ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
            continue;
        }
        if (!std::isxdigit(ch)) {
            normalized.clear();
            return false;
        }
        normalized.push_back(static_cast<char>(std::tolower(ch)));
    }
    if (normalized.size() != 64) {
        normalized.clear();
        return false;
    }
    return true;
}

bool vncCertificateFingerprintIsCanonical(const std::string& value) {
    if (value.size() != 64) {
        return false;
    }
    for (unsigned char ch : value) {
        if (!(ch >= '0' && ch <= '9') && !(ch >= 'a' && ch <= 'f')) {
            return false;
        }
    }
    return true;
}

std::string vncCertificateProbeErrorCategory(int errorCode) {
    switch (static_cast<VncCertificateProbeErrorCode>(errorCode)) {
        case VncCertificateProbeErrorCode::None: return "";
        case VncCertificateProbeErrorCode::InvalidInput: return "invalid_input";
        case VncCertificateProbeErrorCode::ResolveFailed: return "resolve_failed";
        case VncCertificateProbeErrorCode::ConnectFailed: return "connect_failed";
        case VncCertificateProbeErrorCode::ConnectTimeout: return "connect_timeout";
        case VncCertificateProbeErrorCode::TlsContextFailed: return "tls_context_failed";
        case VncCertificateProbeErrorCode::TlsHandshakeFailed: return "tls_handshake_failed";
        case VncCertificateProbeErrorCode::TlsTimeout: return "tls_timeout";
        case VncCertificateProbeErrorCode::Cancelled: return "cancelled";
        case VncCertificateProbeErrorCode::NoCertificate: return "no_certificate";
        case VncCertificateProbeErrorCode::FingerprintFailed: return "fingerprint_failed";
        case VncCertificateProbeErrorCode::TlsVersionRejected: return "tls_version_rejected";
        case VncCertificateProbeErrorCode::MetadataFailed: return "metadata_failed";
        case VncCertificateProbeErrorCode::CertificateChainTooDeep: return "certificate_chain_too_deep";
        case VncCertificateProbeErrorCode::ResolveTimeout: return "resolve_timeout";
    }
    return "unknown";
}

std::string vncCertificateProbeErrorMessage(int errorCode) {
    switch (static_cast<VncCertificateProbeErrorCode>(errorCode)) {
        case VncCertificateProbeErrorCode::None: return "";
        case VncCertificateProbeErrorCode::InvalidInput: return "VNC 证书探测参数无效 [E-VNC-CERT-INPUT]";
        case VncCertificateProbeErrorCode::ResolveFailed: return "VNC TLS endpoint DNS 解析失败 [E-VNC-CERT-DNS]";
        case VncCertificateProbeErrorCode::ConnectFailed: return "VNC TLS endpoint 连接失败 [E-VNC-CERT-CONNECT]";
        case VncCertificateProbeErrorCode::ConnectTimeout: return "VNC TLS endpoint 连接超时 [E-VNC-CERT-CONNECT-TIMEOUT]";
        case VncCertificateProbeErrorCode::TlsContextFailed: return "VNC TLS context 初始化失败 [E-VNC-CERT-TLS-CONTEXT]";
        case VncCertificateProbeErrorCode::TlsHandshakeFailed: return "VNC TLS 握手失败 [E-VNC-CERT-TLS-HANDSHAKE]";
        case VncCertificateProbeErrorCode::TlsTimeout: return "VNC TLS 握手超时 [E-VNC-CERT-TLS-TIMEOUT]";
        case VncCertificateProbeErrorCode::Cancelled: return "VNC 证书探测已取消 [E-VNC-CERT-CANCELLED]";
        case VncCertificateProbeErrorCode::NoCertificate: return "VNC TLS peer 未提供证书 [E-VNC-CERT-NO-CERTIFICATE]";
        case VncCertificateProbeErrorCode::FingerprintFailed: return "VNC TLS 证书指纹读取失败 [E-VNC-CERT-FINGERPRINT]";
        case VncCertificateProbeErrorCode::TlsVersionRejected: return "VNC TLS 版本不受支持 [E-VNC-CERT-TLS-VERSION]";
        case VncCertificateProbeErrorCode::MetadataFailed: return "VNC TLS 证书元数据无效 [E-VNC-CERT-METADATA]";
        case VncCertificateProbeErrorCode::CertificateChainTooDeep: return "VNC TLS 证书链过深 [E-VNC-CERT-CHAIN-DEPTH]";
        case VncCertificateProbeErrorCode::ResolveTimeout: return "VNC TLS endpoint DNS 解析超时 [E-VNC-CERT-DNS-TIMEOUT]";
    }
    return "VNC TLS 证书探测失败 [E-VNC-CERT-UNKNOWN]";
}

std::string vncRedactCertificateMessageForLog(const std::string& message) {
    std::string redacted = message;
    constexpr const char* kMarkers[] = {"VNC_TRUST_REQUIRED:", "VNC_CERT_CHANGED:"};
    for (const char* marker : kMarkers) {
        const size_t markerLength = std::strlen(marker);
        const size_t markerPosition = redacted.find(marker);
        if (markerPosition == std::string::npos) {
            continue;
        }
        const size_t fingerprintStart = markerPosition + markerLength;
        const size_t fingerprintEnd = redacted.find_first_of(" \t\r\n;", fingerprintStart);
        const size_t end = fingerprintEnd == std::string::npos ? redacted.size() : fingerprintEnd;
        if (end > fingerprintStart) {
            redacted.replace(fingerprintStart, end - fingerprintStart, "<fingerprint-redacted>");
        }
    }
    return redacted;
}

VncCertificateInfo probeVncCertificate(const VncCertificateProbeConfig& config) {
    const int timeoutMs = boundedTimeout(config.timeoutMs);
    const ProbeDeadline deadline {Clock::now() + std::chrono::milliseconds(timeoutMs)};
    std::string verifyName;
    bool sendSni = false;
    if (!validAsciiEndpoint(config.host) || config.port < 1 || config.port > 65535 ||
        (config.timeoutMs != 0 && (config.timeoutMs < kMinTimeoutMs ||
                                   config.timeoutMs > kMaxTimeoutMs)) ||
        (!config.serverName.empty() && !validAsciiEndpoint(config.serverName)) ||
        !vncResolveCertificateIdentity(
            config.host, config.serverName, verifyName, sendSni)) {
        return errorResult(config, VncCertificateProbeErrorCode::InvalidInput);
    }
    if (isCancelled(config.cancelled)) {
        return errorResult(config, VncCertificateProbeErrorCode::Cancelled);
    }

    const std::string portText = std::to_string(config.port);
    std::vector<remotedesk::net::ResolvedAddress> addresses;
    int lookup = EAI_FAIL;
    const WaitStatus resolveStatus = resolveAddresses(config.host, portText, deadline,
                                                      config.cancelled, addresses, lookup);
    if (resolveStatus == WaitStatus::Cancelled) {
        return errorResult(config, VncCertificateProbeErrorCode::Cancelled);
    }
    if (resolveStatus == WaitStatus::TimedOut) {
        OH_LOG_WARN(LOG_APP, "[VNC-CERT] category=resolve_timeout host=%{public}s port=%{public}d",
                    SafeLog::MaskHost(config.host).c_str(), config.port);
        return errorResult(config, VncCertificateProbeErrorCode::ResolveTimeout);
    }
    if (resolveStatus != WaitStatus::Ready || lookup != 0 || addresses.empty()) {
        OH_LOG_WARN(LOG_APP, "[VNC-CERT] category=resolve_failed host=%{public}s port=%{public}d",
                    SafeLog::MaskHost(config.host).c_str(), config.port);
        return errorResult(config, VncCertificateProbeErrorCode::ResolveFailed);
    }

    remotedesk::net::ConnectOptions options;
    options.deadline = deadline.value;
    options.cancelled = [token = config.cancelled]() { return isCancelled(token); };
    options.restoreBlocking = false;
    const remotedesk::net::ConnectResult connection =
        remotedesk::net::ConnectTcpCandidates(addresses, options);
    if (connection.status == remotedesk::net::ConnectStatus::Cancelled) {
        return errorResult(config, VncCertificateProbeErrorCode::Cancelled);
    }
    if (connection.status == remotedesk::net::ConnectStatus::TimedOut) {
        return errorResult(config, VncCertificateProbeErrorCode::ConnectTimeout);
    }
    if (connection.status != remotedesk::net::ConnectStatus::Connected ||
        connection.descriptor < 0) {
        return errorResult(config, VncCertificateProbeErrorCode::ConnectFailed);
    }
    int socketFd = connection.descriptor;

    SSL_CTX* context = SSL_CTX_new(TLS_client_method());
    if (context == nullptr || SSL_CTX_set_min_proto_version(context, TLS1_2_VERSION) != 1) {
        if (context != nullptr) {
            SSL_CTX_free(context);
        }
        closeSocket(socketFd);
        return errorResult(config, VncCertificateProbeErrorCode::TlsContextFailed);
    }
    SSL_CTX_set_verify(context, SSL_VERIFY_NONE, nullptr);
    SSL* ssl = SSL_new(context);
    if (ssl == nullptr || SSL_set_fd(ssl, socketFd) != 1) {
        if (ssl != nullptr) {
            SSL_free(ssl);
        }
        SSL_CTX_free(context);
        closeSocket(socketFd);
        return errorResult(config, VncCertificateProbeErrorCode::TlsContextFailed);
    }
    if (sendSni &&
        SSL_set_tlsext_host_name(ssl, verifyName.c_str()) != 1) {
        SSL_free(ssl);
        SSL_CTX_free(context);
        closeSocket(socketFd);
        return errorResult(config, VncCertificateProbeErrorCode::TlsContextFailed);
    }

    WaitStatus tlsStatus = WaitStatus::Failed;
    unsigned long handshakeError = 0;
    while (true) {
        if (isCancelled(config.cancelled)) {
            tlsStatus = WaitStatus::Cancelled;
            break;
        }
        int remainingMs = 0;
        if (!hasTimeRemaining(deadline, remainingMs)) {
            tlsStatus = WaitStatus::TimedOut;
            break;
        }
        ERR_clear_error();
        const int result = SSL_connect(ssl);
        if (result == 1) {
            tlsStatus = hasTimeRemaining(deadline, remainingMs) ?
                WaitStatus::Ready : WaitStatus::TimedOut;
            break;
        }
        const int sslError = SSL_get_error(ssl, result);
        handshakeError = ERR_peek_last_error();
        if (sslError == SSL_ERROR_WANT_READ) {
            tlsStatus = waitForFd(socketFd, POLLIN, deadline, config.cancelled);
        } else if (sslError == SSL_ERROR_WANT_WRITE) {
            tlsStatus = waitForFd(socketFd, POLLOUT, deadline, config.cancelled);
        } else {
            tlsStatus = WaitStatus::Failed;
        }
        if (tlsStatus != WaitStatus::Ready) {
            break;
        }
    }
    if (tlsStatus != WaitStatus::Ready) {
        X509* partialCertificate = SSL_get_peer_certificate(ssl);
        const bool noPeerCertificate = partialCertificate == nullptr;
        if (partialCertificate != nullptr) {
            X509_free(partialCertificate);
        }
        const VncCertificateProbeErrorCode code =
            tlsStatus == WaitStatus::Cancelled ? VncCertificateProbeErrorCode::Cancelled :
            tlsStatus == WaitStatus::TimedOut ? VncCertificateProbeErrorCode::TlsTimeout :
            tlsHandshakeErrorIsVersionFailure(handshakeError) ? VncCertificateProbeErrorCode::TlsVersionRejected :
            noPeerCertificate ? VncCertificateProbeErrorCode::NoCertificate :
            VncCertificateProbeErrorCode::TlsHandshakeFailed;
        SSL_free(ssl);
        SSL_CTX_free(context);
        closeSocket(socketFd);
        return errorResult(config, code);
    }

    const std::string tlsVersion = tlsVersionCategory(SSL_get_version(ssl));
    if (tlsVersion == "unsupported" || tlsVersion == "unknown") {
        SSL_shutdown(ssl);
        SSL_free(ssl);
        SSL_CTX_free(context);
        closeSocket(socketFd);
        return errorResult(config, VncCertificateProbeErrorCode::TlsVersionRejected);
    }
    X509* certificate = SSL_get_peer_certificate(ssl);
    if (certificate == nullptr) {
        SSL_shutdown(ssl);
        SSL_free(ssl);
        SSL_CTX_free(context);
        closeSocket(socketFd);
        return errorResult(config, VncCertificateProbeErrorCode::NoCertificate);
    }
    STACK_OF(X509)* peerChain = SSL_get_peer_cert_chain(ssl);
    if (peerChain != nullptr && sk_X509_num(peerChain) > kMaxPeerChainDepth) {
        X509_free(certificate);
        SSL_shutdown(ssl);
        SSL_free(ssl);
        SSL_CTX_free(context);
        closeSocket(socketFd);
        return errorResult(config, VncCertificateProbeErrorCode::CertificateChainTooDeep);
    }
    unsigned char digest[EVP_MAX_MD_SIZE] = {0};
    unsigned int digestSize = 0;
    if (X509_digest(certificate, EVP_sha256(), digest, &digestSize) != 1 || digestSize != 32) {
        X509_free(certificate);
        SSL_shutdown(ssl);
        SSL_free(ssl);
        SSL_CTX_free(context);
        closeSocket(socketFd);
        return errorResult(config, VncCertificateProbeErrorCode::FingerprintFailed);
    }
    std::ostringstream fingerprint;
    fingerprint << std::hex << std::nouppercase << std::setfill('0');
    for (unsigned int index = 0; index < digestSize; ++index) {
        fingerprint << std::setw(2) << static_cast<unsigned int>(digest[index]);
    }

    VncCertificateInfo result;
    result.ok = true;
    result.host = config.host;
    result.port = config.port;
    result.serverName = config.serverName;
    result.fingerprintSha256 = fingerprint.str();
    result.commonName = boundedCommonName(certificate);
    result.subject = boundedX509Name(X509_get_subject_name(certificate));
    result.issuer = boundedX509Name(X509_get_issuer_name(certificate));
    if (!asn1TimeToMillis(X509_get0_notBefore(certificate), result.notBeforeMs) ||
        !asn1TimeToMillis(X509_get0_notAfter(certificate), result.notAfterMs)) {
        result = errorResult(config, VncCertificateProbeErrorCode::MetadataFailed);
        X509_free(certificate);
        SSL_shutdown(ssl);
        SSL_free(ssl);
        SSL_CTX_free(context);
        closeSocket(socketFd);
        return result;
    }
    result.hostMismatch = !verifyHostName(certificate, verifyName);
    result.tlsVersion = tlsVersion;
    result.cipherCategory = cipherCategory(SSL_get_current_cipher(ssl));

    X509_STORE* store = X509_STORE_new();
    X509_STORE_CTX* storeContext = X509_STORE_CTX_new();
    if (store != nullptr && storeContext != nullptr && X509_STORE_set_default_paths(store) == 1 &&
        X509_STORE_CTX_init(storeContext, store, certificate, peerChain) == 1) {
        X509_VERIFY_PARAM* verifyParameters = X509_STORE_CTX_get0_param(storeContext);
        if (verifyParameters != nullptr) {
            X509_VERIFY_PARAM_set_depth(verifyParameters, kMaxPeerChainDepth);
        }
        result.rootTrusted = X509_verify_cert(storeContext) == 1;
    }
    if (storeContext != nullptr) {
        X509_STORE_CTX_free(storeContext);
    }
    if (store != nullptr) {
        X509_STORE_free(store);
    }
    X509_free(certificate);
    SSL_shutdown(ssl);
    SSL_free(ssl);
    SSL_CTX_free(context);
    closeSocket(socketFd);
    OH_LOG_INFO(LOG_APP,
                "[VNC-CERT] category=ok host=%{public}s port=%{public}d tls=%{public}s rootTrusted=%{public}s hostMismatch=%{public}s fingerprint=%{public}s",
                SafeLog::MaskHost(config.host).c_str(), config.port, result.tlsVersion.c_str(),
                result.rootTrusted ? "true" : "false", result.hostMismatch ? "true" : "false",
                SafeLog::HashForLog(result.fingerprintSha256).c_str());
    return result;
}
