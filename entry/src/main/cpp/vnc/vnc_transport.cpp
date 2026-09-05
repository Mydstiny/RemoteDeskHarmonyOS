/**
 * vnc_transport.cpp - bounded POSIX/TLS/WebSocket VNC transports.
 */
#include "vnc_transport.h"
#include "vnc_certificate_probe.h"
#include "vnc_rfb_protocol.h"
#include "vnc_transport_policy.h"
#include "common/happy_eyeballs_connector.h"
#include "common/network_generation_fence.h"

#include <arpa/inet.h>
#include <climits>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <sstream>

#include <openssl/rand.h>
#include <openssl/sha.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

namespace {

constexpr size_t kMaxHttpHeaderBytes = 64 * 1024;
constexpr size_t kMaxWebSocketFrameBytes = 8 * 1024 * 1024;
constexpr size_t kMaxResolvedAddresses = 16;
constexpr int kDefaultTimeoutMs = 10000;

using Clock = std::chrono::steady_clock;

struct TransportDeadline {
    Clock::time_point value;
};

enum class TransportWaitStatus {
    Ready,
    Failed,
    TimedOut,
    Cancelled,
};

bool hasTimeRemaining(const TransportDeadline& deadline, int& remainingMs) {
    const auto now = Clock::now();
    if (now >= deadline.value) {
        remainingMs = 0;
        return false;
    }
    remainingMs = static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(
        deadline.value - now).count());
    if (remainingMs <= 0) {
        remainingMs = 1;
    }
    return true;
}

bool isCancelled(const std::shared_ptr<std::atomic_bool>& token,
                 uint64_t networkGeneration = 0) {
    if (token && token->load(std::memory_order_acquire)) {
        return true;
    }
    return networkGeneration != 0 &&
        remotedesk::net::ProcessNetworkGenerationFence().shouldCancel(
            remotedesk::net::NetworkGenerationSnapshot {
                networkGeneration, true});
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

TransportWaitStatus resolveTransportAddresses(
    const std::string& host, const std::string& port,
    const TransportDeadline& deadline,
    const std::shared_ptr<std::atomic_bool>& cancelled,
    uint64_t networkGeneration,
    std::vector<remotedesk::net::ResolvedAddress>& addresses, int& lookupResult) {
    auto resolved = remotedesk::net::ResolveTcpAddresses(
        host, port, deadline.value,
        [cancelled, networkGeneration]() {
            return isCancelled(cancelled, networkGeneration);
        }, AF_UNSPEC,
        kMaxResolvedAddresses);
    lookupResult = resolved.gaiError;
    addresses = std::move(resolved.addresses);
    switch (resolved.status) {
    case remotedesk::net::ResolveStatus::Ready:
        return addresses.empty() ? TransportWaitStatus::Failed : TransportWaitStatus::Ready;
    case remotedesk::net::ResolveStatus::Cancelled:
        return TransportWaitStatus::Cancelled;
    case remotedesk::net::ResolveStatus::TimedOut:
        return TransportWaitStatus::TimedOut;
    case remotedesk::net::ResolveStatus::Failed:
    case remotedesk::net::ResolveStatus::ResourceExhausted:
        return TransportWaitStatus::Failed;
    }
    return TransportWaitStatus::Failed;
}

std::string errnoMessage(const char* operation) {
    std::string result = operation == nullptr ? "socket error" : operation;
    result += ": ";
    result += std::strerror(errno);
    return result;
}

bool waitForFd(int fd, short events, const TransportDeadline& deadline,
               std::string& error,
               const std::shared_ptr<std::atomic_bool>& cancelled = nullptr,
               uint64_t networkGeneration = 0) {
    if (fd < 0) {
        error = "socket is closed";
        return false;
    }
    struct pollfd pollFd;
    pollFd.fd = fd;
    pollFd.events = events;
    pollFd.revents = 0;
    while (true) {
        if (isCancelled(cancelled, networkGeneration)) {
            error = "E-VNC-CERT-CANCELLED";
            return false;
        }
        int remainingMs = 0;
        if (!hasTimeRemaining(deadline, remainingMs)) {
            error = "socket operation timed out";
            return false;
        }
        const int pollMs = std::min(remainingMs, 50);
        const int result = ::poll(&pollFd, 1, pollMs);
        if (result > 0) {
            if ((pollFd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                error = "socket closed while waiting";
                return false;
            }
            return (pollFd.revents & events) != 0;
        }
        if (result == 0) {
            continue;
        }
        if (errno != EINTR) {
            error = errnoMessage("poll");
            return false;
        }
    }
}

bool waitForFd(int fd, short events, int timeoutMs, std::string& error,
               const std::shared_ptr<std::atomic_bool>& cancelled = nullptr,
               uint64_t networkGeneration = 0) {
    const int boundedTimeout = timeoutMs <= 0 ? kDefaultTimeoutMs : timeoutMs;
    const TransportDeadline deadline {
        Clock::now() + std::chrono::milliseconds(boundedTimeout)};
    return waitForFd(fd, events, deadline, error, cancelled,
                     networkGeneration);
}

std::string trimAscii(std::string value) {
    while (!value.empty() && (value.back() == '\r' || value.back() == '\n' ||
                              value.back() == ' ' || value.back() == '\t')) {
        value.pop_back();
    }
    size_t start = 0;
    while (start < value.size() && (value[start] == ' ' || value[start] == '\t')) {
        ++start;
    }
    return value.substr(start);
}

void setTlsIoError(std::string& error, bool writing, const std::string& waitError = "") {
    if (waitError == "E-VNC-CERT-CANCELLED") {
        error = "E-VNC-CERT-CANCELLED";
        return;
    }
    if (waitError == "socket operation timed out") {
        error = "E-VNC-CERT-TLS-TIMEOUT";
        return;
    }
    error = writing ? "E-VNC-CERT-TLS-WRITE" : "E-VNC-CERT-TLS-READ";
}

} // namespace

VncTransport::VncTransport() = default;

VncTransport::~VncTransport() {
    close();
}

bool VncTransport::connect(const VncTransportConfig& config, std::string& error) {
    close();
    cancelled_ = config.cancelled;
    networkGeneration_ = config.networkGeneration;
#if defined(RDP_TESTS_ONLY)
    afterConnectRestoreForTesting_ =
        config.afterConnectRestoreForTesting;
#endif
    if (isCancelled(config.cancelled, config.networkGeneration)) {
        error = "E-VNC-CERT-CANCELLED";
        return false;
    }
    if (!vncNativeTransportIsAvailable(config.transport)) {
        error = "VNC transport is disabled until its versioned gateway contract is deployed";
        return false;
    }
    if (config.host.empty() || config.port < 1 || config.port > 65535) {
        error = "invalid VNC transport endpoint";
        return false;
    }
    if (config.tls) {
        std::string identity;
        bool sendSni = false;
        if (!vncResolveCertificateIdentity(
                config.host, config.serverName, identity, sendSni)) {
            error = "invalid VNC TLS identity";
            return false;
        }
    }
    if (config.transport == "websocket_gateway") {
        std::string authority;
        if (!vncFormatWebSocketAuthority(config.host, config.port, authority)) {
            error = "invalid WebSocket gateway endpoint";
            return false;
        }
    }
    const int timeoutMs = config.connectTimeoutMs <= 0 ? kDefaultTimeoutMs : config.connectTimeoutMs;
    const auto deadline = Clock::now() + std::chrono::milliseconds(timeoutMs);
    if (!connectTcp(config.host, config.port, deadline, config.cancelled,
                    config.networkGeneration, error)) {
        close();
        return false;
    }
    if (config.tls && !enableTls(config, deadline, error)) {
        close();
        return false;
    }
    websocket_ = config.transport == "websocket_gateway";
    if (websocket_ && !websocketHandshake(config, error)) {
        close();
        return false;
    }
    if (config.transport == "ultravnc_repeater" && !sendRepeaterPairing(config, error)) {
        close();
        return false;
    }
    open_ = true;
    return true;
}

bool VncTransport::connectTcp(const std::string& host, int port,
                              std::chrono::steady_clock::time_point deadlineValue,
                              const std::shared_ptr<std::atomic_bool>& cancelled,
                              uint64_t networkGeneration,
                              std::string& error) {
    const TransportDeadline deadline {deadlineValue};
    const std::string portText = std::to_string(port);
    std::vector<remotedesk::net::ResolvedAddress> addresses;
    int lookup = EAI_FAIL;
    const TransportWaitStatus resolveStatus = resolveTransportAddresses(
        host, portText, deadline, cancelled, networkGeneration,
        addresses, lookup);
    if (resolveStatus == TransportWaitStatus::Cancelled ||
        isCancelled(cancelled, networkGeneration)) {
        error = "E-VNC-CERT-CANCELLED";
        return false;
    }
    if (resolveStatus == TransportWaitStatus::TimedOut) {
        error = "E-VNC-CERT-CONNECT-TIMEOUT";
        return false;
    }
    if (resolveStatus != TransportWaitStatus::Ready || lookup != 0 || addresses.empty()) {
        error = "DNS lookup failed: ";
        error += gai_strerror(lookup);
        return false;
    }

    remotedesk::net::ConnectOptions options;
    options.deadline = deadlineValue;
    options.cancelled = [cancelled, networkGeneration]() {
        return isCancelled(cancelled, networkGeneration);
    };
    options.restoreBlocking = false;
#if defined(RDP_TESTS_ONLY)
    options.afterRestoreForTest = afterConnectRestoreForTesting_;
#endif
    const remotedesk::net::ConnectResult connection =
        remotedesk::net::ConnectTcpCandidates(addresses, options);
    if (connection.status == remotedesk::net::ConnectStatus::Cancelled) {
        error = "E-VNC-CERT-CANCELLED";
        return false;
    }
    if (connection.status == remotedesk::net::ConnectStatus::TimedOut) {
        error = "E-VNC-CERT-CONNECT-TIMEOUT";
        return false;
    }
    if (connection.status != remotedesk::net::ConnectStatus::Connected ||
        connection.descriptor < 0) {
        error = "unable to connect to VNC endpoint";
        return false;
    }
    socketFd_ = connection.descriptor;
    error.clear();
    // FramebufferUpdateRequest is only ten bytes and gates the server's next
    // capture.  Avoid Nagle delay for those requests, and leave enough receive
    // window for one compressed frame to arrive while the prior frame decodes.
    const int noDelay = 1;
    (void)::setsockopt(socketFd_, IPPROTO_TCP, TCP_NODELAY,
                       &noDelay, sizeof(noDelay));
    const int receiveBufferBytes = 4 * 1024 * 1024;
    (void)::setsockopt(socketFd_, SOL_SOCKET, SO_RCVBUF,
                       &receiveBufferBytes, sizeof(receiveBufferBytes));
    return true;
}

bool VncTransport::enableTls(const VncTransportConfig& config,
                             std::chrono::steady_clock::time_point deadlineValue,
                             std::string& error) {
    const TransportDeadline deadline {deadlineValue};
    const SSL_METHOD* method = TLS_client_method();
    SSL_CTX* context = SSL_CTX_new(method);
    if (context == nullptr) {
        error = "E-VNC-CERT-TLS-CONTEXT";
        return false;
    }
    if (SSL_CTX_set_min_proto_version(context, TLS1_2_VERSION) != 1) {
        SSL_CTX_free(context);
        error = "E-VNC-CERT-TLS-CONTEXT";
        return false;
    }
    // VNC deployments frequently use self-signed certificates.  The first
    // handshake is a fingerprint-probe only and is rejected below; subsequent
    // sessions must supply the user-confirmed SHA-256 pin.  This keeps the
    // trust decision in VncTrustService instead of silently accepting a CA or
    // silently trusting a self-signed peer.
    SSL_CTX_set_verify(context, SSL_VERIFY_NONE, nullptr);
    SSL* ssl = SSL_new(context);
    if (ssl == nullptr) {
        SSL_CTX_free(context);
        error = "E-VNC-CERT-TLS-CONTEXT";
        return false;
    }
    if (SSL_set_fd(ssl, socketFd_) != 1) {
        SSL_free(ssl);
        SSL_CTX_free(context);
        error = "E-VNC-CERT-TLS-CONTEXT";
        return false;
    }
    std::string serverName;
    bool sendSni = false;
    if (!vncResolveCertificateIdentity(config.host, config.serverName, serverName, sendSni)) {
        SSL_free(ssl);
        SSL_CTX_free(context);
        error = "E-VNC-CERT-TLS-IDENTITY";
        return false;
    }
    if (sendSni &&
        SSL_set_tlsext_host_name(ssl, serverName.c_str()) != 1) {
        SSL_free(ssl);
        SSL_CTX_free(context);
        error = "E-VNC-CERT-TLS-SNI";
        return false;
    }
    while (true) {
        if (isCancelled(config.cancelled, config.networkGeneration)) {
            error = "E-VNC-CERT-CANCELLED";
            SSL_free(ssl);
            SSL_CTX_free(context);
            return false;
        }
        int remainingMs = 0;
        if (!hasTimeRemaining(deadline, remainingMs)) {
            error = "E-VNC-CERT-TLS-TIMEOUT";
            SSL_free(ssl);
            SSL_CTX_free(context);
            return false;
        }
        ERR_clear_error();
        const int result = SSL_connect(ssl);
        if (result == 1) {
            if (!hasTimeRemaining(deadline, remainingMs)) {
                error = "E-VNC-CERT-TLS-TIMEOUT";
                SSL_free(ssl);
                SSL_CTX_free(context);
                return false;
            }
            break;
        }
        if (!hasTimeRemaining(deadline, remainingMs)) {
            error = "E-VNC-CERT-TLS-TIMEOUT";
            SSL_free(ssl);
            SSL_CTX_free(context);
            return false;
        }
        const int sslError = SSL_get_error(ssl, result);
        const unsigned long handshakeError = ERR_peek_last_error();
        if (sslError == SSL_ERROR_WANT_READ) {
            if (!waitForFd(socketFd_, POLLIN, deadline, error,
                           config.cancelled, config.networkGeneration)) {
                if (isCancelled(config.cancelled, config.networkGeneration) ||
                    error == "E-VNC-CERT-CANCELLED") {
                    error = "E-VNC-CERT-CANCELLED";
                } else {
                    error = error == "socket operation timed out" ?
                        "E-VNC-CERT-TLS-TIMEOUT" : "E-VNC-CERT-TLS-HANDSHAKE";
                }
                SSL_free(ssl);
                SSL_CTX_free(context);
                return false;
            }
            continue;
        }
        if (sslError == SSL_ERROR_WANT_WRITE) {
            if (!waitForFd(socketFd_, POLLOUT, deadline, error,
                           config.cancelled, config.networkGeneration)) {
                if (isCancelled(config.cancelled, config.networkGeneration) ||
                    error == "E-VNC-CERT-CANCELLED") {
                    error = "E-VNC-CERT-CANCELLED";
                } else {
                    error = error == "socket operation timed out" ?
                        "E-VNC-CERT-TLS-TIMEOUT" : "E-VNC-CERT-TLS-HANDSHAKE";
                }
                SSL_free(ssl);
                SSL_CTX_free(context);
                return false;
            }
            continue;
        }
        X509* partialCertificate = SSL_get_peer_certificate(ssl);
        const bool noPeerCertificate = partialCertificate == nullptr;
        if (partialCertificate != nullptr) X509_free(partialCertificate);
        if (isCancelled(config.cancelled, config.networkGeneration)) {
            error = "E-VNC-CERT-CANCELLED";
        } else if (tlsHandshakeErrorIsVersionFailure(handshakeError)) {
            error = "E-VNC-CERT-TLS-VERSION";
        } else if (noPeerCertificate) {
            error = "E-VNC-CERT-NO-CERTIFICATE";
        } else {
            error = "E-VNC-CERT-TLS-HANDSHAKE";
        }
        SSL_free(ssl);
        SSL_CTX_free(context);
        return false;
    }
    const char* version = SSL_get_version(ssl);
    if (version == nullptr || (std::strcmp(version, "TLSv1.2") != 0 &&
                               std::strcmp(version, "TLSv1.3") != 0)) {
        SSL_free(ssl);
        SSL_CTX_free(context);
        error = "E-VNC-CERT-TLS-VERSION";
        return false;
    }
    sslContext_ = context;
    ssl_ = ssl;
    tls_ = true;
    if (!validatePeerCertificate(config.expectedCertificateFingerprintSha256, error)) {
        return false;
    }
    return true;
}

bool VncTransport::validatePeerCertificate(const std::string& expectedFingerprint,
                                           std::string& error) {
    SSL* ssl = static_cast<SSL*>(ssl_);
    X509* certificate = ssl == nullptr ? nullptr : SSL_get_peer_certificate(ssl);
    if (certificate == nullptr) {
        error = "E-VNC-CERT-NO-CERTIFICATE";
        return false;
    }
    unsigned char digest[EVP_MAX_MD_SIZE] = {0};
    unsigned int digestSize = 0;
    const bool digestOk = X509_digest(certificate, EVP_sha256(), digest, &digestSize) == 1;
    X509_free(certificate);
    if (!digestOk || digestSize == 0) {
        error = "E-VNC-CERT-FINGERPRINT";
        return false;
    }
    std::ostringstream fingerprint;
    fingerprint << std::hex;
    for (unsigned int index = 0; index < digestSize; ++index) {
        fingerprint.width(2);
        fingerprint.fill('0');
        fingerprint << static_cast<unsigned int>(digest[index]);
    }
    const std::string actualFingerprint = lower(fingerprint.str());
    std::string actualNormalized;
    if (!vncNormalizeCertificateFingerprint(actualFingerprint, actualNormalized)) {
        error = "E-VNC-CERT-FINGERPRINT";
        return false;
    }
    if (expectedFingerprint.empty()) {
        error = "E-VNC-CERT-TRUST-REQUIRED;VNC_TRUST_REQUIRED:" + actualFingerprint;
        return false;
    }
    std::string expectedNormalized;
    if (!vncNormalizeCertificateFingerprint(expectedFingerprint, expectedNormalized)) {
        error = "E-VNC-CERT-INVALID-PIN";
        return false;
    }
    if (!constantTimeEqual(actualNormalized, expectedNormalized)) {
        error = "E-VNC-CERT-CHANGED;VNC_CERT_CHANGED:" + actualFingerprint;
        return false;
    }
    return true;
}

bool VncTransport::websocketHandshake(const VncTransportConfig& config, std::string& error) {
    std::string authority;
    if (!vncFormatWebSocketAuthority(config.host, config.port, authority)) {
        error = "invalid WebSocket gateway endpoint";
        return false;
    }
    std::array<uint8_t, 16> nonce = {0};
    if (RAND_bytes(nonce.data(), static_cast<int>(nonce.size())) != 1) {
        error = "unable to generate WebSocket handshake nonce";
        return false;
    }
    const std::string key = base64(nonce.data(), nonce.size());
    std::string path = config.websocketPath.empty() ? "/vnc" : config.websocketPath;
    if (path.front() != '/') {
        path = "/" + path;
    }
    std::string request = "GET " + path + " HTTP/1.1\r\n";
    request += "Host: " + authority + "\r\n";
    request += "Upgrade: websocket\r\nConnection: Upgrade\r\n";
    request += "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: " + key + "\r\n\r\n";
    if (!writeRaw(reinterpret_cast<const uint8_t*>(request.data()), request.size(), error)) {
        return false;
    }
    std::string response;
    uint8_t byte = 0;
    while (response.find("\r\n\r\n") == std::string::npos && response.size() < kMaxHttpHeaderBytes) {
        if (!readRaw(&byte, 1, config.connectTimeoutMs, error)) {
            return false;
        }
        response.push_back(static_cast<char>(byte));
    }
    if (response.find("\r\n\r\n") == std::string::npos) {
        error = "WebSocket HTTP response headers are too large";
        return false;
    }
    if (response.find("HTTP/1.1 101") != 0 && response.find("HTTP/1.0 101") != 0) {
        error = "WebSocket gateway did not return HTTP 101";
        return false;
    }
    const std::string acceptSource = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    unsigned char digest[SHA_DIGEST_LENGTH] = {0};
    SHA1(reinterpret_cast<const unsigned char*>(acceptSource.data()), acceptSource.size(), digest);
    const std::string expectedAccept = base64(digest, sizeof(digest));
    const std::string lowerResponse = lower(response);
    const std::string expectedHeader = "sec-websocket-accept:";
    const size_t headerPosition = lowerResponse.find(expectedHeader);
    if (headerPosition == std::string::npos) {
        error = "WebSocket gateway omitted Sec-WebSocket-Accept";
        return false;
    }
    const size_t valueStart = headerPosition + expectedHeader.size();
    const size_t lineEnd = lowerResponse.find("\r\n", valueStart);
    const std::string actualAccept = trimAscii(response.substr(valueStart,
        lineEnd == std::string::npos ? std::string::npos : lineEnd - valueStart));
    if (!constantTimeEqual(actualAccept, expectedAccept)) {
        error = "WebSocket gateway key validation failed";
        return false;
    }
    return true;
}

bool VncTransport::sendRepeaterPairing(const VncTransportConfig& config, std::string& error) {
    const std::string mode = config.repeaterMode.empty() ? "mode12" : config.repeaterMode;
    if (!vncNativeRepeaterViewerModeIsAvailable(mode)) {
        error = "UltraVNC Repeater mode2 is server-side; this VNC client supports viewer mode12 only";
        return false;
    }
    std::array<uint8_t, VncRfbProtocol::kUltraVncRepeaterFieldBytes> pairing = {0};
    if (!VncRfbProtocol::buildRepeaterTargetField(config.repeaterTarget, pairing, error)) {
        return false;
    }
    std::array<uint8_t, VncRfbProtocol::kProtocolVersionBytes> banner = {0};
    if (!readExact(banner.data(), banner.size(), config.connectTimeoutMs, error)) {
        error = "UltraVNC Repeater mode12 banner read failed: " + error;
        return false;
    }
    if (!VncRfbProtocol::isUltraVncRepeaterBanner(banner.data(), banner.size())) {
        error = "UltraVNC Repeater mode12 banner is invalid";
        return false;
    }
    return writeAll(pairing.data(), pairing.size(), error);
}

bool VncTransport::readExact(uint8_t* destination, size_t size, int timeoutMs, std::string& error) {
    if (destination == nullptr && size != 0) {
        error = "invalid read destination";
        return false;
    }
    if (websocket_) {
        return readWebSocketBytes(destination, size, timeoutMs, error);
    }
    return readRaw(destination, size, timeoutMs, error);
}

bool VncTransport::writeAll(const uint8_t* source, size_t size, std::string& error) {
    if (source == nullptr && size != 0) {
        error = "invalid write source";
        return false;
    }
    std::lock_guard<std::mutex> lock(writeMutex_);
    if (websocket_) {
        return writeWebSocketFrame(0x2, source, size, error);
    }
    return writeRaw(source, size, error);
}

bool VncTransport::readRaw(uint8_t* destination, size_t size, int timeoutMs, std::string& error) {
    size_t offset = 0;
    while (offset < size) {
        if (isCancelled(cancelled_, networkGeneration_)) {
            error = "E-VNC-CERT-CANCELLED";
            return false;
        }
        if (tls_) {
            SSL* ssl = static_cast<SSL*>(ssl_);
            if (ssl == nullptr) {
                error = "E-VNC-CERT-TLS-SESSION";
                return false;
            }
            const int result = SSL_read(ssl, destination + offset,
                                        static_cast<int>(std::min<size_t>(size - offset, INT_MAX)));
            if (result > 0) {
                offset += static_cast<size_t>(result);
                continue;
            }
            const int sslError = SSL_get_error(ssl, result);
            if (sslError == SSL_ERROR_WANT_READ || sslError == SSL_ERROR_WANT_WRITE) {
                std::string waitError;
                if (!waitForFd(socketFd_, sslError == SSL_ERROR_WANT_WRITE ? POLLOUT : POLLIN,
                               timeoutMs, waitError, cancelled_,
                               networkGeneration_)) {
                    setTlsIoError(error, false, waitError);
                    return false;
                }
                continue;
            }
            setTlsIoError(error, false);
            return false;
        }
        const ssize_t result = ::recv(socketFd_, destination + offset, size - offset, 0);
        if (result > 0) {
            offset += static_cast<size_t>(result);
            continue;
        }
        if (result == 0) {
            error = "VNC socket closed by peer";
            return false;
        }
        if (errno == EINTR) {
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            if (!waitForFd(socketFd_, POLLIN, timeoutMs, error, cancelled_,
                           networkGeneration_)) {
                return false;
            }
            continue;
        }
        error = isCancelled(cancelled_, networkGeneration_) ?
            "E-VNC-CERT-CANCELLED" : errnoMessage("recv");
        return false;
    }
    return true;
}

bool VncTransport::writeRaw(const uint8_t* source, size_t size, std::string& error) {
    size_t offset = 0;
    while (offset < size) {
        if (isCancelled(cancelled_, networkGeneration_)) {
            error = "E-VNC-CERT-CANCELLED";
            return false;
        }
        if (tls_) {
            SSL* ssl = static_cast<SSL*>(ssl_);
            if (ssl == nullptr) {
                error = "E-VNC-CERT-TLS-SESSION";
                return false;
            }
            const int result = SSL_write(ssl, source + offset,
                                         static_cast<int>(std::min<size_t>(size - offset, INT_MAX)));
            if (result > 0) {
                offset += static_cast<size_t>(result);
                continue;
            }
            const int sslError = SSL_get_error(ssl, result);
            if (sslError == SSL_ERROR_WANT_READ || sslError == SSL_ERROR_WANT_WRITE) {
                std::string waitError;
                if (!waitForFd(socketFd_, sslError == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT,
                               kDefaultTimeoutMs, waitError, cancelled_,
                               networkGeneration_)) {
                    setTlsIoError(error, true, waitError);
                    return false;
                }
                continue;
            }
            setTlsIoError(error, true);
            return false;
        }
        const ssize_t result = ::send(socketFd_, source + offset, size - offset, MSG_NOSIGNAL);
        if (result > 0) {
            offset += static_cast<size_t>(result);
            continue;
        }
        if (result < 0 && errno == EINTR) {
            continue;
        }
        if (result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (!waitForFd(socketFd_, POLLOUT, kDefaultTimeoutMs, error,
                           cancelled_, networkGeneration_)) {
                return false;
            }
            continue;
        }
        error = isCancelled(cancelled_, networkGeneration_) ?
            "E-VNC-CERT-CANCELLED" : errnoMessage("send");
        return false;
    }
    return true;
}

bool VncTransport::readWebSocketBytes(uint8_t* destination, size_t size, int timeoutMs,
                                      std::string& error) {
    size_t offset = 0;
    while (offset < size) {
        if (websocketIncomingOffset_ < websocketIncoming_.size()) {
            const size_t available = websocketIncoming_.size() - websocketIncomingOffset_;
            const size_t copySize = std::min(available, size - offset);
            std::memcpy(destination + offset, websocketIncoming_.data() + websocketIncomingOffset_, copySize);
            offset += copySize;
            websocketIncomingOffset_ += copySize;
            if (websocketIncomingOffset_ == websocketIncoming_.size()) {
                websocketIncoming_.clear();
                websocketIncomingOffset_ = 0;
            }
            continue;
        }
        uint8_t opcode = 0;
        if (!readWebSocketFrame(websocketIncoming_, opcode, timeoutMs, error)) {
            return false;
        }
        if (opcode != 0x2) {
            error = "WebSocket gateway returned a non-binary RFB frame";
            return false;
        }
        websocketIncomingOffset_ = 0;
    }
    return true;
}

bool VncTransport::readWebSocketFrame(std::vector<uint8_t>& payload, uint8_t& opcode,
                                      int timeoutMs, std::string& error) {
    payload.clear();
    bool fragmented = false;
    uint8_t fragmentOpcode = 0;
    while (true) {
        uint8_t header[2] = {0};
        if (!readRaw(header, sizeof(header), timeoutMs, error)) {
            return false;
        }
        const bool finalFrame = (header[0] & 0x80) != 0;
        const uint8_t frameOpcode = header[0] & 0x0F;
        const bool masked = (header[1] & 0x80) != 0;
        if ((header[0] & 0x70) != 0) {
            error = "WebSocket gateway set an unsupported reserved bit";
            return false;
        }
        uint64_t length = header[1] & 0x7F;
        if (length == 126) {
            uint8_t extended[2] = {0};
            if (!readRaw(extended, sizeof(extended), timeoutMs, error)) return false;
            length = (static_cast<uint64_t>(extended[0]) << 8) | extended[1];
        } else if (length == 127) {
            uint8_t extended[8] = {0};
            if (!readRaw(extended, sizeof(extended), timeoutMs, error)) return false;
            if ((extended[0] & 0x80) != 0) {
                error = "WebSocket payload length is invalid";
                return false;
            }
            length = 0;
            for (uint8_t value : extended) length = (length << 8) | value;
        }
        const bool controlFrame = frameOpcode >= 0x8;
        if (controlFrame && (!finalFrame || length > 125)) {
            error = "WebSocket control frame is invalid";
            return false;
        }
        // Servers must not mask frames sent to the client.  Accepting a
        // masked peer frame would make malformed gateway implementations look
        // healthy and weakens the transport boundary.
        if (masked) {
            error = "WebSocket server frame must not be masked";
            return false;
        }
        if (length > kMaxWebSocketFrameBytes) {
            error = "WebSocket payload exceeds VNC limit";
            return false;
        }
        std::vector<uint8_t> frame(static_cast<size_t>(length));
        if (length > 0 && !readRaw(frame.data(), frame.size(), timeoutMs, error)) return false;
        if (frameOpcode == 0x8) {
            error = "WebSocket gateway closed the VNC channel";
            return false;
        }
        if (frameOpcode == 0x9) {
            std::lock_guard<std::mutex> lock(writeMutex_);
            if (!writeWebSocketFrame(0xA, frame.data(), frame.size(), error)) return false;
            continue;
        }
        if (frameOpcode == 0xA) continue;
        if (frameOpcode == 0x0) {
            if (!fragmented) {
                error = "unexpected WebSocket continuation frame";
                return false;
            }
        } else if (frameOpcode == 0x1 || frameOpcode == 0x2) {
            if (fragmented) {
                error = "nested WebSocket fragmented frame";
                return false;
            }
            fragmented = !finalFrame;
            fragmentOpcode = frameOpcode;
        } else {
            error = "unsupported WebSocket opcode";
            return false;
        }
        if (frame.size() > kMaxWebSocketFrameBytes - payload.size()) {
            error = "fragmented WebSocket payload exceeds VNC limit";
            return false;
        }
        payload.insert(payload.end(), frame.begin(), frame.end());
        if (finalFrame) {
            opcode = frameOpcode == 0x0 ? fragmentOpcode : frameOpcode;
            return true;
        }
    }
}

bool VncTransport::writeWebSocketFrame(uint8_t opcode, const uint8_t* source, size_t size,
                                       std::string& error) {
    if (size > kMaxWebSocketFrameBytes) {
        error = "WebSocket write exceeds VNC limit";
        return false;
    }
    std::vector<uint8_t> frame;
    frame.reserve(size + 14);
    frame.push_back(static_cast<uint8_t>(0x80 | (opcode & 0x0F)));
    if (size < 126) {
        frame.push_back(static_cast<uint8_t>(0x80 | size));
    } else if (size <= 0xFFFF) {
        frame.push_back(0x80 | 126);
        frame.push_back(static_cast<uint8_t>((size >> 8) & 0xFF));
        frame.push_back(static_cast<uint8_t>(size & 0xFF));
    } else {
        frame.push_back(0x80 | 127);
        for (int shift = 56; shift >= 0; shift -= 8) {
            frame.push_back(static_cast<uint8_t>((static_cast<uint64_t>(size) >> shift) & 0xFF));
        }
    }
    std::array<uint8_t, 4> mask = {0};
    if (RAND_bytes(mask.data(), static_cast<int>(mask.size())) != 1) {
        error = "unable to generate WebSocket client mask";
        return false;
    }
    frame.insert(frame.end(), mask.begin(), mask.end());
    for (size_t index = 0; index < size; ++index) frame.push_back(source[index] ^ mask[index % 4]);
    return writeRaw(frame.data(), frame.size(), error);
}

void VncTransport::close() {
    std::lock_guard<std::mutex> lock(writeMutex_);
    open_ = false;
    websocket_ = false;
    websocketIncoming_.clear();
    websocketIncomingOffset_ = 0;
    if (ssl_ != nullptr) {
        SSL* ssl = static_cast<SSL*>(ssl_);
        SSL_shutdown(ssl);
        SSL_free(ssl);
        ssl_ = nullptr;
    }
    if (sslContext_ != nullptr) {
        SSL_CTX_free(static_cast<SSL_CTX*>(sslContext_));
        sslContext_ = nullptr;
    }
    tls_ = false;
    if (socketFd_ >= 0) {
        ::shutdown(socketFd_, SHUT_RDWR);
        ::close(socketFd_);
        socketFd_ = -1;
    }
    cancelled_.reset();
    networkGeneration_ = 0;
#if defined(RDP_TESTS_ONLY)
    afterConnectRestoreForTesting_ = nullptr;
#endif
}

bool VncTransport::isOpen() const {
    return open_ && socketFd_ >= 0;
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
void VncTransport::adoptConnectedSocketForTesting(
    int socketFd, uint64_t networkGeneration) {
    close();
    socketFd_ = socketFd;
    networkGeneration_ = networkGeneration;
    open_ = socketFd_ >= 0;
}
#endif

std::string VncTransport::base64(const uint8_t* data, size_t size) {
    static constexpr char alphabet[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string result;
    result.reserve(((size + 2) / 3) * 4);
    for (size_t index = 0; index < size; index += 3) {
        const size_t remaining = std::min<size_t>(3, size - index);
        uint32_t value = static_cast<uint32_t>(data[index]) << 16;
        if (remaining > 1) value |= static_cast<uint32_t>(data[index + 1]) << 8;
        if (remaining > 2) value |= data[index + 2];
        result.push_back(alphabet[(value >> 18) & 0x3F]);
        result.push_back(alphabet[(value >> 12) & 0x3F]);
        result.push_back(remaining > 1 ? alphabet[(value >> 6) & 0x3F] : '=');
        result.push_back(remaining > 2 ? alphabet[value & 0x3F] : '=');
    }
    return result;
}

std::string VncTransport::lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

bool VncTransport::constantTimeEqual(const std::string& left, const std::string& right) {
    if (left.size() != right.size()) return false;
    unsigned char difference = 0;
    for (size_t index = 0; index < left.size(); ++index) {
        difference |= static_cast<unsigned char>(left[index] ^ right[index]);
    }
    return difference == 0;
}
