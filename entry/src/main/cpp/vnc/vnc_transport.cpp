/**
 * vnc_transport.cpp - bounded POSIX/TLS/WebSocket VNC transports.
 */
#include "vnc_transport.h"
#include "vnc_rfb_protocol.h"
#include "vnc_transport_policy.h"

#include <arpa/inet.h>
#include <climits>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <netdb.h>
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

#include <openssl/err.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

namespace {

constexpr size_t kMaxHttpHeaderBytes = 64 * 1024;
constexpr size_t kMaxWebSocketFrameBytes = 8 * 1024 * 1024;
constexpr int kDefaultTimeoutMs = 10000;

std::string errnoMessage(const char* operation) {
    std::string result = operation == nullptr ? "socket error" : operation;
    result += ": ";
    result += std::strerror(errno);
    return result;
}

bool waitForFd(int fd, short events, int timeoutMs, std::string& error) {
    if (fd < 0) {
        error = "socket is closed";
        return false;
    }
    struct pollfd pollFd;
    pollFd.fd = fd;
    pollFd.events = events;
    pollFd.revents = 0;
    const int boundedTimeout = timeoutMs <= 0 ? kDefaultTimeoutMs : timeoutMs;
    while (true) {
        const int result = ::poll(&pollFd, 1, boundedTimeout);
        if (result > 0) {
            if ((pollFd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                error = "socket closed while waiting";
                return false;
            }
            return (pollFd.revents & events) != 0;
        }
        if (result == 0) {
            error = "socket operation timed out";
            return false;
        }
        if (errno != EINTR) {
            error = errnoMessage("poll");
            return false;
        }
    }
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

std::string opensslError() {
    const unsigned long code = ERR_get_error();
    if (code == 0) {
        return "TLS operation failed";
    }
    char buffer[256] = {0};
    ERR_error_string_n(code, buffer, sizeof(buffer));
    return buffer;
}

} // namespace

VncTransport::VncTransport() = default;

VncTransport::~VncTransport() {
    close();
}

bool VncTransport::connect(const VncTransportConfig& config, std::string& error) {
    close();
    if (!vncNativeTransportIsAvailable(config.transport)) {
        error = "VNC transport is disabled until its versioned gateway contract is deployed";
        return false;
    }
    if (config.host.empty() || config.port < 1 || config.port > 65535) {
        error = "invalid VNC transport endpoint";
        return false;
    }
    const int timeoutMs = config.connectTimeoutMs <= 0 ? kDefaultTimeoutMs : config.connectTimeoutMs;
    if (!connectTcp(config.host, config.port, timeoutMs, error)) {
        close();
        return false;
    }
    if (config.tls && !enableTls(config, error)) {
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

bool VncTransport::connectTcp(const std::string& host, int port, int timeoutMs, std::string& error) {
    struct addrinfo hints;
    std::memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;
    hints.ai_flags = AI_ADDRCONFIG;

    struct addrinfo* addresses = nullptr;
    const std::string portText = std::to_string(port);
    const int lookup = ::getaddrinfo(host.c_str(), portText.c_str(), &hints, &addresses);
    if (lookup != 0) {
        error = "DNS lookup failed: ";
        error += gai_strerror(lookup);
        return false;
    }

    for (struct addrinfo* address = addresses; address != nullptr; address = address->ai_next) {
        const int fd = ::socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (fd < 0) {
            continue;
        }
        const int flags = ::fcntl(fd, F_GETFL, 0);
        if (flags < 0 || ::fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0) {
            ::close(fd);
            continue;
        }
        const int result = ::connect(fd, address->ai_addr, address->ai_addrlen);
        if (result == 0) {
            socketFd_ = fd;
            break;
        }
        if (errno != EINPROGRESS || !waitForFd(fd, POLLOUT, timeoutMs, error)) {
            ::close(fd);
            continue;
        }
        int socketError = 0;
        socklen_t socketErrorLength = sizeof(socketError);
        if (::getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) != 0 ||
            socketError != 0) {
            if (socketError != 0) {
                errno = socketError;
            }
            error = errnoMessage("connect");
            ::close(fd);
            continue;
        }
        socketFd_ = fd;
        break;
    }
    ::freeaddrinfo(addresses);
    if (socketFd_ < 0) {
        if (error.empty()) {
            error = "unable to connect to VNC endpoint";
        }
        return false;
    }
    return true;
}

bool VncTransport::enableTls(const VncTransportConfig& config, std::string& error) {
    const SSL_METHOD* method = TLS_client_method();
    SSL_CTX* context = SSL_CTX_new(method);
    if (context == nullptr) {
        error = opensslError();
        return false;
    }
    SSL_CTX_set_min_proto_version(context, TLS1_2_VERSION);
    // VNC deployments frequently use self-signed certificates.  The first
    // handshake is a fingerprint-probe only and is rejected below; subsequent
    // sessions must supply the user-confirmed SHA-256 pin.  This keeps the
    // trust decision in VncTrustService instead of silently accepting a CA or
    // silently trusting a self-signed peer.
    SSL_CTX_set_verify(context, SSL_VERIFY_NONE, nullptr);
    SSL* ssl = SSL_new(context);
    if (ssl == nullptr) {
        SSL_CTX_free(context);
        error = opensslError();
        return false;
    }
    SSL_set_fd(ssl, socketFd_);
    SSL_set_tlsext_host_name(ssl, config.host.c_str());
    while (true) {
        const int result = SSL_connect(ssl);
        if (result == 1) {
            break;
        }
        const int sslError = SSL_get_error(ssl, result);
        if (sslError == SSL_ERROR_WANT_READ) {
            if (!waitForFd(socketFd_, POLLIN, config.connectTimeoutMs, error)) {
                SSL_free(ssl);
                SSL_CTX_free(context);
                return false;
            }
            continue;
        }
        if (sslError == SSL_ERROR_WANT_WRITE) {
            if (!waitForFd(socketFd_, POLLOUT, config.connectTimeoutMs, error)) {
                SSL_free(ssl);
                SSL_CTX_free(context);
                return false;
            }
            continue;
        }
        error = opensslError();
        SSL_free(ssl);
        SSL_CTX_free(context);
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
        error = "TLS peer certificate is missing";
        return false;
    }
    unsigned char digest[EVP_MAX_MD_SIZE] = {0};
    unsigned int digestSize = 0;
    const bool digestOk = X509_digest(certificate, EVP_sha256(), digest, &digestSize) == 1;
    X509_free(certificate);
    if (!digestOk || digestSize == 0) {
        error = "unable to fingerprint TLS peer certificate";
        return false;
    }
    std::ostringstream fingerprint;
    fingerprint << std::hex;
    for (unsigned int index = 0; index < digestSize; ++index) {
        fingerprint.width(2);
        fingerprint.fill('0');
        fingerprint << static_cast<unsigned int>(digest[index]);
    }
    std::string normalizedExpected = lower(expectedFingerprint);
    normalizedExpected.erase(std::remove_if(normalizedExpected.begin(), normalizedExpected.end(),
        [](char value) { return value == ':' || value == '-' || value == ' ' || value == '\t'; }),
        normalizedExpected.end());
    const std::string actualFingerprint = lower(fingerprint.str());
    if (normalizedExpected.empty()) {
        error = "VNC_TRUST_REQUIRED:" + actualFingerprint;
        return false;
    }
    if (!constantTimeEqual(actualFingerprint, normalizedExpected)) {
        error = "TLS certificate fingerprint does not match the VNC trust record";
        return false;
    }
    return true;
}

bool VncTransport::websocketHandshake(const VncTransportConfig& config, std::string& error) {
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
    request += "Host: " + config.host + "\r\n";
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
        if (tls_) {
            SSL* ssl = static_cast<SSL*>(ssl_);
            if (ssl == nullptr) {
                error = "TLS session is unavailable";
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
                if (!waitForFd(socketFd_, sslError == SSL_ERROR_WANT_WRITE ? POLLOUT : POLLIN,
                               timeoutMs, error)) {
                    return false;
                }
                continue;
            }
            error = "TLS read failed: " + opensslError();
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
            if (!waitForFd(socketFd_, POLLIN, timeoutMs, error)) {
                return false;
            }
            continue;
        }
        error = errnoMessage("recv");
        return false;
    }
    return true;
}

bool VncTransport::writeRaw(const uint8_t* source, size_t size, std::string& error) {
    size_t offset = 0;
    while (offset < size) {
        if (tls_) {
            SSL* ssl = static_cast<SSL*>(ssl_);
            if (ssl == nullptr) {
                error = "TLS session is unavailable";
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
                if (!waitForFd(socketFd_, sslError == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT,
                               kDefaultTimeoutMs, error)) {
                    return false;
                }
                continue;
            }
            error = "TLS write failed: " + opensslError();
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
            if (!waitForFd(socketFd_, POLLOUT, kDefaultTimeoutMs, error)) {
                return false;
            }
            continue;
        }
        error = errnoMessage("send");
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
}

bool VncTransport::isOpen() const {
    return open_ && socketFd_ >= 0;
}

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
