#include "moonlight/runtime/MoonlightProductRuntime.h"

#include "moonlight/control/MoonlightHostControl.h"
#include "moonlight/input/MoonlightControllerMapper.h"
#include "moonlight/pairing/MoonlightPairingManager.h"
#include "moonlight/security/MoonlightSecureIdentity.h"
#include "moonlight/runtime/MoonlightHttpResponseFraming.h"
#include "moonlight/runtime/MoonlightProductStreamingRuntime.h"

#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <functional>
#include <memory>
#include <mutex>
#include <netdb.h>
#include <optional>
#include <poll.h>
#include <string>
#include <sys/socket.h>
#include <unistd.h>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace remotedesk::moonlight {
namespace {

constexpr std::size_t kMaxHeaderBytes = 64U * 1024U;
constexpr std::chrono::milliseconds kPollSlice{100};

std::uint64_t monotonicMilliseconds() noexcept {
    return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

struct HostKey final {
    std::string owner;
    std::string host;

    bool operator==(const HostKey& other) const noexcept {
        return owner == other.owner && host == other.host;
    }
};

struct HostKeyHash final {
    std::size_t operator()(const HostKey& value) const noexcept {
        std::size_t hash = std::hash<std::string>{}(value.owner);
        hash ^= std::hash<std::string>{}(value.host) + 0x9e3779b9U +
                (hash << 6U) + (hash >> 2U);
        return hash;
    }
};

struct RequestKeyHash final {
    std::size_t operator()(const MoonlightHostRequestKey& value) const noexcept {
        std::size_t hash = static_cast<std::size_t>(value.requestId);
        hash ^= static_cast<std::size_t>(value.generation) + 0x9e3779b9U +
                (hash << 6U) + (hash >> 2U);
        hash ^= static_cast<std::size_t>(value.ownerToken) + 0x9e3779b9U +
                (hash << 6U) + (hash >> 2U);
        return hash;
    }
};

struct PairingKeyHash final {
    std::size_t operator()(
        const MoonlightPairingOperationKey& value) const noexcept {
        std::size_t hash = static_cast<std::size_t>(value.requestId);
        hash ^= static_cast<std::size_t>(value.generation) + 0x9e3779b9U +
                (hash << 6U) + (hash >> 2U);
        hash ^= static_cast<std::size_t>(value.ownerToken) + 0x9e3779b9U +
                (hash << 6U) + (hash >> 2U);
        return hash;
    }
};

struct Binding final {
    std::vector<std::uint8_t> serverCertificateDer;
    std::string certificateSha256;
    // Pairing binds the identity lease only for the duration of the manager
    // call. Host Control owns a shared lease instead.
    MoonlightIdentityLease* borrowedIdentity = nullptr;
    std::shared_ptr<MoonlightIdentityLease> ownedIdentity;
};

class BindingRegistry final {
public:
    void setActive(const MoonlightHostRequestKey& key, Binding binding) {
        std::lock_guard<std::mutex> lock(mutex_);
        active_[key] = std::move(binding);
    }

    void rememberLast(const MoonlightHostRequestKey& key,
                      const std::vector<std::uint8_t>& certificate,
                      const std::string& fingerprint) {
        Binding binding;
        binding.serverCertificateDer = certificate;
        binding.certificateSha256 = fingerprint;
        std::lock_guard<std::mutex> lock(mutex_);
        last_[key] = std::move(binding);
    }

    std::optional<Binding> active(const MoonlightHostRequestKey& key) const {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto iterator = active_.find(key);
        return iterator == active_.end() ? std::nullopt :
            std::optional<Binding>(iterator->second);
    }

    void clearActive(const MoonlightHostRequestKey& key) noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        active_.erase(key);
    }

    void clearTransient(const MoonlightHostRequestKey& key) noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        active_.erase(key);
        last_.erase(key);
    }

    bool promoteLast(const MoonlightHostRequestKey& key,
                     const std::string& owner,
                     const std::string& host) {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto iterator = last_.find(key);
        if (iterator == last_.end() || iterator->second.serverCertificateDer.empty() ||
            iterator->second.certificateSha256.empty()) {
            return false;
        }
        hosts_[HostKey{owner, host}] = iterator->second;
        last_.erase(iterator);
        return true;
    }

    bool restoreHost(const std::string& owner, const std::string& host,
                     const std::string& fingerprint) {
        if (owner.empty() || host.empty() || fingerprint.size() != 64U) {
            return false;
        }
        Binding binding;
        binding.certificateSha256 = fingerprint;
        std::lock_guard<std::mutex> lock(mutex_);
        hosts_[HostKey{owner, host}] = std::move(binding);
        return true;
    }

    std::optional<Binding> host(const std::string& owner,
                                const std::string& host) const {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto iterator = hosts_.find(HostKey{owner, host});
        return iterator == hosts_.end() ? std::nullopt :
            std::optional<Binding>(iterator->second);
    }

    void forgetHost(const std::string& owner,
                    const std::string& host) noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        hosts_.erase(HostKey{owner, host});
    }

private:
    mutable std::mutex mutex_;
    std::unordered_map<MoonlightHostRequestKey, Binding, RequestKeyHash> active_;
    std::unordered_map<MoonlightHostRequestKey, Binding, RequestKeyHash> last_;
    std::unordered_map<HostKey, Binding, HostKeyHash> hosts_;
};

bool cancelled(const MoonlightHostTransport::CancellationProbe& probe) noexcept {
    try {
        return probe && probe();
    } catch (...) {
        return true;
    }
}

bool deadlineExpired(std::chrono::steady_clock::time_point deadline) noexcept {
    return std::chrono::steady_clock::now() >= deadline;
}

enum class WaitResult : std::uint8_t { Ready, Timeout, Error, Cancelled };

WaitResult waitForSocket(int descriptor, short events,
                         std::chrono::steady_clock::time_point deadline,
                         const MoonlightHostTransport::CancellationProbe& probe) noexcept {
    while (!deadlineExpired(deadline)) {
        if (cancelled(probe)) { return WaitResult::Cancelled; }
        const auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(
            deadline - std::chrono::steady_clock::now());
        const int timeout = static_cast<int>(std::max<std::int64_t>(
            1, std::min<std::int64_t>(remaining.count(), kPollSlice.count())));
        struct pollfd descriptorState { descriptor, events, 0 };
        const int result = ::poll(&descriptorState, 1, timeout);
        if (result > 0) {
            if ((descriptorState.revents & events) != 0) { return WaitResult::Ready; }
            // A peer that writes its response and immediately closes may
            // report POLLIN | POLLHUP, or only POLLHUP once all bytes have
            // been drained. Let the read path consume data or observe EOF.
            if ((events & POLLIN) != 0 &&
                (descriptorState.revents & POLLHUP) != 0) {
                return WaitResult::Ready;
            }
            if ((descriptorState.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                return WaitResult::Error;
            }
        } else if (result < 0 && errno != EINTR) {
            return WaitResult::Error;
        }
    }
    return WaitResult::Timeout;
}

bool setNonBlocking(int descriptor) noexcept {
    const int flags = ::fcntl(descriptor, F_GETFL, 0);
    return flags >= 0 && ::fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0;
}

class SocketGuard final {
public:
    explicit SocketGuard(int descriptor = -1) noexcept : descriptor_(descriptor) {}
    ~SocketGuard() { if (descriptor_ >= 0) { ::close(descriptor_); } }
    SocketGuard(const SocketGuard&) = delete;
    SocketGuard& operator=(const SocketGuard&) = delete;
    SocketGuard(SocketGuard&& other) noexcept : descriptor_(other.descriptor_) {
        other.descriptor_ = -1;
    }
    SocketGuard& operator=(SocketGuard&& other) noexcept {
        if (this != &other) {
            if (descriptor_ >= 0) { ::close(descriptor_); }
            descriptor_ = other.descriptor_;
            other.descriptor_ = -1;
        }
        return *this;
    }
    int get() const noexcept { return descriptor_; }

private:
    int descriptor_;
};

struct SslCtxDeleter final { void operator()(SSL_CTX* value) const noexcept { SSL_CTX_free(value); } };
struct SslDeleter final { void operator()(SSL* value) const noexcept { SSL_free(value); } };
struct X509Deleter final { void operator()(X509* value) const noexcept { X509_free(value); } };
using SslCtxPtr = std::unique_ptr<SSL_CTX, SslCtxDeleter>;
using SslPtr = std::unique_ptr<SSL, SslDeleter>;
using X509Ptr = std::unique_ptr<X509, X509Deleter>;

std::string hexDigest(X509* certificate) {
    std::array<unsigned char, EVP_MAX_MD_SIZE> digest{};
    unsigned int digestSize = 0;
    if (certificate == nullptr || X509_digest(certificate, EVP_sha256(),
                                               digest.data(), &digestSize) != 1) {
        return {};
    }
    static constexpr char kHex[] = "0123456789abcdef";
    std::string result;
    result.reserve(digestSize * 2U);
    for (unsigned int index = 0; index < digestSize; ++index) {
        result.push_back(kHex[(digest[index] >> 4U) & 0x0fU]);
        result.push_back(kHex[digest[index] & 0x0fU]);
    }
    return result;
}

std::string hostHeader(const MoonlightTransportRequest& request) {
    std::string value = request.serverName().empty() ? request.connectAddress() :
        request.serverName();
    if (value.find(':') != std::string::npos && value.front() != '[') {
        value = '[' + value + ']';
    }
    return value;
}

std::string requestTarget(const MoonlightTransportRequest& request) {
    const std::string& url = request.url();
    const std::size_t scheme = url.find("://");
    if (scheme == std::string::npos) { return request.path(); }
    const std::size_t path = url.find('/', scheme + 3U);
    return path == std::string::npos ? "/" : url.substr(path);
}

class StringCleanser final {
public:
    explicit StringCleanser(std::string& value) noexcept : value_(value) {}
    ~StringCleanser() {
        if (!value_.empty()) { OPENSSL_cleanse(value_.data(), value_.size()); }
        value_.clear();
    }
    StringCleanser(const StringCleanser&) = delete;
    StringCleanser& operator=(const StringCleanser&) = delete;

private:
    std::string& value_;
};

class ProductHttpTransport final : public MoonlightHostTransport {
public:
    explicit ProductHttpTransport(std::shared_ptr<BindingRegistry> bindings)
        : bindings_(std::move(bindings)) {}

    MoonlightTransportOutcome execute(
        const MoonlightTransportRequest& request,
        std::chrono::steady_clock::time_point deadline,
        const CancellationProbe& cancellationProbe) override {
        MoonlightTransportOutcome outcome;
        outcome.stage = MoonlightTransportStage::Dns;
        if (cancelled(cancellationProbe)) {
            outcome.error = MoonlightTransportError::Cancelled;
            return outcome;
        }
        if (deadlineExpired(deadline)) {
            outcome.error = MoonlightTransportError::Timeout;
            return outcome;
        }

        addrinfo hints{};
        hints.ai_socktype = SOCK_STREAM;
        hints.ai_family = request.family() == MoonlightHostAddressFamily::Ipv4 ? AF_INET :
            request.family() == MoonlightHostAddressFamily::Ipv6 ? AF_INET6 : AF_UNSPEC;
        const std::string port = std::to_string(request.port());
        addrinfo* rawAddresses = nullptr;
        if (::getaddrinfo(request.connectAddress().c_str(), port.c_str(), &hints,
                          &rawAddresses) != 0 || rawAddresses == nullptr) {
            outcome.error = MoonlightTransportError::DnsFailure;
            return outcome;
        }
        std::unique_ptr<addrinfo, decltype(&freeaddrinfo)> addresses(rawAddresses, freeaddrinfo);
        SocketGuard socket;
        outcome.stage = MoonlightTransportStage::Connect;
        for (addrinfo* address = addresses.get(); address != nullptr; address = address->ai_next) {
            SocketGuard candidate(::socket(address->ai_family, address->ai_socktype,
                                            address->ai_protocol));
            if (candidate.get() < 0 || !setNonBlocking(candidate.get())) { continue; }
            const int connectResult = ::connect(candidate.get(), address->ai_addr,
                                                address->ai_addrlen);
            if (connectResult == 0) {
                socket = std::move(candidate);
                break;
            }
            if (errno != EINPROGRESS) { continue; }
            const WaitResult wait = waitForSocket(candidate.get(), POLLOUT, deadline,
                                                   cancellationProbe);
            if (wait == WaitResult::Cancelled) {
                outcome.error = MoonlightTransportError::Cancelled;
                return outcome;
            }
            if (wait == WaitResult::Timeout) {
                outcome.error = MoonlightTransportError::Timeout;
                return outcome;
            }
            if (wait != WaitResult::Ready) { continue; }
            int socketError = 0;
            socklen_t socketErrorLength = sizeof(socketError);
            if (::getsockopt(candidate.get(), SOL_SOCKET, SO_ERROR, &socketError,
                             &socketErrorLength) != 0 || socketError != 0) {
                continue;
            }
            socket = std::move(candidate);
            break;
        }
        if (socket.get() < 0) {
            outcome.error = MoonlightTransportError::ConnectFailure;
            return outcome;
        }

        std::optional<Binding> binding;
        if (request.scheme() == MoonlightHostScheme::Https) {
            binding = bindings_->active(request.key());
            if (request.requiresClientIdentity() &&
                (!binding.has_value() || (binding->borrowedIdentity == nullptr &&
                                          binding->ownedIdentity == nullptr))) {
                outcome.error = MoonlightTransportError::TrustConflict;
                outcome.stage = MoonlightTransportStage::Tls;
                return outcome;
            }
        }

        SslCtxPtr context(nullptr);
        SslPtr ssl(nullptr);
        if (request.scheme() == MoonlightHostScheme::Https) {
            outcome.stage = MoonlightTransportStage::Tls;
            context.reset(SSL_CTX_new(TLS_client_method()));
            if (!context || SSL_CTX_set_min_proto_version(context.get(), TLS1_2_VERSION) != 1) {
                outcome.error = MoonlightTransportError::TlsVersionFailure;
                return outcome;
            }
#if defined(SSL_OP_IGNORE_UNEXPECTED_EOF)
            // HTTP close-delimited responses use EOF as framing. Content-
            // Length and chunked truncation are still rejected by the parser.
            (void)SSL_CTX_set_options(context.get(), SSL_OP_IGNORE_UNEXPECTED_EOF);
#endif
            // Sunshine certificates are self-signed. Exact leaf pinning below
            // is the trust decision; the public CA chain is intentionally not
            // consulted for this Moonlight-only transport.
            SSL_CTX_set_verify(context.get(), SSL_VERIFY_NONE, nullptr);
            MoonlightIdentityLease* lease = binding->borrowedIdentity;
            if (lease == nullptr && binding->ownedIdentity != nullptr) {
                lease = binding->ownedIdentity.get();
            }
            if (request.requiresClientIdentity() &&
                (lease == nullptr || lease->configureTlsContext(context.get()) !=
                    MoonlightIdentityCode::Ok)) {
                outcome.error = MoonlightTransportError::TlsChainFailure;
                return outcome;
            }
            ssl.reset(SSL_new(context.get()));
            if (!ssl || SSL_set_fd(ssl.get(), socket.get()) != 1) {
                outcome.error = MoonlightTransportError::TlsVersionFailure;
                return outcome;
            }
            (void)SSL_set_tlsext_host_name(ssl.get(), request.serverName().c_str());
            for (;;) {
                const int result = SSL_connect(ssl.get());
                if (result == 1) { break; }
                const int sslError = SSL_get_error(ssl.get(), result);
                if (sslError != SSL_ERROR_WANT_READ && sslError != SSL_ERROR_WANT_WRITE) {
                    outcome.error = MoonlightTransportError::TlsChainFailure;
                    return outcome;
                }
                const WaitResult wait = waitForSocket(
                    socket.get(), sslError == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT,
                    deadline, cancellationProbe);
                if (wait == WaitResult::Cancelled) {
                    outcome.error = MoonlightTransportError::Cancelled;
                    return outcome;
                }
                if (wait == WaitResult::Timeout) {
                    outcome.error = MoonlightTransportError::Timeout;
                    return outcome;
                }
                if (wait != WaitResult::Ready) {
                    outcome.error = MoonlightTransportError::TlsChainFailure;
                    return outcome;
                }
            }
            X509Ptr peer(SSL_get1_peer_certificate(ssl.get()));
            const std::string peerFingerprint = hexDigest(peer.get());
            if (request.requiresServerPin() &&
                (!binding.has_value() || peerFingerprint.empty() ||
                 peerFingerprint != binding->certificateSha256)) {
                outcome.error = MoonlightTransportError::TrustConflict;
                return outcome;
            }
        }

        outcome.stage = MoonlightTransportStage::Http;
        std::string requestText = "GET " + requestTarget(request) + " HTTP/1.1\r\nHost: " +
            hostHeader(request) + "\r\nAccept: application/xml, */*\r\nConnection: close\r\n\r\n";
        StringCleanser requestTextCleanser(requestText);
        std::size_t sent = 0;
        while (sent < requestText.size()) {
            if (cancelled(cancellationProbe)) {
                outcome.error = MoonlightTransportError::Cancelled;
                return outcome;
            }
            int count = 0;
            if (ssl) {
                count = SSL_write(ssl.get(), requestText.data() + sent,
                                  static_cast<int>(std::min<std::size_t>(
                                      requestText.size() - sent, 16384U)));
                if (count <= 0) {
                    const int sslError = SSL_get_error(ssl.get(), count);
                    if (sslError == SSL_ERROR_WANT_READ || sslError == SSL_ERROR_WANT_WRITE) {
                        const WaitResult wait = waitForSocket(
                            socket.get(), sslError == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT,
                            deadline, cancellationProbe);
                        if (wait == WaitResult::Cancelled) {
                            outcome.error = MoonlightTransportError::Cancelled;
                        } else if (wait == WaitResult::Timeout) {
                            outcome.error = MoonlightTransportError::Timeout;
                        } else if (wait != WaitResult::Ready) {
                            outcome.error = MoonlightTransportError::ProtocolFailure;
                        }
                        if (outcome.error != MoonlightTransportError::None) { return outcome; }
                        continue;
                    }
                    outcome.error = MoonlightTransportError::ProtocolFailure;
                    return outcome;
                }
            } else {
                count = static_cast<int>(::send(socket.get(), requestText.data() + sent,
                                                std::min<std::size_t>(requestText.size() - sent,
                                                                      16384U), 0));
                if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                    const WaitResult wait = waitForSocket(socket.get(), POLLOUT, deadline,
                                                           cancellationProbe);
                    if (wait == WaitResult::Cancelled) {
                        outcome.error = MoonlightTransportError::Cancelled;
                    } else if (wait == WaitResult::Timeout) {
                        outcome.error = MoonlightTransportError::Timeout;
                    } else if (wait != WaitResult::Ready) {
                        outcome.error = MoonlightTransportError::ProtocolFailure;
                    }
                    if (outcome.error != MoonlightTransportError::None) { return outcome; }
                    continue;
                }
                if (count < 0) {
                    outcome.error = MoonlightTransportError::ProtocolFailure;
                    return outcome;
                }
            }
            if (count == 0) {
                outcome.error = MoonlightTransportError::ProtocolFailure;
                return outcome;
            }
            sent += static_cast<std::size_t>(count);
        }
        outcome.sendState = MoonlightTransportSendState::SentResponseUnknown;

        std::string response;
        StringCleanser responseCleanser(response);
        response.reserve(4096U);
        while (!deadlineExpired(deadline)) {
            if (cancelled(cancellationProbe)) {
                outcome.error = MoonlightTransportError::Cancelled;
                return outcome;
            }
            char buffer[16384];
            int count = 0;
            bool endOfStream = false;
            if (ssl) {
                count = SSL_read(ssl.get(), buffer, sizeof(buffer));
                if (count <= 0) {
                    const int sslError = SSL_get_error(ssl.get(), count);
                    if (sslError == SSL_ERROR_ZERO_RETURN) {
                        endOfStream = true;
                    }
                    if (sslError == SSL_ERROR_WANT_READ || sslError == SSL_ERROR_WANT_WRITE) {
                        const WaitResult wait = waitForSocket(
                            socket.get(), sslError == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT,
                            deadline, cancellationProbe);
                        if (wait == WaitResult::Cancelled) {
                            outcome.error = MoonlightTransportError::Cancelled;
                            return outcome;
                        }
                        if (wait == WaitResult::Timeout) {
                            outcome.error = MoonlightTransportError::Timeout;
                            return outcome;
                        }
                        if (wait != WaitResult::Ready) {
                            outcome.error = MoonlightTransportError::ProtocolFailure;
                            return outcome;
                        }
                        continue;
                    }
                    if (!endOfStream) {
                        outcome.error = MoonlightTransportError::ProtocolFailure;
                        return outcome;
                    }
                }
            } else {
                count = static_cast<int>(::recv(socket.get(), buffer, sizeof(buffer), 0));
                if (count == 0) { endOfStream = true; }
                if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                    const WaitResult wait = waitForSocket(socket.get(), POLLIN, deadline,
                                                           cancellationProbe);
                    if (wait == WaitResult::Cancelled) {
                        outcome.error = MoonlightTransportError::Cancelled;
                        return outcome;
                    }
                    if (wait == WaitResult::Timeout) {
                        outcome.error = MoonlightTransportError::Timeout;
                        return outcome;
                    }
                    if (wait != WaitResult::Ready) {
                        outcome.error = MoonlightTransportError::ProtocolFailure;
                        return outcome;
                    }
                    continue;
                }
                if (count < 0) {
                    outcome.error = MoonlightTransportError::ProtocolFailure;
                    return outcome;
                }
            }
            if (count > 0) {
                response.append(buffer, static_cast<std::size_t>(count));
            }
            auto framing = inspectMoonlightHttpResponse(
                response, endOfStream, kMaxHeaderBytes, request.responseBudget());
            if (framing.headersComplete) {
                outcome.httpStatus = framing.httpStatus;
                outcome.sendState = MoonlightTransportSendState::ConfirmedResponse;
            }
            switch (framing.state) {
                case MoonlightHttpFramingState::NeedMore:
                    if (endOfStream) {
                        outcome.error = MoonlightTransportError::ProtocolFailure;
                        return outcome;
                    }
                    break;
                case MoonlightHttpFramingState::Complete:
                    outcome.body = std::move(framing.body);
                    outcome.receivedBodyBytes = outcome.body.size();
                    outcome.stage = MoonlightTransportStage::Complete;
                    return outcome;
                case MoonlightHttpFramingState::ProtocolError:
                    outcome.error = MoonlightTransportError::ProtocolFailure;
                    return outcome;
                case MoonlightHttpFramingState::BodyTooLarge:
                    outcome.error = MoonlightTransportError::BodyTooLarge;
                    return outcome;
            }
        }
        outcome.error = MoonlightTransportError::Timeout;
        return outcome;
    }

private:
    std::shared_ptr<BindingRegistry> bindings_;
};

class ProductTrustPort final : public MoonlightPairingTrustPort {
public:
    bool available() const noexcept override { return true; }

    bool begin(const MoonlightPairingOperationKey& key,
               const std::string& owner,
               const std::string& host) noexcept {
        if (!key.valid() || owner.empty() || host.empty()) {
            return false;
        }
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            operations_[key] = HostKey{owner, host};
            return true;
        } catch (...) {
            return false;
        }
    }

    MoonlightTrustReview review(
        const MoonlightPairingOperationKey& key,
        const MoonlightTrustCandidate& candidate,
        std::chrono::steady_clock::time_point deadline,
        const CancellationProbe& probe) override {
        MoonlightTrustReview result;
        if (cancelled(probe)) {
            result.decision = MoonlightTrustDecision::Cancelled;
            return result;
        }
        if (deadlineExpired(deadline)) {
            result.decision = MoonlightTrustDecision::Timeout;
            return result;
        }
        std::lock_guard<std::mutex> lock(mutex_);
        const auto operation = operations_.find(key);
        if (operation == operations_.end() ||
            operation->second.host != candidate.hostLabel) {
            result.decision = MoonlightTrustDecision::Stale;
            return result;
        }
        const auto iterator = fingerprints_.find(operation->second);
        if (iterator == fingerprints_.end()) {
            fingerprints_[operation->second] = candidate.certificateSha256;
            result.decision = MoonlightTrustDecision::Accept;
            result.change = MoonlightTrustChange::FirstUse;
        } else if (iterator->second == candidate.certificateSha256) {
            result.decision = MoonlightTrustDecision::Accept;
            result.change = MoonlightTrustChange::Matched;
        } else {
            result.decision = MoonlightTrustDecision::Reject;
            result.change = MoonlightTrustChange::Changed;
        }
        return result;
    }

    void cancel(const MoonlightPairingOperationKey& key) noexcept override {
        end(key);
    }

    void end(const MoonlightPairingOperationKey& key) noexcept {
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            operations_.erase(key);
        } catch (...) {
        }
    }

    void restore(const std::string& owner,
                 const std::string& host,
                 const std::string& fingerprint) noexcept {
        if (owner.empty() || host.empty() || fingerprint.size() != 64U) {
            return;
        }
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            fingerprints_[HostKey{owner, host}] = fingerprint;
        } catch (...) {
        }
    }

private:
    mutable std::mutex mutex_;
    std::unordered_map<HostKey, std::string, HostKeyHash> fingerprints_;
    std::unordered_map<MoonlightPairingOperationKey, HostKey, PairingKeyHash>
        operations_;
};

class ProductCommitPort final : public MoonlightPairingCommitPort {
public:
    explicit ProductCommitPort(std::shared_ptr<BindingRegistry> bindings)
        : bindings_(std::move(bindings)) {}

    bool available() const noexcept override { return true; }

    bool repairRequired(const std::string& owner,
                        const std::string& host) const noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        return repairs_.find(HostKey{owner, host}) != repairs_.end();
    }

    MoonlightPairingPortCode commit(const MoonlightPairingCommitRecord& record) override {
        const HostKey hostKey{record.ownerScopeFingerprint, record.hostId};
        if (bindings_ == nullptr || !bindings_->promoteLast(
                toHostKey(record.key), hostKey.owner, hostKey.host)) {
            return MoonlightPairingPortCode::Unavailable;
        }
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            paired_[hostKey] = record;
            repairs_.erase(hostKey);
            return MoonlightPairingPortCode::Ok;
        } catch (...) {
            bindings_->forgetHost(hostKey.owner, hostKey.host);
            throw;
        }
    }

    MoonlightPairingPortCode rollback(const MoonlightPairingCommitRecord& record) noexcept override {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            paired_.erase(HostKey{record.ownerScopeFingerprint, record.hostId});
        }
        if (bindings_ != nullptr) {
            bindings_->forgetHost(record.ownerScopeFingerprint, record.hostId);
        }
        return MoonlightPairingPortCode::Ok;
    }

    void recordRepairRequired(const MoonlightPairingCommitRecord& record) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        repairs_[HostKey{record.ownerScopeFingerprint, record.hostId}] = record;
    }

    void cancel(const MoonlightPairingOperationKey& /*key*/) noexcept override {}

    bool paired(const std::string& owner, const std::string& host) const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        const HostKey key{owner, host};
        return paired_.find(key) != paired_.end() || restored_.find(key) != restored_.end();
    }

    void restorePaired(const std::string& owner, const std::string& host) noexcept {
        if (owner.empty() || host.empty()) { return; }
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            restored_.insert(HostKey{owner, host});
        } catch (...) {
        }
    }

private:
    static MoonlightHostRequestKey toHostKey(
        const MoonlightPairingOperationKey& key) noexcept {
        return {key.requestId, key.generation, key.ownerToken};
    }

    std::shared_ptr<BindingRegistry> bindings_;
    mutable std::mutex mutex_;
    std::unordered_map<HostKey, MoonlightPairingCommitRecord, HostKeyHash> paired_;
    std::unordered_map<HostKey, MoonlightPairingCommitRecord, HostKeyHash> repairs_;
    std::unordered_set<HostKey, HostKeyHash> restored_;
};

class ProductTlsBindingPort final : public MoonlightPairingTlsBindingPort {
public:
    explicit ProductTlsBindingPort(std::shared_ptr<BindingRegistry> bindings)
        : bindings_(std::move(bindings)) {}

    bool available() const noexcept override { return true; }

    MoonlightPairingPortCode bind(
        const MoonlightPairingOperationKey& key,
        const MoonlightHostEndpoint& endpoint,
        const std::vector<std::uint8_t>& certificate,
        const std::string& fingerprint,
        std::chrono::steady_clock::time_point deadline,
        const CancellationProbe& probe,
        MoonlightIdentityLease& identity) override {
        if (cancelled(probe)) { return MoonlightPairingPortCode::Cancelled; }
        if (deadlineExpired(deadline) || endpoint.addresses.empty() || certificate.empty() ||
            fingerprint.size() != 64U || !identity.valid()) {
            return MoonlightPairingPortCode::Unavailable;
        }
        Binding active;
        active.serverCertificateDer = certificate;
        active.certificateSha256 = fingerprint;
        active.borrowedIdentity = &identity;
        bindings_->setActive(toHostKey(key), std::move(active));
        bindings_->rememberLast(toHostKey(key), certificate, fingerprint);
        return MoonlightPairingPortCode::Ok;
    }

    void cancel(const MoonlightPairingOperationKey& key) noexcept override {
        bindings_->clearTransient(toHostKey(key));
    }

    void unbind(const MoonlightPairingOperationKey& key) noexcept override {
        bindings_->clearTransient(toHostKey(key));
    }

private:
    static MoonlightHostRequestKey toHostKey(const MoonlightPairingOperationKey& key) noexcept {
        return {key.requestId, key.generation, key.ownerToken};
    }
    std::shared_ptr<BindingRegistry> bindings_;
};

class ProductAccessPort final : public MoonlightHostControlAccessPort {
public:
    ProductAccessPort(std::shared_ptr<BindingRegistry> bindings,
                      std::shared_ptr<ProductCommitPort> commit,
                      std::shared_ptr<MoonlightSecureIdentity> identity,
                      std::shared_ptr<std::unordered_map<std::string, std::string>> installations,
                      std::shared_ptr<std::mutex> installationMutex)
        : bindings_(std::move(bindings)), commit_(std::move(commit)),
          identity_(std::move(identity)), installations_(std::move(installations)),
          installationMutex_(std::move(installationMutex)) {}

    bool available() const noexcept override { return true; }

    MoonlightHostControlAccessCode authorize(
        const MoonlightHostControlContext& context,
        std::chrono::steady_clock::time_point deadline,
        const CancellationProbe& probe) override {
        if (cancelled(probe)) { return MoonlightHostControlAccessCode::Cancelled; }
        if (deadlineExpired(deadline) || !context.key.valid() ||
            context.ownerScopeFingerprint.empty() || context.hostId.empty() ||
            !context.endpoint.pinnedTrustAvailable || !commit_->paired(
                context.ownerScopeFingerprint, context.hostId)) {
            return MoonlightHostControlAccessCode::Unavailable;
        }
        const auto hostBinding = bindings_->host(context.ownerScopeFingerprint, context.hostId);
        if (!hostBinding.has_value()) { return MoonlightHostControlAccessCode::Unavailable; }
        std::string installation;
        {
            std::lock_guard<std::mutex> lock(*installationMutex_);
            const auto iterator = installations_->find(context.ownerScopeFingerprint);
            if (iterator != installations_->end()) { installation = iterator->second; }
        }
        if (installation.empty() || identity_ == nullptr) {
            return MoonlightHostControlAccessCode::Unavailable;
        }
        MoonlightIdentityScope scope;
        scope.ownerScopeFingerprint = context.ownerScopeFingerprint;
        scope.installationId = installation;
        MoonlightIdentityOperationKey identityKey{
            context.key.requestId, context.key.generation, context.key.ownerToken};
        auto acquired = identity_->acquire(scope, identityKey);
        if (acquired.code != MoonlightIdentityCode::Ok || !acquired.lease.valid()) {
            return acquired.code == MoonlightIdentityCode::Cancelled ?
                MoonlightHostControlAccessCode::Cancelled :
                MoonlightHostControlAccessCode::Unavailable;
        }
        auto owned = std::make_shared<MoonlightIdentityLease>(std::move(acquired.lease));
        Binding active = *hostBinding;
        active.borrowedIdentity = nullptr;
        active.ownedIdentity = std::move(owned);
        bindings_->setActive(toHostKey(context.key), std::move(active));
        return MoonlightHostControlAccessCode::Ready;
    }

    void cancel(const MoonlightHostControlOperationKey& key) noexcept override {
        bindings_->clearActive(toHostKey(key));
    }

private:
    static MoonlightHostRequestKey toHostKey(
        const MoonlightHostControlOperationKey& key) noexcept {
        return {key.requestId, key.generation, key.ownerToken};
    }

    std::shared_ptr<BindingRegistry> bindings_;
    std::shared_ptr<ProductCommitPort> commit_;
    std::shared_ptr<MoonlightSecureIdentity> identity_;
    std::shared_ptr<std::unordered_map<std::string, std::string>> installations_;
    std::shared_ptr<std::mutex> installationMutex_;
};

MoonlightHostRequestKey hostKey(const MoonlightBridgeRequestKey& key) noexcept {
    return {key.requestId, key.generation, key.ownerToken};
}

MoonlightPairingOperationKey pairingKey(const MoonlightBridgeRequestKey& key) noexcept {
    return {key.requestId, key.generation, key.ownerToken};
}

MoonlightHostControlOperationKey controlKey(const MoonlightBridgeRequestKey& key) noexcept {
    return {key.requestId, key.generation, key.ownerToken};
}

MoonlightBridgeCode mapPairCode(MoonlightPairingCode code) noexcept {
    switch (code) {
    case MoonlightPairingCode::Ok: return MoonlightBridgeCode::Ok;
    case MoonlightPairingCode::InvalidArgument: return MoonlightBridgeCode::InvalidArgument;
    case MoonlightPairingCode::Busy:
    case MoonlightPairingCode::AlreadyInProgress: return MoonlightBridgeCode::Busy;
    case MoonlightPairingCode::Unavailable:
    case MoonlightPairingCode::IdentityFailure: return MoonlightBridgeCode::Unavailable;
    case MoonlightPairingCode::LegacySha1Disabled: return MoonlightBridgeCode::ActionRejected;
    case MoonlightPairingCode::MutationOutcomeUnknown: return MoonlightBridgeCode::OutcomeUnknown;
    case MoonlightPairingCode::Cancelled: return MoonlightBridgeCode::Cancelled;
    case MoonlightPairingCode::Stale: return MoonlightBridgeCode::Stale;
    case MoonlightPairingCode::DeadlineExceeded: return MoonlightBridgeCode::DeadlineExceeded;
    case MoonlightPairingCode::TransportFailure: return MoonlightBridgeCode::TransportFailure;
    case MoonlightPairingCode::RepairRequired:
    case MoonlightPairingCode::CommitFailed: return MoonlightBridgeCode::RepairRequired;
    case MoonlightPairingCode::PinWrong:
    case MoonlightPairingCode::CertificateInvalid:
    case MoonlightPairingCode::TrustRejected:
    case MoonlightPairingCode::TrustTimeout:
    case MoonlightPairingCode::ServerAuthenticationFailed:
    case MoonlightPairingCode::ProtocolFailure:
    case MoonlightPairingCode::CryptoFailure: return MoonlightBridgeCode::ProtocolFailure;
    case MoonlightPairingCode::ShuttingDown: return MoonlightBridgeCode::ShuttingDown;
    }
    return MoonlightBridgeCode::ProtocolFailure;
}

MoonlightBridgeCode mapControlCode(MoonlightHostControlCode code) noexcept {
    switch (code) {
    case MoonlightHostControlCode::Ok: return MoonlightBridgeCode::Ok;
    case MoonlightHostControlCode::InvalidArgument: return MoonlightBridgeCode::InvalidArgument;
    case MoonlightHostControlCode::Busy: return MoonlightBridgeCode::Busy;
    case MoonlightHostControlCode::Unavailable: return MoonlightBridgeCode::Unavailable;
    case MoonlightHostControlCode::Unpaired: return MoonlightBridgeCode::Unpaired;
    case MoonlightHostControlCode::AppNotFound: return MoonlightBridgeCode::AppNotFound;
    case MoonlightHostControlCode::InvalidCatalog: return MoonlightBridgeCode::InvalidCatalog;
    case MoonlightHostControlCode::ResumeRequired: return MoonlightBridgeCode::ResumeRequired;
    case MoonlightHostControlCode::HostBusy: return MoonlightBridgeCode::HostBusy;
    case MoonlightHostControlCode::ConfirmationRequired:
        return MoonlightBridgeCode::ConfirmationRequired;
    case MoonlightHostControlCode::ActionRejected: return MoonlightBridgeCode::ActionRejected;
    case MoonlightHostControlCode::OutcomeUnknown: return MoonlightBridgeCode::OutcomeUnknown;
    case MoonlightHostControlCode::Cancelled: return MoonlightBridgeCode::Cancelled;
    case MoonlightHostControlCode::Stale: return MoonlightBridgeCode::Stale;
    case MoonlightHostControlCode::DeadlineExceeded: return MoonlightBridgeCode::DeadlineExceeded;
    case MoonlightHostControlCode::TransportFailure: return MoonlightBridgeCode::TransportFailure;
    case MoonlightHostControlCode::ProtocolFailure: return MoonlightBridgeCode::ProtocolFailure;
    case MoonlightHostControlCode::ShuttingDown: return MoonlightBridgeCode::ShuttingDown;
    }
    return MoonlightBridgeCode::ProtocolFailure;
}

MoonlightBridgeTruth mapTruth(MoonlightHostControlTruth value) noexcept {
    switch (value) {
    case MoonlightHostControlTruth::NotAttempted: return MoonlightBridgeTruth::NotAttempted;
    case MoonlightHostControlTruth::Confirmed: return MoonlightBridgeTruth::Confirmed;
    case MoonlightHostControlTruth::Failed: return MoonlightBridgeTruth::Failed;
    case MoonlightHostControlTruth::Unknown: return MoonlightBridgeTruth::Unknown;
    }
    return MoonlightBridgeTruth::Unknown;
}

void appendControlResult(MoonlightBridgeResult& target,
                         MoonlightHostControlResult source) {
    target.code = mapControlCode(source.code);
    target.terminalStage = source.code == MoonlightHostControlCode::Cancelled ?
        MoonlightBridgeTerminalStage::Cancelled : source.ok() ?
        MoonlightBridgeTerminalStage::Complete : MoonlightBridgeTerminalStage::Failed;
    target.preflightTruth = mapTruth(source.preflightTruth);
    target.actionTruth = mapTruth(source.actionTruth);
    target.postconditionTruth = mapTruth(source.postconditionTruth);
    target.partialAppCount = source.partialAppCount;
    target.observedAtMs = source.observedAtMs;
    target.idempotent = source.idempotent;
    target.mutationMayHaveBeenSent = source.mutationMayHaveBeenSent;
    target.asset = std::move(source.asset);
    target.rtspSessionUrl = std::move(source.rtspSessionUrl);
    target.apps.reserve(source.apps.size());
    for (auto& app : source.apps) {
        target.apps.push_back({app.id, std::move(app.title), app.hdrSupported});
    }
    if (!source.diagnostics.empty()) {
        const auto& diagnostic = source.diagnostics.back();
        target.diagnostics.push_back({
            "host_control", "host_control_result", diagnostic.httpStatus,
            diagnostic.xmlStatus, diagnostic.transportAttempts, diagnostic.byteCount,
            diagnostic.appIdFingerprint});
    }
}

struct ProductRuntimeComponents final {
    ProductRuntimeComponents()
        : bindings(std::make_shared<BindingRegistry>()),
          installations(
              std::make_shared<std::unordered_map<std::string, std::string>>()),
          installationMutex(std::make_shared<std::mutex>()),
          identity(std::shared_ptr<MoonlightSecureIdentity>(
              new MoonlightSecureIdentity(
                  createMoonlightPlatformIdentityBackend()))),
          transport(std::make_shared<ProductHttpTransport>(bindings)),
          trust(std::make_shared<ProductTrustPort>()),
          commit(std::make_shared<ProductCommitPort>(bindings)),
          tlsBinding(std::make_shared<ProductTlsBindingPort>(bindings)),
          access(std::make_shared<ProductAccessPort>(
              bindings, commit, identity, installations, installationMutex)),
          hostApi(std::make_shared<MoonlightHostApi>(transport, []() {
              return std::to_string(monotonicMilliseconds());
          })),
          pairing(std::make_shared<MoonlightPairingManager>(
              hostApi, identity, trust, tlsBinding, commit,
              [](std::uint8_t* data, std::size_t size) {
                  return data != nullptr && size > 0U && RAND_bytes(
                      data, static_cast<int>(size)) == 1;
              })),
          control(std::make_shared<MoonlightHostControl>(hostApi, access)) {}

    std::shared_ptr<BindingRegistry> bindings;
    std::shared_ptr<std::unordered_map<std::string, std::string>> installations;
    std::shared_ptr<std::mutex> installationMutex;
    std::shared_ptr<MoonlightSecureIdentity> identity;
    std::shared_ptr<ProductHttpTransport> transport;
    std::shared_ptr<ProductTrustPort> trust;
    std::shared_ptr<ProductCommitPort> commit;
    std::shared_ptr<ProductTlsBindingPort> tlsBinding;
    std::shared_ptr<ProductAccessPort> access;
    std::shared_ptr<MoonlightHostApi> hostApi;
    std::shared_ptr<MoonlightPairingManager> pairing;
    std::shared_ptr<MoonlightHostControl> control;
};

class ProductRuntime final : public MoonlightNativeRuntimePort {
public:
    ProductRuntime() = default;

    MoonlightBridgeCapabilities capabilities() const noexcept override {
        return capabilitiesFor(ensureComponents());
    }

    MoonlightBridgeResult execute(MoonlightBridgeRequest request,
                                  const CancellationProbe& cancellationProbe) override {
        MoonlightBridgeResult result;
        result.operation = request.operation;
        result.key = request.key;
        result.observedAtMs = monotonicMilliseconds();
        if (cancelled(cancellationProbe)) {
            result.code = MoonlightBridgeCode::Cancelled;
            result.terminalStage = MoonlightBridgeTerminalStage::Cancelled;
            return result;
        }

        // ProductRuntime construction is intentionally side-effect free. The
        // first Moonlight capability/request call reaches this seam and only
        // then creates the secure identity backend, whose constructor performs
        // the Asset Store runtime contract probe.
        const auto components = ensureComponents();
        const auto capability = capabilitiesFor(components);
        if (components == nullptr ||
            (request.operation == MoonlightBridgeOperation::Pair &&
             !capability.pairingReady) ||
            (request.operation != MoonlightBridgeOperation::Pair &&
             !capability.hostControlReady)) {
            result.code = MoonlightBridgeCode::RuntimeProofRequired;
            result.terminalStage = MoonlightBridgeTerminalStage::Failed;
            result.diagnostics.push_back(
                {"preflight", capability.blocker, 0, 0, 0, 0, 0});
            return result;
        }
        restoreLocalRuntimeState(request, *components);
        if (cancelled(cancellationProbe)) {
            result.code = MoonlightBridgeCode::Cancelled;
            result.terminalStage = MoonlightBridgeTerminalStage::Cancelled;
            return result;
        }
        if (request.operation == MoonlightBridgeOperation::Pair) {
            return executePair(
                std::move(request), cancellationProbe, *components);
        }
        return executeControl(
            std::move(request), cancellationProbe, *components);
    }

    void cancel(const MoonlightBridgeRequestKey& key) noexcept override {
        const auto components = currentComponents();
        if (components == nullptr) {
            return;
        }
        if (components->hostApi != nullptr) {
            (void)components->hostApi->cancel(hostKey(key));
        }
        if (components->pairing != nullptr) {
            (void)components->pairing->cancel(pairingKey(key));
        }
        if (components->control != nullptr) {
            (void)components->control->cancel(controlKey(key));
        }
        components->bindings->clearTransient(hostKey(key));
    }

private:
    std::shared_ptr<ProductRuntimeComponents> ensureComponents() const noexcept {
        try {
            std::lock_guard<std::mutex> lock(initializationMutex_);
            if (components_ == nullptr) {
                components_ = std::make_shared<ProductRuntimeComponents>();
            }
            return components_;
        } catch (...) {
            return nullptr;
        }
    }

    std::shared_ptr<ProductRuntimeComponents> currentComponents() const noexcept {
        try {
            std::lock_guard<std::mutex> lock(initializationMutex_);
            return components_;
        } catch (...) {
            return nullptr;
        }
    }

    static MoonlightBridgeCapabilities capabilitiesFor(
        const std::shared_ptr<ProductRuntimeComponents>& components) noexcept {
        MoonlightBridgeCapabilities result;
        result.bridgeCompiled = true;
        if (components == nullptr) {
            result.blocker = "identity_runtime_proof_required";
            return result;
        }
        try {
            result.transportReady = components->transport != nullptr;
            result.trustReady = components->trust != nullptr &&
                components->trust->available();
            result.commitReady = components->commit != nullptr &&
                components->commit->available();
            if (components->identity != nullptr) {
                const auto capability = components->identity->capability();
                result.identityReady = capability.status ==
                    MoonlightIdentityCapabilityStatus::RuntimeReady &&
                    capability.encryptedBlobAtomic &&
                    (capability.directRsaTlsSignerReady ||
                     capability.wrappedPkcs8Ready);
            }
            result.pairingReady = result.identityReady && result.transportReady &&
                result.trustReady && result.commitReady &&
                components->pairing != nullptr;
            result.hostControlReady = result.pairingReady &&
                components->access != nullptr && components->access->available() &&
                components->control != nullptr;
            if (result.hostControlReady) {
                result.blocker = "";
            } else if (!result.identityReady) {
                result.blocker = "identity_runtime_proof_required";
            } else if (!result.transportReady) {
                result.blocker = "transport_unavailable";
            } else {
                result.blocker = "host_control_unavailable";
            }
        } catch (...) {
            result.identityReady = false;
            result.pairingReady = false;
            result.hostControlReady = false;
            result.blocker = "identity_runtime_proof_required";
        }
        return result;
    }

    static void restoreLocalRuntimeState(
        const MoonlightBridgeRequest& request,
        ProductRuntimeComponents& components) noexcept {
        try {
            if (!request.installationId.empty()) {
                std::lock_guard<std::mutex> lock(*components.installationMutex);
                (*components.installations)[request.ownerScopeFingerprint] =
                    request.installationId;
            }
            if (request.pinnedCertificateSha256.size() != 64U) {
                return;
            }
            components.trust->restore(
                request.ownerScopeFingerprint, request.hostId,
                request.pinnedCertificateSha256);
            components.commit->restorePaired(
                request.ownerScopeFingerprint, request.hostId);
            (void)components.bindings->restoreHost(
                request.ownerScopeFingerprint, request.hostId,
                request.pinnedCertificateSha256);
        } catch (...) {
            // Rehydration is an optimization around durable local state. The
            // operation remains fail-closed in authorize() if any projection
            // could not be restored exactly.
        }
    }

    static MoonlightBridgeResult executePair(
        MoonlightBridgeRequest request,
        const CancellationProbe& cancellationProbe,
        ProductRuntimeComponents& components) {
        MoonlightBridgeResult result;
        result.operation = request.operation;
        result.key = request.key;
        result.observedAtMs = monotonicMilliseconds();
        {
            std::lock_guard<std::mutex> lock(*components.installationMutex);
            (*components.installations)[request.ownerScopeFingerprint] =
                request.installationId;
        }
        const MoonlightPairingOperationKey exactPairingKey =
            pairingKey(request.key);
        MoonlightPairingResult source;
        if (!components.trust->begin(
                exactPairingKey, request.ownerScopeFingerprint,
                request.hostId)) {
            source.code = MoonlightPairingCode::Unavailable;
        } else if (cancelled(cancellationProbe)) {
            source.code = MoonlightPairingCode::Cancelled;
        } else {
            MoonlightPairingRequest pairingRequest;
            pairingRequest.key = exactPairingKey;
            pairingRequest.identityScope.ownerScopeFingerprint =
                request.ownerScopeFingerprint;
            pairingRequest.identityScope.installationId = request.installationId;
            pairingRequest.endpoint = request.endpoint;
            pairingRequest.hostId = request.hostId;
            pairingRequest.serverUuid = request.serverUuid;
            pairingRequest.hostLabel = request.hostId;
            pairingRequest.serverMajorVersion = 7;
            pairingRequest.timeout = request.timeout;
            pairingRequest.allowLegacySha1 = request.allowLegacySha1;
            pairingRequest.pin = MoonlightSecureBuffer(std::move(request.pin));
            try {
                source = components.pairing->execute(std::move(pairingRequest));
            } catch (...) {
                source.code = MoonlightPairingCode::ProtocolFailure;
            }
        }
        components.trust->end(exactPairingKey);
        if (!source.ok()) {
            components.bindings->clearTransient(hostKey(request.key));
        }
        result.code = mapPairCode(source.code);
        result.terminalStage = source.code == MoonlightPairingCode::Cancelled ?
            MoonlightBridgeTerminalStage::Cancelled : source.ok() ?
            MoonlightBridgeTerminalStage::Complete :
            MoonlightBridgeTerminalStage::Failed;
        result.preflightTruth = source.ok() ? MoonlightBridgeTruth::Confirmed :
            MoonlightBridgeTruth::Failed;
        result.actionTruth = source.ok() ? MoonlightBridgeTruth::Confirmed :
            source.remoteCleanup == MoonlightRemoteCleanup::OutcomeUnknown ?
            MoonlightBridgeTruth::Unknown : MoonlightBridgeTruth::Failed;
        result.postconditionTruth = source.ok() ? MoonlightBridgeTruth::Confirmed :
            MoonlightBridgeTruth::Unknown;
        result.mutationMayHaveBeenSent =
            source.remoteCleanup != MoonlightRemoteCleanup::NotNeeded;
        result.certificateSha256 = std::move(source.certificateSha256);
        result.diagnostics.push_back(
            {"pairing", source.ok() ? "ok" : "pairing_failed",
             source.lastHttpStatus, source.lastXmlStatus,
             source.transportAttempts, 0, 0});
        return result;
    }

    static MoonlightBridgeResult executeControl(
        MoonlightBridgeRequest request,
        const CancellationProbe& cancellationProbe,
        ProductRuntimeComponents& components) {
        MoonlightBridgeResult result;
        result.operation = request.operation;
        result.key = request.key;
        result.observedAtMs = monotonicMilliseconds();
        if (cancelled(cancellationProbe)) {
            result.code = MoonlightBridgeCode::Cancelled;
            result.terminalStage = MoonlightBridgeTerminalStage::Cancelled;
            return result;
        }
        MoonlightHostControlContext context;
        context.key = controlKey(request.key);
        context.ownerScopeFingerprint = request.ownerScopeFingerprint;
        context.hostId = request.hostId;
        context.serverUuid = request.serverUuid;
        context.endpoint = request.endpoint;
        context.timeout = request.timeout;
        MoonlightHostControlResult source;
        std::array<std::uint8_t, 16U> nativeRiKey {};
        std::int32_t nativeRiKeyId = 0;
        bool launchMaterialReady = false;
        MoonlightBridgeLaunchConfiguration effectiveLaunchConfiguration =
            request.launchConfiguration;
        if (request.operation == MoonlightBridgeOperation::Launch ||
            request.operation == MoonlightBridgeOperation::Resume) {
            // The product mapper owns one stable slot and supports physical /
            // virtual hot handoff. Match Moonlight's non-multi-controller mode:
            // reserve slot 0 at launch and keep it persistent across handoff.
            effectiveLaunchConfiguration.remoteControllersBitmap =
                kMoonlightProductControllerBitmap;
            effectiveLaunchConfiguration.gamepadMask =
                kMoonlightProductControllerBitmap;
            effectiveLaunchConfiguration.persistGamepads =
                kMoonlightProductPersistGamepad;
        }
        try {
            switch (request.operation) {
            case MoonlightBridgeOperation::Catalog: {
                MoonlightCatalogRequest call;
                call.context = std::move(context);
                source = components.control->catalog(std::move(call));
                break;
            }
            case MoonlightBridgeOperation::Asset: {
                MoonlightAssetRequest call;
                call.context = std::move(context);
                call.appId = request.appId;
                call.catalogGeneration = request.catalogGeneration;
                source = components.control->asset(std::move(call));
                break;
            }
            case MoonlightBridgeOperation::Launch:
            case MoonlightBridgeOperation::Resume: {
                std::array<std::uint8_t, sizeof(nativeRiKeyId)> idBytes {};
                launchMaterialReady = RAND_bytes(
                    nativeRiKey.data(), static_cast<int>(nativeRiKey.size())) == 1 &&
                    RAND_bytes(idBytes.data(), static_cast<int>(idBytes.size())) == 1;
                if (!launchMaterialReady) {
                    source.code = MoonlightHostControlCode::Unavailable;
                    break;
                }
                std::memcpy(&nativeRiKeyId, idBytes.data(), idBytes.size());
                OPENSSL_cleanse(idBytes.data(), idBytes.size());
                MoonlightLaunchConfiguration configuration;
                configuration.width = effectiveLaunchConfiguration.width;
                configuration.height = effectiveLaunchConfiguration.height;
                configuration.refreshRate = effectiveLaunchConfiguration.refreshRate;
                configuration.additionalStates =
                    effectiveLaunchConfiguration.additionalStates;
                configuration.sops = effectiveLaunchConfiguration.sops;
                configuration.hdr = effectiveLaunchConfiguration.hdr;
                configuration.playAudioOnHost =
                    effectiveLaunchConfiguration.playAudioOnHost;
                configuration.surroundAudioInfo =
                    effectiveLaunchConfiguration.surroundAudioInfo;
                configuration.remoteControllersBitmap =
                    effectiveLaunchConfiguration.remoteControllersBitmap;
                configuration.gamepadMask = effectiveLaunchConfiguration.gamepadMask;
                configuration.persistGamepads =
                    effectiveLaunchConfiguration.persistGamepads;
                MoonlightLaunchRequest call;
                call.context = std::move(context);
                call.appId = request.appId;
                std::vector<std::uint8_t> material(
                    nativeRiKey.begin(), nativeRiKey.end());
                call.material = MoonlightLaunchMaterial(
                    std::move(material), nativeRiKeyId, configuration);
                source = request.operation == MoonlightBridgeOperation::Launch ?
                    components.control->launch(std::move(call)) :
                    components.control->resume(std::move(call));
                break;
            }
            case MoonlightBridgeOperation::Quit: {
                MoonlightQuitRequest call;
                call.context = std::move(context);
                call.expectedCurrentAppId = request.expectedCurrentAppId;
                call.userConfirmedTermination =
                    request.userConfirmedTermination;
                source = components.control->quit(std::move(call));
                break;
            }
            case MoonlightBridgeOperation::Pair:
                break;
            }
        } catch (...) {
            source.code = MoonlightHostControlCode::ProtocolFailure;
        }
        if (launchMaterialReady && source.ok() &&
            source.rtspSessionUrl.has_value() &&
            source.sessionServerInfo.has_value() &&
            source.sessionAddress.has_value() &&
            !source.sessionAddress->empty()) {
            MoonlightProductLaunchStage stage;
            stage.key = request.key;
            stage.hostId = request.hostId;
            stage.serverUuid = request.serverUuid;
            stage.address = *source.sessionAddress;
            stage.appId = request.appId;
            stage.configuration = effectiveLaunchConfiguration;
            stage.serverInfo = std::move(*source.sessionServerInfo);
            stage.remoteInputKey = nativeRiKey;
            stage.remoteInputKeyId = nativeRiKeyId;
            stage.rtspSessionUrl = *source.rtspSessionUrl;
            stage.expiresAtMonotonicMs = monotonicMilliseconds() + 30000U;
            if (!MoonlightProductStreamingRuntime::process().stageLaunch(
                    std::move(stage))) {
                source.code = MoonlightHostControlCode::OutcomeUnknown;
                source.postconditionTruth = MoonlightHostControlTruth::Unknown;
                source.mutationMayHaveBeenSent = true;
                source.rtspSessionUrl.reset();
            }
        }
        OPENSSL_cleanse(nativeRiKey.data(), nativeRiKey.size());
        nativeRiKeyId = 0;
        appendControlResult(result, std::move(source));
        components.bindings->clearActive(hostKey(request.key));
        return result;
    }

    mutable std::mutex initializationMutex_;
    mutable std::shared_ptr<ProductRuntimeComponents> components_;
};

} // namespace

std::shared_ptr<MoonlightNativeRuntimePort>
createMoonlightProductRuntimePort() noexcept {
    try {
        return std::make_shared<ProductRuntime>();
    } catch (...) {
        return std::make_shared<MoonlightUnavailableRuntimePort>();
    }
}

} // namespace remotedesk::moonlight
