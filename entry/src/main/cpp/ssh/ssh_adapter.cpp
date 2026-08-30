/**
 * ssh_adapter.cpp — SSH 终端协议适配器实现 (libssh2 集成版)
 *
 * 基于 libssh2 + OpenSSL 的完整 SSH2 协议实现.
 * 连接流程: TCP → KEX(Banner内嵌) → 认证 → 通道 → PTY → Shell
 * 所有 libssh2 调用使用非阻塞模式 + select() 轮询.
 */
#include "ssh_adapter.h"
#include "common/endpoint_address_policy.h"
#include "common/happy_eyeballs_connector.h"
#include "common/network_generation_fence.h"
#include "ssh_auth_policy.h"
#include "ssh_auth_replay_policy.h"
#include "ssh_connect_error_policy.h"
#include "ssh_network_generation_policy.h"
#include "ssh_network_lifecycle_policy.h"
#include "ssh_proxy_target_policy.h"
#include "ssh_route_policy.h"
#include "ssh_route_teardown_policy.h"
#include "ssh_sensitive_buffer.h"
#include "ssh_sftp_operation_policy.h"
#include "extension_registry.h"
#include "common/safe_log.h"
#include "ssh_algorithm_prefs.h"
#include <hilog/log.h>
#include <sys/socket.h>
#include <poll.h>
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
    constexpr int kSocksCloseAfterFlush = -2;

    class SshScopeExit final {
    public:
        explicit SshScopeExit(std::function<void()> callback)
            : callback_(std::move(callback)) {}
        ~SshScopeExit() {
            if (callback_) { callback_(); }
        }
        SshScopeExit(const SshScopeExit&) = delete;
        SshScopeExit& operator=(const SshScopeExit&) = delete;

        void dismiss() noexcept { callback_ = nullptr; }

    private:
        std::function<void()> callback_;
    };

    void encodeBase64To(const unsigned char* data, size_t len, std::string& out) {
        static const char b64chars[] =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        out.clear();
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
    }

    std::string encodeBase64(const unsigned char* data, size_t len) {
        std::string out;
        encodeBase64To(data, len, out);
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
            sshSecureWipe(value.data(), value.size());
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

    struct SshJumpKeyboardContext {
        SshAdapter* adapter = nullptr;
        const std::string* password = nullptr;
        std::vector<std::string>* explicitResponses = nullptr;
        size_t* presetIndex = nullptr;
        bool* passwordFallbackUsed = nullptr;
        std::string targetHost;
        std::string hopLabel;
        bool allowPasswordFallback = false;
    };

    void sshJumpKeyboardInteractiveCallback(
        const char* name, int nameLen, const char* instruction, int instructionLen,
        int numPrompts, const LIBSSH2_USERAUTH_KBDINT_PROMPT* prompts,
        LIBSSH2_USERAUTH_KBDINT_RESPONSE* responses, void** abstract) {
        if (numPrompts <= 0 || responses == nullptr || abstract == nullptr ||
            *abstract == nullptr) {
            return;
        }
        auto* context = static_cast<SshJumpKeyboardContext*>(*abstract);
        if (context->adapter == nullptr || context->presetIndex == nullptr ||
            context->passwordFallbackUsed == nullptr) {
            return;
        }
        const int result = context->adapter->fillKeyboardInteractiveResponses(
            name, nameLen, instruction, instructionLen, numPrompts, prompts, responses,
            context->explicitResponses, context->password,
            context->allowPasswordFallback, context->targetHost, context->hopLabel,
            *context->presetIndex, *context->passwordFallbackUsed);
        if (result != 0) {
            context->adapter->recordAuthPromptFailure(result);
        }
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

void SshAdapter::onNetworkChanged(bool available, uint64_t networkGeneration) {
    uint64_t lastGeneration = lastNetworkGeneration_.load(std::memory_order_acquire);
    while (SshNetworkLifecyclePolicy::acceptsGeneration(lastGeneration, networkGeneration) &&
           !lastNetworkGeneration_.compare_exchange_weak(
               lastGeneration, networkGeneration, std::memory_order_acq_rel,
               std::memory_order_acquire)) {
    }
    if (networkGeneration == 0 || networkGeneration <= lastGeneration) {
        return;
    }
    networkAvailable_.store(available, std::memory_order_release);
    // A response belongs to the route generation displayed with its prompt.
    // Wake a pending KBI round immediately; a safe retry will publish a fresh
    // request after resetting the broker for the new generation.
    authPromptBroker_.cancelAll();
    const bool reactorRunning = readerRunning_.load(std::memory_order_acquire);
    const bool connected = state_.load(std::memory_order_acquire) ==
        ConnectionState::CONNECTED;
    if (SshNetworkLifecyclePolicy::shouldRequestRecovery(
            available, reactorRunning, connected)) {
        setSshLifecycleState(SshSessionLifecycleState::NetworkLost);
        setState(ConnectionState::RECONNECTING,
                 available
                     ? "SSH network route changed, reconnecting"
                     : "SSH network unavailable, waiting for recovery");
        transportRecoveryRequested_.store(true, std::memory_order_release);
    }
    if (SshNetworkLifecyclePolicy::shouldWakeRecovery(available, reactorRunning)) {
        reactorCommandCondition_.notify_all();
    }
}

void SshAdapter::setSshLifecycleState(SshSessionLifecycleState state,
                                      const std::string& eventType) {
    const SshSessionLifecycleState current =
        sshLifecycleState_.load(std::memory_order_acquire);
    // A recovery attempt rebuilds transport/KEX/auth in place. Keep those
    // implementation phases under Reconnecting unless the prompt broker has
    // explicitly exposed NeedsAuthentication to the page.
    if (recoveryAttemptInProgress_.load(std::memory_order_acquire) &&
        ((state == SshSessionLifecycleState::Connecting) ||
         (state == SshSessionLifecycleState::Authenticating &&
          current != SshSessionLifecycleState::NeedsAuthentication))) {
        return;
    }
    const SshSessionLifecycleState previous =
        sshLifecycleState_.exchange(state, std::memory_order_acq_rel);
    if (previous == state) {
        return;
    }
    sshEventSequence_.fetch_add(1, std::memory_order_acq_rel);
    SshLifecycleStateCallback callback;
    {
        std::lock_guard<std::mutex> lock(sshLifecycleCallbackMutex_);
        callback = sshLifecycleStateCallback_;
    }
    if (callback) {
        const std::string type = eventType.empty()
            ? std::string(sshSessionLifecycleStateName(state)) : eventType;
        try {
            callback(state, type);
        } catch (...) {
            // Lifecycle observers are diagnostics/state sinks. They must not
            // take down the session-owner reactor if a consumer misbehaves.
            OH_LOG_ERROR(LOG_APP, "[SSH] lifecycle callback threw");
        }
    }
}

SshSessionSnapshot SshAdapter::sessionSnapshot() const {
    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    SshSessionSnapshot snapshot;
    snapshot.sessionId = diagnostics_.snapshot().sessionId;
    snapshot.generation = diagnostics_.sessionGeneration();
    snapshot.state = sshLifecycleState_.load(std::memory_order_acquire);
    snapshot.eventSequence = sshEventSequence_.load(std::memory_order_acquire);
    snapshot.host = savedCfg_.host;
    snapshot.port = savedCfg_.port > 0 ? savedCfg_.port : 22;
    snapshot.backgroundLimited = false;
    return snapshot;
}

bool SshAdapter::getAuthPrompt(SshAuthPromptRequest& out) const {
    return authPromptBroker_.snapshot(out);
}

bool SshAdapter::respondAuthPrompt(const SshAuthPromptResponse& response) {
    if (response.cancelled) {
        return cancelAuthPrompt(response.requestId, response.generation);
    }
    if (response.sessionId == 0 || response.generation == 0) {
        return false;
    }
    return authPromptBroker_.respond(response);
}

bool SshAdapter::cancelAuthPrompt(uint64_t requestId, uint64_t expectedGeneration) {
    const uint64_t sessionId = diagnostics_.snapshot().sessionId;
    if (sessionId == 0 || expectedGeneration == 0 ||
        expectedGeneration != diagnostics_.sessionGeneration()) {
        return false;
    }
    return authPromptBroker_.cancel(requestId, sessionId, expectedGeneration);
}

void SshAdapter::recordAuthPromptFailure(int error) noexcept {
    if (error != 0) {
        authPromptFailure_.store(error, std::memory_order_release);
    }
}

SshForwardingResult SshAdapter::configureForwarding(const SshForwardingConfig& config) {
    auto operation = [this, config]() {
        std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
        SshForwardingConfig owned = config;
        const SshSessionSnapshot owner = sessionSnapshot();
        owned.ownerSessionId = owner.sessionId;
        owned.ownerChannelId = owner.channelId;
        owned.ownerGeneration = owner.generation;

        // A failed profile is replaceable only after the owner reactor has
        // released every old socket/channel. Clear a stale runtime before the
        // manager resets the profile, otherwise remove-then-reconfigure can
        // leave an unowned listener behind.
        SshForwardingSnapshot existing;
        if (forwardingManager_.snapshot(owned.id, existing) &&
            existing.activeConnections == 0 &&
            (existing.state == SshForwardingState::Stopped ||
             existing.state == SshForwardingState::Failed)) {
            std::unique_lock<std::mutex> sessionLock(sessionMutex_);
            closeLocalForwardRuntimeLocked(owned.id);
        }
        return forwardingManager_.upsert(owned);
    };
    if (isReactorThread()) {
        return operation();
    }
    return runOnReactor(operation);
}

SshForwardingResult SshAdapter::removeForwarding(const std::string& id) {
    auto operation = [this, id]() {
        std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
        SshForwardingSnapshot existing;
        if (forwardingManager_.snapshot(id, existing) &&
            existing.activeConnections == 0 &&
            (existing.state == SshForwardingState::Stopped ||
             existing.state == SshForwardingState::Failed)) {
            std::unique_lock<std::mutex> sessionLock(sessionMutex_);
            closeLocalForwardRuntimeLocked(id);
        }
        return forwardingManager_.remove(id);
    };
    if (isReactorThread()) {
        return operation();
    }
    return runOnReactor(operation);
}

SshForwardingResult SshAdapter::startForwarding(const std::string& id,
                                                uint64_t expectedGeneration) {
    auto operation = [this, id, expectedGeneration]() {
        const uint64_t currentGeneration = diagnostics_.sessionGeneration();
        if (expectedGeneration == 0 || currentGeneration == 0 ||
            expectedGeneration != currentGeneration) {
            return SshForwardingResult::StaleSession;
        }
        if (!readerRunning_.load(std::memory_order_acquire) ||
            state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
            return SshForwardingResult::InvalidState;
        }
        SshForwardingSnapshot snapshot;
        if (!forwardingManager_.snapshot(id, snapshot)) {
            return SshForwardingResult::NotFound;
        }
        if (snapshot.activeConnections == 0 &&
            (snapshot.state == SshForwardingState::Stopped ||
             snapshot.state == SshForwardingState::Failed)) {
            std::unique_lock<std::mutex> sessionLock(sessionMutex_);
            closeLocalForwardRuntimeLocked(id);
        }
        const SshForwardingResult started = forwardingManager_.start(id, currentGeneration);
        if (started != SshForwardingResult::Ok) {
            return started;
        }
        int errorCode = 0;
        LocalForwardListener listener;
        listener.profileId = id;
        listener.sessionGeneration = currentGeneration;
        listener.mode = snapshot.config.mode;
        if (snapshot.config.mode == SshForwardingMode::Remote) {
            int boundPort = snapshot.config.bindPort;
            listener.remoteListener = createRemoteForwardListener(
                snapshot.config, boundPort, errorCode);
            listener.boundHost = snapshot.config.bindHost;
            listener.boundPort = boundPort;
            const auto remoteBind = remotedesk::endpoint::ParseHost(
                snapshot.config.bindHost, remotedesk::endpoint::ParseMode::Persisted);
            listener.boundFamily = remoteBind.ok &&
                remoteBind.endpoint.family() == remotedesk::endpoint::AddressFamily::Ipv4
                ? AF_INET
                : remoteBind.ok && remoteBind.endpoint.family() ==
                    remotedesk::endpoint::AddressFamily::Ipv6 ? AF_INET6 : AF_UNSPEC;
            if (listener.remoteListener == nullptr) {
                forwardingManager_.fail(id, currentGeneration, errorCode);
                OH_LOG_ERROR(LOG_APP,
                             "[SSH] remote forwarding listener 创建失败 id=%{public}s rc=%{public}d",
                             id.c_str(), errorCode);
                return SshForwardingResult::TransportFailure;
            }
        } else {
            const int listenerFd = createLocalForwardListener(
                snapshot.config, listener.boundHost, listener.boundPort,
                listener.boundFamily, errorCode);
            if (listenerFd < 0) {
                forwardingManager_.fail(id, currentGeneration, errorCode);
                OH_LOG_ERROR(LOG_APP,
                             "[SSH] local forwarding listener 创建失败 id=%{public}s errno=%{public}d",
                             id.c_str(), errorCode);
                return SshForwardingResult::TransportFailure;
            }
            listener.fd = listenerFd;
        }
        localForwardListeners_[id] = std::move(listener);
        const LocalForwardListener& activeListener = localForwardListeners_.at(id);
        const SshForwardingResult listening =
            forwardingManager_.markListening(
                id, currentGeneration, activeListener.boundHost,
                activeListener.boundPort, activeListener.boundFamily);
        if (listening != SshForwardingResult::Ok) {
            closeLocalForwardRuntimeLocked(id);
            forwardingManager_.fail(id, currentGeneration, EINVAL);
            return listening;
        }
        OH_LOG_INFO(LOG_APP,
                    "[SSH] forwarding listening id=%{public}s mode=%{public}d bindId=%{public}s "
                    "bindPort=%{public}d family=%{public}d target=%{public}s:%{public}d "
                    "fd=%{public}d remote=%{public}d",
                    id.c_str(), static_cast<int>(snapshot.config.mode),
                    SafeLog::MaskHost(activeListener.boundHost).c_str(),
                    activeListener.boundPort, activeListener.boundFamily,
                    SafeLog::MaskHost(snapshot.config.targetHost).c_str(),
                    snapshot.config.targetPort, activeListener.fd,
                    activeListener.remoteListener != nullptr ? 1 : 0);
        return SshForwardingResult::Ok;
    };
    if (isReactorThread()) {
        return operation();
    }
    return runOnReactor(operation);
}

SshForwardingResult SshAdapter::markForwardingListening(
    const std::string& id, uint64_t expectedGeneration) {
    auto operation = [this, id, expectedGeneration]() {
        const uint64_t currentGeneration = diagnostics_.sessionGeneration();
        if (expectedGeneration == 0 || currentGeneration == 0 ||
            expectedGeneration != currentGeneration) {
            return SshForwardingResult::StaleSession;
        }
        return forwardingManager_.markListening(id, currentGeneration);
    };
    if (isReactorThread()) {
        return operation();
    }
    return runOnReactor(operation);
}

SshForwardingResult SshAdapter::failForwarding(const std::string& id,
                                               uint64_t expectedGeneration,
                                               int error) {
    auto operation = [this, id, expectedGeneration, error]() {
        const uint64_t currentGeneration = diagnostics_.sessionGeneration();
        if (expectedGeneration == 0 || currentGeneration == 0 ||
            expectedGeneration != currentGeneration) {
            return SshForwardingResult::StaleSession;
        }
        const SshForwardingResult result =
            forwardingManager_.fail(id, currentGeneration, error);
        if (result == SshForwardingResult::Ok) {
            std::unique_lock<std::mutex> sessionLock(sessionMutex_);
            closeLocalForwardRuntimeLocked(id);
        }
        return result;
    };
    if (isReactorThread()) {
        return operation();
    }
    return runOnReactor(operation);
}

SshForwardingResult SshAdapter::requestForwardingStop(
    const std::string& id, uint64_t expectedGeneration) {
    auto operation = [this, id, expectedGeneration]() {
        const uint64_t currentGeneration = diagnostics_.sessionGeneration();
        if (expectedGeneration == 0 || currentGeneration == 0 ||
            expectedGeneration != currentGeneration) {
            return SshForwardingResult::StaleSession;
        }
        const SshForwardingResult result =
            forwardingManager_.requestStop(id, currentGeneration);
        if (result == SshForwardingResult::Ok) {
            std::unique_lock<std::mutex> sessionLock(sessionMutex_);
            closeLocalForwardRuntimeLocked(id);
        }
        return result;
    };
    if (isReactorThread()) {
        return operation();
    }
    return runOnReactor(operation);
}

SshForwardingResult SshAdapter::completeForwardingStop(const std::string& id,
                                                       uint64_t expectedGeneration) {
    auto operation = [this, id, expectedGeneration]() {
        const uint64_t currentGeneration = diagnostics_.sessionGeneration();
        if (expectedGeneration == 0 || currentGeneration == 0 ||
            expectedGeneration != currentGeneration) {
            return SshForwardingResult::StaleSession;
        }
        std::unique_lock<std::mutex> sessionLock(sessionMutex_);
        closeLocalForwardRuntimeLocked(id);
        return forwardingManager_.completeStop(id);
    };
    if (isReactorThread()) {
        return operation();
    }
    return runOnReactor(operation);
}

SshForwardingResult SshAdapter::acquireForwardingConnection(
    const std::string& id, uint64_t expectedGeneration) {
    auto operation = [this, id, expectedGeneration]() {
        const uint64_t currentGeneration = diagnostics_.sessionGeneration();
        if (expectedGeneration == 0 || currentGeneration == 0 ||
            expectedGeneration != currentGeneration) {
            return SshForwardingResult::StaleSession;
        }
        return forwardingManager_.acquireConnection(id, currentGeneration);
    };
    if (isReactorThread()) {
        return operation();
    }
    return runOnReactor(operation);
}

SshForwardingResult SshAdapter::releaseForwardingConnection(
    const std::string& id, uint64_t expectedGeneration) {
    auto operation = [this, id, expectedGeneration]() {
        const uint64_t currentGeneration = diagnostics_.sessionGeneration();
        if (expectedGeneration == 0 || currentGeneration == 0 ||
            expectedGeneration != currentGeneration) {
            return SshForwardingResult::StaleSession;
        }
        return forwardingManager_.releaseConnection(id, currentGeneration);
    };
    if (isReactorThread()) {
        return operation();
    }
    return runOnReactor(operation);
}

std::vector<SshForwardingSnapshot> SshAdapter::forwardingSnapshots() const {
    return forwardingManager_.snapshots();
}

int SshAdapter::createLocalForwardListener(const SshForwardingConfig& config,
                                           std::string& boundHost, int& boundPort,
                                           int& boundFamily, int& errorCode) {
    errorCode = 0;
    boundHost.clear();
    boundPort = 0;
    boundFamily = AF_UNSPEC;
    if (!isReactorThread()) {
        errorCode = EPERM;
        return -1;
    }

    const std::string& bindHost = config.bindHost;
    char portString[16] = {0};
    snprintf(portString, sizeof(portString), "%d", config.bindPort);

    addrinfo hints {};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    addrinfo* addresses = nullptr;
    const int resolveResult = getaddrinfo(bindHost.c_str(), portString, &hints, &addresses);
    if (resolveResult != 0 || addresses == nullptr) {
        errorCode = EADDRNOTAVAIL;
        return -1;
    }

    int listenerFd = -1;
    int lastError = EADDRNOTAVAIL;
    for (addrinfo* address = addresses; address != nullptr; address = address->ai_next) {
        const int candidate = socket(address->ai_family, address->ai_socktype,
                                     address->ai_protocol);
        if (candidate < 0) {
            lastError = errno;
            continue;
        }
        int reuse = 1;
        (void)setsockopt(candidate, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
        if (address->ai_family == AF_INET6) {
            // A single IPv6 forwarding profile is IPv6-only by contract.
            // Dual-stack exposure must be represented by a second explicit
            // IPv4 listener instead of depending on platform defaults.
            const int ipv6Only = 1;
            if (setsockopt(candidate, IPPROTO_IPV6, IPV6_V6ONLY,
                           &ipv6Only, sizeof(ipv6Only)) != 0) {
                lastError = errno;
                close(candidate);
                continue;
            }
        }
        const int flags = fcntl(candidate, F_GETFL, 0);
        if (flags < 0 || fcntl(candidate, F_SETFL, flags | O_NONBLOCK) < 0) {
            lastError = errno;
            close(candidate);
            continue;
        }
        const int descriptorFlags = fcntl(candidate, F_GETFD, 0);
        if (descriptorFlags >= 0) {
            (void)fcntl(candidate, F_SETFD, descriptorFlags | FD_CLOEXEC);
        }
        if (bind(candidate, address->ai_addr, address->ai_addrlen) != 0) {
            lastError = errno;
            close(candidate);
            continue;
        }
        if (listen(candidate, static_cast<int>(SshForwardingManager::kMaxConnections)) != 0) {
            lastError = errno;
            close(candidate);
            continue;
        }
        sockaddr_storage actualAddress {};
        socklen_t actualLength = sizeof(actualAddress);
        if (getsockname(candidate, reinterpret_cast<sockaddr*>(&actualAddress),
                        &actualLength) != 0) {
            lastError = errno;
            close(candidate);
            continue;
        }
        char numericHost[NI_MAXHOST] = {0};
        char numericService[NI_MAXSERV] = {0};
        const int nameResult = getnameinfo(
            reinterpret_cast<const sockaddr*>(&actualAddress), actualLength,
            numericHost, sizeof(numericHost), numericService, sizeof(numericService),
            NI_NUMERICHOST | NI_NUMERICSERV);
        if (nameResult != 0) {
            lastError = EADDRNOTAVAIL;
            close(candidate);
            continue;
        }
        char* end = nullptr;
        errno = 0;
        const long parsedPort = strtol(numericService, &end, 10);
        if (errno != 0 || end == numericService || *end != '\0' ||
            parsedPort <= 0 || parsedPort > 65535) {
            lastError = EADDRNOTAVAIL;
            close(candidate);
            continue;
        }
        boundHost = numericHost;
        boundPort = static_cast<int>(parsedPort);
        boundFamily = actualAddress.ss_family;
        listenerFd = candidate;
        break;
    }
    freeaddrinfo(addresses);
    if (listenerFd < 0) {
        errorCode = lastError;
        return -1;
    }
    return listenerFd;
}

LIBSSH2_LISTENER* SshAdapter::createRemoteForwardListener(
    const SshForwardingConfig& config, int& boundPort, int& errorCode) {
    errorCode = 0;
    boundPort = config.bindPort;
    if (!isReactorThread()) {
        errorCode = EPERM;
        return nullptr;
    }
    if (session_ == nullptr || sockFd_ < 0) {
        errorCode = ENOTCONN;
        return nullptr;
    }

    const std::string& bindHost = config.bindHost;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    while (std::chrono::steady_clock::now() < deadline) {
        LIBSSH2_LISTENER* listener = nullptr;
        if (!admitConnectedRouteWrite([&]() {
                listener = libssh2_channel_forward_listen_ex(
                    session_, bindHost.c_str(), config.bindPort, &boundPort,
                    static_cast<int>(config.maxConnections));
            })) {
            errorCode = ECANCELED;
            return nullptr;
        }
        if (listener != nullptr) {
            return listener;
        }
        const int libssh2Error = libssh2_session_last_errno(session_);
        if (libssh2Error != LIBSSH2_ERROR_EAGAIN) {
            errorCode = libssh2Error;
            return nullptr;
        }
        const int waitResult = waitSocket(2, 1);
        if (waitResult == -3 || connectCancelRequested_.load(std::memory_order_acquire)) {
            errorCode = ECANCELED;
            return nullptr;
        }
        if (waitResult == -1) {
            errorCode = errno != 0 ? errno : EIO;
            return nullptr;
        }
    }
    errorCode = ETIMEDOUT;
    return nullptr;
}

bool SshAdapter::queueDynamicSocksFailureLocked(LocalForwardConnection& connection,
                                                uint8_t replyCode) {
    try {
        connection.toLocal.insert(connection.toLocal.end(),
                                  {0x05, replyCode, 0x00, 0x01,
                                   0x00, 0x00, 0x00, 0x00, 0x00, 0x00});
    } catch (...) {
        return false;
    }
    connection.closeAfterLocalFlush = true;
    return true;
}

int SshAdapter::pumpDynamicSocksHandshakeLocked(LocalForwardConnection& connection) {
    if (connection.localFd < 0 || connection.mode != SshForwardingMode::Dynamic) {
        return -1;
    }
    std::array<uint8_t, 4096> buffer {};
    if (!connection.localEof && connection.socksInput.size() < 8192) {
        const uint64_t remaining = forwardingManager_.remainingBytes(
            connection.profileId, connection.sessionGeneration);
        const size_t readLength = static_cast<size_t>(std::min<uint64_t>(
            remaining == 0 ? static_cast<uint64_t>(buffer.size()) : remaining,
            static_cast<uint64_t>(buffer.size())));
        const ssize_t received = remaining == 0 ? 0 : recv(
            connection.localFd, buffer.data(), readLength, MSG_DONTWAIT);
        if (received > 0) {
            if (forwardingManager_.recordBytes(connection.profileId,
                                                connection.sessionGeneration,
                                                static_cast<uint64_t>(received)) !=
                SshForwardingResult::Ok) {
                return -1;
            }
            try {
                connection.socksInput.insert(connection.socksInput.end(), buffer.begin(),
                                             buffer.begin() + received);
            } catch (...) {
                return -1;
            }
        } else if (received == 0) {
            connection.localEof = true;
        } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            return -1;
        }
    }
    if (connection.socksInput.size() > 8192) {
        return -1;
    }

    if (!connection.socksGreetingComplete) {
        if (connection.socksInput.size() < 2) {
            return connection.localEof ? -1 : 0;
        }
        const uint8_t version = connection.socksInput[0];
        const size_t methodCount = connection.socksInput[1];
        const size_t greetingSize = 2 + methodCount;
        if (version != 5) {
            return -1;
        }
        if (connection.socksInput.size() < greetingSize) {
            return connection.localEof ? -1 : 0;
        }
        bool noAuthentication = false;
        for (size_t index = 0; index < methodCount; ++index) {
            if (connection.socksInput[2 + index] == 0x00) {
                noAuthentication = true;
                break;
            }
        }
        connection.socksInput.erase(connection.socksInput.begin(),
                                    connection.socksInput.begin() + greetingSize);
        if (!noAuthentication) {
            return queueDynamicSocksFailureLocked(connection, 0xFF)
                ? kSocksCloseAfterFlush : -1;
        }
        try {
            connection.toLocal.insert(connection.toLocal.end(), {0x05, 0x00});
        } catch (...) {
            return -1;
        }
        connection.socksGreetingComplete = true;
    }

    if (!connection.socksRequestComplete) {
        if (connection.socksInput.size() < 4) {
            return connection.localEof ? -1 : 0;
        }
        if (connection.socksInput[0] != 0x05 || connection.socksInput[2] != 0x00) {
            return connection.socksInput[0] == 0x05 &&
                queueDynamicSocksFailureLocked(connection, 0x01)
                ? kSocksCloseAfterFlush : -1;
        }
        const uint8_t command = connection.socksInput[1];
        const uint8_t addressType = connection.socksInput[3];
        size_t addressLength = 0;
        size_t requestSize = 0;
        if (addressType == 0x01) {
            addressLength = 4;
            requestSize = 4 + addressLength + 2;
        } else if (addressType == 0x03) {
            if (connection.socksInput.size() < 5) {
                return connection.localEof ? -1 : 0;
            }
            addressLength = connection.socksInput[4];
            if (addressLength == 0 || addressLength > 255) {
                return queueDynamicSocksFailureLocked(connection, 0x08)
                    ? kSocksCloseAfterFlush : -1;
            }
            requestSize = 4 + 1 + addressLength + 2;
        } else if (addressType == 0x04) {
            addressLength = 16;
            requestSize = 4 + addressLength + 2;
        } else {
            return queueDynamicSocksFailureLocked(connection, 0x08)
                ? kSocksCloseAfterFlush : -1;
        }
        if (connection.socksInput.size() < requestSize) {
            return connection.localEof ? -1 : 0;
        }
        if (command != 0x01) {
            return queueDynamicSocksFailureLocked(connection, 0x07)
                ? kSocksCloseAfterFlush : -1;
        }

        size_t addressOffset = 4;
        if (addressType == 0x03) { addressOffset = 5; }
        if (addressType == 0x01 || addressType == 0x04) {
            char addressText[INET6_ADDRSTRLEN] = {0};
            const void* addressBytes = connection.socksInput.data() + addressOffset;
            const int addressFamily = addressType == 0x01 ? AF_INET : AF_INET6;
            if (inet_ntop(addressFamily, addressBytes, addressText,
                          sizeof(addressText)) == nullptr) {
                return queueDynamicSocksFailureLocked(connection, 0x01)
                    ? kSocksCloseAfterFlush : -1;
            }
            connection.dynamicTargetHost = addressText;
        } else {
            connection.dynamicTargetHost.assign(
                reinterpret_cast<const char*>(connection.socksInput.data() + addressOffset),
                addressLength);
        }
        const size_t portOffset = addressOffset + addressLength;
        connection.dynamicTargetPort =
            (static_cast<int>(connection.socksInput[portOffset]) << 8) |
            static_cast<int>(connection.socksInput[portOffset + 1]);
        if (connection.dynamicTargetHost.empty() || connection.dynamicTargetPort <= 0 ||
            connection.dynamicTargetPort > 65535 ||
            !SshForwardingManager::normalizeRuntimeTargetHost(
                connection.dynamicTargetHost)) {
            return queueDynamicSocksFailureLocked(connection, 0x04)
                ? kSocksCloseAfterFlush : -1;
        }
        connection.socksInput.erase(connection.socksInput.begin(),
                                    connection.socksInput.begin() + requestSize);
        try {
            connection.toChannel.insert(connection.toChannel.end(), connection.socksInput.begin(),
                                        connection.socksInput.end());
        } catch (...) {
            return -1;
        }
        connection.socksInput.clear();
        connection.socksRequestComplete = true;
    }
    return 1;
}

int SshAdapter::openLocalForwardChannelLocked(LocalForwardConnection& connection,
                                              const SshForwardingConfig& config) {
    if (connection.mode == SshForwardingMode::Remote) {
        return connection.channel != nullptr ? 1 : -1;
    }
    if (connection.channel != nullptr) {
        return 1;
    }
    if (session_ == nullptr || connection.localFd < 0) {
        return -1;
    }
    std::string targetHost = connection.mode == SshForwardingMode::Dynamic
        ? connection.dynamicTargetHost : config.targetHost;
    const int targetPort = connection.mode == SshForwardingMode::Dynamic
        ? connection.dynamicTargetPort : config.targetPort;
    if (targetHost.empty() || targetPort <= 0 || targetPort > 65535) {
        return -1;
    }
    if (!admitConnectedRouteWrite([&]() {
            connection.channel = libssh2_channel_direct_tcpip_ex(
                session_, targetHost.c_str(), targetPort, "127.0.0.1", 0);
        })) {
        return -1;
    }
    if (connection.channel != nullptr) {
        return 1;
    }
    const int error = libssh2_session_last_errno(session_);
    if (error == LIBSSH2_ERROR_EAGAIN) {
        return 0;
    }
    OH_LOG_ERROR(LOG_APP,
                 "[SSH] local forwarding direct-tcpip 打开失败 id=%{public}s rc=%{public}d",
                 connection.profileId.c_str(), error);
    return -1;
}

bool SshAdapter::pumpLocalForwardConnectionLocked(LocalForwardConnection& connection,
                                                   const SshForwardingConfig& config) {
    if (connection.targetConnectTask.pending()) {
        if (!connection.targetConnectTask.ready()) {
            return connection.sessionGeneration == diagnostics_.sessionGeneration();
        }
        const SshForwardTargetConnectResult target = connection.targetConnectTask.take();
        if (target.descriptor < 0) {
            OH_LOG_WARN(LOG_APP,
                        "[SSH] remote forwarding target 连接失败 id=%{public}s errno=%{public}d",
                        connection.profileId.c_str(), target.errorCode);
            return false;
        }
        connection.localFd = target.descriptor;
        connection.localConnecting = false;
    }
    if (connection.localFd < 0 || connection.sessionGeneration != diagnostics_.sessionGeneration()) {
        return false;
    }
    if (connection.localConnecting) {
        struct pollfd pollDescriptor {
            connection.localFd, POLLOUT | POLLERR | POLLHUP, 0
        };
        const int pollResult = poll(&pollDescriptor, 1, 0);
        if (pollResult < 0) {
            return errno == EINTR;
        }
        if (pollResult == 0 || (pollDescriptor.revents & POLLOUT) == 0) {
            if ((pollDescriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                return false;
            }
            // Do not relay the remote channel while the target socket is
            // still in EINPROGRESS. The next reactor turn will re-check it.
            return true;
        }
        int socketError = 0;
        socklen_t errorLength = sizeof(socketError);
        if (getsockopt(connection.localFd, SOL_SOCKET, SO_ERROR,
                       &socketError, &errorLength) != 0 || socketError != 0) {
            return false;
        }
        connection.localConnecting = false;
    }

    // A SOCKS5 protocol error owns the connection only until its failure
    // reply is flushed. Never re-enter the handshake while a partial reply is
    // waiting, otherwise the active-connection limit can be held forever.
    if (connection.closeAfterLocalFlush) {
        if (connection.toLocal.empty()) {
            connection.closeAfterLocalFlush = false;
            return false;
        }
        int sendFlags = MSG_DONTWAIT;
#ifdef MSG_NOSIGNAL
        sendFlags |= MSG_NOSIGNAL;
#endif
        const ssize_t written = send(connection.localFd, connection.toLocal.data(),
                                     connection.toLocal.size(), sendFlags);
        if (written > 0) {
            connection.toLocal.erase(connection.toLocal.begin(),
                                     connection.toLocal.begin() + written);
            if (connection.toLocal.empty()) {
                connection.closeAfterLocalFlush = false;
                return false;
            }
            return true;
        }
        if (written < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            return false;
        }
        return true;
    }

    if (connection.mode == SshForwardingMode::Dynamic &&
        !connection.socksRequestComplete) {
        const int handshakeResult = pumpDynamicSocksHandshakeLocked(connection);
        if (handshakeResult == kSocksCloseAfterFlush) {
            if (!connection.toLocal.empty()) {
                int sendFlags = MSG_DONTWAIT;
#ifdef MSG_NOSIGNAL
                sendFlags |= MSG_NOSIGNAL;
#endif
                const ssize_t written = send(connection.localFd, connection.toLocal.data(),
                                              connection.toLocal.size(), sendFlags);
                if (written > 0) {
                    connection.toLocal.erase(connection.toLocal.begin(),
                                             connection.toLocal.begin() + written);
                } else if (written < 0 && errno != EAGAIN && errno != EWOULDBLOCK &&
                           errno != EINTR) {
                    return false;
                }
            }
            return !connection.toLocal.empty();
        }
        if (handshakeResult < 0) { return false; }
        if (handshakeResult == 0) {
            if (!connection.toLocal.empty()) {
                int sendFlags = MSG_DONTWAIT;
#ifdef MSG_NOSIGNAL
                sendFlags |= MSG_NOSIGNAL;
#endif
                const ssize_t written = send(connection.localFd, connection.toLocal.data(),
                                              connection.toLocal.size(), sendFlags);
                if (written > 0) {
                    connection.toLocal.erase(connection.toLocal.begin(),
                                             connection.toLocal.begin() + written);
                } else if (written < 0 && errno != EAGAIN && errno != EWOULDBLOCK &&
                           errno != EINTR) {
                    return false;
                }
            }
            return true;
        }
    }

    const int openResult = openLocalForwardChannelLocked(connection, config);
    if (openResult < 0) {
        return false;
    }
    if (connection.mode == SshForwardingMode::Dynamic && openResult > 0 &&
        !connection.socksConnectResponseQueued) {
        // The SOCKS5 success response is emitted only after the SSH
        // direct-tcpip channel has been accepted. This prevents a client from
        // sending application bytes into a channel that failed to open.
        connection.toLocal.insert(connection.toLocal.end(),
                                  {0x05, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00});
        connection.socksConnectResponseQueued = true;
    }

    std::array<uint8_t, SSH_BUFFER_SIZE> buffer {};
    if (!connection.localEof && connection.toChannel.size() < kForwardBufferLimit) {
        const uint64_t remaining = forwardingManager_.remainingBytes(
            connection.profileId, connection.sessionGeneration);
        if (remaining == 0 && config.maxBytes != 0) {
            connection.localEof = true;
        }
        const size_t readLength = static_cast<size_t>(std::min<uint64_t>(
            remaining == 0 ? static_cast<uint64_t>(buffer.size()) : remaining,
            static_cast<uint64_t>(buffer.size())));
        const ssize_t received = connection.localEof || readLength == 0 ? 0 :
            recv(connection.localFd, buffer.data(), readLength, MSG_DONTWAIT);
        if (received > 0) {
            if (forwardingManager_.recordBytes(connection.profileId,
                                                connection.sessionGeneration,
                                                static_cast<uint64_t>(received)) !=
                SshForwardingResult::Ok) {
                return false;
            }
            try {
                connection.toChannel.insert(connection.toChannel.end(),
                                            buffer.begin(), buffer.begin() + received);
            } catch (...) {
                return false;
            }
        } else if (received == 0) {
            connection.localEof = true;
        } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            return false;
        }
    }

    if (connection.channel != nullptr && !connection.toChannel.empty()) {
        ssize_t written = LIBSSH2_ERROR_SOCKET_SEND;
        if (!admitConnectedRouteWrite([&]() {
                written = libssh2_channel_write(
                    connection.channel,
                    reinterpret_cast<const char*>(connection.toChannel.data()),
                    connection.toChannel.size());
            })) {
            return false;
        }
        if (written > 0) {
            connection.toChannel.erase(connection.toChannel.begin(),
                                       connection.toChannel.begin() + written);
        } else if (written < 0 && written != LIBSSH2_ERROR_EAGAIN) {
            return false;
        }
    }

    if (connection.channel != nullptr && connection.localEof &&
        connection.toChannel.empty() && !connection.channelEofSent) {
        int eofResult = LIBSSH2_ERROR_SOCKET_SEND;
        if (!admitConnectedRouteWrite([&]() {
                eofResult = libssh2_channel_send_eof(connection.channel);
            })) {
            return false;
        }
        if (eofResult == 0) {
            connection.channelEofSent = true;
        } else if (eofResult != LIBSSH2_ERROR_EAGAIN) {
            return false;
        }
    }

    if (connection.channel != nullptr && connection.toLocal.size() < kForwardBufferLimit) {
        for (size_t attempt = 0; attempt < 4; ++attempt) {
            const uint64_t remaining = forwardingManager_.remainingBytes(
                connection.profileId, connection.sessionGeneration);
            if (remaining == 0 && config.maxBytes != 0) { break; }
            const size_t readLength = static_cast<size_t>(std::min<uint64_t>(
                remaining == 0 ? static_cast<uint64_t>(buffer.size()) : remaining,
                static_cast<uint64_t>(buffer.size())));
            ssize_t received = LIBSSH2_ERROR_SOCKET_SEND;
            if (!admitConnectedRouteRead([&]() {
                    received = libssh2_channel_read(
                        connection.channel,
                        reinterpret_cast<char*>(buffer.data()), readLength);
                })) {
                return false;
            }
            if (received > 0) {
                if (forwardingManager_.recordBytes(connection.profileId,
                                                    connection.sessionGeneration,
                                                    static_cast<uint64_t>(received)) !=
                    SshForwardingResult::Ok) {
                    return false;
                }
                try {
                    connection.toLocal.insert(connection.toLocal.end(),
                                              buffer.begin(), buffer.begin() + received);
                } catch (...) {
                    return false;
                }
                continue;
            }
            if (received == LIBSSH2_ERROR_EAGAIN) {
                break;
            }
            if (received == 0) {
                if (libssh2_channel_eof(connection.channel) != 0) {
                    connection.channelEof = true;
                }
                break;
            }
            return false;
        }
    }

    if (connection.localFd >= 0 && !connection.toLocal.empty()) {
        int sendFlags = MSG_DONTWAIT;
#ifdef MSG_NOSIGNAL
        sendFlags |= MSG_NOSIGNAL;
#endif
        const ssize_t written = send(connection.localFd, connection.toLocal.data(),
                                     connection.toLocal.size(), sendFlags);
        if (written > 0) {
            connection.toLocal.erase(connection.toLocal.begin(),
                                     connection.toLocal.begin() + written);
        } else if (written < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            return false;
        }
    }

    if (connection.channelEof && connection.toLocal.empty() &&
        !connection.localWriteShutdown) {
        // SSH channel EOF is the peer's half-close. Preserve the local read
        // side so the client can still send its final request/response bytes.
        (void)shutdown(connection.localFd, SHUT_WR);
        connection.localWriteShutdown = true;
    }
    if (connection.localEof && connection.channelEof &&
        connection.toChannel.empty() && connection.toLocal.empty()) {
        // Destroy the socket only after both directions have observed EOF and
        // both relay buffers have drained. Closing here before localEof loses
        // valid TCP half-close traffic from the client.
        return false;
    }
    return true;
}

bool SshAdapter::tryFreeConnectedForwardChannelLocked(
    LIBSSH2_CHANNEL*& channel) {
    if (channel == nullptr) { return true; }
    int result = LIBSSH2_ERROR_EAGAIN;
    if (!admitConnectedRouteWrite([&]() {
            // libssh2_channel_free() automatically closes an open channel and
            // can therefore emit SSH_MSG_CHANNEL_CLOSE before it releases the
            // local object.
            result = libssh2_channel_free(channel);
        }) || result == LIBSSH2_ERROR_EAGAIN) {
        return false;
    }
    channel = nullptr;
    return true;
}

void SshAdapter::deferForwardChannelCloseLocked(LIBSSH2_CHANNEL* channel) {
    if (channel == nullptr) { return; }
    if (tryFreeConnectedForwardChannelLocked(channel)) { return; }
    try {
        deferredForwardChannelCloses_.push_back(channel);
    } catch (...) {
        // Never discard a live libssh2 pointer on allocation failure. Retire
        // the descriptor without closing it (preventing fd reuse), then allow
        // libssh2 to release only local state. Recovery owns the final close.
        if (sockFd_ >= 0) { (void)shutdown(sockFd_, SHUT_RDWR); }
        (void)libssh2_channel_free(channel);
        transportRecoveryRequested_.store(true, std::memory_order_release);
        reactorCommandCondition_.notify_all();
    }
}

bool SshAdapter::closeLocalForwardConnectionLocked(
    LocalForwardConnection& connection) {
    connection.targetConnectTask.cancelAndClose();
    const bool channelReleased =
        tryFreeConnectedForwardChannelLocked(connection.channel);
    if (connection.localFd >= 0) {
        shutdown(connection.localFd, SHUT_RDWR);
        close(connection.localFd);
        connection.localFd = -1;
    }
    if (connection.sessionGeneration != 0) {
        (void)forwardingManager_.releaseConnection(connection.profileId,
                                                    connection.sessionGeneration);
        connection.sessionGeneration = 0;
    }
    connection.toChannel.clear();
    connection.toLocal.clear();
    return channelReleased;
}

void SshAdapter::closeLocalForwardRuntimeLocked(const std::string& id) {
    const auto listener = localForwardListeners_.find(id);
    if (listener != localForwardListeners_.end()) {
        if (listener->second.fd >= 0) {
            close(listener->second.fd);
            listener->second.fd = -1;
        }
        if (listener->second.remoteListener != nullptr) {
            int cancelResult = LIBSSH2_ERROR_EAGAIN;
            const bool admitted = admitConnectedRouteWrite([&]() {
                cancelResult = libssh2_channel_forward_cancel(
                    listener->second.remoteListener);
            });
            if (admitted && cancelResult != LIBSSH2_ERROR_EAGAIN) {
                listener->second.remoteListener = nullptr;
            }
        }
        if (listener->second.remoteListener == nullptr) {
            localForwardListeners_.erase(listener);
        }
    }
    for (auto connection = localForwardConnections_.begin();
         connection != localForwardConnections_.end();) {
        if (connection->profileId != id) {
            ++connection;
            continue;
        }
        if (closeLocalForwardConnectionLocked(*connection)) {
            connection = localForwardConnections_.erase(connection);
        } else {
            ++connection;
        }
    }
}

void SshAdapter::serviceForwardingOnReactor() {
    if (!isReactorThread() || !readerRunning_.load(std::memory_order_acquire) ||
        state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
        return;
    }
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    if (session_ == nullptr || sockFd_ < 0) {
        return;
    }
    for (auto channel = deferredForwardChannelCloses_.begin();
         channel != deferredForwardChannelCloses_.end();) {
        if (!tryFreeConnectedForwardChannelLocked(*channel)) {
            // Retain the exact pointer and retry on the next reactor turn.
            // Do not accept another remote-forward channel while libssh2 is
            // still completing this channel's non-blocking close.
            return;
        }
        channel = deferredForwardChannelCloses_.erase(channel);
    }

    struct ForwardListenerFailure {
        std::string id;
        uint64_t generation;
        int error;
    };
    std::vector<ForwardListenerFailure> failedListeners;
    std::vector<std::string> staleRuntimeIds;
    for (auto& [id, listener] : localForwardListeners_) {
        (void)id;
        SshForwardingSnapshot snapshot;
        if (!forwardingManager_.snapshot(listener.profileId, snapshot)) {
            staleRuntimeIds.push_back(listener.profileId);
            continue;
        }
        if (snapshot.sessionGeneration != listener.sessionGeneration ||
            snapshot.config.mode != listener.mode) {
            if (snapshot.state != SshForwardingState::Stopped &&
                snapshot.sessionGeneration != 0) {
                failedListeners.push_back({listener.profileId,
                                           snapshot.sessionGeneration,
                                           static_cast<int>(SshForwardingResult::StaleSession)});
            } else {
                staleRuntimeIds.push_back(listener.profileId);
            }
            continue;
        }
        if (snapshot.state != SshForwardingState::Listening) {
            // Failed/stopping/starting profiles no longer own a listener. The
            // manager state is completed by the caller where applicable; the
            // reactor must still release every native runtime handle now.
            staleRuntimeIds.push_back(listener.profileId);
            continue;
        }
        const SshForwardingResult limits = forwardingManager_.checkRuntimeLimits(
            listener.profileId, listener.sessionGeneration);
        if (limits != SshForwardingResult::Ok) {
            failedListeners.push_back({listener.profileId, listener.sessionGeneration,
                                       static_cast<int>(limits)});
            continue;
        }

        if (listener.mode == SshForwardingMode::Remote) {
            for (size_t accepted = 0; accepted < kForwardAcceptBatch; ++accepted) {
                LIBSSH2_CHANNEL* channel = nullptr;
                LIBSSH2_LISTENER* const remoteListener =
                    listener.remoteListener;
                if (!admitConnectedRouteWrite([&channel, remoteListener]() {
                        channel = libssh2_channel_forward_accept(
                            remoteListener);
                    })) {
                    return;
                }
                if (channel == nullptr) {
                    const int libssh2Error = libssh2_session_last_errno(session_);
                    if (libssh2Error != LIBSSH2_ERROR_EAGAIN) {
                        OH_LOG_WARN(LOG_APP,
                                    "[SSH] remote forwarding accept 失败 id=%{public}s rc=%{public}d",
                                    listener.profileId.c_str(), libssh2Error);
                        failedListeners.push_back({listener.profileId,
                                                   listener.sessionGeneration,
                                                   libssh2Error});
                    }
                    break;
                }
                const size_t pendingTargetConnections = static_cast<size_t>(std::count_if(
                    localForwardConnections_.begin(), localForwardConnections_.end(),
                    [](const LocalForwardConnection& connection) {
                        return connection.targetConnectTask.pending();
                }));
                if (pendingTargetConnections >= kMaxForwardTargetConnectWorkers) {
                    deferForwardChannelCloseLocked(channel);
                    OH_LOG_WARN(LOG_APP,
                                "[SSH] remote forwarding target worker 已达上限 id=%{public}s",
                                listener.profileId.c_str());
                    break;
                }
                const SshForwardingResult acquired = forwardingManager_.acquireConnection(
                    listener.profileId, listener.sessionGeneration);
                if (acquired != SshForwardingResult::Ok) {
                    deferForwardChannelCloseLocked(channel);
                    continue;
                }
                bool queued = false;
                try {
                    LocalForwardConnection connection;
                    connection.profileId = listener.profileId;
                    connection.sessionGeneration = listener.sessionGeneration;
                    connection.mode = SshForwardingMode::Remote;
                    connection.channel = channel;
                    if (connection.targetConnectTask.start(
                            snapshot.config.targetHost, snapshot.config.targetPort)) {
                        localForwardConnections_.push_back(std::move(connection));
                        queued = true;
                    }
                } catch (...) {
                    // Cleanup below owns the manager slot and libssh2 channel.
                }
                if (!queued) {
                    (void)forwardingManager_.releaseConnection(listener.profileId,
                                                                listener.sessionGeneration);
                    deferForwardChannelCloseLocked(channel);
                    OH_LOG_WARN(LOG_APP,
                                "[SSH] remote forwarding target worker 启动失败 id=%{public}s",
                                listener.profileId.c_str());
                }
            }
            continue;
        }

        for (size_t accepted = 0; accepted < kForwardAcceptBatch; ++accepted) {
            sockaddr_storage address {};
            socklen_t addressLength = sizeof(address);
            const int clientFd = accept(listener.fd, reinterpret_cast<sockaddr*>(&address),
                                        &addressLength);
            if (clientFd < 0) {
                if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                    OH_LOG_WARN(LOG_APP,
                                "[SSH] local forwarding accept 失败 id=%{public}s errno=%{public}d",
                                listener.profileId.c_str(), errno);
                    failedListeners.push_back({listener.profileId,
                                               listener.sessionGeneration,
                                               errno});
                }
                break;
            }
            const int flags = fcntl(clientFd, F_GETFL, 0);
            const int descriptorFlags = fcntl(clientFd, F_GETFD, 0);
            if (flags < 0 || fcntl(clientFd, F_SETFL, flags | O_NONBLOCK) < 0) {
                close(clientFd);
                continue;
            }
            if (descriptorFlags >= 0) {
                (void)fcntl(clientFd, F_SETFD, descriptorFlags | FD_CLOEXEC);
            }
            const SshForwardingResult acquired = forwardingManager_.acquireConnection(
                listener.profileId, listener.sessionGeneration);
            if (acquired != SshForwardingResult::Ok) {
                close(clientFd);
                continue;
            }
            try {
                LocalForwardConnection connection;
                connection.profileId = listener.profileId;
                connection.sessionGeneration = listener.sessionGeneration;
                connection.mode = listener.mode;
                connection.localFd = clientFd;
                localForwardConnections_.push_back(std::move(connection));
            } catch (...) {
                (void)forwardingManager_.releaseConnection(listener.profileId,
                                                            listener.sessionGeneration);
                close(clientFd);
            }
        }
    }

    for (const std::string& id : staleRuntimeIds) {
        closeLocalForwardRuntimeLocked(id);
    }
    for (const auto& failure : failedListeners) {
        (void)forwardingManager_.fail(failure.id, failure.generation, failure.error);
        closeLocalForwardRuntimeLocked(failure.id);
    }
    failedListeners.clear();

    for (auto connection = localForwardConnections_.begin();
         connection != localForwardConnections_.end();) {
        SshForwardingSnapshot snapshot;
        const bool valid = forwardingManager_.snapshot(connection->profileId, snapshot) &&
            snapshot.config.mode == connection->mode &&
            snapshot.state == SshForwardingState::Listening &&
            snapshot.sessionGeneration == connection->sessionGeneration;
        const bool pumped = valid && pumpLocalForwardConnectionLocked(*connection, snapshot.config);
        SshForwardingSnapshot afterPump;
        if (!pumped && forwardingManager_.snapshot(connection->profileId, afterPump) &&
            afterPump.state == SshForwardingState::Failed &&
            afterPump.sessionGeneration == connection->sessionGeneration) {
            failedListeners.push_back({connection->profileId, connection->sessionGeneration,
                                       afterPump.lastError});
        }
        if (!pumped) {
            if (closeLocalForwardConnectionLocked(*connection)) {
                connection = localForwardConnections_.erase(connection);
            } else {
                ++connection;
            }
        } else {
            ++connection;
        }
    }
    for (const auto& failure : failedListeners) {
        (void)forwardingManager_.fail(failure.id, failure.generation, failure.error);
        closeLocalForwardRuntimeLocked(failure.id);
    }
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
    switch (s) {
        case ConnectionState::CONNECTING:
            setSshLifecycleState(SshSessionLifecycleState::Connecting);
            break;
        case ConnectionState::AUTHENTICATING:
            setSshLifecycleState(SshSessionLifecycleState::Authenticating);
            break;
        case ConnectionState::CONNECTED:
            setSshLifecycleState(SshSessionLifecycleState::Ready);
            break;
        case ConnectionState::RECONNECTING:
            setSshLifecycleState(SshSessionLifecycleState::Reconnecting);
            break;
        case ConnectionState::ERROR:
            setSshLifecycleState(SshSessionLifecycleState::Failed);
            break;
        case ConnectionState::DISCONNECTED:
            setSshLifecycleState(SshSessionLifecycleState::Closed);
            break;
    }
    setConnectionStateOnly(s, message);
}

void SshAdapter::setConnectionStateOnly(
    ConnectionState s, const std::string& message) {
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

bool SshAdapter::connectRouteCancelled() const {
    return SshNetworkGenerationPolicy::shouldCancel(
        connectCancelRequested_.load(std::memory_order_acquire),
        remotedesk::net::ProcessNetworkGenerationFence(),
        connectNetworkSnapshot_);
}

std::chrono::steady_clock::time_point
SshAdapter::connectRouteDeadline() const noexcept {
    return std::chrono::steady_clock::time_point(
        std::chrono::steady_clock::duration(
            connectRouteDeadlineTicks_.load(std::memory_order_acquire)));
}

void SshAdapter::setConnectRouteDeadline(
    std::chrono::steady_clock::time_point deadline) noexcept {
    connectRouteDeadlineTicks_.store(
        deadline.time_since_epoch().count(), std::memory_order_release);
}

bool SshAdapter::connectRouteDeadlineExpired() const noexcept {
    const auto deadline = connectRouteDeadline();
    return deadline != std::chrono::steady_clock::time_point::max() &&
        SshNetworkGenerationPolicy::deadlineExpired(
            deadline, std::chrono::steady_clock::now());
}

std::chrono::steady_clock::time_point
SshAdapter::boundedConnectStageDeadline(
    std::chrono::milliseconds stageBudget) const noexcept {
    return SshNetworkGenerationPolicy::boundedStageDeadline(
        std::chrono::steady_clock::now(), connectRouteDeadline(), stageBudget);
}

int SshAdapter::routeWriteFailure(int deadlineError) const noexcept {
    return connectRouteDeadlineExpired() ? deadlineError
                                         : ERR_SSH_SESSION_CLOSED;
}

bool SshAdapter::admitRouteWrite(
    const remotedesk::net::NetworkGenerationSnapshot& networkSnapshot,
    const std::function<void()>& write) const {
    return SshNetworkGenerationPolicy::admitWrite(
        remotedesk::net::ProcessNetworkGenerationFence(), networkSnapshot,
        [this, &networkSnapshot]() {
            return networkSnapshot.generation !=
                    connectNetworkSnapshot_.generation ||
                networkSnapshot.available != connectNetworkSnapshot_.available ||
                connectCancelRequested_.load(std::memory_order_acquire) ||
                connectRouteDeadlineExpired();
        },
        write);
}

bool SshAdapter::admitConnectedRouteWrite(
    const std::function<void()>& write) const {
    return state_.load(std::memory_order_acquire) ==
            ConnectionState::CONNECTED &&
        admitRouteWrite(connectNetworkSnapshot_, write);
}

bool SshAdapter::admitConnectedRouteRead(
    const std::function<void()>& read) const {
    // libssh2_channel_read_ex() may replenish the remote receive window before
    // returning payload. Treat it as an outbound primitive even though the API
    // is named "read".
    return admitConnectedRouteWrite(read);
}

void SshAdapter::retirePrimaryTransportNoWireLocked(
    TransportTeardownContext& context) noexcept {
    if (context.transportRetired) { return; }
    // Keep the descriptor allocated until every libssh2 object is gone. A
    // close here could let another thread reuse the same integer while
    // libssh2 still retains it; shutdown makes every later send fail locally
    // without opening that fd-reuse window.
    if (sockFd_ >= 0) { (void)shutdown(sockFd_, SHUT_RDWR); }
    if (session_ != nullptr) {
        // After shutdown there is no remote progress to wait for. Blocking
        // mode lets libssh2 finish its local state-machine cleanup instead of
        // handing an EAGAIN-owned pointer back to a caller that is retiring it.
        libssh2_session_set_blocking(session_, 1);
    }
    context.transportRetired = true;
}

int SshAdapter::runTransportTeardownPrimitiveLocked(
    TransportTeardownContext& context,
    const std::function<int()>& primitive) {
    if (!primitive) { return 0; }
    while (!context.transportRetired) {
        int result = LIBSSH2_ERROR_EAGAIN;
        const bool admitted =
            remotedesk::net::ProcessNetworkGenerationFence().admitIfCurrent(
                connectNetworkSnapshot_, [&]() { result = primitive(); });
        const SshRouteTeardownDecision decision =
            SshRouteTeardownPolicy::decide(
                admitted, result, LIBSSH2_ERROR_EAGAIN,
                std::chrono::steady_clock::now(), context.deadline);
        if (decision == SshRouteTeardownDecision::Complete) {
            return result;
        }
        if (decision == SshRouteTeardownDecision::RetireTransport ||
            sockFd_ < 0) {
            retirePrimaryTransportNoWireLocked(context);
            break;
        }

        struct pollfd descriptor {
            sockFd_, POLLIN | POLLOUT | POLLERR | POLLHUP, 0
        };
        int pollResult;
        do {
            pollResult = poll(
                &descriptor, 1,
                SshRouteTeardownPolicy::kPollSliceMilliseconds);
        } while (pollResult < 0 && errno == EINTR);
        if (pollResult < 0) {
            retirePrimaryTransportNoWireLocked(context);
            break;
        }
    }

    // The descriptor is shut down but deliberately not closed, so these
    // calls can only advance/free libssh2's local state. Bound even this path
    // defensively in case a future libssh2 version reports a spurious EAGAIN.
    int result = LIBSSH2_ERROR_EAGAIN;
    for (std::uint32_t attempt = 0;
         attempt < SshRouteTeardownPolicy::kLocalReleaseAttempts &&
         result == LIBSSH2_ERROR_EAGAIN;
         ++attempt) {
        result = primitive();
    }
    return result;
}

void SshAdapter::teardownAllForwardingRuntimeLocked(
    TransportTeardownContext& context) {
    for (auto& [id, listener] : localForwardListeners_) {
        (void)id;
        if (listener.fd >= 0) {
            (void)shutdown(listener.fd, SHUT_RDWR);
            close(listener.fd);
            listener.fd = -1;
        }
        if (listener.remoteListener != nullptr) {
            LIBSSH2_LISTENER* const remoteListener = listener.remoteListener;
            (void)runTransportTeardownPrimitiveLocked(context, [remoteListener]() {
                return libssh2_channel_forward_cancel(remoteListener);
            });
            listener.remoteListener = nullptr;
        }
    }
    localForwardListeners_.clear();

    for (LocalForwardConnection& connection : localForwardConnections_) {
        connection.targetConnectTask.cancelAndClose();
        if (connection.localFd >= 0) {
            (void)shutdown(connection.localFd, SHUT_RDWR);
            close(connection.localFd);
            connection.localFd = -1;
        }
        if (connection.sessionGeneration != 0) {
            (void)forwardingManager_.releaseConnection(
                connection.profileId, connection.sessionGeneration);
            connection.sessionGeneration = 0;
        }
        if (connection.channel != nullptr) {
            (void)runTransportTeardownPrimitiveLocked(context, [&]() {
                return libssh2_channel_free(connection.channel);
            });
            connection.channel = nullptr;
        }
        connection.toChannel.clear();
        connection.toLocal.clear();
    }
    localForwardConnections_.clear();

    for (LIBSSH2_CHANNEL*& channel : deferredForwardChannelCloses_) {
        if (channel == nullptr) { continue; }
        (void)runTransportTeardownPrimitiveLocked(context, [&]() {
            return libssh2_channel_free(channel);
        });
        channel = nullptr;
    }
    deferredForwardChannelCloses_.clear();
}

void SshAdapter::teardownSessionHandlesLocked(const char* description) {
    TransportTeardownContext context {
        SshRouteTeardownPolicy::deadline(std::chrono::steady_clock::now()),
        false
    };
    if (sockFd_ < 0 ||
        remotedesk::net::ProcessNetworkGenerationFence().shouldCancel(
            connectNetworkSnapshot_)) {
        retirePrimaryTransportNoWireLocked(context);
    }

    teardownAllForwardingRuntimeLocked(context);
    if (sftp_ != nullptr) {
        (void)runTransportTeardownPrimitiveLocked(context, [&]() {
            return libssh2_sftp_shutdown(sftp_);
        });
        sftp_ = nullptr;
    }
    if (channel_ != nullptr) {
        (void)runTransportTeardownPrimitiveLocked(context, [&]() {
            return libssh2_channel_free(channel_);
        });
        channel_ = nullptr;
    }
    if (session_ != nullptr) {
        (void)runTransportTeardownPrimitiveLocked(context, [&]() {
            return libssh2_session_disconnect(
                session_, description != nullptr ? description : "Client disconnecting");
        });
        const int freeResult = runTransportTeardownPrimitiveLocked(context, [&]() {
            return libssh2_session_free(session_);
        });
        if (freeResult == LIBSSH2_ERROR_EAGAIN) {
            OH_LOG_WARN(LOG_APP,
                        "[SSH] local session release remained EAGAIN after transport retirement");
        }
        session_ = nullptr;
    }
    if (sockFd_ >= 0) {
        (void)shutdown(sockFd_, SHUT_RDWR);
        close(sockFd_);
        sockFd_ = -1;
    }
}

int SshAdapter::waitSocket(int direction, int timeoutSec) {
    if (sockFd_ < 0) {
        return -1;
    }
    if (connectRouteCancelled()) {
        return -3;
    }
    if (connectRouteDeadlineExpired()) {
        return -2;
    }

    const int timeoutMilliseconds = std::max(0, timeoutSec) * 1000;
    const auto deadline = boundedConnectStageDeadline(
        std::chrono::milliseconds(timeoutMilliseconds));
    while (true) {
        if (connectRouteCancelled()) {
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
    if (connectRouteCancelled()) { return -3; }
    if (connectRouteDeadlineExpired()) { return -2; }
    const int boundedMs = std::max(1, std::min(timeoutMs, 100));
    const auto deadline = boundedConnectStageDeadline(
        std::chrono::milliseconds(boundedMs));
    while (true) {
        if (connectRouteCancelled()) { return -3; }
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
    if (connectRouteDeadlineExpired()) { return -2; }
    const int timeoutMilliseconds = std::max(1, timeoutSec) * 1000;
    const auto deadline = boundedConnectStageDeadline(
        std::chrono::milliseconds(timeoutMilliseconds));
    while (true) {
        if (connectRouteCancelled()) { return -3; }
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
    if (connectRouteDeadlineExpired()) {
        return ERR_SSH_CONNECT_TIMEOUT;
    }
    if (host.empty() || port <= 0 || port > 65535) {
        const std::string logHost = SafeLog::MaskHost(host);
        OH_LOG_ERROR(LOG_APP, "[SSH] 地址参数无效: host=%{public}s port=%{public}d",
                     logHost.c_str(), port);
        return ERR_SSH_DNS_RESOLVE;
    }
    const auto endpoint = remotedesk::endpoint::ParseFields(
        host, static_cast<std::uint16_t>(port),
        remotedesk::endpoint::ParseMode::Persisted);
    if (!endpoint.ok) {
        return ERR_SSH_DNS_RESOLVE;
    }
    const std::string transportHost =
        remotedesk::endpoint::TransportHost(endpoint.endpoint);
    const std::string logHost = SafeLog::MaskHost(transportHost);

    char portString[16] = {0};
    snprintf(portString, sizeof(portString), "%d", port);
    remotedesk::net::ConnectOptions options;
    options.deadline = boundedConnectStageDeadline(std::chrono::seconds(10));
    remotedesk::net::NetworkGenerationFence& networkFence =
        remotedesk::net::ProcessNetworkGenerationFence();
    const remotedesk::net::NetworkGenerationSnapshot networkSnapshot =
        connectNetworkSnapshot_.generation == 0
            ? networkFence.snapshot() : connectNetworkSnapshot_;
    options.cancelled = [this, &networkFence, networkSnapshot]() {
        return SshNetworkGenerationPolicy::shouldCancel(
            connectCancelRequested_.load(std::memory_order_acquire),
            networkFence, networkSnapshot);
    };
    options.restoreBlocking = false;
    remotedesk::net::ConnectResult connection;
    const remotedesk::net::ResolveResult resolution =
        remotedesk::net::ResolveAndConnectTcp(
            transportHost, portString, options, connection);
    const int resolutionError = SshConnectErrorPolicy::fromResolution(resolution);
    if (resolutionError != ERR_SSH_SUCCESS) {
        OH_LOG_ERROR(LOG_APP,
                     "[SSH] DNS 阶段失败: host=%{public}s status=%{public}d "
                     "gai=%{public}d sshError=%{public}d",
                     logHost.c_str(), static_cast<int>(resolution.status),
                     resolution.gaiError, resolutionError);
        return resolutionError;
    }

    OH_LOG_INFO(LOG_APP, "[SSH] 正在连接 %{public}s:%{public}d (AF_UNSPEC) ...",
                logHost.c_str(), port);

    if (connection.status == remotedesk::net::ConnectStatus::Connected &&
        connection.descriptor >= 0) {
        sockFd_ = connection.descriptor;
        OH_LOG_INFO(LOG_APP, "[SSH] TCP 连接建立成功, family=%{public}d fd=%{public}d",
                    connection.family, sockFd_);
        return 0;
    }
    sockFd_ = -1;
    const int connectionError = SshConnectErrorPolicy::fromConnection(connection);
    OH_LOG_ERROR(LOG_APP,
                 "[SSH] TCP 阶段失败: host=%{public}s status=%{public}d "
                 "errno=%{public}d sshError=%{public}d",
                 logHost.c_str(), static_cast<int>(connection.status),
                 connection.lastError, connectionError);
    return connectionError;
}

int SshAdapter::sendSocketBytes(const uint8_t* data, size_t len, int timeoutSec) {
    if (sockFd_ < 0 || (data == nullptr && len > 0)) {
        return ERR_SSH_PROXY_FAILED;
    }
    size_t total = 0;
    while (total < len) {
        if (connectRouteDeadlineExpired()) {
            return ERR_SSH_CONNECT_TIMEOUT;
        }
        ssize_t sent = -1;
        int sendError = 0;
        if (!admitRouteWrite(connectNetworkSnapshot_, [&]() {
                sent = ::send(sockFd_, data + total, len - total, 0);
                sendError = sent < 0 ? errno : 0;
            })) {
            return routeWriteFailure(ERR_SSH_CONNECT_TIMEOUT);
        }
        if (sent > 0) {
            total += static_cast<size_t>(sent);
            continue;
        }
        if (sent < 0 && sendError == EINTR) { continue; }
        if (sent < 0 &&
            (sendError == EAGAIN || sendError == EWOULDBLOCK)) {
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
        if (connectRouteDeadlineExpired()) {
            return ERR_SSH_CONNECT_TIMEOUT;
        }
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
        if (connectRouteDeadlineExpired()) {
            return ERR_SSH_CONNECT_TIMEOUT;
        }
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

int SshAdapter::connectThroughProxy(ConnectionConfig& cfg) {
    const std::string type = cfg.sshProxyType.empty() ? "direct" : cfg.sshProxyType;
    if (!sshRouteTypeIsKnown(type)) {
        OH_LOG_ERROR(LOG_APP, "[SSH] 未知的代理类型: %{public}s", type.c_str());
        return ERR_SSH_PROXY_INVALID;
    }
    if (sshRouteTypeNeedsFrpControlPlane(type)) {
        OH_LOG_ERROR(LOG_APP,
                     "[SSH] FRP %{public}s 需要 FRP 控制面，当前 native 仅支持已映射的 frp_tcp",
                     type.c_str());
        return ERR_SSH_PROXY_UNSUPPORTED;
    }
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

    const int targetPort = cfg.port > 0 ? cfg.port : 22;
    const auto target = remotedesk::ssh::PrepareProxyTarget(
        type, cfg.host, static_cast<std::uint16_t>(targetPort));
    if (!target.ok) {
        return ERR_SSH_PROXY_INVALID;
    }

    int ret = tcpConnect(cfg.sshProxyHost, cfg.sshProxyPort);
    if (ret != 0) { return ret; }

    const std::string& targetHost = target.transportHost;
    if (targetHost.empty() || targetHost.size() > 255) {
        return ERR_SSH_PROXY_INVALID;
    }

    if (type == "http_connect") {
        const std::string& hostHeader = target.uriAuthority;
        {
            std::string request = "CONNECT " + hostHeader + " HTTP/1.1\r\n";
            SshSensitiveBufferGuard<std::string> requestGuard(request);
            request += "Host: " + hostHeader + "\r\n";
            request += "Proxy-Connection: Keep-Alive\r\n";
            if (!cfg.sshProxyUsername.empty() || !cfg.sshProxyPassword.empty()) {
                if (cfg.sshProxyUsername.find_first_of("\r\n") != std::string::npos ||
                    cfg.sshProxyPassword.find_first_of("\r\n") != std::string::npos) {
                    return ERR_SSH_PROXY_INVALID;
                }
                std::string credentials;
                SshSensitiveBufferGuard<std::string> credentialsGuard(credentials);
                credentials.reserve(cfg.sshProxyUsername.size() + 1U +
                                    cfg.sshProxyPassword.size());
                credentials.append(cfg.sshProxyUsername);
                credentials.push_back(':');
                credentials.append(cfg.sshProxyPassword);

                std::string encoded;
                SshSensitiveBufferGuard<std::string> encodedGuard(encoded);
                encodeBase64To(
                    reinterpret_cast<const unsigned char*>(credentials.data()),
                    credentials.size(), encoded);
                constexpr char kProxyAuthorizationPrefix[] =
                    "Proxy-Authorization: Basic ";
                constexpr std::size_t kAuthorizationTerminatorsSize = 4U;
                const std::size_t sensitiveSuffixSize =
                    (sizeof(kProxyAuthorizationPrefix) - 1U) + encoded.size() +
                    kAuthorizationTerminatorsSize;
                if (!sshReserveSensitiveAppend(request, sensitiveSuffixSize)) {
                    return ERR_SSH_PROXY_INVALID;
                }
                request.append(kProxyAuthorizationPrefix,
                               sizeof(kProxyAuthorizationPrefix) - 1U);
                request.append(encoded);
                request.append("\r\n\r\n");
            } else {
                request.append("\r\n");
            }
            ret = sendSocketBytes(
                reinterpret_cast<const uint8_t*>(request.data()), request.size(), 10);
        }
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
        {
            std::vector<uint8_t> auth;
            SshSensitiveBufferGuard<std::vector<uint8_t>> authGuard(auth);
            auth.reserve(3 + cfg.sshProxyUsername.size() + cfg.sshProxyPassword.size());
            auth.push_back(0x01);
            auth.push_back(static_cast<uint8_t>(cfg.sshProxyUsername.size()));
            auth.insert(auth.end(), cfg.sshProxyUsername.begin(), cfg.sshProxyUsername.end());
            auth.push_back(static_cast<uint8_t>(cfg.sshProxyPassword.size()));
            auth.insert(auth.end(), cfg.sshProxyPassword.begin(), cfg.sshProxyPassword.end());
            ret = sendSocketBytes(auth.data(), auth.size(), 10);
        }
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

int SshAdapter::connectThroughSshJump(ConnectionConfig& cfg) {
    if (cfg.host.empty() || cfg.port <= 0 || cfg.port > 65535) {
        return ERR_SSH_PROXY_INVALID;
    }

    // Keep the old single-hop fields as an input compatibility layer. The
    // normalized chain below is the only shape used by the transport code.
    std::vector<SshJumpHop> legacyHops;
    const std::vector<SshJumpHop>* hops = &cfg.sshRoute.hops;
    if (hops->empty()) {
        SshJumpHop hop;
        hop.host = cfg.sshProxyHost;
        hop.port = cfg.sshProxyPort;
        hop.username = cfg.sshProxyUsername;
        hop.authMethod = cfg.sshProxyAuthMethod.empty() ? "password" : cfg.sshProxyAuthMethod;
        hop.expectedHostKeyRawBase64 = cfg.sshJumpHostKeyRawBase64;
        hop.expectedHostKeyFingerprintSha256 = cfg.sshJumpHostKeyFingerprintSha256;
        legacyHops.push_back(std::move(hop));
        hops = &legacyHops;
    }
    if (hops->empty() || hops->size() > kSshMaxJumpHops ||
        !sshRouteHopsValid(SshRoute {
            1, SshRouteKind::SshJump, cfg.host, cfg.port, *hops, "", 10000})) {
        return ERR_SSH_PROXY_INVALID;
    }
    const auto targetEndpoint = remotedesk::endpoint::ParseFields(
        cfg.host, static_cast<std::uint16_t>(cfg.port),
        remotedesk::endpoint::ParseMode::Persisted);
    if (!targetEndpoint.ok || !targetEndpoint.endpoint.scope().empty()) {
        // The final target is resolved by the last jump server. Interface
        // scopes belong to the local network namespace and cannot cross it.
        return ERR_SSH_PROXY_INVALID;
    }
    const std::string normalizedTargetHost =
        remotedesk::endpoint::TransportHost(targetEndpoint.endpoint);
    std::vector<SshJumpHop> normalizedHops = *hops;
    for (size_t index = 0; index < normalizedHops.size(); ++index) {
        const auto hopEndpoint = remotedesk::endpoint::ParseFields(
            normalizedHops[index].host,
            static_cast<std::uint16_t>(normalizedHops[index].port),
            remotedesk::endpoint::ParseMode::Persisted);
        if (!hopEndpoint.ok ||
            (index > 0 && !hopEndpoint.endpoint.scope().empty())) {
            return ERR_SSH_PROXY_INVALID;
        }
        normalizedHops[index].host =
            remotedesk::endpoint::TransportHost(hopEndpoint.endpoint);
    }
    hops = &normalizedHops;
    if (cfg.sshJumpHopHandoffs.size() > hops->size()) {
        return ERR_SSH_PROXY_INVALID;
    }

    const std::string emptySecret;
    std::vector<std::string> emptyResponses;
    auto hopPassword = [&](size_t index) -> const std::string& {
        if (index < cfg.sshJumpHopHandoffs.size() &&
            !cfg.sshJumpHopHandoffs[index].password.empty()) {
            return cfg.sshJumpHopHandoffs[index].password;
        }
        return index == 0 ? cfg.sshProxyPassword : emptySecret;
    };
    auto hopPrivateKey = [&](size_t index) -> const std::string& {
        if (index < cfg.sshJumpHopHandoffs.size() &&
            !cfg.sshJumpHopHandoffs[index].privateKeyPem.empty()) {
            return cfg.sshJumpHopHandoffs[index].privateKeyPem;
        }
        return index == 0 ? cfg.sshProxyPrivateKeyPem : emptySecret;
    };
    auto hopPassphrase = [&](size_t index) -> const std::string& {
        if (index < cfg.sshJumpHopHandoffs.size() &&
            !cfg.sshJumpHopHandoffs[index].privateKeyPassphrase.empty()) {
            return cfg.sshJumpHopHandoffs[index].privateKeyPassphrase;
        }
        return index == 0 ? cfg.sshProxyPrivateKeyPassphrase : emptySecret;
    };
    auto hopResponses = [&](size_t index) -> std::vector<std::string>& {
        if (index < cfg.sshJumpHopHandoffs.size()) {
            return cfg.sshJumpHopHandoffs[index].keyboardInteractiveResponses;
        }
        return index == 0 ? cfg.sshProxyKeyboardInteractiveResponses : emptyResponses;
    };

    auto fail = [this](int code) {
        stopSshJumpRelay();
        if (sockFd_ >= 0) {
            shutdown(sockFd_, SHUT_RDWR);
            close(sockFd_);
            sockFd_ = -1;
        }
        return code;
    };

    int ret = tcpConnect((*hops)[0].host, (*hops)[0].port);
    if (ret != 0) { return ret; }
    const int firstTransportFd = sockFd_;
    sockFd_ = -1;
    {
        std::lock_guard<std::mutex> runtimeLock(jumpRuntimeMutex_);
        jumpHopRuntimes_.clear();
        jumpHopRuntimes_.resize(hops->size());
        jumpHopRuntimes_[0].transportFd = firstTransportFd;
    }

    auto startRelay = [this]() {
        if (jumpRelayRunning_.load(std::memory_order_acquire)) { return; }
        if (jumpRelayThread_.joinable() &&
            jumpRelayThread_.get_id() != std::this_thread::get_id()) {
            // A relay can terminate on an I/O error before the enclosing
            // ProxyJump setup notices it. Reap that finished thread before
            // assigning a new std::thread object.
            jumpRelayThread_.join();
        }
        jumpRelayStopRequested_.store(false, std::memory_order_release);
        jumpRelayRunning_.store(true, std::memory_order_release);
        jumpRelayThread_ = std::thread(&SshAdapter::sshJumpRelayLoop, this);
    };

    auto configureSocketPair = [](int socketPair[2]) -> bool {
        for (int fd : {socketPair[0], socketPair[1]}) {
            const int flags = fcntl(fd, F_GETFL, 0);
            const int descriptorFlags = fcntl(fd, F_GETFD, 0);
            if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
                return false;
            }
            if (descriptorFlags >= 0) {
                (void)fcntl(fd, F_SETFD, descriptorFlags | FD_CLOEXEC);
            }
        }
        return true;
    };

    for (size_t index = 0; index < hops->size(); ++index) {
        if (connectRouteDeadlineExpired()) {
            return fail(ERR_SSH_CONNECT_TIMEOUT);
        }
        const SshJumpHop& hop = (*hops)[index];
        JumpHopRuntime* runtime = nullptr;
        {
            std::lock_guard<std::mutex> runtimeLock(jumpRuntimeMutex_);
            runtime = &jumpHopRuntimes_[index];
            runtime->session = libssh2_session_init();
        }
        if (runtime == nullptr || runtime->session == nullptr) {
            return fail(ERR_SSH_SESSION_INIT);
        }
        libssh2_session_set_blocking(runtime->session, 0);

        int rc = 0;
        while ((rc = libssh2_session_handshake(runtime->session, runtime->transportFd)) ==
               LIBSSH2_ERROR_EAGAIN) {
            if (connectRouteDeadlineExpired()) {
                return fail(ERR_SSH_KEX_TIMEOUT);
            }
            if (waitSocketOnFd(runtime->transportFd, 2,
                               std::max(1, static_cast<int>(hop.connectTimeoutMs / 1000))) != 0) {
                return fail(ERR_SSH_KEX_TIMEOUT);
            }
        }
        if (rc != 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] ProxyJump hop=%{public}zu handshake failed rc=%{public}d",
                         index, rc);
            return fail(ERR_SSH_KEX_FAILED);
        }

        const std::string hopLabel = "hop-" + std::to_string(index + 1);
        const int hostKeyResult = verifyHostKey(
            runtime->session, hop.expectedHostKeyRawBase64,
            hop.expectedHostKeyFingerprintSha256, true, hopLabel.c_str(),
            hop.host, hop.port, static_cast<int>(index));
        if (hostKeyResult != 0) { return fail(hostKeyResult); }

        const std::string authMethod = hop.authMethod.empty() ? "password" : hop.authMethod;
        if (hop.username.empty() ||
            (authMethod != "password" && authMethod != "publickey" &&
             authMethod != "kbd-interactive" && authMethod != "keyboard-interactive")) {
            return fail(ERR_SSH_PROXY_INVALID);
        }

        char* methods = nullptr;
        while (true) {
            if (connectRouteDeadlineExpired()) {
                return fail(ERR_SSH_AUTH_TIMEOUT);
            }
            if (!admitRouteWrite(connectNetworkSnapshot_, [&]() {
                    methods = libssh2_userauth_list(
                        runtime->session, hop.username.c_str(),
                        hop.username.size());
            })) {
                return fail(routeWriteFailure(ERR_SSH_AUTH_TIMEOUT));
            }
            if (methods != nullptr ||
                libssh2_session_last_errno(runtime->session) !=
                    LIBSSH2_ERROR_EAGAIN) {
                break;
            }
            if (waitSocketOnFd(runtime->transportFd, 2, 30) != 0) {
                return fail(ERR_SSH_AUTH_TIMEOUT);
            }
        }
        const std::string advertisedMethods = methods == nullptr ? std::string() : std::string(methods);
        const auto methodAdvertised = [&advertisedMethods](const char* wanted) {
            return advertisedMethods.empty() || sshAuthMethodAdvertised(advertisedMethods, wanted);
        };
        if ((authMethod == "publickey" && !methodAdvertised("publickey")) ||
            (authMethod == "password" && !methodAdvertised("password")) ||
            ((authMethod == "kbd-interactive" || authMethod == "keyboard-interactive") &&
             !methodAdvertised("keyboard-interactive"))) {
            return fail(ERR_SSH_AUTH_METHODS);
        }

        const std::string& password = hopPassword(index);
        const std::string& privateKey = hopPrivateKey(index);
        const std::string& passphrase = hopPassphrase(index);
        std::vector<std::string>& responses = hopResponses(index);
        auto authenticateInteractive = [&](bool allowPasswordFallback) -> int {
            void** abstract = libssh2_session_abstract(runtime->session);
            if (abstract == nullptr) { return ERR_SSH_AUTH_FAILED; }
            authPromptHop_ = hopLabel;
            authPromptPresetIndex_ = 0;
            authPromptFailure_.store(0, std::memory_order_release);
            bool passwordFallbackUsed = false;
            SshJumpKeyboardContext context {
                this, &password, &responses, &authPromptPresetIndex_,
                &passwordFallbackUsed, hop.host, hopLabel, allowPasswordFallback
            };
            *abstract = &context;
            int authResult = 0;
            while (true) {
                authResponseAdmission_.reset();
                if (connectRouteDeadlineExpired()) {
                    authPromptHop_ = "target";
                    return ERR_SSH_AUTH_TIMEOUT;
                }
                if (connectRouteCancelled()) {
                    authPromptHop_ = "target";
                    return ERR_SSH_SESSION_CLOSED;
                }
                authResult = libssh2_userauth_keyboard_interactive(
                    runtime->session, hop.username.c_str(),
                    &sshJumpKeyboardInteractiveCallback);
                authResponseAdmission_.reset();
                if (connectRouteDeadlineExpired()) {
                    authPromptHop_ = "target";
                    return ERR_SSH_AUTH_TIMEOUT;
                }
                if (connectRouteCancelled()) {
                    authPromptHop_ = "target";
                    return ERR_SSH_SESSION_CLOSED;
                }
                if (authResult != LIBSSH2_ERROR_EAGAIN) { break; }
                if (waitSocketOnFd(runtime->transportFd, 2, 30) != 0) {
                    authPromptHop_ = "target";
                    return ERR_SSH_AUTH_TIMEOUT;
                }
            }
            const int promptFailure = authPromptFailure_.load(std::memory_order_acquire);
            authPromptHop_ = "target";
            if (promptFailure != 0) { return promptFailure; }
            return authResult;
        };

        if (authMethod == "publickey") {
            if (privateKey.empty()) { return fail(ERR_SSH_PROXY_AUTH); }
            const char* keyPassphrase = passphrase.empty() ? nullptr : passphrase.c_str();
            while (true) {
                if (connectRouteDeadlineExpired()) {
                    return fail(ERR_SSH_AUTH_TIMEOUT);
                }
                if (!admitRouteWrite(connectNetworkSnapshot_, [&]() {
                        rc = libssh2_userauth_publickey_frommemory(
                            runtime->session, hop.username.c_str(),
                            hop.username.size(), nullptr, 0,
                            privateKey.c_str(), privateKey.size(),
                            keyPassphrase);
                    })) {
                    return fail(routeWriteFailure(ERR_SSH_AUTH_TIMEOUT));
                }
                if (rc != LIBSSH2_ERROR_EAGAIN) { break; }
                if (waitSocketOnFd(runtime->transportFd, 2, 30) != 0) {
                    return fail(ERR_SSH_AUTH_TIMEOUT);
                }
            }
        } else if (authMethod == "kbd-interactive" || authMethod == "keyboard-interactive") {
            rc = authenticateInteractive(true);
        } else {
            if (password.empty()) { return fail(ERR_SSH_PROXY_AUTH); }
            while (true) {
                if (connectRouteDeadlineExpired()) {
                    return fail(ERR_SSH_AUTH_TIMEOUT);
                }
                if (!admitRouteWrite(connectNetworkSnapshot_, [&]() {
                        rc = libssh2_userauth_password(
                            runtime->session, hop.username.c_str(),
                            password.c_str());
                    })) {
                    return fail(routeWriteFailure(ERR_SSH_AUTH_TIMEOUT));
                }
                if (rc != LIBSSH2_ERROR_EAGAIN) { break; }
                if (waitSocketOnFd(runtime->transportFd, 2, 30) != 0) {
                    return fail(ERR_SSH_AUTH_TIMEOUT);
                }
            }
            if (rc != 0 && sshPasswordFallbackAllowsKeyboardInteractive(
                    advertisedMethods, rc)) {
                rc = authenticateInteractive(true);
            }
        }
        if (rc != 0 || !libssh2_userauth_authenticated(runtime->session)) {
            OH_LOG_ERROR(LOG_APP, "[SSH] ProxyJump hop=%{public}zu authentication failed rc=%{public}d",
                         index, rc);
            return fail(ERR_SSH_PROXY_AUTH);
        }

        const std::string nextHost = index + 1 < hops->size()
            ? (*hops)[index + 1].host : normalizedTargetHost;
        const int nextPort = index + 1 < hops->size()
            ? (*hops)[index + 1].port : cfg.port;
        if (connectRouteDeadlineExpired()) {
            return fail(ERR_SSH_CONNECT_TIMEOUT);
        }
        LIBSSH2_CHANNEL* channel = nullptr;
        while (channel == nullptr) {
            if (!admitRouteWrite(connectNetworkSnapshot_, [&]() {
                    channel = libssh2_channel_direct_tcpip_ex(
                        runtime->session, nextHost.c_str(), nextPort,
                        "127.0.0.1", 22);
                })) {
                return fail(routeWriteFailure(ERR_SSH_CONNECT_TIMEOUT));
            }
            if (channel != nullptr) {
                break;
            }
            if (libssh2_session_last_errno(runtime->session) != LIBSSH2_ERROR_EAGAIN) {
                return fail(ERR_SSH_PROXY_FAILED);
            }
            if (connectRouteDeadlineExpired()) {
                return fail(ERR_SSH_CONNECT_TIMEOUT);
            }
            if (waitSocketOnFd(runtime->transportFd, 2, 30) != 0) {
                return fail(ERR_SSH_CONNECT_TIMEOUT);
            }
        }

        int socketPair[2] = {-1, -1};
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, socketPair) != 0 ||
            !configureSocketPair(socketPair)) {
            if (socketPair[0] >= 0) { close(socketPair[0]); }
            if (socketPair[1] >= 0) { close(socketPair[1]); }
            // The channel remains linked to runtime->session. fail() retires
            // that runtime's transport before session_free releases it; do not
            // call channel_free here outside route admission.
            return fail(ERR_SSH_SOCKET_CREATE);
        }
        {
            std::lock_guard<std::mutex> runtimeLock(jumpRuntimeMutex_);
            runtime->channel = channel;
            runtime->channelPeerFd = socketPair[1];
            if (index + 1 < hops->size()) {
                jumpHopRuntimes_[index + 1].transportFd = socketPair[0];
            } else {
                sockFd_ = socketPair[0];
            }
        }
        startRelay();
        OH_LOG_INFO(LOG_APP,
                    "[SSH] ProxyJump hop=%{public}zu ready next=%{public}s:%{public}d",
                    index + 1, SafeLog::MaskHost(nextHost).c_str(), nextPort);
    }

    OH_LOG_INFO(LOG_APP, "[SSH] ProxyJump chain established hops=%{public}zu target=%{public}s:%{public}d",
                hops->size(), SafeLog::MaskHost(normalizedTargetHost).c_str(), cfg.port);
    return 0;
}

void SshAdapter::sshJumpRelayLoop() {
    constexpr size_t kRelayBufferLimit = 512 * 1024;
    struct RelayState {
        std::vector<uint8_t> toChannel;
        std::vector<uint8_t> toPeer;
        bool peerEof = false;
        bool channelEof = false;
        bool channelEofSent = false;
        bool peerWriteShutdown = false;
    };
    std::array<RelayState, kSshMaxJumpHops> states;
    std::array<uint8_t, SSH_BUFFER_SIZE> buffer {};

    while (!jumpRelayStopRequested_.load(std::memory_order_acquire)) {
        if (connectRouteDeadlineExpired()) { break; }
        bool progress = false;
        bool relayFailure = false;
        fd_set readSet;
        fd_set writeSet;
        FD_ZERO(&readSet);
        FD_ZERO(&writeSet);
        int maxFd = -1;
        {
            std::lock_guard<std::mutex> runtimeLock(jumpRuntimeMutex_);
            for (size_t index = 0; index < jumpHopRuntimes_.size() &&
                 index < states.size(); ++index) {
                JumpHopRuntime& runtime = jumpHopRuntimes_[index];
                RelayState& state = states[index];
                if (runtime.channel == nullptr || runtime.channelPeerFd < 0) { continue; }
                if (!state.peerEof && state.toChannel.size() < kRelayBufferLimit) {
                    const size_t readLength = std::min(
                        buffer.size(), kRelayBufferLimit - state.toChannel.size());
                    const ssize_t received = recv(runtime.channelPeerFd, buffer.data(),
                                                  readLength, MSG_DONTWAIT);
                    if (received > 0) {
                        try {
                            state.toChannel.insert(state.toChannel.end(), buffer.begin(),
                                                   buffer.begin() + received);
                        } catch (...) {
                            relayFailure = true;
                        }
                        progress = true;
                    } else if (received == 0) {
                        state.peerEof = true;
                    } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                        relayFailure = true;
                    }
                }
                if (!state.toChannel.empty()) {
                    ssize_t written = LIBSSH2_ERROR_EAGAIN;
                    if (!admitRouteWrite(connectNetworkSnapshot_, [&]() {
                            written = libssh2_channel_write(
                                runtime.channel,
                                reinterpret_cast<const char*>(
                                    state.toChannel.data()),
                                state.toChannel.size());
                        })) {
                        relayFailure = true;
                        break;
                    }
                    if (written > 0) {
                        state.toChannel.erase(state.toChannel.begin(),
                                              state.toChannel.begin() + written);
                        progress = true;
                    } else if (written < 0 && written != LIBSSH2_ERROR_EAGAIN) {
                        relayFailure = true;
                    }
                }
                if (state.peerEof && state.toChannel.empty() && !state.channelEofSent) {
                    int eofResult = LIBSSH2_ERROR_SOCKET_SEND;
                    if (!admitRouteWrite(connectNetworkSnapshot_, [&]() {
                            eofResult = libssh2_channel_send_eof(runtime.channel);
                        })) {
                        relayFailure = true;
                        break;
                    }
                    if (eofResult == 0) {
                        state.channelEofSent = true;
                    } else if (eofResult != LIBSSH2_ERROR_EAGAIN) {
                        relayFailure = true;
                    }
                }
                if (!state.channelEof && state.toPeer.size() < kRelayBufferLimit) {
                    for (size_t attempt = 0; attempt < 4; ++attempt) {
                        if (state.toPeer.size() >= kRelayBufferLimit) { break; }
                        const size_t readLength = std::min(
                            buffer.size(), kRelayBufferLimit - state.toPeer.size());
                        ssize_t received = LIBSSH2_ERROR_SOCKET_SEND;
                        // A channel read can emit WINDOW_ADJUST. The jump relay
                        // is also alive while the target session is still being
                        // established, so use the captured route rather than a
                        // CONNECTED-only admission.
                        if (!admitRouteWrite(connectNetworkSnapshot_, [&]() {
                                received = libssh2_channel_read(
                                    runtime.channel,
                                    reinterpret_cast<char*>(buffer.data()),
                                    readLength);
                            })) {
                            relayFailure = true;
                            break;
                        }
                        if (received > 0) {
                            try {
                                state.toPeer.insert(state.toPeer.end(), buffer.begin(),
                                                    buffer.begin() + received);
                            } catch (...) {
                                relayFailure = true;
                            }
                            progress = true;
                            continue;
                        }
                        if (received == 0) {
                            if (libssh2_channel_eof(runtime.channel) != 0) {
                                state.channelEof = true;
                            }
                            break;
                        }
                        if (received != LIBSSH2_ERROR_EAGAIN) { relayFailure = true; }
                        break;
                    }
                }
                if (!state.toPeer.empty()) {
                    int sendFlags = MSG_DONTWAIT;
#ifdef MSG_NOSIGNAL
                    sendFlags |= MSG_NOSIGNAL;
#endif
                    const ssize_t written = send(runtime.channelPeerFd, state.toPeer.data(),
                                                  state.toPeer.size(), sendFlags);
                    if (written > 0) {
                        state.toPeer.erase(state.toPeer.begin(), state.toPeer.begin() + written);
                        progress = true;
                    } else if (written < 0 && errno != EAGAIN && errno != EWOULDBLOCK &&
                               errno != EINTR) {
                        relayFailure = true;
                    }
                }
                if (state.channelEof && state.toPeer.empty() && !state.peerWriteShutdown) {
                    (void)shutdown(runtime.channelPeerFd, SHUT_WR);
                    state.peerWriteShutdown = true;
                }
                FD_SET(runtime.channelPeerFd, &readSet);
                if (!state.toPeer.empty()) { FD_SET(runtime.channelPeerFd, &writeSet); }
                maxFd = std::max(maxFd, runtime.channelPeerFd);
                if (runtime.transportFd >= 0) {
                    FD_SET(runtime.transportFd, &readSet);
                    FD_SET(runtime.transportFd, &writeSet);
                    maxFd = std::max(maxFd, runtime.transportFd);
                }
                if (state.peerEof && state.channelEof && state.toChannel.empty() &&
                    state.toPeer.empty()) {
                    relayFailure = true;
                }
            }
        }
        if (relayFailure) { break; }
        if (progress) { continue; }
        struct timeval tv = {0, 100000};
        const int selected = select(maxFd + 1, &readSet, &writeSet, nullptr, &tv);
        if (selected < 0 && errno != EINTR) { break; }
    }
    jumpRelayRunning_.store(false, std::memory_order_release);
}

void SshAdapter::stopSshJumpRelay() {
    jumpRelayStopRequested_.store(true, std::memory_order_release);
    {
        std::lock_guard<std::mutex> runtimeLock(jumpRuntimeMutex_);
        for (JumpHopRuntime& runtime : jumpHopRuntimes_) {
            if (runtime.channelPeerFd >= 0) { shutdown(runtime.channelPeerFd, SHUT_RDWR); }
            if (runtime.transportFd >= 0) { shutdown(runtime.transportFd, SHUT_RDWR); }
        }
    }
    if (jumpRelayThread_.joinable() && jumpRelayThread_.get_id() != std::this_thread::get_id()) {
        jumpRelayThread_.join();
    }
    jumpRelayRunning_.store(false, std::memory_order_release);
    std::lock_guard<std::mutex> runtimeLock(jumpRuntimeMutex_);
    for (JumpHopRuntime& runtime : jumpHopRuntimes_) {
        // Every runtime transport was shut down above while its descriptor is
        // still reserved. libssh2 cleanup below can therefore release local
        // channel/session state but cannot put a CLOSE/DISCONNECT packet on an
        // obsolete route or a newly reused fd.
        if (runtime.session != nullptr) {
            libssh2_session_set_blocking(runtime.session, 1);
        }
        if (runtime.channel != nullptr) {
            (void)libssh2_channel_free(runtime.channel);
            runtime.channel = nullptr;
        }
        if (runtime.session != nullptr) {
            (void)libssh2_session_free(runtime.session);
            runtime.session = nullptr;
        }
        if (runtime.channelPeerFd >= 0) {
            close(runtime.channelPeerFd);
            runtime.channelPeerFd = -1;
        }
        if (runtime.transportFd >= 0) {
            close(runtime.transportFd);
            runtime.transportFd = -1;
        }
    }
    jumpHopRuntimes_.clear();
}

// exchangeBanner() 已移除 — libssh2_session_handshake 内部处理 banner 交换

// ============================================================
// SSH 协议方法 (libssh2 集成)
// ============================================================

int SshAdapter::verifyHostKey(LIBSSH2_SESSION* session,
                              const std::string& expectedRawBase64,
                              const std::string& expectedFingerprintSha256,
                              bool required, const char* endpointLabel,
                              const std::string& endpointHost, int endpointPort,
                              int hopIndex) {
    if (connectRouteDeadlineExpired()) {
        return ERR_SSH_AUTH_TIMEOUT;
    }
    if (session == nullptr) {
        return ERR_SSH_SESSION_INIT;
    }
    const bool hasExpectedKey = !expectedRawBase64.empty() ||
        !expectedFingerprintSha256.empty();
    if (!hasExpectedKey && !required && !savedCfg_.sshHostKeyPromptEnabled) { return 0; }
    const char* fingerprint = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256);
    size_t keyLen = 0;
    int keyType = LIBSSH2_HOSTKEY_TYPE_UNKNOWN;
    const char* rawKey = libssh2_session_hostkey(session, &keyLen, &keyType);
    if (!rawKey || keyLen == 0 || !fingerprint) {
        OH_LOG_ERROR(LOG_APP, "[SSH] %{public}s host key 读取失败",
                     endpointLabel ? endpointLabel : "SSH endpoint");
        return ERR_SSH_HOSTKEY_MISMATCH;
    }
    const std::string currentRaw = encodeBase64(
        reinterpret_cast<const unsigned char*>(rawKey), keyLen);
    std::string currentFpB64 = encodeBase64(
        reinterpret_cast<const unsigned char*>(fingerprint), 32);
    while (!currentFpB64.empty() && currentFpB64.back() == '=') { currentFpB64.pop_back(); }
    const std::string currentFp = "SHA256:" + currentFpB64;
    const bool matches = !expectedRawBase64.empty()
        ? currentRaw == expectedRawBase64
        : (!expectedFingerprintSha256.empty() && currentFp == expectedFingerprintSha256);
    if (matches) {
        OH_LOG_INFO(LOG_APP, "[SSH] %{public}s host key 校验通过",
                    endpointLabel ? endpointLabel : "SSH endpoint");
        return 0;
    }
    if (!savedCfg_.sshHostKeyPromptEnabled) {
        OH_LOG_ERROR(LOG_APP,
            "[SSH] %{public}s host key %{public}s expected=%{public}s current=%{public}s",
            endpointLabel ? endpointLabel : "SSH endpoint",
            hasExpectedKey ? "mismatch" : "missing",
            expectedFingerprintSha256.c_str(), currentFp.c_str());
        return ERR_SSH_HOSTKEY_MISMATCH;
    }

    setSshLifecycleState(SshSessionLifecycleState::NeedsAuthentication);
    const SshAuthPromptWaitResult waitResult = authPromptBroker_.waitForHostKeyDecision(
        diagnostics_.snapshot().sessionId, diagnostics_.sessionGeneration(), savedCfg_.host,
        endpointLabel ? endpointLabel : "SSH endpoint", savedCfg_.sshTrustHostId,
        savedCfg_.sshHostKeyRouteIdentity,
        endpointHost, endpointPort, hopIndex, sshHostKeyTypeName(keyType), currentFp,
        currentRaw, expectedFingerprintSha256, hasExpectedKey,
        connectRouteDeadline());
    setSshLifecycleState(SshSessionLifecycleState::Authenticating);
    switch (waitResult) {
        case SshAuthPromptWaitResult::Cancelled:
            return ERR_SSH_AUTH_CANCELLED;
        case SshAuthPromptWaitResult::TimedOut:
            return ERR_SSH_AUTH_TIMEOUT;
        case SshAuthPromptWaitResult::Closed:
            return ERR_SSH_SESSION_CLOSED;
        case SshAuthPromptWaitResult::Responded:
            break;
    }
    if (hopIndex >= 0) {
        const size_t index = static_cast<size_t>(hopIndex);
        if (index >= savedCfg_.sshRoute.hops.size()) { return ERR_SSH_PROXY_INVALID; }
        savedCfg_.sshRoute.hops[index].expectedHostKeyRawBase64 = currentRaw;
        savedCfg_.sshRoute.hops[index].expectedHostKeyFingerprintSha256 = currentFp;
        if (index == 0) {
            savedCfg_.sshJumpHostKeyRawBase64 = currentRaw;
            savedCfg_.sshJumpHostKeyFingerprintSha256 = currentFp;
        }
    } else {
        savedCfg_.expectedHostKeyRawBase64 = currentRaw;
        savedCfg_.expectedHostKeyFingerprintSha256 = currentFp;
    }
    OH_LOG_INFO(LOG_APP, "[SSH] %{public}s host key 已由用户确认",
                endpointLabel ? endpointLabel : "SSH endpoint");
    return 0;
}

int SshAdapter::sshHandshake() {
    if (!assertSessionOwner("handshake")) {
        return ERR_SSH_SESSION_INIT;
    }
    if (connectRouteDeadlineExpired()) {
        return ERR_SSH_KEX_TIMEOUT;
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
    libssh2_keepalive_config(session_, 1, SshReconnectPolicy::kKeepaliveSeconds);
    keepaliveNextDue_ = std::chrono::steady_clock::now() +
        std::chrono::seconds(SshReconnectPolicy::kKeepaliveSeconds);
    keepaliveConsecutiveFailures_ = 0;

    applySshAlgorithmPreferences(session_);
    OH_LOG_INFO(LOG_APP, "[SSH] 算法偏好已设置");

    // KEX 握手 (非阻塞 + select 轮询)
    int rc;
    while ((rc = libssh2_session_handshake(session_, sockFd_)) == LIBSSH2_ERROR_EAGAIN) {
        if (connectRouteDeadlineExpired()) {
            libssh2_session_free(session_);
            session_ = nullptr;
            return ERR_SSH_KEX_TIMEOUT;
        }
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
        savedCfg_.expectedHostKeyFingerprintSha256, false, "目标主机",
        savedCfg_.host, savedCfg_.port, -1);
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
    while (true) {
        if (connectRouteDeadlineExpired()) {
            return ERR_SSH_AUTH_TIMEOUT;
        }
        if (!admitRouteWrite(connectNetworkSnapshot_, [&]() {
                userList = libssh2_userauth_list(
                    session_, savedCfg_.username.c_str(),
                    savedCfg_.username.length());
            })) {
            return routeWriteFailure(ERR_SSH_AUTH_TIMEOUT);
        }
        if (userList != nullptr ||
            libssh2_session_last_errno(session_) != LIBSSH2_ERROR_EAGAIN) {
            break;
        }
        if (waitSocket(2, 30) != 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] 查询密码认证方法超时");
            return ERR_SSH_AUTH_TIMEOUT;
        }
    }
    OH_LOG_INFO(LOG_APP, "[SSH] 服务器认证方法: %{public}s",
                userList ? userList : "(none)");
    advertisedAuthMethods_ = userList == nullptr ? std::string() : std::string(userList);

    if (!sshPasswordAuthShouldAttempt(advertisedAuthMethods_)) {
        OH_LOG_INFO(LOG_APP,
                    "[SSH] 服务器未声明 password，跳过 password 方法并交给后续 fallback");
        return ERR_SSH_AUTH_METHODS;
    }

    // 密码认证 (非阻塞)
    int rc;
    while (true) {
        if (connectRouteDeadlineExpired()) {
            return ERR_SSH_AUTH_TIMEOUT;
        }
        if (!admitRouteWrite(connectNetworkSnapshot_, [&]() {
                rc = libssh2_userauth_password(
                    session_, savedCfg_.username.c_str(),
                    savedCfg_.password.c_str());
            })) {
            return routeWriteFailure(ERR_SSH_AUTH_TIMEOUT);
        }
        if (rc != LIBSSH2_ERROR_EAGAIN) { break; }
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
    if (numPrompts <= 0 || responses == nullptr || abstract == nullptr ||
        *abstract == nullptr) {
        return;
    }

    auto* adapter = static_cast<SshAdapter*>(*abstract);
    const int result = adapter->keyboardInteractiveResponseRound(
        name, nameLen, instruction, instructionLen, numPrompts, prompts, responses);
    if (result != 0) {
        adapter->recordAuthPromptFailure(result);
    }
}

int SshAdapter::fillKeyboardInteractiveResponses(
    const char* name, int nameLen, const char* instruction, int instructionLen,
    int numPrompts, const LIBSSH2_USERAUTH_KBDINT_PROMPT* prompts,
    LIBSSH2_USERAUTH_KBDINT_RESPONSE* responses,
    std::vector<std::string>* explicitResponses,
    const std::string* password, bool allowPasswordFallback,
    const std::string& targetHost, const std::string& hop,
    size_t& presetIndex, bool& passwordFallbackUsed) {
    if (numPrompts <= 0) {
        return 0;
    }
    authResponseAdmission_.reset();
    if (responses == nullptr || prompts == nullptr ||
        static_cast<uint32_t>(numPrompts) > SshAuthPromptBroker::kMaxPrompts) {
        return ERR_SSH_AUTH_FAILED;
    }
    if (connectRouteDeadlineExpired()) {
        return ERR_SSH_AUTH_TIMEOUT;
    }

    for (int index = 0; index < numPrompts; ++index) {
        responses[index].text = nullptr;
        responses[index].length = 0;
    }

    std::vector<SshAuthPrompt> promptList;
    promptList.reserve(static_cast<size_t>(numPrompts));
    for (int index = 0; index < numPrompts; ++index) {
        SshAuthPrompt prompt;
        if (prompts[index].text != nullptr && prompts[index].length > 0) {
            prompt.text.assign(reinterpret_cast<const char*>(prompts[index].text),
                               std::min<size_t>(prompts[index].length,
                                                SshAuthPromptBroker::kMaxPromptBytes));
        }
        prompt.echo = prompts[index].echo != 0;
        promptList.push_back(std::move(prompt));
    }

    std::vector<std::string> values;
    const size_t promptCount = static_cast<size_t>(numPrompts);
    if (explicitResponses != nullptr &&
        presetIndex <= explicitResponses->size() &&
        explicitResponses->size() - presetIndex >= promptCount) {
        values.insert(values.end(), explicitResponses->begin() + presetIndex,
                      explicitResponses->begin() + presetIndex + promptCount);
        SshAuthReplayPolicy::clearConsumedResponses(
            *explicitResponses, presetIndex, promptCount);
        presetIndex += promptCount;
        explicitAuthResponseConsumed_.store(true, std::memory_order_release);
    } else {
        const bool canUsePassword = allowPasswordFallback && password != nullptr &&
            !password->empty() &&
            sshKeyboardInteractivePasswordFallbackCanAutofill(
                promptCount, promptList.front().echo, passwordFallbackUsed);
        if (canUsePassword) {
            values.push_back(*password);
            passwordFallbackUsed = true;
        } else {
            setSshLifecycleState(SshSessionLifecycleState::NeedsAuthentication);
            const SshAuthPromptWaitResult waitResult = authPromptBroker_.waitForResponse(
                diagnostics_.snapshot().sessionId, diagnostics_.sessionGeneration(),
                targetHost, hop, name, nameLen, instruction, instructionLen,
                promptList, values, connectRouteDeadline());
            setSshLifecycleState(SshSessionLifecycleState::Authenticating);
            switch (waitResult) {
                case SshAuthPromptWaitResult::Responded:
                    break;
                case SshAuthPromptWaitResult::Cancelled:
                    return ERR_SSH_AUTH_CANCELLED;
                case SshAuthPromptWaitResult::TimedOut:
                    return ERR_SSH_AUTH_TIMEOUT;
                case SshAuthPromptWaitResult::Closed:
                    return ERR_SSH_SESSION_CLOSED;
            }
            if (values.size() != promptCount) {
                return ERR_SSH_AUTH_FAILED;
            }
        }
    }

    if (connectCancelRequested_.load(std::memory_order_acquire)) {
        return ERR_SSH_SESSION_CLOSED;
    }
    if (connectRouteDeadlineExpired()) {
        return ERR_SSH_AUTH_TIMEOUT;
    }
    remotedesk::net::NetworkGenerationAdmission admission =
        remotedesk::net::ProcessNetworkGenerationFence().acquireAdmission(
            connectNetworkSnapshot_);
    if (!admission ||
        connectCancelRequested_.load(std::memory_order_acquire)) {
        return ERR_SSH_SESSION_CLOSED;
    }
    authResponseAdmission_.reset(
        new (std::nothrow) remotedesk::net::NetworkGenerationAdmission(
            std::move(admission)));
    if (!authResponseAdmission_) { return ERR_SSH_AUTH_FAILED; }

    for (size_t index = 0; index < values.size(); ++index) {
        if (values[index].size() > SshAuthPromptBroker::kMaxPromptBytes) {
            return ERR_SSH_AUTH_FAILED;
        }
        if (values[index].empty()) {
            continue;
        }
        char* allocated = static_cast<char*>(std::malloc(values[index].size()));
        if (allocated == nullptr) {
            return ERR_SSH_AUTH_FAILED;
        }
        std::memcpy(allocated, values[index].data(), values[index].size());
        responses[index].text = allocated;
        responses[index].length = static_cast<unsigned int>(
            std::min<size_t>(values[index].size(), UINT_MAX));
    }
    return 0;
}

int SshAdapter::keyboardInteractiveResponseRound(
    const char* name, int nameLen, const char* instruction, int instructionLen,
    int numPrompts, const LIBSSH2_USERAUTH_KBDINT_PROMPT* prompts,
    LIBSSH2_USERAUTH_KBDINT_RESPONSE* responses) {
    return fillKeyboardInteractiveResponses(
        name, nameLen, instruction, instructionLen, numPrompts, prompts, responses,
        &savedCfg_.sshKeyboardInteractiveResponses, &savedCfg_.password,
        authPromptAllowPasswordFallback_, savedCfg_.host, authPromptHop_,
        authPromptPresetIndex_, authPromptPasswordFallbackUsed_);
}

int SshAdapter::authenticateKeyboardInteractive(bool allowPasswordFallback) {
    if (!assertSessionOwner("keyboard_interactive_auth")) {
        return ERR_SSH_AUTH_FAILED;
    }
    if (!session_) { return ERR_SSH_AUTH_FAILED; }

    char* userList = nullptr;
    while (true) {
        if (connectRouteDeadlineExpired()) {
            return ERR_SSH_AUTH_TIMEOUT;
        }
        if (!admitRouteWrite(connectNetworkSnapshot_, [&]() {
                userList = libssh2_userauth_list(
                    session_, savedCfg_.username.c_str(),
                    static_cast<unsigned int>(savedCfg_.username.size()));
            })) {
            return routeWriteFailure(ERR_SSH_AUTH_TIMEOUT);
        }
        if (userList != nullptr ||
            libssh2_session_last_errno(session_) != LIBSSH2_ERROR_EAGAIN) {
            break;
        }
        if (waitSocket(2, 30) != 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] 查询 keyboard-interactive 方法超时");
            return ERR_SSH_AUTH_TIMEOUT;
        }
    }
    advertisedAuthMethods_ = userList == nullptr ? std::string() : std::string(userList);
    if (!sshAuthMethodAdvertised(advertisedAuthMethods_, "keyboard-interactive")) {
        OH_LOG_ERROR(LOG_APP, "[SSH] 服务器不支持 keyboard-interactive 认证");
        return ERR_SSH_AUTH_METHODS;
    }

    void** abstract = libssh2_session_abstract(session_);
    if (abstract != nullptr) {
        *abstract = this;
    }

    authPromptAllowPasswordFallback_ = allowPasswordFallback;
    authPromptHop_ = "target";
    authPromptPresetIndex_ = 0;
    authPromptPasswordFallbackUsed_ = false;
    authPromptFailure_.store(0, std::memory_order_release);
    int rc;
    while (true) {
        authResponseAdmission_.reset();
        if (connectRouteDeadlineExpired()) {
            return ERR_SSH_AUTH_TIMEOUT;
        }
        if (connectRouteCancelled()) {
            return ERR_SSH_SESSION_CLOSED;
        }
        rc = libssh2_userauth_keyboard_interactive(
            session_, savedCfg_.username.c_str(),
            &SshAdapter::keyboardInteractiveCallback);
        authResponseAdmission_.reset();
        if (connectRouteDeadlineExpired()) {
            return ERR_SSH_AUTH_TIMEOUT;
        }
        if (connectRouteCancelled()) { return ERR_SSH_SESSION_CLOSED; }
        if (rc != LIBSSH2_ERROR_EAGAIN) { break; }
        int w = waitSocket(2, 30);
        if (w != 0) {
            OH_LOG_ERROR(LOG_APP, "[SSH] keyboard-interactive 认证超时");
            return ERR_SSH_AUTH_TIMEOUT;
        }
    }
    const int promptFailure = authPromptFailure_.load(std::memory_order_acquire);
    if (promptFailure != 0) {
        return promptFailure;
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
    while (true) {
        if (connectRouteDeadlineExpired()) {
            return ERR_SSH_AUTH_TIMEOUT;
        }
        if (!admitRouteWrite(connectNetworkSnapshot_, [&]() {
                rc = libssh2_userauth_publickey_frommemory(
                    session_, username.c_str(), username.length(),
                    nullptr, 0, privateKeyPem.c_str(),
                    privateKeyPem.length(), pass);
            })) {
            return routeWriteFailure(ERR_SSH_AUTH_TIMEOUT);
        }
        if (rc != LIBSSH2_ERROR_EAGAIN) { break; }
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

int SshAdapter::authenticateConfiguredUser(const ConnectionConfig& cfg) {
    setState(ConnectionState::AUTHENTICATING, "SSH authenticating");
    OH_LOG_INFO(LOG_APP, "[SSH] \u8ba4\u8bc1\u65b9\u5f0f=%{public}s", cfg.authMethod.c_str());
    auto authenticatePasswordWithFallback = [this]() {
        const int passwordResult = authenticatePassword();
        if (!sshPasswordFallbackAllowsKeyboardInteractive(
                advertisedAuthMethods_, passwordResult)) {
            return passwordResult;
        }
        OH_LOG_WARN(LOG_APP,
                    "[SSH] password method failed; trying advertised keyboard-interactive fallback");
        const int interactiveResult = authenticateKeyboardInteractive(true);
        return sshPasswordFallbackFinalResult(passwordResult, interactiveResult);
    };

    int result = ERR_SSH_AUTH_FAILED;
    if (cfg.authMethod == "kbd-interactive" || cfg.authMethod == "keyboard-interactive") {
        result = authenticateKeyboardInteractive(true);
    } else if (cfg.authMethod == "publickey" && !cfg.privateKeyPem.empty()) {
        result = authenticatePublicKey(
            cfg.username, cfg.privateKeyPem, cfg.privateKeyPassphrase);
        if (result < 0 && !cfg.password.empty()) {
            OH_LOG_WARN(LOG_APP, "[SSH] \u516c\u94a5\u8ba4\u8bc1\u5931\u8d25, \u56de\u9000\u5230\u5bc6\u7801\u8ba4\u8bc1");
            result = authenticatePasswordWithFallback();
        }
    } else {
        result = authenticatePasswordWithFallback();
    }
    return result;
}

int SshAdapter::openChannel() {
    if (!assertSessionOwner("open_channel")) {
        return ERR_SSH_CHANNEL_OPEN;
    }
    if (!session_) { return ERR_SSH_CHANNEL_OPEN; }
    if (connectRouteDeadlineExpired()) { return ERR_SSH_CHANNEL_OPEN; }

    while (channel_ == nullptr) {
        if (!admitRouteWrite(connectNetworkSnapshot_, [&]() {
                channel_ = libssh2_channel_open_session(session_);
            })) {
            return routeWriteFailure(ERR_SSH_CHANNEL_OPEN);
        }
        if (channel_ != nullptr) {
            break;
        }
        if (connectRouteDeadlineExpired()) {
            return ERR_SSH_CHANNEL_OPEN;
        }
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
    if (connectRouteDeadlineExpired()) {
        return failPty(LIBSSH2_ERROR_TIMEOUT);
    }

    int rc;
    while (true) {
        if (!admitRouteWrite(connectNetworkSnapshot_, [&]() {
                rc = libssh2_channel_request_pty(channel_, "xterm-256color");
            })) {
            return failPty(LIBSSH2_ERROR_SOCKET_SEND);
        }
        if (rc != LIBSSH2_ERROR_EAGAIN) {
            break;
        }
        if (connectRouteDeadlineExpired()) {
            return failPty(LIBSSH2_ERROR_TIMEOUT);
        }
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
    while (true) {
        if (!admitRouteWrite(connectNetworkSnapshot_, [&]() {
                rc = libssh2_channel_request_pty_size(channel_, cols, rows);
            })) {
            return failPty(LIBSSH2_ERROR_SOCKET_SEND);
        }
        if (rc != LIBSSH2_ERROR_EAGAIN) {
            break;
        }
        if (connectRouteDeadlineExpired()) {
            return failPty(LIBSSH2_ERROR_TIMEOUT);
        }
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

int SshAdapter::requestSessionLocale(const std::string& locale) {
    if (locale.empty()) { return 0; }
    if (!assertSessionOwner("request_session_locale") || !channel_) {
        return LIBSSH2_ERROR_BAD_USE;
    }
    if (connectRouteDeadlineExpired()) {
        return LIBSSH2_ERROR_TIMEOUT;
    }

    int rc;
    while (true) {
        if (!admitRouteWrite(connectNetworkSnapshot_, [&]() {
                rc = libssh2_channel_setenv(
                    channel_, "LANG", locale.c_str());
            })) {
            return routeWriteFailure(LIBSSH2_ERROR_TIMEOUT);
        }
        if (rc != LIBSSH2_ERROR_EAGAIN) {
            break;
        }
        if (connectRouteDeadlineExpired()) {
            return LIBSSH2_ERROR_TIMEOUT;
        }
        const int waitResult = waitSocket(2, 15);
        if (waitResult != 0) {
            OH_LOG_WARN(LOG_APP,
                        "[SSH] LANG 环境请求等待超时 locale=%{public}s",
                        locale.c_str());
            return LIBSSH2_ERROR_TIMEOUT;
        }
    }
    if (rc != 0) {
        // OpenSSH may reject this when AcceptEnv does not include LANG. The
        // shell is still usable, so locale negotiation is intentionally
        // best-effort and the caller proceeds to PTY allocation.
        OH_LOG_WARN(LOG_APP,
                    "[SSH] 服务器拒绝 LANG 环境请求 locale=%{public}s rc=%{public}d",
                    locale.c_str(), rc);
        return rc;
    }
    OH_LOG_INFO(LOG_APP, "[SSH] 已请求会话 LANG=%{public}s", locale.c_str());
    return 0;
}

int SshAdapter::startShell() {
    if (!assertSessionOwner("start_shell")) {
        return ERR_SSH_SHELL_FAILED;
    }
    if (!channel_) { return ERR_SSH_SHELL_FAILED; }
    if (connectRouteDeadlineExpired()) { return ERR_SSH_SHELL_FAILED; }

    int rc;
    while (true) {
        if (!admitRouteWrite(connectNetworkSnapshot_, [&]() {
                rc = libssh2_channel_shell(channel_);
            })) {
            return routeWriteFailure(ERR_SSH_SHELL_FAILED);
        }
        if (rc != LIBSSH2_ERROR_EAGAIN) {
            break;
        }
        if (connectRouteDeadlineExpired()) {
            return ERR_SSH_SHELL_FAILED;
        }
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

int SshAdapter::connectForOperation(
    const ConnectionConfig& cfg, SshOperationSessionMode mode,
    remotedesk::net::NetworkGenerationSnapshot networkSnapshot,
    SshOperationHostKeySnapshot& hostKey,
    std::chrono::steady_clock::time_point deadline) {
    hostKey = SshOperationHostKeySnapshot {};
    if (isReactorThread()) {
        return connectForOperationInternal(
            cfg, mode, networkSnapshot, hostKey, deadline);
    }

    const bool hadPreviousState =
        state_.load(std::memory_order_acquire) != ConnectionState::DISCONNECTED;
    if (hadPreviousState) {
        disconnect();
        connectCancelRequested_.store(false, std::memory_order_release);
    }
    startReader();
    return runOnReactor(
        [this, &cfg, mode, networkSnapshot, &hostKey, deadline]() {
            return connectForOperationInternal(
                cfg, mode, networkSnapshot, hostKey, deadline);
        });
}

int SshAdapter::connectForOperationInternal(
    const ConnectionConfig& cfg, SshOperationSessionMode mode,
    remotedesk::net::NetworkGenerationSnapshot networkSnapshot,
    SshOperationHostKeySnapshot& hostKey,
    std::chrono::steady_clock::time_point deadline) {
    if (!assertSessionOwner("operation_connect")) {
        return ERR_SSH_SESSION_INIT;
    }
    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    const auto previousDeadline = connectRouteDeadline();
    setConnectRouteDeadline(deadline);
    SshScopeExit deadlineRestore([this, previousDeadline]() {
        setConnectRouteDeadline(previousDeadline);
    });
    hostKey = SshOperationHostKeySnapshot {};
    authPromptBroker_.resetForNewConnection();
    authPromptFailure_.store(0, std::memory_order_release);
    authPromptHop_ = "target";
    authPromptAllowPasswordFallback_ = false;
    authPromptPresetIndex_ = 0;
    authPromptPasswordFallbackUsed_ = false;
    if (connectCancelRequested_.load(std::memory_order_acquire)) {
        disconnect();
        return ERR_SSH_AUTH_CANCELLED;
    }
    if (connectRouteDeadlineExpired()) {
        disconnect();
        return ERR_SSH_CONNECT_TIMEOUT;
    }
    remotedesk::net::NetworkGenerationFence& networkFence =
        remotedesk::net::ProcessNetworkGenerationFence();
    if (networkSnapshot.generation == 0 || !networkSnapshot.available ||
        networkFence.shouldCancel(networkSnapshot)) {
        disconnect();
        return ERR_SSH_SESSION_CLOSED;
    }
    connectNetworkSnapshot_ = networkSnapshot;
    // Auxiliary workers have no interactive prompt broker. Authenticated
    // operations must therefore arrive with an already route-bound target pin.
    if (cfg.sshHostKeyPromptEnabled ||
        (mode == SshOperationSessionMode::Authenticated &&
         cfg.expectedHostKeyRawBase64.empty() &&
         cfg.expectedHostKeyFingerprintSha256.empty())) {
        disconnect();
        return ERR_SSH_HOSTKEY_MISMATCH;
    }

    savedCfg_ = cfg;
    setState(ConnectionState::CONNECTING, "SSH operation connecting");
    int result = connectThroughProxy(savedCfg_);
    if (result != 0) {
        disconnect();
        return result;
    }
    if (connectRouteDeadlineExpired()) {
        disconnect();
        return ERR_SSH_CONNECT_TIMEOUT;
    }
    result = sshHandshake();
    if (result != 0) {
        disconnect();
        return result;
    }

    size_t keyLength = 0;
    int keyType = LIBSSH2_HOSTKEY_TYPE_UNKNOWN;
    const char* rawKey = libssh2_session_hostkey(session_, &keyLength, &keyType);
    const char* fingerprint = libssh2_hostkey_hash(
        session_, LIBSSH2_HOSTKEY_HASH_SHA256);
    if (rawKey == nullptr || keyLength == 0 || fingerprint == nullptr) {
        disconnect();
        return ERR_SSH_HOSTKEY_MISMATCH;
    }
    hostKey.algorithm = sshHostKeyTypeName(keyType);
    hostKey.rawBase64 = encodeBase64(
        reinterpret_cast<const unsigned char*>(rawKey), keyLength);
    std::string fingerprintBase64 = encodeBase64(
        reinterpret_cast<const unsigned char*>(fingerprint), 32);
    while (!fingerprintBase64.empty() && fingerprintBase64.back() == '=') {
        fingerprintBase64.pop_back();
    }
    hostKey.fingerprintSha256 = "SHA256:" + fingerprintBase64;
    const char* banner = libssh2_session_banner_get(session_);
    if (banner != nullptr) { hostKey.serverBanner = banner; }
    hostKey.ok = true;

    if (mode == SshOperationSessionMode::Authenticated) {
        result = authenticateConfiguredUser(cfg);
        if (result != 0) {
            disconnect();
            return result;
        }
    }
    if (connectRouteDeadlineExpired()) {
        disconnect();
        return ERR_SSH_CONNECT_TIMEOUT;
    }
    if (connectRouteCancelled()) {
        disconnect();
        return ERR_SSH_SESSION_CLOSED;
    }
    setState(ConnectionState::CONNECTED,
             mode == SshOperationSessionMode::Authenticated
                 ? "SSH operation authenticated" : "SSH operation probe ready");
    // Keep the caller's immutable operation deadline active for a following
    // route-bound command/SFTP step. disconnect() retires it with the route.
    deadlineRestore.dismiss();
    return 0;
}

int SshAdapter::connectInternal(const ConnectionConfig& cfg, bool preserveOwner) {
    if (!assertSessionOwner("connect")) {
        return ERR_SSH_SESSION_INIT;
    }
    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    const auto previousDeadline = connectRouteDeadline();
    const auto routeDeadline =
        SshNetworkGenerationPolicy::initialRouteDeadline(
            std::chrono::steady_clock::now());
    setConnectRouteDeadline(routeDeadline);
    SshScopeExit deadlineRestore([this, previousDeadline]() {
        setConnectRouteDeadline(previousDeadline);
    });
    if (!preserveOwner) {
        explicitAuthResponseConsumed_.store(false, std::memory_order_release);
        setSshLifecycleState(SshSessionLifecycleState::Created);
        networkAvailable_.store(true, std::memory_order_release);
    }
    auto prepareAuthenticationAttempt = [this]() {
        authPromptBroker_.resetForNewConnection();
        authPromptFailure_.store(0, std::memory_order_release);
        authPromptHop_ = "target";
        authPromptAllowPasswordFallback_ = false;
        authPromptPresetIndex_ = 0;
        authPromptPasswordFallbackUsed_ = false;
    };
    prepareAuthenticationAttempt();
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
    remotedesk::net::NetworkGenerationFence& networkFence =
        remotedesk::net::ProcessNetworkGenerationFence();
    connectNetworkSnapshot_ = networkFence.snapshot();

    auto failConnect = [this, preserveOwner](
        int code, const std::string& message,
        bool preserveLifecycle = false) {
        if (preserveOwner || preserveLifecycle) {
            // Keep the owner reactor and saved configuration alive so the
            // recovery loop or an explicit re-authentication can rebuild the
            // route without replaying terminal input.
            resetTransportForRecovery();
        } else {
            disconnect();
        }
        if (preserveLifecycle) {
            setSshLifecycleState(
                SshSessionLifecycleState::NeedsAuthentication,
                "reauthentication_required");
            setConnectionStateOnly(ConnectionState::ERROR, message);
        } else {
            setState(ConnectionState::ERROR, message);
        }
        return code;
    };

    // 保存配置 (用于后续认证和重连)
    savedCfg_ = cfg;
    auto attemptConnect = [this]() -> std::pair<int, std::string> {
        if (connectRouteDeadlineExpired()) {
            return {ERR_SSH_CONNECT_TIMEOUT, "SSH connection deadline exceeded"};
        }
        ioGeneration_.fetch_add(1, std::memory_order_acq_rel);
        setState(ConnectionState::CONNECTING, "SSH connecting");

        // Step 1: TCP 连接
        int ret = connectThroughProxy(savedCfg_);
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
        ret = authenticateConfiguredUser(savedCfg_);
        if (ret < 0) {
            return {ret, "SSH authentication failed [" + std::to_string(ret) + "]"};
        }

        // Step 5: 打开 SSH 会话通道
        ret = openChannel();
        if (ret < 0) {
            return {ret, "SSH channel open failed [" + std::to_string(ret) + "]"};
        }

        // Step 6: LANG is a channel environment request, not terminal input.
        // Refusal is non-fatal because many servers deliberately omit LANG
        // from AcceptEnv while still providing a fully usable shell.
        (void)requestSessionLocale(savedCfg_.sshLocale);

        // Step 7: 请求 PTY (SSH 调用方将 width/height 传为终端 cols/rows)
        int ptyCols = savedCfg_.width > 0 ? savedCfg_.width : 80;
        int ptyRows = savedCfg_.height > 0 ? savedCfg_.height : 24;
        ret = requestPty(ptyCols, ptyRows);
        if (ret < 0) {
            return {ret,
                "SSH PTY request failed [" + std::to_string(ret) + "] libssh2=[" +
                std::to_string(lastPtyLibssh2Error_) + "]"};
        }

        // Step 8: 启动远程 Shell
        ret = startShell();
        if (ret < 0) {
            return {ret, "SSH shell start failed [" + std::to_string(ret) + "]"};
        }

        if (connectRouteCancelled()) {
            return {ERR_SSH_SESSION_CLOSED,
                    "SSH network changed before route activation"};
        }

        startTerminalInput();
        setState(ConnectionState::CONNECTED, "SSH connected");
        // Start the per-session owner before the page publishes its push
        // callback. The reactor can accept early terminal input without
        // creating a second writer; it simply waits for the callback before
        // consuming remote output.
        startReader();
        const std::string logHost = SafeLog::MaskHost(savedCfg_.host);
        OH_LOG_INFO(LOG_APP, "[SSH] SSH 连接建立完成 (libssh2 完整握手, %{public}s:%{public}d)",
                    logHost.c_str(), savedCfg_.port);
        return {0, ""};
    };

    // An initial connection can lose the socket between authentication and
    // PTY negotiation. Rebuild the complete transport a bounded number of
    // times. A recovery already has its own three-attempt loop, so it gets one
    // PTY attempt per outer recovery cycle instead of multiplying retries.
    const uint32_t maxPtyAttempts = preserveOwner
        ? 1U : SshPtyRecoveryPolicy::kMaxInitialAttempts;
    uint32_t ptyAttemptsStarted = 0;
    uint32_t networkAttemptsStarted = 1;
    while (true) {
        ++ptyAttemptsStarted;
        const auto outcome = attemptConnect();
        remotedesk::net::NetworkGenerationSnapshot currentNetwork =
            networkFence.snapshot();
        if (connectRouteDeadlineExpired()) {
            return failConnect(
                ERR_SSH_CONNECT_TIMEOUT,
                "SSH connection deadline exceeded");
        }
        if (networkFence.shouldCancel(connectNetworkSnapshot_)) {
            if (!SshAuthReplayPolicy::allowsAutomaticNewSession(
                    explicitAuthResponseConsumed_.load(
                        std::memory_order_acquire))) {
                return failConnect(
                    ERR_SSH_AUTH_CANCELLED,
                    "SSH network changed after one-time authentication; "
                    "fresh authentication is required",
                    true);
            }
            const auto retryDecision = [&]() {
                return SshNetworkGenerationPolicy::retryDecision(
                    networkAttemptsStarted,
                    connectCancelRequested_.load(std::memory_order_acquire) ||
                        !readerRunning_.load(std::memory_order_acquire),
                    std::chrono::steady_clock::now() >= routeDeadline,
                    connectNetworkSnapshot_, currentNetwork);
            };
            SshNetworkRetryDecision decision = retryDecision();
            while (decision ==
                   SshNetworkRetryDecision::WaitForAvailableNetwork) {
                const auto now = std::chrono::steady_clock::now();
                if (now >= routeDeadline) {
                    decision = SshNetworkRetryDecision::StopDeadline;
                    break;
                }
                std::unique_lock<std::mutex> retryLock(reactorCommandMutex_);
                reactorCommandCondition_.wait_until(
                    retryLock,
                    std::min(
                        routeDeadline,
                        now + std::chrono::milliseconds(
                            SshNetworkGenerationPolicy::kRetryPollMilliseconds)),
                    [this]() {
                        return connectCancelRequested_.load(
                                   std::memory_order_acquire) ||
                            !readerRunning_.load(std::memory_order_acquire);
                    });
                currentNetwork = networkFence.snapshot();
                decision = retryDecision();
            }
            if (decision == SshNetworkRetryDecision::RetryCurrentNetwork) {
                ++networkAttemptsStarted;
                OH_LOG_WARN(
                    LOG_APP,
                    "[SSH] 网络代际变化, 重建完整路由 generation=%{public}llu "
                    "attempt=%{public}u/%{public}u",
                    static_cast<unsigned long long>(currentNetwork.generation),
                    networkAttemptsStarted,
                    SshNetworkGenerationPolicy::kMaxRouteAttempts);
                resetTransportForRecovery();
                prepareAuthenticationAttempt();
                connectNetworkSnapshot_ = currentNetwork;
                ptyAttemptsStarted = 0;
                continue;
            }
            if (decision == SshNetworkRetryDecision::StopDeadline) {
                return failConnect(
                    ERR_SSH_CONNECT_TIMEOUT,
                    "SSH network retry deadline exceeded");
            }
            if (decision == SshNetworkRetryDecision::StopCancelled) {
                return failConnect(
                    ERR_SSH_SESSION_CLOSED,
                    "SSH connect cancelled during network retry");
            }
            return failConnect(
                ERR_SSH_SESSION_CLOSED,
                "SSH network changed and route retry was exhausted");
        }
        if (outcome.first == 0) {
            return 0;
        }
        if (outcome.first == ERR_SSH_PTY_FAILED &&
            !SshAuthReplayPolicy::allowsAutomaticNewSession(
                explicitAuthResponseConsumed_.load(
                    std::memory_order_acquire))) {
            return failConnect(
                ERR_SSH_AUTH_CANCELLED,
                "SSH PTY recovery requires fresh one-time authentication",
                true);
        }
        const bool canRetry = outcome.first == ERR_SSH_PTY_FAILED &&
            SshPtyRecoveryPolicy::retryable(lastPtyFailureClass_) &&
            ptyAttemptsStarted < maxPtyAttempts &&
            !connectCancelRequested_.load(std::memory_order_acquire);
        if (!canRetry) {
            return failConnect(outcome.first, outcome.second);
        }

        OH_LOG_WARN(LOG_APP,
                    "[SSH] PTY 瞬态失败, 重建 SSH 传输 attempt=%{public}u/%{public}u "
                    "libssh2=%{public}d",
                    ptyAttemptsStarted, maxPtyAttempts, lastPtyLibssh2Error_);
        resetTransportForRecovery();
        prepareAuthenticationAttempt();
        std::unique_lock<std::mutex> retryLock(reactorCommandMutex_);
        const auto retryNow = std::chrono::steady_clock::now();
        reactorCommandCondition_.wait_until(
            retryLock,
            std::min(
                routeDeadline,
                retryNow + std::chrono::milliseconds(
                    SshPtyRecoveryPolicy::kRetryDelayMilliseconds)),
            [this]() {
                return connectCancelRequested_.load(std::memory_order_acquire) ||
                    !readerRunning_.load(std::memory_order_acquire);
            });
        if (connectCancelRequested_.load(std::memory_order_acquire) ||
            !readerRunning_.load(std::memory_order_acquire)) {
            return failConnect(ERR_SSH_SESSION_CLOSED, "SSH connect cancelled during PTY recovery");
        }
        if (connectRouteDeadlineExpired()) {
            return failConnect(
                ERR_SSH_CONNECT_TIMEOUT,
                "SSH connection deadline exceeded during PTY recovery");
        }
    }
}

void SshAdapter::disconnect() {
    setSshLifecycleState(SshSessionLifecycleState::Closing);
    authPromptBroker_.cancelAll();
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
        teardownSessionHandlesLocked("Client disconnecting");
        OH_LOG_INFO(LOG_APP, "[SSH] TCP 连接已断开");
        ioGeneration_.fetch_add(1, std::memory_order_acq_rel);
        authenticated_ = false;
        secureClearString(savedCfg_.password);
        secureClearString(savedCfg_.privateKeyPem);
        secureClearString(savedCfg_.privateKeyPassphrase);
        secureClearString(savedCfg_.sshProxyPassword);
        secureClearString(savedCfg_.sshProxyPrivateKeyPem);
        secureClearString(savedCfg_.sshProxyPrivateKeyPassphrase);
        for (std::string& response : savedCfg_.sshKeyboardInteractiveResponses) {
            secureClearString(response);
        }
        savedCfg_.sshKeyboardInteractiveResponses.clear();
        for (std::string& response : savedCfg_.sshProxyKeyboardInteractiveResponses) {
            secureClearString(response);
        }
        savedCfg_.sshProxyKeyboardInteractiveResponses.clear();
        for (SshJumpHopHandoff& handoff : savedCfg_.sshJumpHopHandoffs) {
            secureClearString(handoff.password);
            secureClearString(handoff.privateKeyPem);
            secureClearString(handoff.privateKeyPassphrase);
            for (std::string& response : handoff.keyboardInteractiveResponses) {
                secureClearString(response);
            }
            handoff.keyboardInteractiveResponses.clear();
        }
        savedCfg_.sshJumpHopHandoffs.clear();
    }
    keepaliveNextDue_ = std::chrono::steady_clock::time_point::max();
    keepaliveConsecutiveFailures_ = 0;
    transportRecoveryRequested_.store(false, std::memory_order_release);
    recoveryAttemptInProgress_.store(false, std::memory_order_release);
    networkAvailable_.store(true, std::memory_order_release);
    setConnectRouteDeadline(std::chrono::steady_clock::time_point::max());
    forwardingManager_.resetRuntimeAfterTransportClose();
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
    authPromptBroker_.cancelAll();

    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    std::lock_guard<std::mutex> sftpLock(sftpOperationMutex_);
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    std::lock_guard<std::mutex> writeFence(inputWriteFenceMutex_);
    teardownSessionHandlesLocked("SSH transport recovery");
    ioGeneration_.fetch_add(1, std::memory_order_acq_rel);
    authenticated_ = false;
    keepaliveNextDue_ = std::chrono::steady_clock::time_point::max();
    keepaliveConsecutiveFailures_ = 0;
    forwardingManager_.resetRuntimeAfterTransportClose();
}

bool SshAdapter::reconnectAfterTransportFailure() {
    if (!isReactorThread() || !readerRunning_.load(std::memory_order_acquire) ||
        savedCfg_.host.empty()) {
        return false;
    }

    auto stopForFreshAuthentication = [this]() {
        resetTransportForRecovery();
        stopTerminalInput();
        readerRunning_.store(false, std::memory_order_release);
        transportRecoveryRequested_.store(false, std::memory_order_release);
        recoveryAttemptInProgress_.store(false, std::memory_order_release);
        networkAvailable_.store(true, std::memory_order_release);
        setSshLifecycleState(
            SshSessionLifecycleState::NeedsAuthentication,
            "reauthentication_required");
        setConnectionStateOnly(
            ConnectionState::ERROR,
            "SSH transport recovery requires fresh one-time authentication");
        reactorCommandCondition_.notify_all();
        return false;
    };
    if (!SshAuthReplayPolicy::allowsAutomaticNewSession(
            explicitAuthResponseConsumed_.load(std::memory_order_acquire))) {
        return stopForFreshAuthentication();
    }

    const auto recoveryStartedAt = std::chrono::steady_clock::now();
    uint32_t attemptsStarted = 0;
    setSshLifecycleState(SshSessionLifecycleState::NetworkLost);
    while (true) {
        // A platform netLost event must pause the bounded retry budget. The
        // session remains recoverable, but offline time must not consume all
        // eight attempts before netAvailable is delivered.
        if (!networkAvailable_.load(std::memory_order_acquire)) {
            std::unique_lock<std::mutex> waitLock(reactorCommandMutex_);
            reactorCommandCondition_.wait_for(waitLock, std::chrono::milliseconds(250), [this]() {
                return networkAvailable_.load(std::memory_order_acquire) ||
                    !readerRunning_.load(std::memory_order_acquire) ||
                    connectCancelRequested_.load(std::memory_order_acquire);
            });
            if (!readerRunning_.load(std::memory_order_acquire) ||
                connectCancelRequested_.load(std::memory_order_acquire)) {
                return false;
            }
            continue;
        }
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - recoveryStartedAt).count();
        const int elapsedMilliseconds = static_cast<int>(std::min<int64_t>(
            std::max<int64_t>(0, elapsed), INT_MAX));
        if (!SshReconnectPolicy::canAttempt(attemptsStarted, elapsedMilliseconds)) {
            break;
        }
        if (!readerRunning_.load(std::memory_order_acquire) ||
            connectCancelRequested_.load(std::memory_order_acquire)) {
            return false;
        }

        setSshLifecycleState(SshSessionLifecycleState::ReconnectScheduled);
        const uint64_t entropy = static_cast<uint64_t>(
            std::chrono::steady_clock::now().time_since_epoch().count());
        const uint32_t randomPermille = static_cast<uint32_t>(
            (entropy ^ (static_cast<uint64_t>(attemptsStarted + 1) * 0x9E3779B97F4A7C15ULL)) % 1001ULL);
        const int delayMilliseconds = SshReconnectPolicy::jitteredDelayMilliseconds(
            attemptsStarted, randomPermille);
        {
            std::unique_lock<std::mutex> waitLock(reactorCommandMutex_);
            reactorCommandCondition_.wait_for(
                waitLock, std::chrono::milliseconds(delayMilliseconds), [this]() {
                    return !readerRunning_.load(std::memory_order_acquire) ||
                        connectCancelRequested_.load(std::memory_order_acquire) ||
                        !networkAvailable_.load(std::memory_order_acquire);
                });
        }
        if (!readerRunning_.load(std::memory_order_acquire) ||
            connectCancelRequested_.load(std::memory_order_acquire)) {
            return false;
        }
        if (!networkAvailable_.load(std::memory_order_acquire)) {
            continue;
        }

        ++attemptsStarted;
        setSshLifecycleState(SshSessionLifecycleState::Reconnecting);
        setState(ConnectionState::RECONNECTING,
                 "SSH transport lost, reconnecting [" +
                 std::to_string(attemptsStarted) + "/" +
                 std::to_string(SshReconnectPolicy::kMaxAttempts) + "]");
        resetTransportForRecovery();
        recoveryAttemptInProgress_.store(true, std::memory_order_release);
        const int ret = connectInternal(savedCfg_, true);
        recoveryAttemptInProgress_.store(false, std::memory_order_release);
        if (ret == 0) {
            transportRecoveryRequested_.store(false, std::memory_order_release);
            setState(ConnectionState::CONNECTED,
                     "连接已恢复，新 shell 已启动");
            OH_LOG_INFO(LOG_APP, "[SSH] transport recovery succeeded attempt=%{public}u",
                        attemptsStarted);
            return true;
        }

        if (!SshAuthReplayPolicy::allowsAutomaticNewSession(
                explicitAuthResponseConsumed_.load(
                    std::memory_order_acquire))) {
            return stopForFreshAuthentication();
        }

        OH_LOG_WARN(LOG_APP,
                    "[SSH] transport recovery failed attempt=%{public}u rc=%{public}d",
                    attemptsStarted, ret);
    }

    stopTerminalInput();
    readerRunning_.store(false, std::memory_order_release);
    transportRecoveryRequested_.store(false, std::memory_order_release);
    networkAvailable_.store(true, std::memory_order_release);
    setState(ConnectionState::ERROR, "SSH transport recovery failed");
    reactorCommandCondition_.notify_all();
    return false;
}

ConnectionState SshAdapter::getState() {
    return state_.load(std::memory_order_acquire);
}

void SshAdapter::requestConnectCancel() {
    connectCancelRequested_.store(true, std::memory_order_release);
    authPromptBroker_.cancelAll();
    reactorCommandCondition_.notify_all();
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

    while (sftp_ == nullptr) {
        if (!admitConnectedRouteWrite([&]() {
                sftp_ = libssh2_sftp_init(session_);
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (sftp_ != nullptr) {
            break;
        }
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

int SshAdapter::closeSftpHandleLocked(
    LIBSSH2_SFTP_HANDLE* handle,
    std::unique_lock<std::mutex>& sessionLock,
    bool directory) {
    if (handle == nullptr || !sessionLock.owns_lock()) {
        return ERR_SSH_SESSION_CLOSED;
    }
    int rc = LIBSSH2_ERROR_EAGAIN;
    while (true) {
        if (!admitConnectedRouteWrite([&]() {
                rc = directory ? libssh2_sftp_closedir(handle)
                               : libssh2_sftp_close(handle);
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (rc != LIBSSH2_ERROR_EAGAIN) {
            return rc;
        }
        if (!yieldSftpSlice(sessionLock, 2, 1)) {
            return ERR_SSH_WRITE_FAILED;
        }
    }
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
    while (handle == nullptr) {
        if (!admitConnectedRouteWrite([&]() {
                handle = libssh2_sftp_open(
                    sftp_, remotePath.c_str(),
                    LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT |
                        LIBSSH2_FXF_TRUNC,
                    LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SFTP_S_IWUSR |
                        LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IROTH);
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (handle != nullptr) {
            break;
        }
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
        ssize_t written = LIBSSH2_ERROR_SOCKET_SEND;
        if (!admitConnectedRouteWrite([&]() {
                written = libssh2_sftp_write(
                    handle, reinterpret_cast<const char*>(data + total), chunk);
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (written == LIBSSH2_ERROR_EAGAIN) {
            if (!yieldSftpSlice(sessionLock, 1, 1)) {
                (void)closeSftpHandleLocked(handle, sessionLock);
                return ERR_SSH_WRITE_FAILED;
            }
            continue;
        }
        if (written <= 0) {
            OH_LOG_ERROR(LOG_APP, "[SFTP] 写入失败: pathId=%{public}s ret=%{public}zd",
                         pathId.c_str(), written);
            (void)closeSftpHandleLocked(handle, sessionLock);
            return ERR_SSH_WRITE_FAILED;
        }
        total += static_cast<uint32_t>(written);
        if (total < len && !yieldSftpSlice(sessionLock, -1, 0)) {
            (void)closeSftpHandleLocked(handle, sessionLock);
            return ERR_SSH_WRITE_FAILED;
        }
    }

    // A partial is eligible for atomic commit only after the server has
    // flushed its file handle. Treat an unsupported fsync extension as an
    // explicit capability failure instead of silently claiming durability.
    int syncRc = LIBSSH2_ERROR_EAGAIN;
    while (true) {
        if (!admitConnectedRouteWrite([&]() {
                syncRc = libssh2_sftp_fsync(handle);
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (syncRc != LIBSSH2_ERROR_EAGAIN) {
            break;
        }
        if (!yieldSftpSlice(sessionLock, 2, 1)) {
            (void)closeSftpHandleLocked(handle, sessionLock);
            return ERR_SSH_WRITE_FAILED;
        }
    }
    if (syncRc != 0) {
        const unsigned long sftpError = libssh2_sftp_last_error(sftp_);
        (void)closeSftpHandleLocked(handle, sessionLock);
        return sftpError == LIBSSH2_FX_OP_UNSUPPORTED
            ? ERR_SSH_SFTP_DURABILITY_UNSUPPORTED : ERR_SSH_WRITE_FAILED;
    }

    rc = closeSftpHandleLocked(handle, sessionLock);
    OH_LOG_INFO(LOG_APP, "[SFTP] 上传完成: pathId=%{public}s bytes=%{public}u rc=%{public}d",
                pathId.c_str(), len, rc);
    if (rc == ERR_SSH_SESSION_CLOSED) { return rc; }
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
    while (handle == nullptr) {
        if (!admitConnectedRouteWrite([&]() {
                handle = libssh2_sftp_open(
                    sftp_, remotePath.c_str(), flags,
                    LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SFTP_S_IWUSR |
                        LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IROTH);
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (handle != nullptr) {
            break;
        }
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
        ssize_t written = LIBSSH2_ERROR_SOCKET_SEND;
        if (!admitConnectedRouteWrite([&]() {
                written = libssh2_sftp_write(
                    handle, reinterpret_cast<const char*>(data + total), chunk);
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (written == LIBSSH2_ERROR_EAGAIN) {
            if (!yieldSftpSlice(sessionLock, 1, 1)) {
                (void)closeSftpHandleLocked(handle, sessionLock);
                return ERR_SSH_WRITE_FAILED;
            }
            continue;
        }
        if (written <= 0) {
            OH_LOG_ERROR(LOG_APP, "[SFTP] 分块写入失败: pathId=%{public}s offset=%{public}llu ret=%{public}zd",
                         pathId.c_str(),
                         static_cast<unsigned long long>(offset + total),
                         written);
            (void)closeSftpHandleLocked(handle, sessionLock);
            return ERR_SSH_WRITE_FAILED;
        }
        total += static_cast<uint32_t>(written);
        if (total < len && !yieldSftpSlice(sessionLock, -1, 0)) {
            (void)closeSftpHandleLocked(handle, sessionLock);
            return ERR_SSH_WRITE_FAILED;
        }
    }

    int syncRc = LIBSSH2_ERROR_EAGAIN;
    while (true) {
        if (!admitConnectedRouteWrite([&]() {
                syncRc = libssh2_sftp_fsync(handle);
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (syncRc != LIBSSH2_ERROR_EAGAIN) {
            break;
        }
        if (!yieldSftpSlice(sessionLock, 2, 1)) {
            (void)closeSftpHandleLocked(handle, sessionLock);
            return ERR_SSH_WRITE_FAILED;
        }
    }
    if (syncRc != 0) {
        const unsigned long sftpError = libssh2_sftp_last_error(sftp_);
        (void)closeSftpHandleLocked(handle, sessionLock);
        return sftpError == LIBSSH2_FX_OP_UNSUPPORTED
            ? ERR_SSH_SFTP_DURABILITY_UNSUPPORTED : ERR_SSH_WRITE_FAILED;
    }

    rc = closeSftpHandleLocked(handle, sessionLock);
    if (rc == ERR_SSH_SESSION_CLOSED) { return rc; }
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
    while (handle == nullptr) {
        if (!admitConnectedRouteWrite([&]() {
                handle = libssh2_sftp_opendir(sftp_, dirPath.c_str());
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (handle != nullptr) {
            break;
        }
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
        int n = LIBSSH2_ERROR_SOCKET_SEND;
        if (!admitConnectedRouteWrite([&]() {
                n = libssh2_sftp_readdir_ex(
                    handle, nameBuf, sizeof(nameBuf) - 1,
                    longEntryBuf, sizeof(longEntryBuf) - 1, &attrs);
            })) {
            (void)closeSftpHandleLocked(handle, sessionLock, true);
            return ERR_SSH_SESSION_CLOSED;
        }
        if (n == LIBSSH2_ERROR_EAGAIN) {
            if (!yieldSftpSlice(sessionLock, 2, 1)) {
                (void)closeSftpHandleLocked(handle, sessionLock, true);
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
            (void)closeSftpHandleLocked(handle, sessionLock, true);
            return ERR_SSH_READ_FAILED;
        }
    }

    rc = closeSftpHandleLocked(handle, sessionLock, true);
    if (rc == ERR_SSH_SESSION_CLOSED) { return rc; }
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
    while (handle == nullptr) {
        if (!admitConnectedRouteWrite([&]() {
                handle = libssh2_sftp_open(
                    sftp_, remotePath.c_str(), LIBSSH2_FXF_READ, 0);
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (handle != nullptr) {
            break;
        }
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
        ssize_t n = LIBSSH2_ERROR_SOCKET_SEND;
        if (!admitConnectedRouteWrite([&]() {
                n = libssh2_sftp_read(
                    handle, reinterpret_cast<char*>(buf.data()), buf.size());
            })) {
            (void)closeSftpHandleLocked(handle, sessionLock);
            return ERR_SSH_SESSION_CLOSED;
        }
        if (n == LIBSSH2_ERROR_EAGAIN) {
            if (!yieldSftpSlice(sessionLock, 0, 1)) {
                (void)closeSftpHandleLocked(handle, sessionLock);
                return ERR_SSH_READ_FAILED;
            }
            continue;
        }
        if (n < 0) {
            OH_LOG_ERROR(LOG_APP, "[SFTP] 读取文件失败: pathId=%{public}s ret=%{public}zd",
                         pathId.c_str(), n);
            (void)closeSftpHandleLocked(handle, sessionLock);
            return ERR_SSH_READ_FAILED;
        }
        if (n == 0) { break; }
        out.insert(out.end(), buf.begin(), buf.begin() + n);
        if (out.size() > 100 * 1024 * 1024) {
            OH_LOG_WARN(LOG_APP, "[SFTP] 下载超过 100MB, 已中止: pathId=%{public}s", pathId.c_str());
            (void)closeSftpHandleLocked(handle, sessionLock);
            out.clear();
            return -2;
        }
        if (!yieldSftpSlice(sessionLock, -1, 0)) {
            (void)closeSftpHandleLocked(handle, sessionLock);
            out.clear();
            return ERR_SSH_READ_FAILED;
        }
    }

    rc = closeSftpHandleLocked(handle, sessionLock);
    OH_LOG_INFO(LOG_APP, "[SFTP] 下载完成: pathId=%{public}s bytes=%{public}zu rc=%{public}d",
                pathId.c_str(), out.size(), rc);
    if (rc == ERR_SSH_SESSION_CLOSED) { return rc; }
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
    while (handle == nullptr) {
        if (!admitConnectedRouteWrite([&]() {
                handle = libssh2_sftp_open(
                    sftp_, remotePath.c_str(), LIBSSH2_FXF_READ, 0);
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (handle != nullptr) {
            break;
        }
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
        ssize_t n = LIBSSH2_ERROR_SOCKET_SEND;
        if (!admitConnectedRouteWrite([&]() {
                n = libssh2_sftp_read(
                    handle, reinterpret_cast<char*>(buf.data()), want);
            })) {
            (void)closeSftpHandleLocked(handle, sessionLock);
            return ERR_SSH_SESSION_CLOSED;
        }
        if (n == LIBSSH2_ERROR_EAGAIN) {
            if (!yieldSftpSlice(sessionLock, 0, 1)) {
                (void)closeSftpHandleLocked(handle, sessionLock);
                return ERR_SSH_READ_FAILED;
            }
            continue;
        }
        if (n < 0) {
            OH_LOG_ERROR(LOG_APP, "[SFTP] 分块读取文件失败: pathId=%{public}s offset=%{public}llu ret=%{public}zd",
                         pathId.c_str(),
                         static_cast<unsigned long long>(offset + out.size()),
                         n);
            (void)closeSftpHandleLocked(handle, sessionLock);
            return ERR_SSH_READ_FAILED;
        }
        if (n == 0) { break; }
        out.insert(out.end(), buf.begin(), buf.begin() + n);
        if (out.size() < maxLen && !yieldSftpSlice(sessionLock, -1, 0)) {
            (void)closeSftpHandleLocked(handle, sessionLock);
            out.clear();
            return ERR_SSH_READ_FAILED;
        }
    }

    rc = closeSftpHandleLocked(handle, sessionLock);
    if (rc == ERR_SSH_SESSION_CLOSED) { return rc; }
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
    while (true) {
        if (!admitConnectedRouteWrite([&]() {
                rc = libssh2_sftp_unlink(sftp_, remotePath.c_str());
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (rc != LIBSSH2_ERROR_EAGAIN) {
            break;
        }
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
    while (true) {
        if (!admitConnectedRouteWrite([&]() {
                rc = libssh2_sftp_rmdir(sftp_, remotePath.c_str());
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (rc != LIBSSH2_ERROR_EAGAIN) {
            break;
        }
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
    while (true) {
        if (!admitConnectedRouteWrite([&]() {
                rc = libssh2_sftp_mkdir(
                    sftp_, remotePath.c_str(),
                    LIBSSH2_SFTP_S_IRWXU | LIBSSH2_SFTP_S_IRGRP |
                        LIBSSH2_SFTP_S_IXGRP | LIBSSH2_SFTP_S_IROTH |
                        LIBSSH2_SFTP_S_IXOTH);
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (rc != LIBSSH2_ERROR_EAGAIN) {
            break;
        }
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
    while (true) {
        if (!admitConnectedRouteWrite([&]() {
                rc = libssh2_sftp_rename(
                    sftp_, oldPath.c_str(), newPath.c_str());
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (rc != LIBSSH2_ERROR_EAGAIN) {
            break;
        }
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
    while (true) {
        if (!admitConnectedRouteWrite([&]() {
                rc = libssh2_sftp_posix_rename(
                    sftp_, oldPath.c_str(), newPath.c_str());
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (rc != LIBSSH2_ERROR_EAGAIN) {
            break;
        }
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

SftpOperationResult SshAdapter::executeSftpOperation(
        const std::function<int()>& operation) {
    if (!operation) {
        return {ERR_SSH_SESSION_CLOSED, false};
    }
    const auto executeAndClassifyOnOwner = [this, &operation]() {
        // Capture libssh2's state in the same reactor turn as the operation.
        // A recovery command must not run between failure and classification.
        const SshSftpOperationObservation observation =
            ObserveSshSftpOperationOnOwner(operation, [this](int errorCode) {
                return classifySftpTransportFailure(errorCode);
            });
        return SftpOperationResult {
            observation.errorCode,
            observation.transportLost
        };
    };
    return isReactorThread()
        ? executeAndClassifyOnOwner()
        : runOnReactor(executeAndClassifyOnOwner);
}

bool SshAdapter::classifySftpTransportFailure(int operationError) {
    if (operationError >= 0 || operationError == ERR_SSH_SFTP_DURABILITY_UNSUPPORTED ||
        operationError == ERR_SSH_SESSION_STALE ||
        operationError == ERR_SSH_REACTOR_QUEUE_FULL) {
        return false;
    }
    const auto classifyOnOwner = [this, operationError]() {
        const ConnectionState currentState = state_.load(std::memory_order_acquire);
        bool transportLost = operationError == ERR_SSH_SESSION_CLOSED ||
            transportRecoveryRequested_.load(std::memory_order_acquire) ||
            currentState == ConnectionState::RECONNECTING;
        int libssh2Error = 0;
        {
            std::lock_guard<std::mutex> sessionLock(sessionMutex_);
            if (session_ != nullptr) {
                libssh2Error = libssh2_session_last_errno(session_);
            }
        }
        transportLost = transportLost ||
            classifyPtyFailure(libssh2Error) == SshPtyFailureClass::TRANSIENT_TRANSPORT ||
            currentState != ConnectionState::CONNECTED;
        if (transportLost && readerRunning_.load(std::memory_order_acquire) &&
            !connectCancelRequested_.load(std::memory_order_acquire)) {
            terminalInputAccepting_.store(false, std::memory_order_release);
            setSshLifecycleState(SshSessionLifecycleState::NetworkLost);
            setState(ConnectionState::RECONNECTING,
                "SSH SFTP transport lost, reconnecting");
            transportRecoveryRequested_.store(true, std::memory_order_release);
            reactorCommandCondition_.notify_all();
        }
        return transportLost;
    };
    return isReactorThread() ? classifyOnOwner() : runOnReactor(classifyOnOwner);
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

void SshAdapter::setSshLifecycleStateCallback(SshLifecycleStateCallback callback) {
    std::lock_guard<std::mutex> lock(sshLifecycleCallbackMutex_);
    sshLifecycleStateCallback_ = std::move(callback);
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
            if (!admitConnectedRouteWrite([&]() {
                    diagnostics_.recordWriteAttempt(sequence);
                    rc = libssh2_channel_write(
                        channel_, reinterpret_cast<const char*>(data) + total,
                        len - total);
                })) {
                if (state_.load(std::memory_order_acquire) ==
                        ConnectionState::CONNECTED &&
                    !connectCancelRequested_.load(std::memory_order_acquire)) {
                    terminalInputAccepting_.store(false, std::memory_order_release);
                    transportRecoveryRequested_.store(true,
                                                      std::memory_order_release);
                    reactorCommandCondition_.notify_all();
                }
                return ERR_SSH_SESSION_CLOSED;
            }
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
    size_t queueDepthAfterDequeue = 0;
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
        queueDepthAfterDequeue = inputQueue_.size();
    }
    OH_LOG_INFO(LOG_APP,
        "[SSH] terminal input dequeue seq=%{public}llu bytes=%{public}zu control=%{public}d "
        "ordered=%{public}d orderedEnd=%{public}d generation=%{public}llu queueDepth=%{public}zu",
        static_cast<unsigned long long>(item.sequence), item.bytes.size(),
        item.control ? 1 : 0, item.ordered ? 1 : 0, item.orderedEnd ? 1 : 0,
        static_cast<unsigned long long>(item.generation), queueDepthAfterDequeue);
    if (item.ordered) {
        orderedInputActive_.store(!item.orderedEnd, std::memory_order_release);
    }
    if (!terminalInputAccepting_.load(std::memory_order_acquire) ||
        !terminalInputRunning_.load(std::memory_order_acquire) ||
        item.generation != diagnostics_.sessionGeneration() ||
        state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED) {
        diagnostics_.recordLoss();
        OH_LOG_WARN(LOG_APP,
            "[SSH] terminal input rejected after dequeue seq=%{public}llu itemGeneration=%{public}llu "
            "sessionGeneration=%{public}llu accepting=%{public}d running=%{public}d state=%{public}d",
            static_cast<unsigned long long>(item.sequence),
            static_cast<unsigned long long>(item.generation),
            static_cast<unsigned long long>(diagnostics_.sessionGeneration()),
            terminalInputAccepting_.load(std::memory_order_acquire) ? 1 : 0,
            terminalInputRunning_.load(std::memory_order_acquire) ? 1 : 0,
            static_cast<int>(state_.load(std::memory_order_acquire)));
        return;
    }
    const int result = writeTerminalData(item.bytes.data(), item.bytes.size(), item.sequence, true);
    OH_LOG_INFO(LOG_APP, "[SSH] terminal input write seq=%{public}llu bytes=%{public}zu result=%{public}d",
        static_cast<unsigned long long>(item.sequence), item.bytes.size(), result);
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
            ssize_t n = LIBSSH2_ERROR_SOCKET_SEND;
            if (!admitConnectedRouteRead([&]() {
                    n = libssh2_channel_read(
                        channel_, reinterpret_cast<char*>(buffer.data()),
                        buffer.size());
                })) {
                readError = true;
                readErrorCode = ERR_SSH_SESSION_CLOSED;
                break;
            }
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

int SshAdapter::executeCommandForOperation(
    const std::string& command, SshCommandResult& result,
    remotedesk::net::NetworkGenerationSnapshot networkSnapshot,
    int timeoutMs) {
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        return runOnReactor(
            [this, command, &result, networkSnapshot, timeoutMs]() {
                return executeCommandForOperation(
                    command, result, networkSnapshot, timeoutMs);
            });
    }
    return executeChannelRequest(
        command, false, result, timeoutMs, &networkSnapshot);
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

int SshAdapter::executeChannelRequest(
    const std::string& request, bool subsystem,
    SshCommandResult& result, int timeoutMs,
    const remotedesk::net::NetworkGenerationSnapshot*
        requiredNetworkSnapshot) {
    result = SshCommandResult {};
    if (request.empty()) { return ERR_SSH_SUBSYSTEM_FAILED; }
    if (timeoutMs <= 0) { timeoutMs = 30000; }
    if (!isReactorThread() && readerRunning_.load(std::memory_order_acquire)) {
        if (requiredNetworkSnapshot != nullptr) {
            const remotedesk::net::NetworkGenerationSnapshot captured =
                *requiredNetworkSnapshot;
            return runOnReactor(
                [this, request, subsystem, &result, timeoutMs, captured]() {
                    return executeChannelRequest(
                        request, subsystem, result, timeoutMs, &captured);
                });
        }
        return runOnReactor([this, request, subsystem, &result, timeoutMs]() {
            return executeChannelRequest(request, subsystem, result, timeoutMs);
        });
    }
    const auto deadline = boundedConnectStageDeadline(
        std::chrono::milliseconds(timeoutMs));

    std::lock_guard<std::recursive_mutex> lifecycleLock(lifecycleMutex_);
    std::unique_lock<std::mutex> sessionLock(sessionMutex_);
    const remotedesk::net::NetworkGenerationSnapshot routeSnapshot =
        requiredNetworkSnapshot != nullptr
            ? *requiredNetworkSnapshot : connectNetworkSnapshot_;
    auto requiredRouteCurrent = [this, requiredNetworkSnapshot]() {
        return requiredNetworkSnapshot == nullptr ||
            (requiredNetworkSnapshot->available &&
             requiredNetworkSnapshot->generation != 0 &&
             requiredNetworkSnapshot->generation ==
                 connectNetworkSnapshot_.generation &&
             requiredNetworkSnapshot->available ==
                 connectNetworkSnapshot_.available &&
             !remotedesk::net::ProcessNetworkGenerationFence().shouldCancel(
                 *requiredNetworkSnapshot));
    };
    if (std::chrono::steady_clock::now() >= deadline) {
        return ERR_SSH_COMMAND_TIMEOUT;
    }
    if (!session_ ||
        state_.load(std::memory_order_acquire) != ConnectionState::CONNECTED ||
        !requiredRouteCurrent()) {
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
            !connectCancelRequested_.load(std::memory_order_acquire) &&
            requiredRouteCurrent();
    };

    LIBSSH2_CHANNEL* commandChannel = nullptr;
    while (commandChannel == nullptr) {
        if (!admitRouteWrite(routeSnapshot, [&]() {
                commandChannel = libssh2_channel_open_session(session_);
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (commandChannel != nullptr) {
            break;
        }
        if (std::chrono::steady_clock::now() >= deadline) {
            return ERR_SSH_COMMAND_TIMEOUT;
        }
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
            if (!admitRouteWrite(routeSnapshot, [&]() {
                    closeResult = libssh2_channel_close(commandChannel);
                })) {
                commandChannel = nullptr;
                return;
            }
            if (closeResult == LIBSSH2_ERROR_EAGAIN) {
                if (!waitForRequest()) { break; }
            }
        }
        int freeResult = LIBSSH2_ERROR_EAGAIN;
        while (freeResult == LIBSSH2_ERROR_EAGAIN) {
            if (!admitRouteWrite(routeSnapshot, [&]() {
                    freeResult = libssh2_channel_free(commandChannel);
                })) {
                // The session retains the channel and its later stale-route
                // teardown will retire the socket before releasing it.
                commandChannel = nullptr;
                return;
            }
            if (freeResult == LIBSSH2_ERROR_EAGAIN && !waitForRequest()) {
                break;
            }
        }
        commandChannel = nullptr;
    };

    int startupResult = LIBSSH2_ERROR_EAGAIN;
    while (true) {
        if (std::chrono::steady_clock::now() >= deadline) {
            closeChannel();
            return ERR_SSH_COMMAND_TIMEOUT;
        }
        if (!admitRouteWrite(routeSnapshot, [&]() {
                startupResult = subsystem
                    ? libssh2_channel_subsystem(
                        commandChannel, request.c_str())
                    : libssh2_channel_exec(
                        commandChannel, request.c_str());
            })) {
            closeChannel();
            return routeWriteFailure(ERR_SSH_COMMAND_TIMEOUT);
        }
        if (startupResult != LIBSSH2_ERROR_EAGAIN) { break; }
        if (!waitForRequest()) {
            closeChannel();
            return ERR_SSH_COMMAND_TIMEOUT;
        }
    }
    if (startupResult != 0) {
        closeChannel();
        return ERR_SSH_SUBSYSTEM_FAILED;
    }

    // A generation change after libssh2 accepts a request is an unknown
    // server-side outcome. The optional required snapshot is used by the
    // exact authorized_keys command, whose grep-before-append form is
    // idempotent; only that caller's outer generation runner may repeat it.

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
        if ((isReactorThread() &&
             !readerRunning_.load(std::memory_order_acquire)) ||
            !requiredRouteCurrent()) {
            closeChannel();
            return ERR_SSH_SESSION_CLOSED;
        }
        serviceTerminalInput();
        bool progressed = false;
        if (!stdoutDone) {
            ssize_t readResult = LIBSSH2_ERROR_SOCKET_SEND;
            if (!admitRouteWrite(routeSnapshot, [&]() {
                    readResult = libssh2_channel_read(
                        commandChannel, reinterpret_cast<char*>(buffer.data()),
                        buffer.size());
                })) {
                closeChannel();
                return ERR_SSH_SESSION_CLOSED;
            }
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
            ssize_t readResult = LIBSSH2_ERROR_SOCKET_SEND;
            if (!admitRouteWrite(routeSnapshot, [&]() {
                    readResult = libssh2_channel_read_stderr(
                        commandChannel,
                        reinterpret_cast<char*>(buffer.data()), buffer.size());
                })) {
                closeChannel();
                return ERR_SSH_SESSION_CLOSED;
            }
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
    while (true) {
        if (!admitConnectedRouteWrite([&]() {
                rc = libssh2_channel_signal(channel_, signal.c_str());
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (rc != LIBSSH2_ERROR_EAGAIN) {
            break;
        }
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
    while (true) {
        if (!admitConnectedRouteWrite([&]() {
                rc = libssh2_channel_send_eof(channel_);
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
        if (rc != LIBSSH2_ERROR_EAGAIN) {
            break;
        }
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
        ssize_t n = LIBSSH2_ERROR_SOCKET_SEND;
        if (!admitConnectedRouteRead([&]() {
                n = libssh2_channel_read(
                    channel_, reinterpret_cast<char*>(buf), bufSize);
            })) {
            return ERR_SSH_SESSION_CLOSED;
        }
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
            if (!admitConnectedRouteWrite([&]() {
                    rc = libssh2_channel_request_pty_size(
                        channel_, cols, rows);
                })) {
                break;
            }
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
    while (true) {
        if (!admitConnectedRouteWrite([&]() {
                rc = libssh2_keepalive_send(session_, &secondsToNext);
            })) {
            return -2;
        }
        if (rc != LIBSSH2_ERROR_EAGAIN) {
            break;
        }
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
        if (!admitConnectedRouteWrite([&]() {
                rc = libssh2_keepalive_send(session_, &secondsToNext);
            })) {
            return;
        }
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
        const int interval = secondsToNext > 0 ? secondsToNext : SshReconnectPolicy::kKeepaliveSeconds;
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
    if (!SshReconnectPolicy::keepaliveFailureTriggersRecovery(keepaliveConsecutiveFailures_)) {
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

void SshAdapter::redeliverTerminalOutputAfterDetach(
    const std::vector<uint8_t>& data) {
    // DataTsfnCallJs runs on the ArkTS thread. deliverTerminalOutput owns the
    // callback/FIFO locks, so this is safe whether the target window has
    // already installed its new consumer or is still mounting.
    deliverTerminalOutput(data);
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
        serviceForwardingOnReactor();
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
            ssize_t n = LIBSSH2_ERROR_SOCKET_SEND;
            if (!admitConnectedRouteRead([&]() {
                    n = libssh2_channel_read(
                        ch, reinterpret_cast<char*>(buf.data()), kBufSize);
                })) {
                readError = true;
                readErrorCode = ERR_SSH_SESSION_CLOSED;
                break;
            }
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
