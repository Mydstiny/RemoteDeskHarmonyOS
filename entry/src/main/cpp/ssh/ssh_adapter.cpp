/**
 * ssh_adapter.cpp — SSH 终端协议适配器实现 (libssh2 集成版)
 *
 * 基于 libssh2 + OpenSSL 的完整 SSH2 协议实现.
 * 连接流程: TCP → KEX(Banner内嵌) → 认证 → 通道 → PTY → Shell
 * 所有 libssh2 调用使用非阻塞模式 + select() 轮询.
 */
#include "ssh_adapter.h"
#include "ssh_auth_policy.h"
#include "ssh_route_policy.h"
#include "extension_registry.h"
#include "common/safe_log.h"
#include "ssh_algorithm_prefs.h"
#include <hilog/log.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <cstring>
#include <cerrno>
#include <climits>
#include <mutex>
#include <chrono>
#include <cstdlib>
#include <array>
#include <vector>
#include <algorithm>
#include <limits>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0010
#define LOG_TAG "SSH_ADAPTER"

// ============================================================
// 静态: libssh2 全局初始化 (进程级, 调用一次)
// ============================================================

namespace {
    std::once_flag g_libssh2_init_flag;

    std::string encodeBase64(const unsigned char* data, size_t len) {
        static const char b64chars[] =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        std::string out;
        out.reserve(((len + 2) / 3) * 4);
        for (size_t i = 0; i < len; i += 3) {
            unsigned int n = static_cast<unsigned int>(data[i]) << 16;
            if (i + 1 < len) {
                n |= static_cast<unsigned int>(data[i + 1]) << 8;
            }
            if (i + 2 < len) {
                n |= static_cast<unsigned int>(data[i + 2]);
            }
            out += b64chars[(n >> 18) & 0x3F];
            out += b64chars[(n >> 12) & 0x3F];
            out += (i + 1 < len) ? b64chars[(n >> 6) & 0x3F] : '=';
            out += (i + 2 < len) ? b64chars[n & 0x3F] : '=';
        }
        return out;
    }

    void ensureLibssh2Init() {
        std::call_once(g_libssh2_init_flag, []() {
            int rc = libssh2_init(0);
            if (rc == 0) {
                OH_LOG_INFO(LOG_APP, "[SSH] libssh2 全局初始化完成");
            } else {
                OH_LOG_ERROR(LOG_APP, "[SSH] libssh2_init 失败: rc=%{public}d", rc);
            }
        });
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

    /**
     * libssh2 reports a short non-blocking receive race as
     * LIBSSH2_ERROR_SOCKET_RECV. Peek without consuming bytes so the reactor
     * can distinguish EAGAIN/EINTR from an actual socket close/error. Keep the
     * raw probe values for diagnostics; a boolean alone cannot explain a
     * long-lived connection failure.
     */
    struct SocketReceiveProbe {
        ssize_t peeked = -1;
        int peekErrno = 0;
        int socketError = 0;
        int socketErrorErrno = 0;
        bool transient = false;
    };

    SocketReceiveProbe probeSocketReceive(int socketFd) {
        SocketReceiveProbe result;
        if (socketFd < 0) { return result; }
        char probe = 0;
        while (true) {
            // errno is only meaningful for this exact recv result. Clear it
            // before each retry so EINTR cannot leak into a later success.
            result.peekErrno = 0;
            result.peeked = ::recv(socketFd, &probe, sizeof(probe), MSG_PEEK);
            if (result.peeked >= 0) { break; }
            result.peekErrno = errno;
            if (result.peekErrno == EINTR) { continue; }
            break;
        }
        result.transient = result.peeked > 0 ||
            (result.peeked < 0 &&
             (result.peekErrno == EAGAIN || result.peekErrno == EWOULDBLOCK));
        // SO_ERROR is a read-and-clear socket option. Do not inspect it for a
        // transient peek result, otherwise a pending error can disappear
        // before libssh2 gets the chance to observe it on the retry.
        if (result.transient) { return result; }
        socklen_t errorLength = sizeof(result.socketError);
        if (::getsockopt(socketFd, SOL_SOCKET, SO_ERROR,
                         &result.socketError, &errorLength) != 0) {
            result.socketErrorErrno = errno;
            result.socketError = 0;
        }
        return result;
    }

    SshPtyFailureClass classifyPtyFailure(int libssh2Error) {
        switch (libssh2Error) {
            case LIBSSH2_ERROR_SOCKET_SEND:
            case LIBSSH2_ERROR_SOCKET_RECV:
            case LIBSSH2_ERROR_SOCKET_DISCONNECT:
            case LIBSSH2_ERROR_SOCKET_TIMEOUT:
            case LIBSSH2_ERROR_TIMEOUT:
                return SshPtyFailureClass::TRANSIENT_TRANSPORT;
            case LIBSSH2_ERROR_CHANNEL_CLOSED:
            case LIBSSH2_ERROR_CHANNEL_FAILURE:
                return SshPtyFailureClass::TRANSIENT_CHANNEL;
            case LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED:
            case LIBSSH2_ERROR_REQUEST_DENIED:
            case LIBSSH2_ERROR_METHOD_NOT_SUPPORTED:
            case LIBSSH2_ERROR_INVAL:
                return SshPtyFailureClass::SERVER_REJECTED;
            default:
                return SshPtyFailureClass::PERMANENT;
        }
    }
}

// ============================================================
// 构造 / 析构
// ============================================================

SshAdapter::SshAdapter()
    : sockFd_(-1)
    , state_(ConnectionState::DISCONNECTED)
    , authenticated_(false)
    , session_(nullptr)
    , channel_(nullptr)
    , sftp_(nullptr)
{
    ensureLibssh2Init();
}

SshAdapter::~SshAdapter() {
    disconnect();
}

// ============================================================
// ProtocolAdapter 元信息
// ============================================================

std::string SshAdapter::protocolName() {
    return "SSH";
}

int SshAdapter::defaultPort() {
    return 22;
}

std::string SshAdapter::protocolVersion() {
    return SSH_ADAPTER_VERSION;
}

void SshAdapter::setSessionIdentity(uint64_t sessionId) {
    diagnostics_.setSessionIdentity(sessionId);
}

void SshAdapter::setSessionGeneration(uint64_t generation) {
    diagnostics_.setSessionGeneration(generation);
}

SshTerminalDiagnosticsSnapshot SshAdapter::terminalDiagnostics() const {
    return diagnostics_.snapshot();
}

void SshAdapter::recordTerminalCallbackAccepted(size_t byteCount) {
    diagnostics_.recordCallbackAccepted(byteCount);
}

void SshAdapter::recordTerminalCallbackQueueFull() {
    diagnostics_.recordCallbackQueueFull();
}

void SshAdapter::recordTerminalCallbackDeliveryError(bool closing) {
    diagnostics_.recordCallbackDeliveryError(closing);
}

void SshAdapter::markTerminalCallbackInstrumentation() {
    diagnostics_.markCallbackInstrumentation();
}

void SshAdapter::failTerminalOutput(const std::string& reason) {
    diagnostics_.recordCallbackDeliveryError(false);
    terminalInputAccepting_.store(false, std::memory_order_release);
    readerRunning_.store(false, std::memory_order_release);
    reactorCommandCondition_.notify_all();
    setState(ConnectionState::ERROR, reason);
}

// ============================================================
// 内部辅助方法
// ============================================================

void SshAdapter::setState(ConnectionState s, const std::string& message) {
    ConnectionStateCallback callback;
    {
        std::lock_guard<std::mutex> lock(stateCallbackMutex_);
        state_.store(s, std::memory_order_release);
        callback = stateCallback_;
    }
    if (callback) {
        callback(s, message);
    }
}

int SshAdapter::waitSocket(int direction, int timeoutSec) {
    if (sockFd_ < 0) {
        return -1;
    }
    if (connectCancelRequested_.load(std::memory_order_acquire)) {
        return -3;
    }

    const int timeoutMilliseconds = std::max(0, timeoutSec) * 1000;
    const auto deadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(timeoutMilliseconds);
    while (true) {
        if (connectCancelRequested_.load(std::memory_order_acquire)) {
            return -3;
        }
        const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
            deadline - std::chrono::steady_clock::now()).count();
        if (remaining <= 0) {
            return -2;
        }

        const int sliceMilliseconds = static_cast<int>(std::min<int64_t>(remaining, 100));
        int ret;
        while (true) {
            // select() mutates both fd_set and timeval, including when it
            // returns EINTR. Rebuild them for every retry.
            fd_set rfds, wfds;
            FD_ZERO(&rfds);
            FD_ZERO(&wfds);
            if (direction == 0 || direction == 2) { FD_SET(sockFd_, &rfds); }
            if (direction == 1 || direction == 2) { FD_SET(sockFd_, &wfds); }
            struct timeval tv = {
                sliceMilliseconds / 1000,
                (sliceMilliseconds % 1000) * 1000
            };
            ret = select(sockFd_ + 1, &rfds, &wfds, nullptr, &tv);
            if (ret >= 0 || errno != EINTR) { break; }
        }
        if (ret < 0) { return -1; }
        if (ret > 0) { return 0; }
    }
}

int SshAdapter::waitSocketMilliseconds(int direction, int timeoutMs) {
    if (sockFd_ < 0) { return -1; }
    if (connectCancelRequested_.load(std::memory_order_acquire)) { return -3; }
    const int boundedMs = std::max(1, std::min(timeoutMs, 100));
    const auto deadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(boundedMs);
    while (true) {
        if (connectCancelRequested_.load(std::memory_order_acquire)) { return -3; }
        const auto remaining = std::chrono::duration_cast<std::chrono::microseconds>(
            deadline - std::chrono::steady_clock::now()).count();
        if (remaining <= 0) { return -2; }
        const int fd = sockFd_;
        if (fd < 0) { return -1; }
        fd_set rfds;
        fd_set wfds;
        FD_ZERO(&rfds);
        FD_ZERO(&wfds);
        if (direction == 0 || direction == 2) { FD_SET(fd, &rfds); }
        if (direction == 1 || direction == 2) { FD_SET(fd, &wfds); }
        const auto boundedRemaining = std::min<int64_t>(remaining, 100'000);
        struct timeval tv = {
            static_cast<long>(boundedRemaining / 1'000'000),
            static_cast<long>((boundedRemaining % 1'000'000) / 1'000)
        };
        const int ret = select(fd + 1, &rfds, &wfds, nullptr, &tv);
        if (ret < 0 && errno == EINTR) { continue; }
        if (ret < 0) { return -1; }
        return ret > 0 ? 0 : -2;
    }
}

int SshAdapter::waitSocketOnFd(int fd, int direction, int timeoutSec) {
    if (fd < 0) { return -1; }
    const int timeoutMilliseconds = std::max(1, timeoutSec) * 1000;
    const auto deadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(timeoutMilliseconds);
    while (true) {
        if (connectCancelRequested_.load(std::memory_order_acquire)) { return -3; }
        const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
            deadline - std::chrono::steady_clock::now()).count();
        if (remaining <= 0) { return -2; }
        fd_set rfds;
        fd_set wfds;
        FD_ZERO(&rfds);
        FD_ZERO(&wfds);
        if (direction == 0 || direction == 2) { FD_SET(fd, &rfds); }
        if (direction == 1 || direction == 2) { FD_SET(fd, &wfds); }
        const int sliceMs = static_cast<int>(std::min<int64_t>(remaining, 100));
        struct timeval tv = { sliceMs / 1000, (sliceMs % 1000) * 1000 };
        const int ret = select(fd + 1, &rfds, &wfds, nullptr, &tv);
        if (ret < 0 && errno == EINTR) { continue; }
        if (ret < 0) { return -1; }
        if (ret > 0) { return 0; }
    }
}

// ============================================================
// TCP 连接
// ============================================================

int SshAdapter::tcpConnect(const std::string& host, int port) {
    const std::string logHost = SafeLog::MaskHost(host);
    if (host.empty() || port <= 0 || port > 65535) {
        OH_LOG_ERROR(LOG_APP, "[SSH] 地址参数无效: host=%{public}s port=%{public}d",
                     logHost.c_str(), port);
        return ERR_SSH_DNS_RESOLVE;
    }

    struct addrinfo hints {};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    char portString[16] = {0};
    snprintf(portString, sizeof(portString), "%d", port);
    struct addrinfo* addresses = nullptr;
    const int resolveResult = getaddrinfo(host.c_str(), portString, &hints, &addresses);
    if (resolveResult != 0 || addresses == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[SSH] DNS 解析失败: host=%{public}s code=%{public}d",
                     logHost.c_str(), resolveResult);
        return ERR_SSH_DNS_RESOLVE;
    }

    OH_LOG_INFO(LOG_APP, "[SSH] 正在连接 %{public}s:%{public}d (AF_UNSPEC) ...",
                logHost.c_str(), port);

    bool sawSocketError = false;
    bool sawTimeout = false;
    for (struct addrinfo* address = addresses; address != nullptr; address = address->ai_next) {
        sockFd_ = static_cast<int>(socket(address->ai_family, address->ai_socktype,
                                          address->ai_protocol));
        if (sockFd_ < 0) {
            sawSocketError = true;
            continue;
        }

        const int flags = fcntl(sockFd_, F_GETFL, 0);
        if (flags < 0 || fcntl(sockFd_, F_SETFL, flags | O_NONBLOCK) < 0) {
            sawSocketError = true;
            close(sockFd_);
            sockFd_ = -1;
            continue;
        }

        int ret = ::connect(sockFd_, address->ai_addr, address->ai_addrlen);
        if (ret < 0 && errno == EINPROGRESS) {
            const int waitResult = waitSocket(1, 10);
            if (waitResult == -2) {
                sawTimeout = true;
                close(sockFd_);
                sockFd_ = -1;
                continue;
            }
            if (waitResult != 0) {
                sawSocketError = true;
                close(sockFd_);
                sockFd_ = -1;
                continue;
            }

            int socketError = 0;
            socklen_t socketErrorLength = sizeof(socketError);
            if (getsockopt(sockFd_, SOL_SOCKET, SO_ERROR, &socketError,
                           &socketErrorLength) != 0 || socketError != 0) {
                sawSocketError = true;
                close(sockFd_);
                sockFd_ = -1;
                continue;
            }
        } else if (ret < 0) {
            sawSocketError = true;
            close(sockFd_);
            sockFd_ = -1;
            continue;
        }

        const int family = address->ai_family;
        freeaddrinfo(addresses);
        OH_LOG_INFO(LOG_APP, "[SSH] TCP 连接建立成功, family=%{public}d fd=%{public}d",
                    family, sockFd_);
        return 0;
    }

    freeaddrinfo(addresses);
    sockFd_ = -1;
    if (sawTimeout) {
        OH_LOG_ERROR(LOG_APP, "[SSH] 连接超时: %{public}s:%{public}d", logHost.c_str(), port);
        return ERR_SSH_CONNECT_TIMEOUT;
    }
    OH_LOG_ERROR(LOG_APP, "[SSH] 所有地址连接失败: host=%{public}s socketError=%{public}s",
                 logHost.c_str(), sawSocketError ? "yes" : "no");
    return ERR_SSH_SOCKET_CONNECT;
}

int SshAdapter::sendSocketBytes(const uint8_t* data, size_t len, int timeoutSec) {
    if (sockFd_ < 0 || (data == nullptr && len > 0)) {
        return ERR_SSH_PROXY_FAILED;
    }
    size_t total = 0;
    while (total < len) {
        const ssize_t sent = ::send(sockFd_, data + total, len - total, 0);
        if (sent > 0) {
            total += static_cast<size_t>(sent);
            continue;
        }
        if (sent < 0 && (errno == EINTR)) { continue; }
        if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (waitSocket(1, timeoutSec) != 0) { return ERR_SSH_CONNECT_TIMEOUT; }
            continue;
        }
        return ERR_SSH_PROXY_FAILED;
    }
    return 0;
}

int SshAdapter::receiveSocketBytes(uint8_t* data, size_t len, int timeoutSec) {
    if (sockFd_ < 0 || (data == nullptr && len > 0)) {
        return ERR_SSH_PROXY_FAILED;
    }
    size_t total = 0;
    while (total < len) {
        const ssize_t received = ::recv(sockFd_, data + total, len - total, 0);
        if (received > 0) {
            total += static_cast<size_t>(received);
            continue;
        }
        if (received == 0) { return ERR_SSH_PROXY_FAILED; }
        if (errno == EINTR) { continue; }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            if (waitSocket(0, timeoutSec) != 0) { return ERR_SSH_CONNECT_TIMEOUT; }
            continue;
        }
        return ERR_SSH_PROXY_FAILED;
    }
    return 0;
}

int SshAdapter::receiveProxyHeaders(std::string& headers, size_t maxLen, int timeoutSec) {
    headers.clear();
    // Read one byte at a time until the header terminator. A proxy may send
    // the first SSH banner in the same TCP packet as the 200 response; a
    // larger recv() buffer would consume and discard those bytes before
    // libssh2_session_handshake() gets the socket.
    char byte = 0;
    while (headers.find("\r\n\r\n") == std::string::npos) {
        const ssize_t received = ::recv(sockFd_, &byte, 1, 0);
        if (received > 0) {
            headers.push_back(byte);
            if (headers.size() > maxLen) { return ERR_SSH_PROXY_FAILED; }
            continue;
        }
        if (received == 0) { return ERR_SSH_PROXY_FAILED; }
        if (errno == EINTR) { continue; }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            if (waitSocket(0, timeoutSec) != 0) { return ERR_SSH_CONNECT_TIMEOUT; }
            continue;
        }
        return ERR_SSH_PROXY_FAILED;
    }
    return 0;
}

int SshAdapter::connectThroughProxy(const ConnectionConfig& cfg) {
    const std::string type = cfg.sshProxyType.empty() ? "direct" : cfg.sshProxyType;
    if (type == "direct") {
        return tcpConnect(cfg.host, cfg.port > 0 ? cfg.port : 22);
    }
    if (type == "frp_tcp") {
        if (cfg.sshProxyHost.empty() || cfg.sshProxyPort <= 0 || cfg.sshProxyPort > 65535) {
            OH_LOG_ERROR(LOG_APP, "[SSH] FRP TCP 映射端点参数无效 host=%{public}s port=%{public}d",
                         SafeLog::MaskHost(cfg.sshProxyHost).c_str(), cfg.sshProxyPort);
            return ERR_SSH_PROXY_INVALID;
        }
        // FRP TCP mode is an already-exposed raw SSH endpoint. There is no
        // FRP control-plane handshake inside the client and no proxy protocol
        // to send; the SSH handshake starts on the mapped socket directly.
        return tcpConnect(cfg.sshProxyHost, cfg.sshProxyPort);
    }
    if (type == "ssh_jump") {
        return connectThroughSshJump(cfg);
    }
    if (type != "http_connect" && type != "socks5") {
        OH_LOG_ERROR(LOG_APP, "[SSH] 不支持的代理类型: %{public}s", type.c_str());
        return ERR_SSH_PROXY_INVALID;
    }
    if (cfg.sshProxyHost.empty() || cfg.sshProxyPort <= 0 || cfg.sshProxyPort > 65535) {
        OH_LOG_ERROR(LOG_APP, "[SSH] 代理地址参数无效: type=%{public}s host=%{public}s port=%{public}d",
                     type.c_str(), SafeLog::MaskHost(cfg.sshProxyHost).c_str(), cfg.sshProxyPort);
        return ERR_SSH_PROXY_INVALID;
    }
    if (cfg.host.find('\r') != std::string::npos || cfg.host.find('\n') != std::string::npos) {
        return ERR_SSH_PROXY_INVALID;
    }

    int ret = tcpConnect(cfg.sshProxyHost, cfg.sshProxyPort);
    if (ret != 0) { return ret; }

    std::string targetHost = cfg.host;
    if (targetHost.size() >= 2 && targetHost.front() == '[' && targetHost.back() == ']') {
        targetHost = targetHost.substr(1, targetHost.size() - 2);
    }
    const int targetPort = cfg.port > 0 ? cfg.port : 22;
    if (targetHost.empty() || targetHost.size() > 255) {
        return ERR_SSH_PROXY_INVALID;
    }

    if (type == "http_connect") {
        std::string hostHeader = targetHost;
        in6_addr ipv6 {};
        if (inet_pton(AF_INET6, targetHost.c_str(), &ipv6) == 1) {
            hostHeader = "[" + targetHost + "]";
        }
        hostHeader += ":" + std::to_string(targetPort);
        std::string request = "CONNECT " + hostHeader + " HTTP/1.1\r\n";
        request += "Host: " + hostHeader + "\r\n";
        request += "Proxy-Connection: Keep-Alive\r\n";
        if (!cfg.sshProxyUsername.empty() || !cfg.sshProxyPassword.empty()) {
            if (cfg.sshProxyUsername.find_first_of("\r\n") != std::string::npos ||
                cfg.sshProxyPassword.find_first_of("\r\n") != std::string::npos) {
                return ERR_SSH_PROXY_INVALID;
            }
            const std::string credentials = cfg.sshProxyUsername + ":" + cfg.sshProxyPassword;
            const std::string encoded = encodeBase64(
                reinterpret_cast<const unsigned char*>(credentials.data()), credentials.size());
            request += "Proxy-Authorization: Basic " + encoded + "\r\n";
        }
        request += "\r\n";
        ret = sendSocketBytes(reinterpret_cast<const uint8_t*>(request.data()), request.size(), 10);
        if (ret != 0) { return ret; }

        std::string response;
        ret = receiveProxyHeaders(response, 16 * 1024, 10);
        if (ret != 0) { return ret; }
        const size_t lineEnd = response.find("\r\n");
        const std::string statusLine = response.substr(0, lineEnd);
        const size_t statusStart = statusLine.find(' ');
        if (statusStart == std::string::npos || statusStart + 4 > statusLine.size()) {
            return ERR_SSH_PROXY_FAILED;
        }
        const int status = std::atoi(statusLine.c_str() + statusStart + 1);
        if (status == 407) { return ERR_SSH_PROXY_AUTH; }
        if (status < 200 || status >= 300) { return ERR_SSH_PROXY_FAILED; }
        OH_LOG_INFO(LOG_APP, "[SSH] HTTP CONNECT 代理握手成功 target=%{public}s:%{public}d",
                    SafeLog::MaskHost(targetHost).c_str(), targetPort);
        return 0;
    }

    std::vector<uint8_t> greeting {0x05, 0x01, 0x00};
    const bool hasProxyCredentials =
        !cfg.sshProxyUsername.empty() || !cfg.sshProxyPassword.empty();
    if (hasProxyCredentials) {
        greeting[1] = 0x02;
        greeting.push_back(0x02);
    }
    ret = sendSocketBytes(greeting.data(), greeting.size(), 10);
    if (ret != 0) { return ret; }

    uint8_t methodReply[2] = {0};
    ret = receiveSocketBytes(methodReply, sizeof(methodReply), 10);
    if (ret != 0 || methodReply[0] != 0x05) { return ERR_SSH_PROXY_FAILED; }
    if (methodReply[1] == 0xFF) { return ERR_SSH_PROXY_AUTH; }
    if (methodReply[1] == 0x02) {
        if (!hasProxyCredentials || cfg.sshProxyUsername.size() > 255 ||
            cfg.sshProxyPassword.size() > 255) {
            return ERR_SSH_PROXY_AUTH;
        }
        std::vector<uint8_t> auth;
        auth.reserve(3 + cfg.sshProxyUsername.size() + cfg.sshProxyPassword.size());
        auth.push_back(0x01);
        auth.push_back(static_cast<uint8_t>(cfg.sshProxyUsername.size()));
        auth.insert(auth.end(), cfg.sshProxyUsername.begin(), cfg.sshProxyUsername.end());
        auth.push_back(static_cast<uint8_t>(cfg.sshProxyPassword.size()));
        auth.insert(auth.end(), cfg.sshProxyPassword.begin(), cfg.sshProxyPassword.end());
        ret = sendSocketBytes(auth.data(), auth.size(), 10);
        if (ret != 0) { return ret; }
        uint8_t authReply[2] = {0};
        ret = receiveSocketBytes(authReply, sizeof(authReply), 10);
        if (ret != 0 || authReply[0] != 0x01 || authReply[1] != 0x00) {
            return ERR_SSH_PROXY_AUTH;
        }
    } else if (methodReply[1] != 0x00) {
        return ERR_SSH_PROXY_AUTH;
    }

    std::vector<uint8_t> request {0x05, 0x01, 0x00};
    in_addr ipv4 {};
    in6_addr ipv6 {};
    if (inet_pton(AF_INET, targetHost.c_str(), &ipv4) == 1) {
        request.push_back(0x01);
        const uint8_t* raw = reinterpret_cast<const uint8_t*>(&ipv4);
        request.insert(request.end(), raw, raw + sizeof(ipv4));
    } else if (inet_pton(AF_INET6, targetHost.c_str(), &ipv6) == 1) {
        request.push_back(0x04);
        const uint8_t* raw = reinterpret_cast<const uint8_t*>(&ipv6);
        request.insert(request.end(), raw, raw + sizeof(ipv6));
    } else {
        request.push_back(0x03);
        request.push_back(static_cast<uint8_t>(targetHost.size()));
        request.insert(request.end(), targetHost.begin(), targetHost.end());
    }
    request.push_back(static_cast<uint8_t>((targetPort >> 8) & 0xFF));
    request.push_back(static_cast<uint8_t>(targetPort & 0xFF));
    ret = sendSocketBytes(request.data(), request.size(), 10);
    if (ret != 0) { return ret; }

    uint8_t replyHead[4] = {0};
    ret = receiveSocketBytes(replyHead, sizeof(replyHead), 10);
    if (ret != 0 || replyHead[0] != 0x05) { return ERR_SSH_PROXY_FAILED; }
    if (replyHead[1] != 0x00) {
        return replyHead[1] == 0x02 ? ERR_SSH_PROXY_AUTH : ERR_SSH_PROXY_FAILED;
    }
    size_t addressLength = 0;
    if (replyHead[3] == 0x01) { addressLength = 4; }
    else if (replyHead[3] == 0x04) { addressLength = 16; }
    else if (replyHead[3] == 0x03) {
        uint8_t domainLength = 0;
        ret = receiveSocketBytes(&domainLength, 1, 10);
        if (ret != 0) { return ret; }
        addressLength = domainLength;
    } else {
        return ERR_SSH_PROXY_FAILED;
    }
    std::vector<uint8_t> discard(addressLength + 2);
    ret = receiveSocketBytes(discard.data(), discard.size(), 10);
    if (ret != 0) { return ret; }
    OH_LOG_INFO(LOG_APP, "[SSH] SOCKS5 代理握手成功 target=%{public}s:%{public}d",
                SafeLog::MaskHost(targetHost).c_str(), targetPort);
    return 0;
}

int SshAdapter::connectThroughSshJump(const ConnectionConfig& cfg) {
    if (cfg.sshProxyHost.empty() || cfg.sshProxyPort <= 0 || cfg.sshProxyPort > 65535 ||
        cfg.host.empty() || cfg.port <= 0 || cfg.port > 65535) {
        return ERR_SSH_PROXY_INVALID;
    }

    const int ret = tcpConnect(cfg.sshProxyHost, cfg.sshProxyPort);
    if (ret != 0) { return ret; }
    jumpSockFd_ = sockFd_;
    sockFd_ = -1;

    auto fail = [this](int code) {
        if (jumpChannel_ != nullptr) {
            libssh2_channel_free(jumpChannel_);
            jumpChannel_ = nullptr;
        }
        if (jumpSession_ != nullptr) {
            libssh2_session_disconnect(jumpSession_, "ProxyJump setup failed");
            libssh2_session_free(jumpSession_);
            jumpSession_ = nullptr;
        }
        if (jumpSockFd_ >= 0) {
            shutdown(jumpSockFd_, SHUT_RDWR);
            close(jumpSockFd_);
            jumpSockFd_ = -1;
        }
        return code;
    };

    jumpSession_ = libssh2_session_init();
    if (jumpSession_ == nullptr) { return fail(ERR_SSH_SESSION_INIT); }
    libssh2_session_set_blocking(jumpSession_, 0);

    int rc = 0;
    while ((rc = libssh2_session_handshake(jumpSession_, jumpSockFd_)) ==
           LIBSSH2_ERROR_EAGAIN) {
        if (waitSocketOnFd(jumpSockFd_, 2, 30) != 0) {
            return fail(ERR_SSH_KEX_TIMEOUT);
        }
    }
    if (rc != 0) {
        OH_LOG_ERROR(LOG_APP, "[SSH] ProxyJump 跳板机握手失败 rc=%{public}d", rc);
        return fail(ERR_SSH_KEX_FAILED);
    }

    const int jumpHostKeyResult = verifyHostKey(
        jumpSession_, cfg.sshJumpHostKeyRawBase64,
        cfg.sshJumpHostKeyFingerprintSha256, true, "ProxyJump 跳板机");
    if (jumpHostKeyResult != 0) {
        return fail(jumpHostKeyResult);
    }

    const std::string jumpUsername = cfg.sshProxyUsername.empty()
        ? cfg.username : cfg.sshProxyUsername;
    const std::string jumpPassword = cfg.sshProxyPassword.empty()
        ? cfg.password : cfg.sshProxyPassword;
    if (jumpUsername.empty()) { return fail(ERR_SSH_PROXY_INVALID); }
    if (cfg.authMethod == "publickey" && !cfg.privateKeyPem.empty()) {
        const char* passphrase = cfg.privateKeyPassphrase.empty()
            ? nullptr : cfg.privateKeyPassphrase.c_str();
        while ((rc = libssh2_userauth_publickey_frommemory(
                    jumpSession_, jumpUsername.c_str(), jumpUsername.size(),
                    nullptr, 0, cfg.privateKeyPem.c_str(), cfg.privateKeyPem.size(),
                    passphrase)) == LIBSSH2_ERROR_EAGAIN) {
            if (waitSocketOnFd(jumpSockFd_, 2, 30) != 0) {
                return fail(ERR_SSH_AUTH_TIMEOUT);
            }
        }
    } else {
        while ((rc = libssh2_userauth_password(
                    jumpSession_, jumpUsername.c_str(), jumpPassword.c_str())) ==
               LIBSSH2_ERROR_EAGAIN) {
            if (waitSocketOnFd(jumpSockFd_, 2, 30) != 0) {
                return fail(ERR_SSH_AUTH_TIMEOUT);
            }
        }
    }
    if (rc != 0 || !libssh2_userauth_authenticated(jumpSession_)) {
        OH_LOG_ERROR(LOG_APP, "[SSH] ProxyJump 跳板机认证失败 rc=%{public}d", rc);
        return fail(ERR_SSH_PROXY_AUTH);
    }

    std::string targetHost = cfg.host;
    if (targetHost.size() >= 2 && targetHost.front() == '[' && targetHost.back() == ']') {
        targetHost = targetHost.substr(1, targetHost.size() - 2);
    }
    while ((jumpChannel_ = libssh2_channel_direct_tcpip_ex(
                jumpSession_, targetHost.c_str(), cfg.port, "127.0.0.1", 22)) == nullptr) {
        if (libssh2_session_last_errno(jumpSession_) != LIBSSH2_ERROR_EAGAIN) {
            return fail(ERR_SSH_PROXY_FAILED);
        }
        if (waitSocketOnFd(jumpSockFd_, 2, 30) != 0) {
            return fail(ERR_SSH_CONNECT_TIMEOUT);
        }
    }

    int socketPair[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, socketPair) != 0) {
        return fail(ERR_SSH_SOCKET_CREATE);
    }
    for (int fd : socketPair) {
        const int flags = fcntl(fd, F_GETFL, 0);
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
            close(socketPair[0]);
            close(socketPair[1]);
            return fail(ERR_SSH_SOCKET_CREATE);
        }
    }
    sockFd_ = socketPair[0];
    jumpRelayFd_ = socketPair[1];
    jumpRelayStopRequested_.store(false, std::memory_order_release);
    jumpRelayRunning_.store(true, std::memory_order_release);
    jumpRelayThread_ = std::thread(&SshAdapter::sshJumpRelayLoop, this);
    OH_LOG_INFO(LOG_APP, "[SSH] ProxyJump 路由已建立 target=%{public}s:%{public}d",
                SafeLog::MaskHost(targetHost).c_str(), cfg.port);
    return 0;
}

void SshAdapter::sshJumpRelayLoop() {
    constexpr size_t kRelayBufferLimit = 512 * 1024;
    std::vector<uint8_t> toChannel;
    std::vector<uint8_t> toLocal;
    bool localEof = false;
    bool channelEof = false;
    std::array<uint8_t, SSH_BUFFER_SIZE> buffer {};

    while (!jumpRelayStopRequested_.load(std::memory_order_acquire)) {
        bool progress = false;
        if (!localEof && toChannel.size() < kRelayBufferLimit) {
            const ssize_t received = recv(jumpRelayFd_, buffer.data(), buffer.size(), MSG_DONTWAIT);
            if (received > 0) {
                toChannel.insert(toChannel.end(), buffer.begin(), buffer.begin() + received);
                progress = true;
            } else if (received == 0) {
                localEof = true;
                libssh2_channel_send_eof(jumpChannel_);
            } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                break;
            }
        }
        if (!toChannel.empty()) {
            const ssize_t written = libssh2_channel_write(
                jumpChannel_, reinterpret_cast<const char*>(toChannel.data()), toChannel.size());
            if (written > 0) {
                toChannel.erase(toChannel.begin(), toChannel.begin() + written);
                progress = true;
            } else if (written < 0 && written != LIBSSH2_ERROR_EAGAIN) {
                break;
            }
        }
        if (!channelEof && toLocal.size() < kRelayBufferLimit) {
            const ssize_t received = libssh2_channel_read(
                jumpChannel_, reinterpret_cast<char*>(buffer.data()), buffer.size());
            if (received > 0) {
                toLocal.insert(toLocal.end(), buffer.begin(), buffer.begin() + received);
                progress = true;
            } else if (received == 0 && libssh2_channel_eof(jumpChannel_)) {
                channelEof = true;
                shutdown(jumpRelayFd_, SHUT_WR);
            } else if (received < 0 && received != LIBSSH2_ERROR_EAGAIN) {
                break;
            }
        }
        if (!toLocal.empty()) {
            const ssize_t written = send(jumpRelayFd_, toLocal.data(), toLocal.size(), MSG_DONTWAIT);
            if (written > 0) {
                toLocal.erase(toLocal.begin(), toLocal.begin() + written);
                progress = true;
            } else if (written < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                break;
            }
        }
        if (localEof && channelEof && toChannel.empty() && toLocal.empty()) { break; }
        if (progress) { continue; }

        fd_set readSet;
        fd_set writeSet;
        FD_ZERO(&readSet);
        FD_ZERO(&writeSet);
        FD_SET(jumpRelayFd_, &readSet);
        if (!toLocal.empty()) { FD_SET(jumpRelayFd_, &writeSet); }
        FD_SET(jumpSockFd_, &readSet);
        FD_SET(jumpSockFd_, &writeSet);
        const int maxFd = std::max(jumpRelayFd_, jumpSockFd_);
        struct timeval tv = {0, 100000};
        const int selected = select(maxFd + 1, &readSet, &writeSet, nullptr, &tv);
        if (selected < 0 && errno != EINTR) { break; }
    }
    jumpRelayRunning_.store(false, std::memory_order_release);
}

void SshAdapter::stopSshJumpRelay() {
    jumpRelayStopRequested_.store(true, std::memory_order_release);
    if (jumpRelayFd_ >= 0) { shutdown(jumpRelayFd_, SHUT_RDWR); }
    if (jumpSockFd_ >= 0) { shutdown(jumpSockFd_, SHUT_RDWR); }
    if (jumpRelayThread_.joinable() && jumpRelayThread_.get_id() != std::this_thread::get_id()) {
        jumpRelayThread_.join();
    }
    jumpRelayRunning_.store(false, std::memory_order_release);
    if (jumpChannel_ != nullptr) {
        libssh2_channel_free(jumpChannel_);
        jumpChannel_ = nullptr;
    }
    if (jumpSession_ != nullptr) {
        libssh2_session_free(jumpSession_);
        jumpSession_ = nullptr;
    }
    if (jumpRelayFd_ >= 0) {
        close(jumpRelayFd_);
        jumpRelayFd_ = -1;
    }
    if (jumpSockFd_ >= 0) {
        close(jumpSockFd_);
        jumpSockFd_ = -1;
    }
}

// exchangeBanner() 已移除 — libssh2_session_handshake 内部处理 banner 交换

// ============================================================
// SSH 协议方法 (libssh2 集成)
// ============================================================

int SshAdapter::verifyHostKey(LIBSSH2_SESSION* session,
                              const std::string& expectedRawBase64,
                              const std::string& expectedFingerprintSha256,
                              bool required, const char* endpointLabel) {
    if (session == nullptr) {
        return ERR_SSH_SESSION_INIT;
    }
    if (expectedRawBase64.empty() && expectedFingerprintSha256.empty()) {
        if (required) {
            OH_LOG_ERROR(LOG_APP, "[SSH] %{public}s 缺少 host-key trust binding",
                         endpointLabel ? endpointLabel : "SSH endpoint");
            return ERR_SSH_HOSTKEY_MISMATCH;
        }
        return 0;
    }

    const char* fingerprint = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256);
    if (!expectedRawBase64.empty()) {
        size_t keyLen = 0;
        int keyType = LIBSSH2_HOSTKEY_TYPE_UNKNOWN;
        const char* rawKey = libssh2_session_hostkey(session, &keyLen, &keyType);
        if (!rawKey || keyLen == 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] %{public}s host key raw 读取失败",
                         endpointLabel ? endpointLabel : "SSH endpoint");
            return ERR_SSH_HOSTKEY_MISMATCH;
        }
        const std::string currentRaw = encodeBase64(
            reinterpret_cast<const unsigned char*>(rawKey), keyLen);
        if (currentRaw != expectedRawBase64) {
            std::string currentFp;
            if (fingerprint) {
                std::string fpB64 = encodeBase64(
                    reinterpret_cast<const unsigned char*>(fingerprint), 32);
                while (!fpB64.empty() && fpB64.back() == '=') { fpB64.pop_back(); }
                currentFp = "SHA256:" + fpB64;
            }
            OH_LOG_ERROR(LOG_APP,
                "[SSH] %{public}s host key raw mismatch keyType=%{public}d algorithm=%{public}s currentFp=%{public}s expectedFp=%{public}s",
                endpointLabel ? endpointLabel : "SSH endpoint", keyType,
                sshHostKeyTypeName(keyType), currentFp.c_str(),
                expectedFingerprintSha256.c_str());
            return ERR_SSH_HOSTKEY_MISMATCH;
        }
        OH_LOG_INFO(LOG_APP, "[SSH] %{public}s host key raw 校验通过",
                    endpointLabel ? endpointLabel : "SSH endpoint");
        return 0;
    }

    if (!fingerprint) {
        OH_LOG_ERROR(LOG_APP, "[SSH] %{public}s SHA256 host key fingerprint 读取失败",
                     endpointLabel ? endpointLabel : "SSH endpoint");
        return ERR_SSH_HOSTKEY_MISMATCH;
    }
    std::string currentFpB64 = encodeBase64(
        reinterpret_cast<const unsigned char*>(fingerprint), 32);
    while (!currentFpB64.empty() && currentFpB64.back() == '=') { currentFpB64.pop_back(); }
    const std::string currentFp = "SHA256:" + currentFpB64;
    if (currentFp != expectedFingerprintSha256) {
        OH_LOG_ERROR(LOG_APP,
            "[SSH] %{public}s host key mismatch expected=%{public}s current=%{public}s",
            endpointLabel ? endpointLabel : "SSH endpoint",
            expectedFingerprintSha256.c_str(), currentFp.c_str());
        return ERR_SSH_HOSTKEY_MISMATCH;
    }
    OH_LOG_INFO(LOG_APP, "[SSH] %{public}s host key fingerprint 校验通过",
                endpointLabel ? endpointLabel : "SSH endpoint");
    return 0;
}

int SshAdapter::sshHandshake() {
    if (!assertSessionOwner("handshake")) {
        return ERR_SSH_SESSION_INIT;
    }
    session_ = libssh2_session_init();
    if (!session_) {
        OH_LOG_ERROR(LOG_APP, "[SSH] libssh2_session_init 失败");
        return ERR_SSH_SESSION_INIT;
    }

    // 非阻塞模式
    libssh2_session_set_blocking(session_, 0);
    // Non-blocking applications must call libssh2_keepalive_send() themselves.
    // The reader reactor does that even while the page callback is detached,
    // so an idle background session does not rely on the UI latency probe.
    libssh2_keepalive_config(session_, 1, SshTerminalKeepalivePolicy::kIntervalSeconds);
    keepaliveNextDue_ = std::chrono::steady_clock::now() +
        std::chrono::seconds(SshTerminalKeepalivePolicy::kIntervalSeconds);
    keepaliveConsecutiveFailures_ = 0;

    applySshAlgorithmPreferences(session_);
    OH_LOG_INFO(LOG_APP, "[SSH] 算法偏好已设置");

    // KEX 握手 (非阻塞 + select 轮询)
    int rc;
    while ((rc = libssh2_session_handshake(session_, sockFd_)) == LIBSSH2_ERROR_EAGAIN) {
        int w = waitSocket(2, 30); // 30s KEX timeout
        if (w != 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] KEX 握手超时");
            libssh2_session_free(session_);
            session_ = nullptr;
            return ERR_SSH_KEX_TIMEOUT;
        }
    }
    if (rc) {
        char* errMsg = nullptr;
        libssh2_session_last_error(session_, &errMsg, nullptr, 0);
        OH_LOG_ERROR(LOG_APP, "[SSH] KEX握手失败: rc=%{public}d msg=%{public}s serverBanner=%{public}s",
                     rc, errMsg ? errMsg : "unknown", serverBanner_.c_str());
        libssh2_session_free(session_);
        session_ = nullptr;
        return ERR_SSH_KEX_FAILED;
    }

    // 主机密钥指纹 (SHA256, 用于日志)
    const char* fingerprint = libssh2_hostkey_hash(session_, LIBSSH2_HOSTKEY_HASH_SHA256);
    if (fingerprint) {
        char hex[65];
        for (int i = 0; i < 32; i++) {
            sprintf(hex + i * 2, "%02X", (unsigned char)fingerprint[i]);
        }
        hex[64] = '\0';
        OH_LOG_INFO(LOG_APP, "[SSH] 主机密钥 SHA256: %{public}s", hex);
    }

    // 二次校验 expected host key (防 probe/connect 间 TOCTOU)。
    const int hostKeyResult = verifyHostKey(
        session_, savedCfg_.expectedHostKeyRawBase64,
        savedCfg_.expectedHostKeyFingerprintSha256, false, "目标主机");
    if (hostKeyResult != 0) {
        libssh2_session_free(session_);
        session_ = nullptr;
        return hostKeyResult;
    }

    OH_LOG_INFO(LOG_APP, "[SSH] KEX 握手完成");
    return 0;
}

int SshAdapter::authenticatePassword() {
    if (!assertSessionOwner("password_auth")) {
        return ERR_SSH_AUTH_FAILED;
    }
    if (!session_) { return ERR_SSH_AUTH_FAILED; }

    // 查询服务器支持的认证方法
    char* userList = nullptr;
    while ((userList = libssh2_userauth_list(session_,
               savedCfg_.username.c_str(), savedCfg_.username.length())) == nullptr &&
           libssh2_session_last_errno(session_) == LIBSSH2_ERROR_EAGAIN) {
        if (waitSocket(2, 30) != 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] 查询密码认证方法超时");
            return ERR_SSH_AUTH_TIMEOUT;
        }
    }
    OH_LOG_INFO(LOG_APP, "[SSH] 服务器认证方法: %{public}s",
                userList ? userList : "(none)");
    advertisedAuthMethods_ = userList == nullptr ? std::string() : std::string(userList);

    // 密码认证 (非阻塞)
    int rc;
    while ((rc = libssh2_userauth_password(session_,
               savedCfg_.username.c_str(),
               savedCfg_.password.c_str())) == LIBSSH2_ERROR_EAGAIN) {
        int w = waitSocket(2, 30); // 30s auth timeout
        if (w != 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] 密码认证超时");
            return ERR_SSH_AUTH_TIMEOUT;
        }
    }
    if (rc) {
        const char* errMsg = "未知错误";
        if (rc == LIBSSH2_ERROR_AUTHENTICATION_FAILED) {
            errMsg = "用户名或密码错误";
        } else if (rc == LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED) {
            errMsg = "公钥未验证";
        }
        char* detail = nullptr;
        libssh2_session_last_error(session_, &detail, nullptr, 0);
        OH_LOG_ERROR(LOG_APP, "[SSH] 认证失败: %{public}s (rc=%{public}d detail=%{public}s)",
                     errMsg, rc, detail ? detail : "");
        return ERR_SSH_AUTH_FAILED;
    }

    authenticated_ = true;
    OH_LOG_INFO(LOG_APP, "[SSH] 密码认证成功");
    return 0;
}

void SshAdapter::keyboardInteractiveCallback(
    const char* name, int nameLen, const char* instruction, int instructionLen,
    int numPrompts, const LIBSSH2_USERAUTH_KBDINT_PROMPT* prompts,
    LIBSSH2_USERAUTH_KBDINT_RESPONSE* responses, void** abstract) {
    (void)name;
    (void)nameLen;
    (void)instruction;
    (void)instructionLen;
    (void)prompts;
    if (numPrompts <= 0 || responses == nullptr || abstract == nullptr ||
        *abstract == nullptr) {
        return;
    }

    auto* adapter = static_cast<SshAdapter*>(*abstract);
    for (int index = 0; index < numPrompts; ++index) {
        std::string response;
        if (index >= 0 &&
            static_cast<size_t>(index) < adapter->savedCfg_.sshKeyboardInteractiveResponses.size()) {
            response = adapter->savedCfg_.sshKeyboardInteractiveResponses[static_cast<size_t>(index)];
        } else {
            // Password is a useful compatibility fallback for servers that
            // expose a password prompt through keyboard-interactive.
            response = adapter->savedCfg_.password;
        }
        if (response.empty()) {
            responses[index].text = nullptr;
            responses[index].length = 0;
            continue;
        }
        char* allocated = static_cast<char*>(std::malloc(response.size()));
        if (allocated == nullptr) {
            responses[index].text = nullptr;
            responses[index].length = 0;
            continue;
        }
        std::memcpy(allocated, response.data(), response.size());
        responses[index].text = allocated;
        responses[index].length = static_cast<unsigned int>(
            std::min<size_t>(response.size(), UINT_MAX));
    }
}

int SshAdapter::authenticateKeyboardInteractive() {
    if (!assertSessionOwner("keyboard_interactive_auth")) {
        return ERR_SSH_AUTH_FAILED;
    }
    if (!session_) { return ERR_SSH_AUTH_FAILED; }

    char* userList = nullptr;
    while ((userList = libssh2_userauth_list(
                session_, savedCfg_.username.c_str(),
                static_cast<unsigned int>(savedCfg_.username.size()))) == nullptr &&
           libssh2_session_last_errno(session_) == LIBSSH2_ERROR_EAGAIN) {
        if (waitSocket(2, 30) != 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] 查询 keyboard-interactive 方法超时");
            return ERR_SSH_AUTH_TIMEOUT;
        }
    }
    if (userList == nullptr || std::strstr(userList, "keyboard-interactive") == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[SSH] 服务器不支持 keyboard-interactive 认证");
        return ERR_SSH_AUTH_METHODS;
    }

    void** abstract = libssh2_session_abstract(session_);
    if (abstract != nullptr) {
        *abstract = this;
    }

    int rc;
    while ((rc = libssh2_userauth_keyboard_interactive(
                session_, savedCfg_.username.c_str(),
                &SshAdapter::keyboardInteractiveCallback)) == LIBSSH2_ERROR_EAGAIN) {
        int w = waitSocket(2, 30);
        if (w != 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] keyboard-interactive 认证超时");
            return ERR_SSH_AUTH_TIMEOUT;
        }
    }
    if (rc != 0) {
        char* detail = nullptr;
        libssh2_session_last_error(session_, &detail, nullptr, 0);
        OH_LOG_ERROR(LOG_APP, "[SSH] keyboard-interactive 认证失败: rc=%{public}d detail=%{public}s",
                     rc, detail ? detail : "");
        return rc == LIBSSH2_ERROR_AUTHENTICATION_FAILED ?
            ERR_SSH_AUTH_PARTIAL : ERR_SSH_AUTH_FAILED;
    }

    authenticated_ = true;
    OH_LOG_INFO(LOG_APP, "[SSH] keyboard-interactive 认证成功, prompts=%{public}zu",
                savedCfg_.sshKeyboardInteractiveResponses.size());
    return 0;
}

int SshAdapter::authenticatePublicKey(const std::string& username,
                                       const std::string& privateKeyPem,
                                       const std::string& passphrase) {
    if (!assertSessionOwner("publickey_auth")) {
        return ERR_SSH_AUTH_FAILED;
    }
    if (!session_) { return ERR_SSH_AUTH_FAILED; }

    // 诊断: 仅输出密钥长度, 不泄露内容
    OH_LOG_INFO(LOG_APP, "[SSH] 密钥数据 len=%{public}zu", privateKeyPem.size());

    const char* pass = passphrase.empty() ? nullptr : passphrase.c_str();

    int rc;
    while ((rc = libssh2_userauth_publickey_frommemory(
                session_,
                username.c_str(), username.length(),
                nullptr, 0,
                privateKeyPem.c_str(), privateKeyPem.length(),
                pass)) == LIBSSH2_ERROR_EAGAIN) {
        int w = waitSocket(2, 30);
        if (w != 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] 公钥认证超时");
            return ERR_SSH_AUTH_TIMEOUT;
        }
    }
    if (rc != 0) {
        char* detail = nullptr;
        libssh2_session_last_error(session_, &detail, nullptr, 0);
        OH_LOG_ERROR(LOG_APP, "[SSH] 公钥认证失败: rc=%{public}d detail=%{public}s",
                     rc, detail ? detail : "");
        return ERR_SSH_AUTH_FAILED;
    }

    authenticated_ = true;
    OH_LOG_INFO(LOG_APP, "[SSH] 公钥认证成功 (OpenSSL 后端)");
    return 0;
}

int SshAdapter::openChannel() {
    if (!assertSessionOwner("open_channel")) {
        return ERR_SSH_CHANNEL_OPEN;
    }
    if (!session_) { return ERR_SSH_CHANNEL_OPEN; }

    while ((channel_ = libssh2_channel_open_session(session_)) == nullptr) {
        if (libssh2_session_last_errno(session_) == LIBSSH2_ERROR_EAGAIN) {
            int w = waitSocket(2, 15); // 15s channel timeout
            if (w != 0) {
                OH_LOG_ERROR(LOG_APP, "[SSH] 打开通道超时");
                return ERR_SSH_CHANNEL_OPEN;
            }
        } else {
            char* errMsg = nullptr;
            libssh2_session_last_error(session_, &errMsg, nullptr, 0);
            OH_LOG_ERROR(LOG_APP, "[SSH] libssh2_channel_open_session 失败: %{public}s",
                         errMsg ? errMsg : "unknown");
            return ERR_SSH_CHANNEL_OPEN;
        }
    }
    OH_LOG_INFO(LOG_APP, "[SSH] 通道已打开");
    return 0;
}

int SshAdapter::requestPty(int cols, int rows) {
    lastPtyLibssh2Error_ = 0;
    lastPtyFailureClass_ = SshPtyFailureClass::NONE;
    if (!assertSessionOwner("request_pty")) {
        lastPtyFailureClass_ = SshPtyFailureClass::PERMANENT;
        return ERR_SSH_PTY_FAILED;
    }
    if (!channel_) {
        lastPtyFailureClass_ = SshPtyFailureClass::PERMANENT;
        return ERR_SSH_PTY_FAILED;
    }

    auto failPty = [this](int libssh2Error) {
        lastPtyLibssh2Error_ = libssh2Error;
        lastPtyFailureClass_ = classifyPtyFailure(libssh2Error);
        return ERR_SSH_PTY_FAILED;
    };

    int rc;
    while ((rc = libssh2_channel_request_pty(channel_, "xterm-256color")) == LIBSSH2_ERROR_EAGAIN) {
        int w = waitSocket(2, 15);
        if (w != 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] PTY 请求超时");
            return failPty(LIBSSH2_ERROR_TIMEOUT);
        }
    }
    if (rc) {
        OH_LOG_ERROR(LOG_APP, "[SSH] PTY 请求失败: rc=%{public}d", rc);
        return failPty(rc);
    }

    // 设置初始窗口大小；该请求同样可能返回 EAGAIN，不能把失败
    // 静默当成成功，否则远端会以默认尺寸启动并破坏终端布局。
    while ((rc = libssh2_channel_request_pty_size(channel_, cols, rows)) ==
           LIBSSH2_ERROR_EAGAIN) {
        int w = waitSocket(2, 15);
        if (w != 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] PTY 尺寸请求超时");
            return failPty(LIBSSH2_ERROR_TIMEOUT);
        }
    }
    if (rc != 0) {
        OH_LOG_ERROR(LOG_APP, "[SSH] PTY 尺寸请求失败: rc=%{public}d", rc);
        return failPty(rc);
    }
    OH_LOG_INFO(LOG_APP, "[SSH] PTY 已分配 %{public}dx%{public}d (term=xterm-256color)", cols, rows);
    return 0;
}

int SshAdapter::startShell() {
    if (!assertSessionOwner("start_shell")) {
        return ERR_SSH_SHELL_FAILED;
    }
    if (!channel_) { return ERR_SSH_SHELL_FAILED; }

    int rc;
    while ((rc = libssh2_channel_shell(channel_)) == LIBSSH2_ERROR_EAGAIN) {
        int w = waitSocket(2, 15);
        if (w != 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] 启动 Shell 超时");
            return ERR_SSH_SHELL_FAILED;
        }
    }
    if (rc) {
        OH_LOG_ERROR(LOG_APP, "[SSH] 启动 Shell 失败: rc=%{public}d", rc);
        return ERR_SSH_SHELL_FAILED;
    }
    OH_LOG_INFO(LOG_APP, "[SSH] Shell 已启动");
    return 0;
}

// ============================================================
// 连接管理 (完整 SSH2 流程)
// ============================================================

int SshAdapter::connect(const ConnectionConfig& cfg) {
    if (isReactorThread()) {
        return connectInternal(cfg);
    }

    // The session owner is created before any socket, libssh2 session, or
    // authentication state is touched. The async N-API worker only waits for
    // this owner command and never enters libssh2 itself.
    const bool hadPreviousState =
        state_.load(std::memory_order_acquire) != ConnectionState::DISCONNECTED;
    if (hadPreviousState) {
        OH_LOG_WARN(LOG_APP, "[SSH] 已连接, 先断开");
        disconnect();
        // An explicit reconnect after a completed session clears the old
        // cancellation request. A cancellation received while the new async
        // request was still pending keeps the flag set and is honored below.
        connectCancelRequested_.store(false, std::memory_order_release);
    }
    startReader();
    return runOnReactor([this, cfg]() {
        return connectInternal(cfg);
    });
}

int SshAdapter::connectInternal(const ConnectionConfig& cfg, bool preserveOwner) {
    if (!assertSessionOwner("connect")) {
        return ERR_SSH_SESSION_INIT;
    }
    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    if (connectCancelRequested_.load(std::memory_order_acquire)) {
        OH_LOG_INFO(LOG_APP, "[SSH] 连接在开始前已取消");
        if (preserveOwner) {
            resetTransportForRecovery();
        } else {
            stopTerminalInput();
            // connect() starts the owner before publishing this command. A
            // cancellation that wins before DNS must also stop that otherwise
            // idle owner; the async completion path may still join it later.
            stopReader();
        }
        setState(ConnectionState::ERROR, "SSH connect cancelled");
        return ERR_SSH_SESSION_CLOSED;
    }

    auto failConnect = [this, preserveOwner](int code, const std::string& message) {
        if (preserveOwner) {
            // Keep the owner reactor and saved configuration alive so the
            // recovery loop can retry without replaying terminal input.
            resetTransportForRecovery();
        } else {
            disconnect();
        }
        setState(ConnectionState::ERROR, message);
        return code;
    };

    // 保存配置 (用于后续认证和重连)
    savedCfg_ = cfg;
    auto attemptConnect = [this, &cfg]() -> std::pair<int, std::string> {
        ioGeneration_.fetch_add(1, std::memory_order_acq_rel);
        setState(ConnectionState::CONNECTING, "SSH connecting");

        // Step 1: TCP 连接
        int ret = connectThroughProxy(cfg);
        if (ret < 0) {
            // Proxy validation/handshake may fail after a TCP socket has
            // already been opened. The caller owns cleanup and retry policy.
            return {ret, "SSH transport connection failed [" + std::to_string(ret) + "]"};
        }

        // Step 2: KEX 密钥交换 (libssh2内部处理Banner,无需手动预读)
        ret = sshHandshake();
        if (ret < 0) {
            return {ret, "SSH handshake failed [" + std::to_string(ret) + "]"};
        }

        // Step 4: 用户认证 (公钥优先, 失败时回退密码)
        OH_LOG_INFO(LOG_APP, "[SSH] 认证方式=%{public}s", cfg.authMethod.c_str());
        auto authenticatePasswordWithFallback = [this]() {
            const int passwordResult = authenticatePassword();
            if (!sshPasswordFallbackAllowsKeyboardInteractive(
                    advertisedAuthMethods_, passwordResult)) {
                return passwordResult;
            }
            OH_LOG_WARN(LOG_APP,
                        "[SSH] password method failed; trying advertised keyboard-interactive fallback");
            const int interactiveResult = authenticateKeyboardInteractive();
            return interactiveResult == 0 ? 0 : passwordResult;
        };
        if (cfg.authMethod == "kbd-interactive" || cfg.authMethod == "keyboard-interactive") {
            ret = authenticateKeyboardInteractive();
        } else if (cfg.authMethod == "publickey" && !cfg.privateKeyPem.empty()) {
            ret = authenticatePublicKey(cfg.username, cfg.privateKeyPem, cfg.privateKeyPassphrase);
            if (ret < 0 && !cfg.password.empty()) {
                OH_LOG_WARN(LOG_APP, "[SSH] 公钥认证失败, 回退到密码认证");
                ret = authenticatePasswordWithFallback();
            }
        } else {
            ret = authenticatePasswordWithFallback();
        }
        if (ret < 0) {
            return {ret, "SSH authentication failed [" + std::to_string(ret) + "]"};
        }

        // Step 5: 打开 SSH 会话通道
        ret = openChannel();
        if (ret < 0) {
            return {ret, "SSH channel open failed [" + std::to_string(ret) + "]"};
        }

        // Step 6: 请求 PTY (SSH 调用方将 cfg.width/height 传为终端 cols/rows)
        int ptyCols = cfg.width > 0 ? cfg.width : 80;
        int ptyRows = cfg.height > 0 ? cfg.height : 24;
        ret = requestPty(ptyCols, ptyRows);
        if (ret < 0) {
            return {ret,
                "SSH PTY request failed [" + std::to_string(ret) + "] libssh2=[" +
                std::to_string(lastPtyLibssh2Error_) + "]"};
        }

        // Step 7: 启动远程 Shell
        ret = startShell();
        if (ret < 0) {
            return {ret, "SSH shell start failed [" + std::to_string(ret) + "]"};
        }

        startTerminalInput();
        setState(ConnectionState::CONNECTED, "SSH connected");
        // Start the per-session owner before the page publishes its push
        // callback. The reactor can accept early terminal input without
        // creating a second writer; it simply waits for the callback before
        // consuming remote output.
        startReader();
        const std::string logHost = SafeLog::MaskHost(cfg.host);
        OH_LOG_INFO(LOG_APP, "[SSH] SSH 连接建立完成 (libssh2 完整握手, %{public}s:%{public}d)",
                    logHost.c_str(), cfg.port);
        return {0, ""};
    };

    // An initial connection can lose the socket between authentication and
    // PTY negotiation. Rebuild the complete transport a bounded number of
    // times. A recovery already has its own three-attempt loop, so it gets one
    // PTY attempt per outer recovery cycle instead of multiplying retries.
    const uint32_t maxAttempts = preserveOwner
        ? 1U : SshPtyRecoveryPolicy::kMaxInitialAttempts;
    for (uint32_t attempt = 0; attempt < maxAttempts; ++attempt) {
        const auto outcome = attemptConnect();
        if (outcome.first == 0) {
            return 0;
        }
        const bool canRetry = outcome.first == ERR_SSH_PTY_FAILED &&
            SshPtyRecoveryPolicy::retryable(lastPtyFailureClass_) &&
            attempt + 1 < maxAttempts &&
            !connectCancelRequested_.load(std::memory_order_acquire);
        if (!canRetry) {
            return failConnect(outcome.first, outcome.second);
        }

        OH_LOG_WARN(LOG_APP,
                    "[SSH] PTY 瞬态失败, 重建 SSH 传输 attempt=%{public}u/%{public}u "
                    "libssh2=%{public}d",
                    attempt + 1, maxAttempts, lastPtyLibssh2Error_);
        resetTransportForRecovery();
        std::unique_lock<std::mutex> retryLock(reactorCommandMutex_);
        reactorCommandCondition_.wait_for(
            retryLock,
            std::chrono::milliseconds(SshPtyRecoveryPolicy::kRetryDelayMilliseconds),
            [this]() {
                return connectCancelRequested_.load(std::memory_order_acquire) ||
                    !readerRunning_.load(std::memory_order_acquire);
            });
        if (connectCancelRequested_.load(std::memory_order_acquire) ||
            !readerRunning_.load(std::memory_order_acquire)) {
            return failConnect(ERR_SSH_SESSION_CLOSED, "SSH connect cancelled during PTY recovery");
        }
    }

    return failConnect(ERR_SSH_PTY_FAILED, "SSH PTY recovery exhausted");
}

void SshAdapter::disconnect() {
    // Close the input admission gate before the asynchronous teardown task is
    // published. The registry may remain visible until that task starts.
    rejectTerminalInput();
    // Set the flag before taking lifecycleMutex_: an async connect worker may
    // currently be blocked in DNS/proxy/KEX waitSocket(). The worker observes
    // cancellation in <=100 ms, while this method then serializes all handle
    // destruction behind the same lifecycle lock.
    requestConnectCancel();
    // Stop producers before taking the lifecycle lock. Reactor commands hold
    // that lock for their libssh2 slice; joining while holding it would make
    // teardown wait forever for a command that cannot acquire the lock.
    stopTerminalInput();
    stopReader();
    stopSshJumpRelay();

    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);

    {
        std::lock_guard<std::mutex> callbackLock(callbackMutex_);
        onDataCallback_ = nullptr;
    }
    clearDetachedTerminalOutput();

    {
        // Keep the lock order identical to writeTerminalData(): session first,
        // then the write fence. Once this point is reached no channel write
        // can start after teardown begins, and no writer can retain the
        // channel while it is freed below.
        std::lock_guard<std::mutex> sftpLock(sftpOperationMutex_);
        std::unique_lock<std::mutex> sessionLock(sessionMutex_);
        std::lock_guard<std::mutex> writeFence(inputWriteFenceMutex_);
        if (sftp_) {
            libssh2_sftp_shutdown(sftp_);
            sftp_ = nullptr;
        }
        if (channel_) {
            libssh2_channel_free(channel_);
            channel_ = nullptr;
        }
        if (session_) {
            libssh2_session_disconnect(session_, "Client disconnecting");
            libssh2_session_free(session_);
            session_ = nullptr;
        }
        if (sockFd_ >= 0) {
            shutdown(sockFd_, SHUT_RDWR);
            close(sockFd_);
            sockFd_ = -1;
            OH_LOG_INFO(LOG_APP, "[SSH] TCP 连接已断开");
        }
        ioGeneration_.fetch_add(1, std::memory_order_acq_rel);
        authenticated_ = false;
        secureClearString(savedCfg_.password);
        secureClearString(savedCfg_.privateKeyPem);
        secureClearString(savedCfg_.privateKeyPassphrase);
        secureClearString(savedCfg_.sshProxyPassword);
        for (std::string& response : savedCfg_.sshKeyboardInteractiveResponses) {
            secureClearString(response);
        }
        savedCfg_.sshKeyboardInteractiveResponses.clear();
    }
    keepaliveNextDue_ = std::chrono::steady_clock::time_point::max();
    keepaliveConsecutiveFailures_ = 0;
    transportRecoveryRequested_.store(false, std::memory_order_release);
    // Do not invoke user code while sessionMutex_ is held. A state callback
    // can synchronously update the page and call back into disconnect/send.
    setState(ConnectionState::DISCONNECTED, "SSH disconnected");
}

void SshAdapter::resetTransportForRecovery() {
    // This is called only by the session owner, or while connectInternal holds
    // the recursive lifecycle gate. Keep savedCfg_ and the data callback: the
    // next handshake must use the same explicit host-key policy and consumer.
    stopTerminalInput();
    stopSshJumpRelay();

    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    std::lock_guard<std::mutex> sftpLock(sftpOperationMutex_);
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    std::lock_guard<std::mutex> writeFence(inputWriteFenceMutex_);
    if (sftp_) {
        libssh2_sftp_shutdown(sftp_);
        sftp_ = nullptr;
    }
    if (channel_) {
        libssh2_channel_free(channel_);
        channel_ = nullptr;
    }
    if (session_) {
        libssh2_session_disconnect(session_, "SSH transport recovery");
        libssh2_session_free(session_);
        session_ = nullptr;
    }
    if (sockFd_ >= 0) {
        shutdown(sockFd_, SHUT_RDWR);
        close(sockFd_);
        sockFd_ = -1;
    }
    ioGeneration_.fetch_add(1, std::memory_order_acq_rel);
    authenticated_ = false;
    keepaliveNextDue_ = std::chrono::steady_clock::time_point::max();
    keepaliveConsecutiveFailures_ = 0;
}

bool SshAdapter::reconnectAfterTransportFailure() {
    if (!isReactorThread() || !readerRunning_.load(std::memory_order_acquire) ||
        savedCfg_.host.empty()) {
        return false;
    }

    constexpr uint32_t kMaxAttempts = SshTerminalKeepalivePolicy::kMaxConsecutiveFailures;
    for (uint32_t attempt = 0; attempt < kMaxAttempts; ++attempt) {
        if (!readerRunning_.load(std::memory_order_acquire) ||
            connectCancelRequested_.load(std::memory_order_acquire)) {
            return false;
        }

        setState(ConnectionState::RECONNECTING,
                 "SSH transport lost, reconnecting [" +
                 std::to_string(attempt + 1) + "/" + std::to_string(kMaxAttempts) + "]");
        resetTransportForRecovery();
        const int ret = connectInternal(savedCfg_, true);
        if (ret == 0) {
            transportRecoveryRequested_.store(false, std::memory_order_release);
            OH_LOG_INFO(LOG_APP, "[SSH] transport recovery succeeded attempt=%{public}u",
                        attempt + 1);
            return true;
        }

        OH_LOG_WARN(LOG_APP,
                    "[SSH] transport recovery failed attempt=%{public}u rc=%{public}d",
                    attempt + 1, ret);
        if (attempt + 1 < kMaxAttempts) {
            std::unique_lock<std::mutex> waitLock(reactorCommandMutex_);
            reactorCommandCondition_.wait_for(
                waitLock,
                std::chrono::milliseconds(SshTerminalKeepalivePolicy::kRetryDelayMilliseconds),
                [this]() {
                    return !readerRunning_.load(std::memory_order_acquire) ||
                        connectCancelRequested_.load(std::memory_order_acquire);
                });
        }
    }

    stopTerminalInput();
    readerRunning_.store(false, std::memory_order_release);
    transportRecoveryRequested_.store(false, std::memory_order_release);
    setState(ConnectionState::ERROR, "SSH transport recovery failed");
    reactorCommandCondition_.notify_all();
    return false;
}

ConnectionState SshAdapter::getState() {
    return state_.load(std::memory_order_acquire);
}

void SshAdapter::requestConnectCancel() {
    connectCancelRequested_.store(true, std::memory_order_release);
}

// ============================================================
// 输入事件 (SSH 终端仅 sendText 有效)
// ============================================================

void SshAdapter::sendKey(uint32_t scancode, bool pressed) {
    // SSH 终端不直接处理按键扫描码, 通过 sendText 传递字符
    (void)scancode; (void)pressed;
}

void SshAdapter::sendMouse(int x, int y, MouseButton button, bool pressed) {
    (void)x; (void)y; (void)button; (void)pressed;
}

void SshAdapter::sendMouseWheel(int x, int y, int delta) {
    (void)x; (void)y; (void)delta;
}

void SshAdapter::sendText(const std::string& text) {
    (void)enqueueTerminalInput(reinterpret_cast<const uint8_t*>(text.data()),
                               text.size(), false, 0);
}

// ============================================================
// 编码能力
// ============================================================

bool SshAdapter::supportsCodec(CodecType codec) {
    (void)codec;
    return false;
}

std::vector<CodecType> SshAdapter::supportedCodecs() {
    return {};
}

// ============================================================
// SFTP 文件传输
// ============================================================

int SshAdapter::ensureSftpLocked(std::unique_lock<std::mutex>& sessionLock) {
    if (!assertSessionOwner("sftp")) {
        return ERR_SSH_SESSION_CLOSED;
    }
    if (!session_ || state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
        return ERR_SSH_SESSION_CLOSED;
    }
    if (sftp_) { return 0; }

    while ((sftp_ = libssh2_sftp_init(session_)) == nullptr) {
        int err = libssh2_session_last_errno(session_);
        if (err == LIBSSH2_ERROR_EAGAIN) {
            if (!yieldSftpSlice(sessionLock, 2, 1)) {
                OH_LOG_ERROR(LOG_APP, "[SFTP] 初始化超时");
                return ERR_SSH_CHANNEL_OPEN;
            }
            continue;
        }
        char* errMsg = nullptr;
        libssh2_session_last_error(session_, &errMsg, nullptr, 0);
        OH_LOG_ERROR(LOG_APP, "[SFTP] 初始化失败: err=%{public}d msg=%{public}s",
                     err, errMsg ? errMsg : "");
        return ERR_SSH_CHANNEL_OPEN;
    }

    OH_LOG_INFO(LOG_APP, "[SFTP] 子系统已初始化");
    return 0;
}

bool SshAdapter::yieldSftpSlice(std::unique_lock<std::mutex>& sessionLock,
                                int direction, int timeoutSec) {
    if (!sessionLock.owns_lock()) {
        return false;
    }
    sessionLock.unlock();
    int waitResult = 0;
    const bool onReactor = isReactorThread();
    if (direction >= 0) {
        // The owner reactor must remain responsive to terminal input while an
        // SFTP packet is waiting. Poll in <=5ms slices and drain one input
        // item between polls; no other thread enters libssh2.
        if (onReactor) {
            waitResult = waitSocketMilliseconds(direction, kReactorWaitSliceMs);
            drainInputQueueOnReactor();
            drainShellOutputOnReactor();
        } else {
            waitResult = waitSocket(direction, std::min(timeoutSec, 1));
        }
    } else {
        if (onReactor) {
            drainInputQueueOnReactor();
            drainShellOutputOnReactor();
        } else {
            std::this_thread::yield();
        }
    }
    sessionLock.lock();
    // sftp_ is intentionally allowed to be null while ensureSftpLocked() is
    // completing its first handshake. All other callers already own a live
    // handle and will fail their next libssh2 operation if it disappeared.
    // A reactor slice is intentionally only a cooperative yield. A short
    // poll timeout is not an SFTP failure; the caller retries the original
    // libssh2 operation while input remains prioritized between polls.
    const bool socketReady = onReactor ? waitResult != -1 && waitResult != -3
                                       : waitResult == 0;
    return socketReady && session_ != nullptr &&
        (!onReactor || readerRunning_.load(std::memory_order_acquire)) &&
        state_.load(std::memory_order_acquire) == ConnectionState::CONNECTED &&
        !connectCancelRequested_.load(std::memory_order_acquire);
}

int SshAdapter::sendFileData(const std::string& remotePath, const uint8_t* data, uint32_t len) {
    if (remotePath.empty() || (data == nullptr && len > 0)) {
        return -1;
    }
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        return runOnReactor([this, remotePath, data, len]() {
            return sendFileData(remotePath, data, len);
        });
    }
    const std::string pathId = SafeLog::HashForLog(remotePath);
    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    std::lock_guard<std::mutex> sftpLock(sftpOperationMutex_);
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    int rc = ensureSftpLocked(sessionLock);
    if (rc != 0) { return rc; }

    LIBSSH2_SFTP_HANDLE* handle = nullptr;
    while ((handle = libssh2_sftp_open(sftp_, remotePath.c_str(),
        LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC,
        LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SFTP_S_IWUSR |
        LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IROTH)) == nullptr) {
        int err = libssh2_session_last_errno(session_);
        if (err == LIBSSH2_ERROR_EAGAIN) {
            if (!yieldSftpSlice(sessionLock, 2, 1)) {
                return ERR_SSH_WRITE_FAILED;
            }
            continue;
        }
        OH_LOG_ERROR(LOG_APP, "[SFTP] 打开远端写文件失败: pathId=%{public}s err=%{public}d",
                     pathId.c_str(), err);
        return ERR_SSH_WRITE_FAILED;
    }

    uint32_t total = 0;
    while (total < len) {
        size_t chunk = std::min<size_t>(kSftpSliceBytes, len - total);
        ssize_t written = libssh2_sftp_write(handle,
            reinterpret_cast<const char*>(data + total), chunk);
        if (written == LIBSSH2_ERROR_EAGAIN) {
            if (!yieldSftpSlice(sessionLock, 1, 1)) {
                libssh2_sftp_close(handle);
                return ERR_SSH_WRITE_FAILED;
            }
            continue;
        }
        if (written <= 0) {
            OH_LOG_ERROR(LOG_APP, "[SFTP] 写入失败: pathId=%{public}s ret=%{public}zd",
                         pathId.c_str(), written);
            libssh2_sftp_close(handle);
            return ERR_SSH_WRITE_FAILED;
        }
        total += static_cast<uint32_t>(written);
        if (total < len && !yieldSftpSlice(sessionLock, -1, 0)) {
            libssh2_sftp_close(handle);
            return ERR_SSH_WRITE_FAILED;
        }
    }

    // A partial is eligible for atomic commit only after the server has
    // flushed its file handle. Treat an unsupported fsync extension as an
    // explicit capability failure instead of silently claiming durability.
    int syncRc = LIBSSH2_ERROR_EAGAIN;
    while ((syncRc = libssh2_sftp_fsync(handle)) == LIBSSH2_ERROR_EAGAIN) {
        if (!yieldSftpSlice(sessionLock, 2, 1)) {
            libssh2_sftp_close(handle);
            return ERR_SSH_WRITE_FAILED;
        }
    }
    if (syncRc != 0) {
        const unsigned long sftpError = libssh2_sftp_last_error(sftp_);
        while (libssh2_sftp_close(handle) == LIBSSH2_ERROR_EAGAIN) {
            if (!yieldSftpSlice(sessionLock, 2, 1)) { break; }
        }
        return sftpError == LIBSSH2_FX_OP_UNSUPPORTED
            ? ERR_SSH_SFTP_DURABILITY_UNSUPPORTED : ERR_SSH_WRITE_FAILED;
    }

    while ((rc = libssh2_sftp_close(handle)) == LIBSSH2_ERROR_EAGAIN) {
        if (!yieldSftpSlice(sessionLock, 2, 1)) {
            libssh2_sftp_close(handle);
            return ERR_SSH_WRITE_FAILED;
        }
    }
    OH_LOG_INFO(LOG_APP, "[SFTP] 上传完成: pathId=%{public}s bytes=%{public}u rc=%{public}d",
                pathId.c_str(), len, rc);
    return rc == 0 ? static_cast<int>(len) : ERR_SSH_WRITE_FAILED;
}

int SshAdapter::writeRemoteFileChunk(const std::string& remotePath, const uint8_t* data,
                                     uint32_t len, uint64_t offset, bool truncate) {
    if (remotePath.empty() || (data == nullptr && len > 0)) {
        return -1;
    }
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        return runOnReactor([this, remotePath, data, len, offset, truncate]() {
            return writeRemoteFileChunk(remotePath, data, len, offset, truncate);
        });
    }
    const std::string pathId = SafeLog::HashForLog(remotePath);
    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    std::lock_guard<std::mutex> sftpLock(sftpOperationMutex_);
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    int rc = ensureSftpLocked(sessionLock);
    if (rc != 0) { return rc; }

    unsigned long flags = LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT;
    if (truncate) { flags |= LIBSSH2_FXF_TRUNC; }
    LIBSSH2_SFTP_HANDLE* handle = nullptr;
    while ((handle = libssh2_sftp_open(sftp_, remotePath.c_str(), flags,
        LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SFTP_S_IWUSR |
        LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IROTH)) == nullptr) {
        int err = libssh2_session_last_errno(session_);
        if (err == LIBSSH2_ERROR_EAGAIN) {
            if (!yieldSftpSlice(sessionLock, 2, 1)) {
                return ERR_SSH_WRITE_FAILED;
            }
            continue;
        }
        OH_LOG_ERROR(LOG_APP, "[SFTP] 打开分块写文件失败: pathId=%{public}s err=%{public}d",
                     pathId.c_str(), err);
        return ERR_SSH_WRITE_FAILED;
    }

    libssh2_sftp_seek64(handle, offset);
    uint32_t total = 0;
    while (total < len) {
        size_t chunk = std::min<size_t>(kSftpSliceBytes, len - total);
        ssize_t written = libssh2_sftp_write(handle,
            reinterpret_cast<const char*>(data + total), chunk);
        if (written == LIBSSH2_ERROR_EAGAIN) {
            if (!yieldSftpSlice(sessionLock, 1, 1)) {
                libssh2_sftp_close(handle);
                return ERR_SSH_WRITE_FAILED;
            }
            continue;
        }
        if (written <= 0) {
            OH_LOG_ERROR(LOG_APP, "[SFTP] 分块写入失败: pathId=%{public}s offset=%{public}llu ret=%{public}zd",
                         pathId.c_str(),
                         static_cast<unsigned long long>(offset + total),
                         written);
            libssh2_sftp_close(handle);
            return ERR_SSH_WRITE_FAILED;
        }
        total += static_cast<uint32_t>(written);
        if (total < len && !yieldSftpSlice(sessionLock, -1, 0)) {
            libssh2_sftp_close(handle);
            return ERR_SSH_WRITE_FAILED;
        }
    }

    int syncRc = LIBSSH2_ERROR_EAGAIN;
    while ((syncRc = libssh2_sftp_fsync(handle)) == LIBSSH2_ERROR_EAGAIN) {
        if (!yieldSftpSlice(sessionLock, 2, 1)) {
            libssh2_sftp_close(handle);
            return ERR_SSH_WRITE_FAILED;
        }
    }
    if (syncRc != 0) {
        const unsigned long sftpError = libssh2_sftp_last_error(sftp_);
        while (libssh2_sftp_close(handle) == LIBSSH2_ERROR_EAGAIN) {
            if (!yieldSftpSlice(sessionLock, 2, 1)) { break; }
        }
        return sftpError == LIBSSH2_FX_OP_UNSUPPORTED
            ? ERR_SSH_SFTP_DURABILITY_UNSUPPORTED : ERR_SSH_WRITE_FAILED;
    }

    while ((rc = libssh2_sftp_close(handle)) == LIBSSH2_ERROR_EAGAIN) {
        if (!yieldSftpSlice(sessionLock, 2, 1)) {
            libssh2_sftp_close(handle);
            return ERR_SSH_WRITE_FAILED;
        }
    }
    return rc == 0 ? static_cast<int>(total) : ERR_SSH_WRITE_FAILED;
}

int SshAdapter::listRemoteDir(const std::string& remotePath, std::vector<SftpFileEntry>& entries) {
    entries.clear();
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        return runOnReactor([this, remotePath, &entries]() {
            return listRemoteDir(remotePath, entries);
        });
    }
    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    std::lock_guard<std::mutex> sftpLock(sftpOperationMutex_);
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    int rc = ensureSftpLocked(sessionLock);
    if (rc != 0) { return rc; }

    std::string dirPath = remotePath.empty() ? "." : remotePath;
    const std::string pathId = SafeLog::HashForLog(dirPath);
    LIBSSH2_SFTP_HANDLE* handle = nullptr;
    while ((handle = libssh2_sftp_opendir(sftp_, dirPath.c_str())) == nullptr) {
        int err = libssh2_session_last_errno(session_);
        if (err == LIBSSH2_ERROR_EAGAIN) {
            if (!yieldSftpSlice(sessionLock, 2, 1)) {
                return ERR_SSH_READ_FAILED;
            }
            continue;
        }
        OH_LOG_ERROR(LOG_APP, "[SFTP] 打开目录失败: pathId=%{public}s err=%{public}d",
                     pathId.c_str(), err);
        return ERR_SSH_READ_FAILED;
    }

    bool readFailed = false;
    while (true) {
        char nameBuf[4096] = {0};
        char longEntryBuf[4096] = {0};
        LIBSSH2_SFTP_ATTRIBUTES attrs;
        memset(&attrs, 0, sizeof(attrs));
        int n = libssh2_sftp_readdir_ex(handle, nameBuf, sizeof(nameBuf) - 1,
            longEntryBuf, sizeof(longEntryBuf) - 1, &attrs);
        if (n == LIBSSH2_ERROR_EAGAIN) {
            if (!yieldSftpSlice(sessionLock, 2, 1)) {
                libssh2_sftp_closedir(handle);
                return ERR_SSH_READ_FAILED;
            }
            continue;
        }
        if (n < 0) {
            OH_LOG_WARN(LOG_APP, "[SFTP] 读取目录中断: pathId=%{public}s ret=%{public}d",
                        pathId.c_str(), n);
            readFailed = true;
            break;
        }
        if (n == 0) { break; }
        std::string name(nameBuf, static_cast<size_t>(n));
        if (name == "." || name == "..") { continue; }

        SftpFileEntry entry;
        entry.name = name;
        if (dirPath == "/" || dirPath.empty()) {
            entry.path = "/" + name;
        } else {
            entry.path = dirPath + "/" + name;
        }
        entry.isDirectory = (attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) &&
            LIBSSH2_SFTP_S_ISDIR(attrs.permissions);
        if (attrs.flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) {
            entry.isSymbolicLink = LIBSSH2_SFTP_S_ISLNK(attrs.permissions);
            entry.isSpecialFile = !entry.isDirectory && !entry.isSymbolicLink &&
                !LIBSSH2_SFTP_S_ISREG(attrs.permissions);
            entry.mode = static_cast<int64_t>(attrs.permissions);
        }
        entry.size = (attrs.flags & LIBSSH2_SFTP_ATTR_SIZE) &&
                attrs.filesize <= static_cast<uint64_t>(std::numeric_limits<int64_t>::max())
            ? static_cast<int64_t>(attrs.filesize) : -1;
        if (attrs.flags & LIBSSH2_SFTP_ATTR_UIDGID) {
            entry.uid = attrs.uid <= static_cast<unsigned long>(std::numeric_limits<int64_t>::max())
                ? static_cast<int64_t>(attrs.uid) : -1;
            entry.gid = attrs.gid <= static_cast<unsigned long>(std::numeric_limits<int64_t>::max())
                ? static_cast<int64_t>(attrs.gid) : -1;
        }
        // A missing mtime is not an epoch timestamp. Preserve the unknown
        // state so resume identity checks can fail closed instead of treating
        // an unavailable server attribute as a valid identity.
        if (attrs.flags & LIBSSH2_SFTP_ATTR_ACMODTIME) {
            entry.atime = attrs.atime <= static_cast<unsigned long>(std::numeric_limits<int64_t>::max())
                ? static_cast<int64_t>(attrs.atime) : -1;
            entry.mtime = attrs.mtime <= static_cast<unsigned long>(std::numeric_limits<int64_t>::max())
                ? static_cast<int64_t>(attrs.mtime) : -1;
        }
        entries.push_back(entry);
        if (!yieldSftpSlice(sessionLock, -1, 0)) {
            libssh2_sftp_closedir(handle);
            return ERR_SSH_READ_FAILED;
        }
    }

    while ((rc = libssh2_sftp_closedir(handle)) == LIBSSH2_ERROR_EAGAIN) {
        if (!yieldSftpSlice(sessionLock, 2, 1)) {
            return ERR_SSH_READ_FAILED;
        }
    }
    if (rc != 0 || readFailed) { return ERR_SSH_READ_FAILED; }
    OH_LOG_INFO(LOG_APP, "[SFTP] 目录读取完成: pathId=%{public}s count=%{public}zu",
                pathId.c_str(), entries.size());
    return static_cast<int>(entries.size());
}

int SshAdapter::readRemoteFile(const std::string& remotePath, std::vector<uint8_t>& out) {
    out.clear();
    if (remotePath.empty()) { return -1; }
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        return runOnReactor([this, remotePath, &out]() {
            return readRemoteFile(remotePath, out);
        });
    }
    const std::string pathId = SafeLog::HashForLog(remotePath);
    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    std::lock_guard<std::mutex> sftpLock(sftpOperationMutex_);
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    int rc = ensureSftpLocked(sessionLock);
    if (rc != 0) { return rc; }

    LIBSSH2_SFTP_HANDLE* handle = nullptr;
    while ((handle = libssh2_sftp_open(sftp_, remotePath.c_str(), LIBSSH2_FXF_READ, 0)) == nullptr) {
        int err = libssh2_session_last_errno(session_);
        if (err == LIBSSH2_ERROR_EAGAIN) {
            if (!yieldSftpSlice(sessionLock, 2, 1)) {
                return ERR_SSH_READ_FAILED;
            }
            continue;
        }
        OH_LOG_ERROR(LOG_APP, "[SFTP] 打开远端读文件失败: pathId=%{public}s err=%{public}d",
                     pathId.c_str(), err);
        return ERR_SSH_READ_FAILED;
    }

    std::vector<uint8_t> buf(kSftpSliceBytes);
    while (true) {
        ssize_t n = libssh2_sftp_read(handle, reinterpret_cast<char*>(buf.data()), buf.size());
        if (n == LIBSSH2_ERROR_EAGAIN) {
            if (!yieldSftpSlice(sessionLock, 0, 1)) {
                libssh2_sftp_close(handle);
                return ERR_SSH_READ_FAILED;
            }
            continue;
        }
        if (n < 0) {
            OH_LOG_ERROR(LOG_APP, "[SFTP] 读取文件失败: pathId=%{public}s ret=%{public}zd",
                         pathId.c_str(), n);
            libssh2_sftp_close(handle);
            return ERR_SSH_READ_FAILED;
        }
        if (n == 0) { break; }
        out.insert(out.end(), buf.begin(), buf.begin() + n);
        if (out.size() > 100 * 1024 * 1024) {
            OH_LOG_WARN(LOG_APP, "[SFTP] 下载超过 100MB, 已中止: pathId=%{public}s", pathId.c_str());
            libssh2_sftp_close(handle);
            out.clear();
            return -2;
        }
        if (!yieldSftpSlice(sessionLock, -1, 0)) {
            libssh2_sftp_close(handle);
            out.clear();
            return ERR_SSH_READ_FAILED;
        }
    }

    while ((rc = libssh2_sftp_close(handle)) == LIBSSH2_ERROR_EAGAIN) {
        if (!yieldSftpSlice(sessionLock, 2, 1)) {
            out.clear();
            return ERR_SSH_READ_FAILED;
        }
    }
    OH_LOG_INFO(LOG_APP, "[SFTP] 下载完成: pathId=%{public}s bytes=%{public}zu rc=%{public}d",
                pathId.c_str(), out.size(), rc);
    return rc == 0 ? static_cast<int>(out.size()) : ERR_SSH_READ_FAILED;
}

int SshAdapter::readRemoteFileChunk(const std::string& remotePath, uint64_t offset,
                                    uint32_t maxLen, std::vector<uint8_t>& out) {
    out.clear();
    if (remotePath.empty() || maxLen == 0 || maxLen > 8 * 1024 * 1024) { return -1; }
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        return runOnReactor([this, remotePath, offset, maxLen, &out]() {
            return readRemoteFileChunk(remotePath, offset, maxLen, out);
        });
    }
    const std::string pathId = SafeLog::HashForLog(remotePath);
    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    std::lock_guard<std::mutex> sftpLock(sftpOperationMutex_);
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    int rc = ensureSftpLocked(sessionLock);
    if (rc != 0) { return rc; }

    LIBSSH2_SFTP_HANDLE* handle = nullptr;
    while ((handle = libssh2_sftp_open(sftp_, remotePath.c_str(), LIBSSH2_FXF_READ, 0)) == nullptr) {
        int err = libssh2_session_last_errno(session_);
        if (err == LIBSSH2_ERROR_EAGAIN) {
            if (!yieldSftpSlice(sessionLock, 2, 1)) {
                return ERR_SSH_READ_FAILED;
            }
            continue;
        }
        OH_LOG_ERROR(LOG_APP, "[SFTP] 打开远端分块读文件失败: pathId=%{public}s err=%{public}d",
                     pathId.c_str(), err);
        return ERR_SSH_READ_FAILED;
    }

    libssh2_sftp_seek64(handle, offset);
    std::vector<uint8_t> buf(std::min<size_t>(kSftpSliceBytes, maxLen));
    while (out.size() < maxLen) {
        const size_t remain = static_cast<size_t>(maxLen) - out.size();
        const size_t want = std::min(buf.size(), remain);
        ssize_t n = libssh2_sftp_read(handle, reinterpret_cast<char*>(buf.data()), want);
        if (n == LIBSSH2_ERROR_EAGAIN) {
            if (!yieldSftpSlice(sessionLock, 0, 1)) {
                libssh2_sftp_close(handle);
                return ERR_SSH_READ_FAILED;
            }
            continue;
        }
        if (n < 0) {
            OH_LOG_ERROR(LOG_APP, "[SFTP] 分块读取文件失败: pathId=%{public}s offset=%{public}llu ret=%{public}zd",
                         pathId.c_str(),
                         static_cast<unsigned long long>(offset + out.size()),
                         n);
            libssh2_sftp_close(handle);
            return ERR_SSH_READ_FAILED;
        }
        if (n == 0) { break; }
        out.insert(out.end(), buf.begin(), buf.begin() + n);
        if (out.size() < maxLen && !yieldSftpSlice(sessionLock, -1, 0)) {
            libssh2_sftp_close(handle);
            out.clear();
            return ERR_SSH_READ_FAILED;
        }
    }

    while ((rc = libssh2_sftp_close(handle)) == LIBSSH2_ERROR_EAGAIN) {
        if (!yieldSftpSlice(sessionLock, 2, 1)) {
            out.clear();
            return ERR_SSH_READ_FAILED;
        }
    }
    return rc == 0 ? static_cast<int>(out.size()) : ERR_SSH_READ_FAILED;
}

int SshAdapter::removeRemoteFile(const std::string& remotePath) {
    if (remotePath.empty()) { return ERR_SSH_WRITE_FAILED; }
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        return runOnReactor([this, remotePath]() {
            return removeRemoteFile(remotePath);
        });
    }
    const std::string pathId = SafeLog::HashForLog(remotePath);
    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    std::lock_guard<std::mutex> sftpLock(sftpOperationMutex_);
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    int rc = ensureSftpLocked(sessionLock);
    if (rc != 0) { return rc; }
    while ((rc = libssh2_sftp_unlink(sftp_, remotePath.c_str())) == LIBSSH2_ERROR_EAGAIN) {
        if (!yieldSftpSlice(sessionLock, 2, 1)) {
            return ERR_SSH_WRITE_FAILED;
        }
    }
    OH_LOG_INFO(LOG_APP, "[SFTP] 删除文件: pathId=%{public}s rc=%{public}d", pathId.c_str(), rc);
    return rc == 0 ? 0 : ERR_SSH_WRITE_FAILED;
}

int SshAdapter::removeRemoteDir(const std::string& remotePath) {
    if (remotePath.empty()) { return ERR_SSH_WRITE_FAILED; }
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        return runOnReactor([this, remotePath]() {
            return removeRemoteDir(remotePath);
        });
    }
    const std::string pathId = SafeLog::HashForLog(remotePath);
    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    std::lock_guard<std::mutex> sftpLock(sftpOperationMutex_);
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    int rc = ensureSftpLocked(sessionLock);
    if (rc != 0) { return rc; }
    while ((rc = libssh2_sftp_rmdir(sftp_, remotePath.c_str())) == LIBSSH2_ERROR_EAGAIN) {
        if (!yieldSftpSlice(sessionLock, 2, 1)) {
            return ERR_SSH_WRITE_FAILED;
        }
    }
    OH_LOG_INFO(LOG_APP, "[SFTP] 删除目录: pathId=%{public}s rc=%{public}d", pathId.c_str(), rc);
    return rc == 0 ? 0 : ERR_SSH_WRITE_FAILED;
}

int SshAdapter::makeRemoteDir(const std::string& remotePath) {
    if (remotePath.empty()) { return ERR_SSH_WRITE_FAILED; }
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        return runOnReactor([this, remotePath]() {
            return makeRemoteDir(remotePath);
        });
    }
    const std::string pathId = SafeLog::HashForLog(remotePath);
    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    std::lock_guard<std::mutex> sftpLock(sftpOperationMutex_);
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    int rc = ensureSftpLocked(sessionLock);
    if (rc != 0) { return rc; }
    while ((rc = libssh2_sftp_mkdir(sftp_, remotePath.c_str(),
        LIBSSH2_SFTP_S_IRWXU | LIBSSH2_SFTP_S_IRGRP |
        LIBSSH2_SFTP_S_IXGRP | LIBSSH2_SFTP_S_IROTH | LIBSSH2_SFTP_S_IXOTH)) == LIBSSH2_ERROR_EAGAIN) {
        if (!yieldSftpSlice(sessionLock, 2, 1)) {
            return ERR_SSH_WRITE_FAILED;
        }
    }
    OH_LOG_INFO(LOG_APP, "[SFTP] 创建目录: pathId=%{public}s rc=%{public}d", pathId.c_str(), rc);
    return rc == 0 ? 0 : ERR_SSH_WRITE_FAILED;
}

int SshAdapter::renameRemotePath(const std::string& oldPath, const std::string& newPath) {
    if (oldPath.empty() || newPath.empty()) { return ERR_SSH_WRITE_FAILED; }
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        return runOnReactor([this, oldPath, newPath]() {
            return renameRemotePath(oldPath, newPath);
        });
    }
    const std::string oldPathId = SafeLog::HashForLog(oldPath);
    const std::string newPathId = SafeLog::HashForLog(newPath);
    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    std::lock_guard<std::mutex> sftpLock(sftpOperationMutex_);
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    int rc = ensureSftpLocked(sessionLock);
    if (rc != 0) { return rc; }
    while ((rc = libssh2_sftp_rename(sftp_, oldPath.c_str(), newPath.c_str())) == LIBSSH2_ERROR_EAGAIN) {
        if (!yieldSftpSlice(sessionLock, 2, 1)) {
            return ERR_SSH_WRITE_FAILED;
        }
    }
    OH_LOG_INFO(LOG_APP, "[SFTP] 重命名: %{public}s -> %{public}s rc=%{public}d",
                oldPathId.c_str(), newPathId.c_str(), rc);
    return rc == 0 ? 0 : ERR_SSH_WRITE_FAILED;
}

int SshAdapter::renameRemotePathAtomic(const std::string& oldPath,
                                       const std::string& newPath) {
    if (oldPath.empty() || newPath.empty()) { return ERR_SSH_WRITE_FAILED; }
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        return runOnReactor([this, oldPath, newPath]() {
            return renameRemotePathAtomic(oldPath, newPath);
        });
    }
    const std::string oldPathId = SafeLog::HashForLog(oldPath);
    const std::string newPathId = SafeLog::HashForLog(newPath);
    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    std::lock_guard<std::mutex> sftpLock(sftpOperationMutex_);
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    int rc = ensureSftpLocked(sessionLock);
    if (rc != 0) { return rc; }
    while ((rc = libssh2_sftp_posix_rename(sftp_, oldPath.c_str(), newPath.c_str())) ==
           LIBSSH2_ERROR_EAGAIN) {
        if (!yieldSftpSlice(sessionLock, 2, 1)) {
            return ERR_SSH_WRITE_FAILED;
        }
    }
    const unsigned long sftpError = libssh2_sftp_last_error(sftp_);
    OH_LOG_INFO(LOG_APP, "[SFTP] 原子重命名: %{public}s -> %{public}s rc=%{public}d sftp=%{public}lu",
                oldPathId.c_str(), newPathId.c_str(), rc, sftpError);
    if (rc == 0) { return 0; }
    return sftpError == LIBSSH2_FX_OP_UNSUPPORTED
        ? ERR_SSH_SFTP_DURABILITY_UNSUPPORTED : ERR_SSH_WRITE_FAILED;
}

// ============================================================
// 回调
// ============================================================

void SshAdapter::setVideoCallback(VideoFrameCallback callback) {
    (void)callback;
}

void SshAdapter::setAudioCallback(AudioDataCallback callback) {
    (void)callback;
}

void SshAdapter::setConnectionStateCallback(ConnectionStateCallback callback) {
    std::lock_guard<std::mutex> lock(stateCallbackMutex_);
    stateCallback_ = std::move(callback);
}

// ============================================================
// SSH 终端数据读写 (加密通道)
// ============================================================

int SshAdapter::sendData(const uint8_t* data, size_t len) {
    if (data == nullptr && len > 0) { return ERR_SSH_WRITE_FAILED; }
    if (len == 0) { return 0; }
    const SshTerminalInputResult result = enqueueTerminalInput(
        data, len, false, diagnostics_.sessionGeneration());
    return result.accepted() ? static_cast<int>(len) : ERR_SSH_WRITE_FAILED;
}

SshTerminalInputResult SshAdapter::enqueueTerminalInput(
    const uint8_t* data, size_t len, bool control, uint64_t expectedGeneration,
    bool ordered, bool orderedEnd) {
    SshTerminalInputResult result;
    result.generation = diagnostics_.sessionGeneration();
    if (data == nullptr || len == 0 || len > kInputQueueMaxBytes) {
        result.status = SshTerminalInputStatus::INVALID;
        return result;
    }
    if (expectedGeneration != 0 && expectedGeneration != result.generation) {
        result.status = SshTerminalInputStatus::STALE_GENERATION;
        return result;
    }
    if (!terminalInputAccepting_.load(std::memory_order_acquire) ||
        !terminalInputRunning_.load(std::memory_order_acquire) ||
        !readerRunning_.load(std::memory_order_acquire) ||
        state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
        result.status = SshTerminalInputStatus::SESSION_CLOSED;
        return result;
    }

    {
        std::lock_guard<std::mutex> lock(inputQueueMutex_);
        if (!terminalInputAccepting_.load(std::memory_order_acquire) ||
            !terminalInputRunning_.load(std::memory_order_acquire) ||
            !readerRunning_.load(std::memory_order_acquire) ||
            state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
            result.status = SshTerminalInputStatus::SESSION_CLOSED;
            result.queueDepth = inputQueue_.size();
            result.queueBytes = inputQueueBytes_;
            return result;
        }
        const auto admission = SshTerminalInputQueuePolicy::admit(
            inputQueue_.size(), inputQueueBytes_, inputQueueControlItems_,
            inputQueueControlBytes_, inputQueueDataItems_, inputQueueDataBytes_,
            len, control, expectedGeneration, result.generation);
        if (admission != SshTerminalInputQueuePolicy::Admission::ACCEPTED) {
            result.status = admission == SshTerminalInputQueuePolicy::Admission::STALE_GENERATION
                ? SshTerminalInputStatus::STALE_GENERATION
                : SshTerminalInputStatus::QUEUE_FULL;
            result.queueDepth = inputQueue_.size();
            result.queueBytes = inputQueueBytes_;
            return result;
        }

        TerminalInputItem item;
        item.sequence = diagnostics_.beginInput(len);
        item.generation = result.generation;
        item.control = control;
        item.ordered = ordered;
        item.orderedEnd = orderedEnd;
        try {
            item.bytes.assign(data, data + len);
        } catch (...) {
            result.status = SshTerminalInputStatus::QUEUE_FULL;
            result.queueDepth = inputQueue_.size();
            result.queueBytes = inputQueueBytes_;
            return result;
        }
        inputQueue_.push_back(std::move(item));
        inputQueueBytes_ += len;
        if (control) {
            inputQueueControlItems_++;
            inputQueueControlBytes_ += len;
        } else {
            inputQueueDataItems_++;
            inputQueueDataBytes_ += len;
        }
        diagnostics_.recordInputQueue(inputQueue_.size(), inputQueueBytes_);
        // Queue insertion and its diagnostic publication share one
        // linearization point. Producers cannot report sequence N+1 before N
        // has become visible in the FIFO, so reorder counters reflect the
        // actual admission order rather than scheduler timing.
        result.sequence = inputQueue_.back().sequence;
        diagnostics_.recordNativeEnqueue(result.sequence);
        result.status = SshTerminalInputStatus::ACCEPTED;
        result.queueDepth = inputQueue_.size();
        result.queueBytes = inputQueueBytes_;
        inputQueueCondition_.notify_one();
    }
    reactorCommandCondition_.notify_one();
    return result;
}

int SshAdapter::writeTerminalData(const uint8_t* data, size_t len, uint64_t sequence,
                                  bool fromTerminalInput) {
    if (data == nullptr && len > 0) { return ERR_SSH_WRITE_FAILED; }
    if (len == 0) { return 0; }
    if (readerRunning_.load(std::memory_order_acquire) &&
        !assertSessionOwner("channel_write")) {
        return ERR_SSH_SESSION_CLOSED;
    }
    const auto lockWaitStartedAt = std::chrono::steady_clock::now();
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    const auto lockWaitNs = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now() - lockWaitStartedAt).count();
    if (lockWaitNs >= 8'000'000) {
        diagnostics_.recordOwnerStall();
    }
    if ((fromTerminalInput &&
         (!terminalInputAccepting_.load(std::memory_order_acquire) ||
          !terminalInputRunning_.load(std::memory_order_acquire))) ||
        !channel_ || sockFd_ < 0 ||
        state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
        return ERR_SSH_SESSION_CLOSED;
    }
    ssize_t total = 0;
    while (total < static_cast<ssize_t>(len)) {
        if (fromTerminalInput &&
            (!terminalInputAccepting_.load(std::memory_order_acquire) ||
             !terminalInputRunning_.load(std::memory_order_acquire))) {
            return ERR_SSH_SESSION_CLOSED;
        }
        ssize_t rc = 0;
        {
            // This fence is the write-side half of disconnect()'s
            // linearization point. Recheck admission while holding it so a
            // teardown request cannot slip between the check and the actual
            // libssh2 call.
            std::lock_guard<std::mutex> writeFence(inputWriteFenceMutex_);
            if (fromTerminalInput &&
                (!terminalInputAccepting_.load(std::memory_order_acquire) ||
                 !terminalInputRunning_.load(std::memory_order_acquire))) {
                return ERR_SSH_SESSION_CLOSED;
            }
            if (!channel_ || sockFd_ < 0 ||
                state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
                return ERR_SSH_SESSION_CLOSED;
            }
            diagnostics_.recordWriteAttempt(sequence);
            rc = libssh2_channel_write(channel_,
                reinterpret_cast<const char*>(data) + total, len - total);
        }
        if (rc == LIBSSH2_ERROR_EAGAIN) {
            diagnostics_.recordWriteEagain();
            if (fromTerminalInput &&
                (!terminalInputAccepting_.load(std::memory_order_acquire) ||
                 !terminalInputRunning_.load(std::memory_order_acquire))) {
                return ERR_SSH_SESSION_CLOSED;
            }
            sessionLock.unlock();
            int waitResult = 0;
            if (isReactorThread()) {
                waitResult = waitSocketMilliseconds(1, kReactorWaitSliceMs);
                // The write loop is the only place where the owner can be
                // waiting for channel writability. Give a control key one
                // chance between each short socket slice.
                drainInputQueueOnReactor();
            } else {
                waitResult = waitSocket(1, 1);
            }
            sessionLock.lock();
            if (waitResult == -1 || waitResult == -3 ||
                (!isReactorThread() && waitResult != 0)) {
                return ERR_SSH_WRITE_FAILED;
            }
            continue;
        }
        if (rc < 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] libssh2_channel_write 失败: %{public}zd", rc);
            return ERR_SSH_WRITE_FAILED;
        }
        total += rc;
    }
    diagnostics_.recordWriteComplete(sequence, static_cast<size_t>(total));
    return static_cast<int>(total);
}

void SshAdapter::startTerminalInput() {
    bool expected = false;
    if (!terminalInputRunning_.compare_exchange_strong(expected, true,
                                                     std::memory_order_acq_rel)) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(inputQueueMutex_);
        terminalInputAccepting_.store(true, std::memory_order_release);
    }
    diagnostics_.markInputQueueInstrumentation();
    // Input is drained by the session owner (reader/reactor) thread. Keeping
    // a second libssh2 writer thread would reintroduce cross-thread channel
    // calls and make SFTP fairness depend on mutex timing.
    reactorCommandCondition_.notify_one();
    OH_LOG_INFO(LOG_APP, "[SSH] input writer 已并入 session owner reactor");
}

void SshAdapter::suspendTerminalInput() {
    terminalInputAccepting_.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> lock(inputQueueMutex_);
    clearInputQueueLocked(true);
    reactorCommandCondition_.notify_all();
}

void SshAdapter::resumeTerminalInput() {
    if (state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
        return;
    }
    if (!terminalInputRunning_.load(std::memory_order_acquire)) {
        startTerminalInput();
        return;
    }
    terminalInputAccepting_.store(true, std::memory_order_release);
    reactorCommandCondition_.notify_one();
}

void SshAdapter::stopTerminalInput() {
    terminalInputAccepting_.store(false, std::memory_order_release);
    terminalInputRunning_.store(false, std::memory_order_release);
    inputQueueCondition_.notify_all();
    reactorCommandCondition_.notify_all();
    std::lock_guard<std::mutex> lock(inputQueueMutex_);
    clearInputQueueLocked(true);
}

void SshAdapter::rejectTerminalInput() {
    std::lock_guard<std::mutex> lock(inputQueueMutex_);
    terminalInputAccepting_.store(false, std::memory_order_release);
}

void SshAdapter::clearInputQueueLocked(bool recordLoss) {
    if (recordLoss) {
        for (const TerminalInputItem& item : inputQueue_) {
            (void)item;
            diagnostics_.recordLoss();
        }
    }
    inputQueue_.clear();
    inputQueueBytes_ = 0;
    inputQueueControlItems_ = 0;
    inputQueueControlBytes_ = 0;
    inputQueueDataItems_ = 0;
    inputQueueDataBytes_ = 0;
    orderedInputActive_.store(false, std::memory_order_release);
    diagnostics_.recordInputQueue(0, 0);
}

bool SshAdapter::isReactorThread() const {
    return reactorThreadId_ == std::this_thread::get_id();
}

bool SshAdapter::assertSessionOwner(const char* operation) const noexcept {
    if (isReactorThread()) {
        return true;
    }
    OH_LOG_ERROR(LOG_APP,
        "[SSH] libssh2 owner violation operation=%{public}s running=%{public}s alive=%{public}s",
        operation != nullptr ? operation : "unknown",
        readerRunning_.load(std::memory_order_acquire) ? "yes" : "no",
        reactorAlive_.load(std::memory_order_acquire) ? "yes" : "no");
    return false;
}

void SshAdapter::drainInputQueueOnReactor() {
    if (!terminalInputRunning_.load(std::memory_order_acquire)) { return; }
    TerminalInputItem item;
    {
        std::lock_guard<std::mutex> lock(inputQueueMutex_);
        if (inputQueue_.empty()) { return; }
        // A bracketed paste is one ordered transaction. Controls/data that
        // were already queued before its first item may still run first, but
        // once the transaction starts select the next ordered item explicitly.
        // The ordered item may be temporarily absent while ArkTS is retrying
        // a queue-full closing marker; never let a later control split it.
        auto selected = inputQueue_.begin();
        if (orderedInputActive_.load(std::memory_order_acquire)) {
            selected = std::find_if(inputQueue_.begin(), inputQueue_.end(),
                [](const TerminalInputItem& queued) { return queued.ordered; });
            if (selected == inputQueue_.end()) {
                return;
            }
        } else {
            const auto firstOrdered = std::find_if(inputQueue_.begin(), inputQueue_.end(),
                [](const TerminalInputItem& queued) { return queued.ordered; });
            if (firstOrdered != inputQueue_.end()) {
                // Preserve FIFO for all input admitted before the paste.
                selected = std::min_element(inputQueue_.begin(), firstOrdered,
                    [](const TerminalInputItem& left, const TerminalInputItem& right) {
                        return left.sequence < right.sequence;
                    });
            } else {
                // Outside a paste transaction controls retain the low-latency
                // reserved lane and may preempt ordinary data.
                selected = std::find_if(inputQueue_.begin(), inputQueue_.end(),
                    [](const TerminalInputItem& queued) { return queued.control; });
                if (selected == inputQueue_.end()) {
                    selected = inputQueue_.begin();
                }
            }
        }
        item = std::move(*selected);
        inputQueue_.erase(selected);
        inputQueueBytes_ -= item.bytes.size();
        if (item.control) {
            if (inputQueueControlItems_ > 0) { inputQueueControlItems_--; }
            inputQueueControlBytes_ = inputQueueControlBytes_ >= item.bytes.size()
                ? inputQueueControlBytes_ - item.bytes.size() : 0;
        } else {
            if (inputQueueDataItems_ > 0) { inputQueueDataItems_--; }
            inputQueueDataBytes_ = inputQueueDataBytes_ >= item.bytes.size()
                ? inputQueueDataBytes_ - item.bytes.size() : 0;
        }
        diagnostics_.recordInputQueue(inputQueue_.size(), inputQueueBytes_);
    }
    if (item.ordered) {
        orderedInputActive_.store(!item.orderedEnd, std::memory_order_release);
    }
    if (!terminalInputAccepting_.load(std::memory_order_acquire) ||
        !terminalInputRunning_.load(std::memory_order_acquire) ||
        item.generation != diagnostics_.sessionGeneration() ||
        state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
        diagnostics_.recordLoss();
        return;
    }
    const int result = writeTerminalData(item.bytes.data(), item.bytes.size(), item.sequence, true);
    if (result < 0) {
        diagnostics_.recordLoss();
    }
}

void SshAdapter::drainShellOutputOnReactor() {
    if (!isReactorThread() || !readerRunning_.load(std::memory_order_acquire)) {
        return;
    }

    constexpr size_t kBufSize = SSH_BUFFER_SIZE;
    std::vector<uint8_t> buffer(kBufSize);
    std::vector<uint8_t> accumulated;
    accumulated.reserve(kBufSize * 2);
    bool gotData = false;
    bool eofDetected = false;
    bool readError = false;
    ssize_t readErrorCode = 0;
    {
        std::unique_lock<std::mutex> sessionLock(sessionMutex_);
        if (!channel_ || sockFd_ < 0 ||
            state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
            return;
        }
        while (readerRunning_.load(std::memory_order_acquire)) {
            const ssize_t n = libssh2_channel_read(
                channel_, reinterpret_cast<char*>(buffer.data()), buffer.size());
            if (n == LIBSSH2_ERROR_EAGAIN) { break; }
            if (n < 0) {
                if (n == LIBSSH2_ERROR_SOCKET_RECV) {
                    if (libssh2_channel_eof(channel_) != 0) {
                        eofDetected = true;
                        readerRunning_.store(false, std::memory_order_release);
                        break;
                    }
                    const SocketReceiveProbe probe = probeSocketReceive(sockFd_);
                    if (probe.transient) {
                        // The channel is still open and the non-blocking
                        // socket has no consumable bytes. Let the owner return
                        // to poll.
                        break;
                    }
                    OH_LOG_ERROR(LOG_APP,
                        "[SSH] terminal recv probe failed: rc=%{public}zd fd=%{public}d "
                        "peek=%{public}zd peekErrno=%{public}d soError=%{public}d "
                        "soErrno=%{public}d sessionErr=%{public}d",
                        n, sockFd_, probe.peeked, probe.peekErrno, probe.socketError,
                        probe.socketErrorErrno, libssh2_session_last_errno(session_));
                }
                readError = true;
                readErrorCode = n;
                break;
            }
            if (n == 0) {
                if (libssh2_channel_eof(channel_) != 0) {
                    eofDetected = true;
                    readerRunning_.store(false, std::memory_order_release);
                }
                break;
            }
            accumulated.insert(accumulated.end(), buffer.begin(), buffer.begin() + n);
            gotData = true;
            // Keep a cooperative SFTP/latency slice bounded like readerLoop.
            if (accumulated.size() >= kBufSize * 4) { break; }
        }
    }

    if (readError) {
        transportRecoveryRequested_.store(true, std::memory_order_release);
        OH_LOG_WARN(LOG_APP, "[SSH] terminal read failed during owner command rc=%{public}zd",
                    readErrorCode);
    } else if (eofDetected) {
        setState(ConnectionState::DISCONNECTED, "SSH remote channel closed");
    }
    if (gotData && !accumulated.empty()) {
        diagnostics_.recordRemoteBytesRead(accumulated.size());
        deliverTerminalOutput(accumulated);
    }
}

void SshAdapter::drainReactorCommands() {
    // Run one command per turn. This preserves a chance for terminal input
    // and channel reads between long SFTP/command operations.
    std::function<void()> command;
    {
        std::lock_guard<std::mutex> lock(reactorCommandMutex_);
        if (reactorCommands_.empty()) { return; }
        command = std::move(reactorCommands_.front());
        reactorCommands_.pop_front();
    }
    if (command) {
        try { command(); } catch (...) { /* packaged_task stores exceptions */ }
    }
}

int SshAdapter::executeCommand(const std::string& command, SshCommandResult& result,
                               int timeoutMs) {
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        return runOnReactor([this, command, &result, timeoutMs]() {
            return executeCommand(command, result, timeoutMs);
        });
    }
    return executeChannelRequest(command, false, result, timeoutMs);
}

int SshAdapter::executeSubsystem(const std::string& subsystem, SshCommandResult& result,
                                 int timeoutMs) {
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        return runOnReactor([this, subsystem, &result, timeoutMs]() {
            return executeSubsystem(subsystem, result, timeoutMs);
        });
    }
    return executeChannelRequest(subsystem, true, result, timeoutMs);
}

int SshAdapter::executeChannelRequest(const std::string& request, bool subsystem,
                                      SshCommandResult& result, int timeoutMs) {
    result = SshCommandResult {};
    if (request.empty()) { return ERR_SSH_SUBSYSTEM_FAILED; }
    if (timeoutMs <= 0) { timeoutMs = 30000; }
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        return runOnReactor([this, request, subsystem, &result, timeoutMs]() {
            return executeChannelRequest(request, subsystem, result, timeoutMs);
        });
    }
    const auto deadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(timeoutMs);

    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    if (!session_ || state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
        return ERR_SSH_SESSION_CLOSED;
    }
    auto waitForRequest = [&]() -> bool {
        const auto remainingMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            deadline - std::chrono::steady_clock::now()).count();
        if (remainingMs <= 0) { return false; }
        if (isReactorThread() && !readerRunning_.load(std::memory_order_acquire)) {
            return false;
        }
        sessionLock.unlock();
        bool ready = false;
        if (isReactorThread()) {
            const int waitMs = static_cast<int>(std::min<int64_t>(remainingMs, 50));
            const int waitResult = waitSocketMilliseconds(2, waitMs);
            // A short timeout is expected. Keep retrying until the command
            // deadline, servicing terminal input between packet polls.
            ready = waitResult != -1 && waitResult != -3;
            drainInputQueueOnReactor();
        } else {
            const int waitSeconds = static_cast<int>((remainingMs + 999) / 1000);
            ready = waitSocket(2, std::min(waitSeconds, 15)) == 0;
        }
        sessionLock.lock();
        return ready && session_ != nullptr &&
            !connectCancelRequested_.load(std::memory_order_acquire);
    };

    LIBSSH2_CHANNEL* commandChannel = nullptr;
    while ((commandChannel = libssh2_channel_open_session(session_)) == nullptr) {
        if (libssh2_session_last_errno(session_) != LIBSSH2_ERROR_EAGAIN) {
            return ERR_SSH_CHANNEL_OPEN;
        }
        if (!waitForRequest()) {
            return ERR_SSH_COMMAND_TIMEOUT;
        }
    }

    auto closeChannel = [&]() {
        if (commandChannel == nullptr) { return; }
        int closeResult = LIBSSH2_ERROR_EAGAIN;
        while (closeResult == LIBSSH2_ERROR_EAGAIN) {
            closeResult = libssh2_channel_close(commandChannel);
            if (closeResult == LIBSSH2_ERROR_EAGAIN) {
                if (!waitForRequest()) { break; }
            }
        }
        libssh2_channel_free(commandChannel);
        commandChannel = nullptr;
    };

    int startupResult = LIBSSH2_ERROR_EAGAIN;
    while ((startupResult = subsystem
                ? libssh2_channel_subsystem(commandChannel, request.c_str())
                : libssh2_channel_exec(commandChannel, request.c_str())) == LIBSSH2_ERROR_EAGAIN) {
        if (!waitForRequest()) {
            closeChannel();
            return ERR_SSH_COMMAND_TIMEOUT;
        }
    }
    if (startupResult != 0) {
        closeChannel();
        return ERR_SSH_SUBSYSTEM_FAILED;
    }

    constexpr size_t kMaxCommandOutputBytes = 64 * 1024 * 1024;
    std::vector<uint8_t> buffer(32768);
    bool stdoutDone = false;
    bool stderrDone = false;
    auto serviceTerminalInput = [&]() {
        if (!isReactorThread()) { return; }
        sessionLock.unlock();
        drainInputQueueOnReactor();
        sessionLock.lock();
    };
    auto appendOutput = [&](std::vector<uint8_t>& destination,
                            const uint8_t* source, size_t length) -> bool {
        const size_t currentSize = result.stdoutBytes.size() + result.stderrBytes.size();
        if (currentSize > kMaxCommandOutputBytes ||
            length > kMaxCommandOutputBytes - currentSize) {
            return false;
        }
        destination.insert(destination.end(), source, source + length);
        return true;
    };
    while (!(stdoutDone && stderrDone)) {
        if (isReactorThread() && !readerRunning_.load(std::memory_order_acquire)) {
            closeChannel();
            return ERR_SSH_SESSION_CLOSED;
        }
        serviceTerminalInput();
        bool progressed = false;
        if (!stdoutDone) {
            ssize_t readResult = libssh2_channel_read(
                commandChannel, reinterpret_cast<char*>(buffer.data()), buffer.size());
            if (readResult == LIBSSH2_ERROR_EAGAIN) {
                // Wait below; stderr may still have pending bytes.
            } else if (readResult < 0) {
                closeChannel();
                return ERR_SSH_READ_FAILED;
            } else if (readResult == 0) {
                stdoutDone = libssh2_channel_eof(commandChannel) != 0;
            } else {
                if (!appendOutput(result.stdoutBytes, buffer.data(),
                                   static_cast<size_t>(readResult))) {
                    OH_LOG_WARN(LOG_APP, "[SSH] exec stdout 超过安全上限");
                    closeChannel();
                    return ERR_SSH_OUTPUT_LIMIT;
                }
                progressed = true;
            }
        }
        if (!stderrDone) {
            ssize_t readResult = libssh2_channel_read_stderr(
                commandChannel, reinterpret_cast<char*>(buffer.data()), buffer.size());
            if (readResult == LIBSSH2_ERROR_EAGAIN) {
                // Wait below.
            } else if (readResult < 0) {
                closeChannel();
                return ERR_SSH_READ_FAILED;
            } else if (readResult == 0) {
                stderrDone = libssh2_channel_eof(commandChannel) != 0;
            } else {
                if (!appendOutput(result.stderrBytes, buffer.data(),
                                   static_cast<size_t>(readResult))) {
                    OH_LOG_WARN(LOG_APP, "[SSH] exec stderr 超过安全上限");
                    closeChannel();
                    return ERR_SSH_OUTPUT_LIMIT;
                }
                progressed = true;
            }
        }

        if (stdoutDone && stderrDone) { break; }
        if (std::chrono::steady_clock::now() >= deadline) {
            closeChannel();
            return ERR_SSH_COMMAND_TIMEOUT;
        }
        if (!progressed) {
            if (!waitForRequest()) {
                closeChannel();
                return ERR_SSH_COMMAND_TIMEOUT;
            }
        }
    }

    result.exitCode = libssh2_channel_get_exit_status(commandChannel);
    char* exitSignal = nullptr;
    size_t exitSignalLength = 0;
    if (libssh2_channel_get_exit_signal(commandChannel, &exitSignal, &exitSignalLength,
                                        nullptr, nullptr, nullptr, nullptr) == 0 &&
        exitSignal != nullptr && exitSignalLength > 0) {
        result.signaled = true;
        result.signal.assign(exitSignal, exitSignalLength);
    }
    closeChannel();
    return 0;
}

int SshAdapter::sendChannelSignal(const std::string& signal) {
    if (signal.empty()) { return ERR_SSH_SUBSYSTEM_FAILED; }
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        return runOnReactor([this, signal]() {
            return sendChannelSignal(signal);
        });
    }
    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    if (!channel_ || state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
        return ERR_SSH_SESSION_CLOSED;
    }
    int rc;
    while ((rc = libssh2_channel_signal(channel_, signal.c_str())) == LIBSSH2_ERROR_EAGAIN) {
        sessionLock.unlock();
        const int waitResult = isReactorThread()
            ? waitSocketMilliseconds(2, kReactorWaitSliceMs) : waitSocket(2, 5);
        if (isReactorThread()) { drainInputQueueOnReactor(); }
        sessionLock.lock();
        if (isReactorThread() && !readerRunning_.load(std::memory_order_acquire)) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (waitResult == -1 || waitResult == -3 ||
            (!isReactorThread() && waitResult != 0)) {
            return ERR_SSH_COMMAND_TIMEOUT;
        }
    }
    return rc == 0 ? 0 : ERR_SSH_SUBSYSTEM_FAILED;
}

int SshAdapter::sendChannelEof() {
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        return runOnReactor([this]() {
            return sendChannelEof();
        });
    }
    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    if (!channel_ || state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
        return ERR_SSH_SESSION_CLOSED;
    }
    int rc;
    while ((rc = libssh2_channel_send_eof(channel_)) == LIBSSH2_ERROR_EAGAIN) {
        sessionLock.unlock();
        const int waitResult = isReactorThread()
            ? waitSocketMilliseconds(2, kReactorWaitSliceMs) : waitSocket(2, 5);
        if (isReactorThread()) { drainInputQueueOnReactor(); }
        sessionLock.lock();
        if (isReactorThread() && !readerRunning_.load(std::memory_order_acquire)) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (waitResult == -1 || waitResult == -3 ||
            (!isReactorThread() && waitResult != 0)) {
            return ERR_SSH_COMMAND_TIMEOUT;
        }
    }
    return rc == 0 ? 0 : ERR_SSH_SUBSYSTEM_FAILED;
}

int SshAdapter::readData(uint8_t* buf, size_t bufSize) {
    if (buf == nullptr && bufSize > 0) { return ERR_SSH_READ_FAILED; }
    if (bufSize == 0) { return 0; }
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        return runOnReactor([this, buf, bufSize]() {
            return readData(buf, bufSize);
        });
    }
    bool eof = false;
    int result = 0;
    {
        std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
        std::lock_guard<std::mutex> sessionLock(sessionMutex_);
        if (!channel_ || sockFd_ < 0 ||
            state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
            return ERR_SSH_SESSION_CLOSED;
        }

        // Push mode owns the socket poll. The legacy readData API is a
        // non-blocking compatibility read and must never select while holding
        // sessionMutex_ or on the ArkUI thread.
        ssize_t n = libssh2_channel_read(channel_, reinterpret_cast<char*>(buf), bufSize);
        if (n == LIBSSH2_ERROR_EAGAIN) {
            return 0;
        }
        if (n < 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] libssh2_channel_read 失败: %{public}zd", n);
            return ERR_SSH_READ_FAILED;
        }
        if (n == 0) {
            // libssh2 may report a zero-byte read while no decrypted payload
            // is currently available. Only the channel EOF flag means the
            // remote side actually closed the stream.
            if (libssh2_channel_eof(channel_) != 0) {
                eof = true;
                result = ERR_SSH_SESSION_CLOSED;
            }
        } else {
            result = static_cast<int>(n);
            diagnostics_.recordRemoteBytesRead(static_cast<size_t>(n));
        }
    }
    if (eof) {
        OH_LOG_INFO(LOG_APP, "[SSH] 远程关闭通道 (EOF)");
        setState(ConnectionState::DISCONNECTED, "SSH remote channel closed");
    }
    return result;
}

void SshAdapter::resizePty(int cols, int rows) {
    if (cols <= 0 || rows <= 0) { return; }
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        bool publishCommand = false;
        {
            std::lock_guard<std::mutex> resizeLock(resizeMutex_);
            pendingResizeCols_ = cols;
            pendingResizeRows_ = rows;
            if (!resizePending_) {
                resizePending_ = true;
            }
            // A failed post leaves the latest dimensions pending. The owner
            // retries them on its next turn instead of silently losing the
            // only SIGWINCH for a new keyboard/orientation geometry.
            if (!resizeCommandPosted_) {
                resizeCommandPosted_ = true;
                publishCommand = true;
            }
        }
        if (publishCommand && !postOnReactor([this]() { processPendingResize(); })) {
            std::lock_guard<std::mutex> resizeLock(resizeMutex_);
            resizeCommandPosted_ = false;
        }
        // Window/layout callbacks are fire-and-forget. Coalescing keeps a
        // resize storm from occupying the reactor command queue or blocking
        // the ArkUI input path.
        return;
    }
    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    if (channel_ && state_.load(std::memory_order_acquire) == ConnectionState::CONNECTED) {
        int rc = LIBSSH2_ERROR_EAGAIN;
        while (rc == LIBSSH2_ERROR_EAGAIN) {
            rc = libssh2_channel_request_pty_size(channel_, cols, rows);
            if (rc == LIBSSH2_ERROR_EAGAIN) {
                sessionLock.unlock();
                const int waitResult = isReactorThread()
                    ? waitSocketMilliseconds(2, kReactorWaitSliceMs) : waitSocket(2, 5);
                if (isReactorThread()) { drainInputQueueOnReactor(); }
                sessionLock.lock();
                if (isReactorThread() && !readerRunning_.load(std::memory_order_acquire)) {
                    break;
                }
                if (waitResult == -1 || waitResult == -3 ||
                    (!isReactorThread() && waitResult != 0)) {
                    break;
                }
            }
        }
        if (rc == 0) {
            OH_LOG_INFO(LOG_APP, "[SSH] PTY 尺寸已调整: %{public}dx%{public}d", cols, rows);
        } else {
            OH_LOG_WARN(LOG_APP, "[SSH] PTY 尺寸调整失败: rc=%{public}d", rc);
        }
    } else {
        OH_LOG_WARN(LOG_APP, "[SSH] resizePty 失败: 通道未打开");
    }
}

void SshAdapter::processPendingResize() {
    int cols = 0;
    int rows = 0;
    {
        std::lock_guard<std::mutex> resizeLock(resizeMutex_);
        cols = pendingResizeCols_;
        rows = pendingResizeRows_;
        resizePending_ = false;
        resizeCommandPosted_ = false;
    }
    if (cols > 0 && rows > 0) {
        resizePty(cols, rows);
    }
}

int SshAdapter::getSocketFd() const {
    std::lock_guard<std::mutex> sessionLock(sessionMutex_);
    return sockFd_;
}

int SshAdapter::measureLatencyMs() {
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        return runOnReactor([this]() {
            return measureLatencyMs();
        });
    }
    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    if (!session_ || sockFd_ < 0 ||
        state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
        return -1;
    }
    auto start = std::chrono::steady_clock::now();
    // Keep the owner reactor responsive to shell output and keyboard input.
    // A keepalive probe is a health hint, not a reason to stall the terminal
    // for the old three-second timeout.
    constexpr auto kProbeBudget = std::chrono::milliseconds(50);
    const auto deadline = start + kProbeBudget;
    int secondsToNext = 0;
    int rc = LIBSSH2_ERROR_EAGAIN;
    while ((rc = libssh2_keepalive_send(session_, &secondsToNext)) == LIBSSH2_ERROR_EAGAIN) {
        if (std::chrono::steady_clock::now() >= deadline) {
            return -2;
        }
        sessionLock.unlock();
        const int waitResult = isReactorThread()
            ? waitSocketMilliseconds(2, kReactorWaitSliceMs) : waitSocket(2, 3);
        if (isReactorThread()) {
            drainInputQueueOnReactor();
            drainShellOutputOnReactor();
        }
        sessionLock.lock();
        if (isReactorThread() && !readerRunning_.load(std::memory_order_acquire)) {
            return -2;
        }
        if (waitResult == -1 || waitResult == -3 ||
            (!isReactorThread() && waitResult != 0)) {
            OH_LOG_WARN(LOG_APP, "[SSH] keepalive 等待超时: wait=%{public}d", waitResult);
            return -2;
        }
    }
    if (rc != 0) {
        OH_LOG_WARN(LOG_APP, "[SSH] keepalive 失败: rc=%{public}d", rc);
        return -3;
    }
    if (isReactorThread()) {
        // A keepalive can complete immediately while shell bytes are already
        // readable. Give the callback path one bounded read before returning.
        sessionLock.unlock();
        drainShellOutputOnReactor();
        sessionLock.lock();
    }
    auto end = std::chrono::steady_clock::now();
    return static_cast<int>(
        std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count());
}

void SshAdapter::serviceKeepaliveOnReactor() {
    if (!isReactorThread() || !readerRunning_.load(std::memory_order_acquire)) {
        return;
    }
    const auto now = std::chrono::steady_clock::now();
    if (now < keepaliveNextDue_) {
        return;
    }

    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    if (!session_ || sockFd_ < 0 ||
        state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
        return;
    }

    int secondsToNext = 0;
    int rc = LIBSSH2_ERROR_EAGAIN;
    // A non-blocking keepalive may need one short writable/readable poll. Keep
    // this bounded so keyboard input and queued terminal commands stay ahead
    // of a congested socket.
    for (int attempt = 0; attempt < 2; ++attempt) {
        if (!readerRunning_.load(std::memory_order_acquire)) {
            return;
        }
        rc = libssh2_keepalive_send(session_, &secondsToNext);
        if (rc != LIBSSH2_ERROR_EAGAIN) {
            break;
        }
        const int blockDirections = libssh2_session_block_directions(session_);
        int waitDirection = 2;
        if (blockDirections == LIBSSH2_SESSION_BLOCK_INBOUND) {
            waitDirection = 0;
        } else if (blockDirections == LIBSSH2_SESSION_BLOCK_OUTBOUND) {
            waitDirection = 1;
        }
        sessionLock.unlock();
        const int waitResult = waitSocketMilliseconds(
            waitDirection, SshTerminalKeepalivePolicy::kRetryWaitMilliseconds);
        sessionLock.lock();
        if (waitResult == -1 || waitResult == -3 ||
            !readerRunning_.load(std::memory_order_acquire) ||
            !session_ || sockFd_ < 0 ||
            state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
            return;
        }
    }

    const auto retryAt = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(SshTerminalKeepalivePolicy::kRetryDelayMilliseconds);
    if (rc == 0) {
        const int interval = SshTerminalKeepalivePolicy::intervalSeconds(secondsToNext);
        keepaliveNextDue_ = std::chrono::steady_clock::now() +
            std::chrono::seconds(interval);
        keepaliveConsecutiveFailures_ = 0;
        return;
    }
    if (rc == LIBSSH2_ERROR_EAGAIN) {
        // A short readiness timeout is not a dead SSH session. Try again on
        // the next bounded reactor turn without changing connection state.
        keepaliveNextDue_ = retryAt;
        return;
    }

    ++keepaliveConsecutiveFailures_;
    if (SshTerminalKeepalivePolicy::retryableFailure(keepaliveConsecutiveFailures_)) {
        keepaliveNextDue_ = retryAt;
        OH_LOG_WARN(LOG_APP, "[SSH] keepalive 暂时失败 rc=%{public}d retry=%{public}u",
                    rc, keepaliveConsecutiveFailures_);
        return;
    }

    sessionLock.unlock();
    terminalInputAccepting_.store(false, std::memory_order_release);
    transportRecoveryRequested_.store(true, std::memory_order_release);
    OH_LOG_WARN(LOG_APP, "[SSH] keepalive exhausted, requesting transport recovery rc=%{public}d",
                rc);
    reactorCommandCondition_.notify_all();
}

// ============================================================
// 推送式数据回调 (后台 reader 线程)
// ============================================================

void SshAdapter::setOnDataCallback(DataCallback cb) {
    bool hasCallback = false;
    if (!cb) {
        // Stop before clearing the callback so an in-flight reader can
        // deliver bytes it has already consumed instead of dropping them.
        stopReader();
        std::lock_guard<std::mutex> deliveryLock(callbackDeliveryMutex_);
        std::lock_guard<std::mutex> lk(callbackMutex_);
        onDataCallback_ = nullptr;
    } else {
        {
            std::lock_guard<std::mutex> deliveryLock(callbackDeliveryMutex_);
            {
                std::lock_guard<std::mutex> lk(callbackMutex_);
                onDataCallback_ = std::move(cb);
            }
            std::deque<std::vector<uint8_t>> replay;
            {
                std::lock_guard<std::mutex> outputLock(detachedTerminalMutex_);
                replay.swap(detachedTerminalOutput_);
                detachedTerminalOutputBytes_ = 0;
            }
            DataCallback replayCallback;
            {
                std::lock_guard<std::mutex> lk(callbackMutex_);
                replayCallback = onDataCallback_;
            }
            if (replayCallback) {
                for (const std::vector<uint8_t>& bytes : replay) {
                    try { replayCallback(bytes); } catch (...) { /* keep the owner alive */ }
                }
            }
            hasCallback = true;
        }
        // connect() starts the owner early; this call only wakes it and
        // publishes the consumer that is allowed to receive remote bytes.
        startReader();
    }
    OH_LOG_INFO(LOG_APP, "[SSH] onDataCallback %{public}s",
                hasCallback ? "已注册" : "已清除");
}

void SshAdapter::detachOnDataCallback() {
    std::lock_guard<std::mutex> deliveryLock(callbackDeliveryMutex_);
    std::lock_guard<std::mutex> lk(callbackMutex_);
    onDataCallback_ = nullptr;
    // The owner reactor remains alive and can be rebound by a later page.
    reactorCommandCondition_.notify_one();
    OH_LOG_INFO(LOG_APP, "[SSH] onDataCallback 已脱离, session reactor 保持");
}

void SshAdapter::deliverTerminalOutput(const std::vector<uint8_t>& data) {
    if (data.empty()) {
        return;
    }
    std::lock_guard<std::mutex> deliveryLock(callbackDeliveryMutex_);
    DataCallback callback;
    {
        std::lock_guard<std::mutex> callbackLock(callbackMutex_);
        callback = onDataCallback_;
    }
    if (callback) {
        try { callback(data); } catch (...) { /* keep the owner reactor alive */ }
        return;
    }

    bool overflowed = false;
    {
        std::lock_guard<std::mutex> outputLock(detachedTerminalMutex_);
        if (detachedTerminalOutput_.size() >= kDetachedTerminalMaxChunks ||
            detachedTerminalOutputBytes_ + data.size() > kDetachedTerminalMaxBytes) {
            overflowed = true;
        } else {
            detachedTerminalOutput_.push_back(data);
            detachedTerminalOutputBytes_ += data.size();
        }
    }
    if (overflowed) {
        OH_LOG_ERROR(LOG_APP,
                     "[SSH] detached terminal output FIFO overflow, closing session");
        failTerminalOutput("SSH detached terminal output queue overflow");
    }
}

void SshAdapter::clearDetachedTerminalOutput() {
    std::lock_guard<std::mutex> outputLock(detachedTerminalMutex_);
    detachedTerminalOutput_.clear();
    detachedTerminalOutputBytes_ = 0;
}

void SshAdapter::startReader() {
    std::lock_guard<std::mutex> lifecycleLock(readerLifecycleMutex_);
    bool expected = false;
    if (!readerRunning_.compare_exchange_strong(expected, true)) { return; }
    // A failed connect can stop the owner from inside its own command. The
    // thread remains joinable until the async completion/next caller reclaims
    // it; never overwrite that std::thread object while it is still joinable.
    if (readerThread_.joinable()) {
        if (isReactorThread()) {
            readerRunning_.store(false, std::memory_order_release);
            return;
        }
        readerThread_.join();
    }
    readerThread_ = std::thread(&SshAdapter::readerLoop, this);
    OH_LOG_INFO(LOG_APP, "[SSH] reader 线程已启动");
}

void SshAdapter::stopReader() {
    std::lock_guard<std::mutex> lifecycleLock(readerLifecycleMutex_);
    if (isReactorThread()) {
        readerRunning_.store(false, std::memory_order_release);
        reactorCommandCondition_.notify_all();
        return;
    }
    if (!readerRunning_.load()) {
        if (readerThread_.joinable()) { readerThread_.join(); }
        return;
    }
    readerRunning_.store(false);
    reactorCommandCondition_.notify_all();
    if (readerThread_.joinable()) {
        readerThread_.join();
    }
    OH_LOG_INFO(LOG_APP, "[SSH] reader 线程已退出");
}

void SshAdapter::readerLoop() {
    constexpr size_t kBufSize = SSH_BUFFER_SIZE;
    std::vector<uint8_t> buf(kBufSize);
    reactorThreadId_ = std::this_thread::get_id();
    reactorAlive_.store(true, std::memory_order_release);

    while (readerRunning_.load(std::memory_order_acquire)) {
        if (transportRecoveryRequested_.exchange(false, std::memory_order_acq_rel)) {
            if (!reconnectAfterTransportFailure()) { break; }
            continue;
        }
        // Control/data admission is already bounded. One item per turn keeps
        // a paste from monopolizing the owner while the channel is readable.
        drainInputQueueOnReactor();
        serviceKeepaliveOnReactor();
        if (!readerRunning_.load(std::memory_order_acquire)) {
            break;
        }
        if (transportRecoveryRequested_.exchange(false, std::memory_order_acq_rel)) {
            if (!reconnectAfterTransportFailure()) { break; }
            continue;
        }
        // If a resize command could not enter the bounded reactor queue, the
        // owner itself retries it here. This also recovers a command that was
        // discarded when a prior reactor stopped during teardown.
        bool retryResize = false;
        {
            std::lock_guard<std::mutex> resizeLock(resizeMutex_);
            if (resizePending_ && !resizeCommandPosted_ &&
                state_.load(std::memory_order_acquire) == ConnectionState::CONNECTED) {
                resizeCommandPosted_ = true;
                retryResize = true;
            }
        }
        if (retryResize) {
            processPendingResize();
        }
        // Terminal input has priority over queued SFTP/command work. Each
        // long operation also yields back through this same drain path.
        drainReactorCommands();
        if (transportRecoveryRequested_.exchange(false, std::memory_order_acq_rel)) {
            if (!reconnectAfterTransportFailure()) { break; }
            continue;
        }
        // Snapshot only the poll identity. Waiting in select() must not hold
        // sessionMutex_: otherwise a quiet SSH channel stalls terminal writes
        // and every SFTP operation for the full poll interval.
        int fd = -1;
        LIBSSH2_CHANNEL* ch = nullptr;
        uint64_t generation = 0;
        {
            std::lock_guard<std::mutex> sessionLock(sessionMutex_);
            fd = sockFd_;
            ch = channel_;
            generation = ioGeneration_.load(std::memory_order_acquire);
        }
        if (fd < 0 || ch == nullptr ||
            state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
            std::unique_lock<std::mutex> waitLock(reactorCommandMutex_);
            reactorCommandCondition_.wait_for(waitLock, std::chrono::milliseconds(10));
            continue;
        }

        // A short poll bounds command/input latency while retaining a single
        // libssh2 owner. The old 100ms poll was visible as keyboard lag.
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        struct timeval tv = {0, 10 * 1000};
        int sret = select(fd + 1, &rfds, nullptr, nullptr, &tv);
        if (sret < 0) {
            if (errno == EINTR) { continue; }
            if (!readerRunning_.load(std::memory_order_acquire)) { break; }
            // A non-EINTR select failure means the poll identity is no longer
            // trustworthy. Let the single owner rebuild the transport instead
            // of spinning on a dead fd and leaving the page looking connected.
            transportRecoveryRequested_.store(true, std::memory_order_release);
            OH_LOG_WARN(LOG_APP,
                        "[SSH] reader select 错误, 请求传输恢复: errno=%{public}d",
                        errno);
            continue;
        }
        if (sret == 0) {
            continue;
        }  // 超时, 继续循环

        // Reacquire only for the actual libssh2 read and validate the whole
        // snapshot. disconnect/reconnect increments ioGeneration_ while
        // clearing the channel, so an fd reuse cannot read a stale pointer.
        std::unique_lock<std::mutex> sessionLock(sessionMutex_);
        if (!readerRunning_.load(std::memory_order_acquire) ||
            fd != sockFd_ || ch != channel_ ||
            generation != ioGeneration_.load(std::memory_order_acquire) ||
            state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
            continue;
        }
        // 反复读直到 EAGAIN, 减少 select 次数 (大输出场景)
        bool gotData = false;
        bool eofDetected = false;
        bool readError = false;
        ssize_t readErrorCode = 0;
        std::vector<uint8_t> accumulated;
        accumulated.reserve(kBufSize * 2);
        while (readerRunning_.load()) {
            ssize_t n = libssh2_channel_read(ch, reinterpret_cast<char*>(buf.data()), kBufSize);
            if (n == LIBSSH2_ERROR_EAGAIN) { break; }
            if (n < 0) {
                if (n == LIBSSH2_ERROR_SOCKET_RECV) {
                    if (libssh2_channel_eof(ch) != 0) {
                        eofDetected = true;
                        break;
                    }
                    const SocketReceiveProbe probe = probeSocketReceive(fd);
                    if (probe.transient) {
                        // A readiness edge can race with libssh2's encrypted
                        // receive. Keep the reactor alive and wait for the
                        // next socket edge instead of converting it into a
                        // disconnect.
                        break;
                }
                OH_LOG_ERROR(LOG_APP,
                        "[SSH] reader recv probe failed: rc=%{public}zd fd=%{public}d "
                        "peek=%{public}zd peekErrno=%{public}d soError=%{public}d "
                        "soErrno=%{public}d sessionErr=%{public}d",
                        n, fd, probe.peeked, probe.peekErrno, probe.socketError,
                        probe.socketErrorErrno, libssh2_session_last_errno(session_));
                }
                OH_LOG_ERROR(LOG_APP, "[SSH] reader libssh2_channel_read 失败: %{public}zd", n);
                readError = true;
                readErrorCode = n;
                break;
            }
            if (n == 0) {
                // A zero-byte read is not itself EOF; libssh2 can return it
                // when no decrypted payload is ready yet. Re-enter select()
                // unless the channel explicitly reports EOF.
                if (libssh2_channel_eof(ch) != 0) {
                    OH_LOG_INFO(LOG_APP, "[SSH] reader 检测到 EOF, 通道关闭");
                    eofDetected = true;
                }
                break;
            }
            accumulated.insert(accumulated.end(), buf.begin(), buf.begin() + n);
            gotData = true;
            // 单批最多 256KB, 防止极端场景占用过多内存
            if (accumulated.size() >= kBufSize * 4) { break; }
        }
        sessionLock.unlock();

        if (readError) {
            transportRecoveryRequested_.store(true, std::memory_order_release);
            OH_LOG_WARN(LOG_APP, "[SSH] terminal transport failure requests recovery rc=%{public}zd",
                        readErrorCode);
        } else if (eofDetected) {
            // Remote shell EOF is a transport loss in an otherwise live
            // session. Keep the owner alive so reconnectAfterTransportFailure
            // can rebuild the channel without making the page discard its
            // session binding.
            transportRecoveryRequested_.store(true, std::memory_order_release);
            setState(ConnectionState::RECONNECTING,
                     "SSH remote channel closed, reconnecting");
        }

        if (gotData && !accumulated.empty()) {
            diagnostics_.recordRemoteBytesRead(accumulated.size());
            deliverTerminalOutput(accumulated);
        }
    }

    reactorThreadId_ = std::thread::id {};
    reactorAlive_.store(false, std::memory_order_release);
    readerRunning_.store(false, std::memory_order_release);
    {
        std::lock_guard<std::mutex> commandLock(reactorCommandMutex_);
        reactorCommands_.clear();
    }
    {
        std::lock_guard<std::mutex> resizeLock(resizeMutex_);
        // Keep resizePending_ intact so the next owner can publish the latest
        // dimensions after a reconnect; only the dropped command marker is
        // cleared here.
        resizeCommandPosted_ = false;
    }
    reactorCommandCondition_.notify_all();
    OH_LOG_INFO(LOG_APP, "[SSH] session owner reactor 结束");
}

// ============================================================
// 注册到 ExtensionSystem
// ============================================================

void registerSshAdapter() {
    auto adapter = std::shared_ptr<SshAdapter>(new SshAdapter());
    ExtensionSystem::instance().protocols.registerExt("protocol", "ssh", adapter);
    OH_LOG_INFO(LOG_APP, "[SSH] SSH 适配器已注册 (libssh2 集成版 v%{public}s)", SSH_ADAPTER_VERSION);
}
