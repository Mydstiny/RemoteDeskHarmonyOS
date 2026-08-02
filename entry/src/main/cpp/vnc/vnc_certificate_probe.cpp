/**
 * vnc_certificate_probe.cpp - bounded POSIX/OpenSSL VNC TLS probe.
 */
#include "vnc_certificate_probe.h"

#include "common/safe_log.h"

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

bool isIpLiteral(const std::string& value) {
    in_addr ipv4 {};
    in6_addr ipv6 {};
    return inet_pton(AF_INET, value.c_str(), &ipv4) == 1 ||
        inet_pton(AF_INET6, value.c_str(), &ipv6) == 1;
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
        const int pollMs = std::min(remainingMs, 250);
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

bool setNonBlocking(int fd) {
    const int flags = ::fcntl(fd, F_GETFL, 0);
    return flags >= 0 && ::fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

WaitStatus connectAddress(int fd, const sockaddr* address, socklen_t addressLength,
                          const ProbeDeadline& deadline,
                          const std::shared_ptr<std::atomic_bool>& token) {
    if (::connect(fd, address, addressLength) == 0) {
        return WaitStatus::Ready;
    }
    if (errno != EINPROGRESS) {
        return WaitStatus::Failed;
    }
    const WaitStatus waitStatus = waitForFd(fd, POLLOUT, deadline, token);
    if (waitStatus != WaitStatus::Ready) {
        return waitStatus;
    }
    int socketError = 0;
    socklen_t socketErrorLength = sizeof(socketError);
    if (::getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) != 0 ||
        socketError != 0) {
        return WaitStatus::Failed;
    }
    return WaitStatus::Ready;
}

std::string boundedPrintable(const std::string& value, size_t maxBytes) {
    std::string output;
    output.reserve(std::min(value.size(), maxBytes));
    for (unsigned char ch : value) {
        if (output.size() >= maxBytes) {
            break;
        }
        output.push_back(ch >= 0x20 && ch <= 0x7e ? static_cast<char>(ch) : '?');
    }
    return output;
}

std::string boundedX509Name(X509_NAME* name) {
    if (name == nullptr) {
        return "";
    }
    char* text = X509_NAME_oneline(name, nullptr, 0);
    if (text == nullptr) {
        return "";
    }
    const std::string raw(text);
    OPENSSL_free(text);
    return boundedPrintable(raw, kMaxNameBytes);
}

std::string boundedCommonName(X509* certificate) {
    if (certificate == nullptr) {
        return "";
    }
    X509_NAME* subject = X509_get_subject_name(certificate);
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
    return boundedPrintable(std::string(reinterpret_cast<const char*>(data),
                                        static_cast<size_t>(length)),
                            kMaxCommonNameBytes);
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
    if (isIpLiteral(name)) {
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
    }
    return "VNC TLS 证书探测失败 [E-VNC-CERT-UNKNOWN]";
}

VncCertificateInfo probeVncCertificate(const VncCertificateProbeConfig& config) {
    const int timeoutMs = boundedTimeout(config.timeoutMs);
    const ProbeDeadline deadline {Clock::now() + std::chrono::milliseconds(timeoutMs)};
    if (!validAsciiEndpoint(config.host) || config.port < 1 || config.port > 65535 ||
        (config.timeoutMs != 0 && (config.timeoutMs < kMinTimeoutMs ||
                                   config.timeoutMs > kMaxTimeoutMs)) ||
        (!config.serverName.empty() && !validAsciiEndpoint(config.serverName))) {
        return errorResult(config, VncCertificateProbeErrorCode::InvalidInput);
    }
    if (isCancelled(config.cancelled)) {
        return errorResult(config, VncCertificateProbeErrorCode::Cancelled);
    }

    addrinfo hints {};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo* addresses = nullptr;
    const std::string portText = std::to_string(config.port);
    const int lookup = ::getaddrinfo(config.host.c_str(), portText.c_str(), &hints, &addresses);
    if (lookup != 0 || addresses == nullptr) {
        OH_LOG_WARN(LOG_APP, "[VNC-CERT] category=resolve_failed host=%{public}s port=%{public}d",
                    SafeLog::MaskHost(config.host).c_str(), config.port);
        return errorResult(config, VncCertificateProbeErrorCode::ResolveFailed);
    }

    int socketFd = -1;
    WaitStatus connectStatus = WaitStatus::Failed;
    for (addrinfo* address = addresses; address != nullptr; address = address->ai_next) {
        if (isCancelled(config.cancelled)) {
            connectStatus = WaitStatus::Cancelled;
            break;
        }
        socketFd = ::socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (socketFd < 0 || !setNonBlocking(socketFd)) {
            closeSocket(socketFd);
            continue;
        }
        connectStatus = connectAddress(socketFd, address->ai_addr,
                                       static_cast<socklen_t>(address->ai_addrlen),
                                       deadline, config.cancelled);
        if (connectStatus == WaitStatus::Ready) {
            break;
        }
        closeSocket(socketFd);
        if (connectStatus == WaitStatus::Cancelled || connectStatus == WaitStatus::TimedOut) {
            break;
        }
    }
    ::freeaddrinfo(addresses);
    if (connectStatus == WaitStatus::Cancelled) {
        closeSocket(socketFd);
        return errorResult(config, VncCertificateProbeErrorCode::Cancelled);
    }
    if (connectStatus == WaitStatus::TimedOut) {
        closeSocket(socketFd);
        return errorResult(config, VncCertificateProbeErrorCode::ConnectTimeout);
    }
    if (socketFd < 0 || connectStatus != WaitStatus::Ready) {
        closeSocket(socketFd);
        return errorResult(config, VncCertificateProbeErrorCode::ConnectFailed);
    }

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
    std::string verifyName = config.serverName;
    if (verifyName.empty() && !isIpLiteral(config.host)) {
        verifyName = config.host;
    }
    if (!verifyName.empty() && !isIpLiteral(verifyName) &&
        SSL_set_tlsext_host_name(ssl, verifyName.c_str()) != 1) {
        SSL_free(ssl);
        SSL_CTX_free(context);
        closeSocket(socketFd);
        return errorResult(config, VncCertificateProbeErrorCode::TlsContextFailed);
    }

    WaitStatus tlsStatus = WaitStatus::Failed;
    while (true) {
        if (isCancelled(config.cancelled)) {
            tlsStatus = WaitStatus::Cancelled;
            break;
        }
        const int result = SSL_connect(ssl);
        if (result == 1) {
            tlsStatus = WaitStatus::Ready;
            break;
        }
        const int sslError = SSL_get_error(ssl, result);
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
        const VncCertificateProbeErrorCode code =
            tlsStatus == WaitStatus::Cancelled ? VncCertificateProbeErrorCode::Cancelled :
            tlsStatus == WaitStatus::TimedOut ? VncCertificateProbeErrorCode::TlsTimeout :
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
        X509_STORE_CTX_init(storeContext, store, certificate, nullptr) == 1) {
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
