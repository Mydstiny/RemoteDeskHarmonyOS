#include "happy_eyeballs_connector.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <condition_variable>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <mutex>
#include <poll.h>
#include <thread>
#include <unistd.h>

namespace remotedesk::net {
namespace {

constexpr int kMaxConcurrentResolvers = 8;
constexpr std::chrono::milliseconds kCancellationSlice{50};

struct ResolveState final {
    std::mutex mutex;
    std::condition_variable condition;
    bool done = false;
    bool abandoned = false;
    int gaiError = EAI_FAIL;
    std::vector<ResolvedAddress> addresses;
};

struct ActiveSocket final {
    int descriptor = -1;
    int originalFlags = 0;
    ResolvedAddress address;
};

std::atomic<int> gActiveResolvers{0};

class ResolverPermit final {
public:
    ResolverPermit() = default;

    bool acquire() noexcept {
        const int previous = gActiveResolvers.fetch_add(1, std::memory_order_acq_rel);
        if (previous >= kMaxConcurrentResolvers) {
            gActiveResolvers.fetch_sub(1, std::memory_order_acq_rel);
            return false;
        }
        acquired_ = true;
        return true;
    }

    ~ResolverPermit() {
        if (acquired_) {
            gActiveResolvers.fetch_sub(1, std::memory_order_acq_rel);
        }
    }

    ResolverPermit(const ResolverPermit&) = delete;
    ResolverPermit& operator=(const ResolverPermit&) = delete;

private:
    bool acquired_ = false;
};

class ScopedDescriptor final {
public:
    explicit ScopedDescriptor(int descriptor) noexcept : descriptor_(descriptor) {}
    ~ScopedDescriptor() {
        if (descriptor_ >= 0) { ::close(descriptor_); }
    }

    int release() noexcept {
        const int descriptor = descriptor_;
        descriptor_ = -1;
        return descriptor;
    }

    ScopedDescriptor(const ScopedDescriptor&) = delete;
    ScopedDescriptor& operator=(const ScopedDescriptor&) = delete;

private:
    int descriptor_ = -1;
};

bool cancellationRequested(const std::function<bool()>& probe) noexcept {
    try {
        return probe && probe();
    } catch (...) {
        return true;
    }
}

std::string stripBrackets(const std::string& host) {
    if (host.size() >= 2U && host.front() == '[' && host.back() == ']') {
        return host.substr(1U, host.size() - 2U);
    }
    return host;
}

bool sameAddress(const ResolvedAddress& left, const ResolvedAddress& right) noexcept {
    if (left.family != right.family || left.length != right.length) {
        return false;
    }
    if (left.family == AF_INET && left.length >= sizeof(sockaddr_in)) {
        const auto* a = reinterpret_cast<const sockaddr_in*>(&left.storage);
        const auto* b = reinterpret_cast<const sockaddr_in*>(&right.storage);
        return a->sin_port == b->sin_port &&
            std::memcmp(&a->sin_addr, &b->sin_addr, sizeof(in_addr)) == 0;
    }
    if (left.family == AF_INET6 && left.length >= sizeof(sockaddr_in6)) {
        const auto* a = reinterpret_cast<const sockaddr_in6*>(&left.storage);
        const auto* b = reinterpret_cast<const sockaddr_in6*>(&right.storage);
        return a->sin6_port == b->sin6_port &&
            a->sin6_scope_id == b->sin6_scope_id &&
            std::memcmp(&a->sin6_addr, &b->sin6_addr, sizeof(in6_addr)) == 0;
    }
    return std::memcmp(&left.storage, &right.storage,
                       static_cast<std::size_t>(left.length)) == 0;
}

void copyResolved(addrinfo* source, std::size_t limit,
                  std::vector<ResolvedAddress>& destination) {
    std::size_t ipv4Count = 0U;
    std::size_t ipv6Count = 0U;
    for (addrinfo* item = source; item != nullptr; item = item->ai_next) {
        if (item->ai_addr == nullptr || item->ai_addrlen <= 0 ||
            static_cast<std::size_t>(item->ai_addrlen) > sizeof(sockaddr_storage) ||
            (item->ai_family != AF_INET && item->ai_family != AF_INET6)) {
            continue;
        }
        ResolvedAddress address;
        std::memcpy(&address.storage, item->ai_addr,
                    static_cast<std::size_t>(item->ai_addrlen));
        address.length = static_cast<socklen_t>(item->ai_addrlen);
        address.family = item->ai_family;
        address.socktype = item->ai_socktype == 0 ? SOCK_STREAM : item->ai_socktype;
        address.protocol = item->ai_protocol == 0 ? IPPROTO_TCP : item->ai_protocol;
        const bool duplicate = std::any_of(
            destination.begin(), destination.end(), [&](const ResolvedAddress& existing) {
                return sameAddress(existing, address);
            });
        if (duplicate) { continue; }
        std::size_t& familyCount = address.family == AF_INET ? ipv4Count : ipv6Count;
        if (familyCount >= limit) { continue; }
        destination.push_back(address);
        ++familyCount;
    }
}

void closeActive(std::vector<ActiveSocket>& active, int except = -1) noexcept {
    for (const ActiveSocket& socket : active) {
        if (socket.descriptor >= 0 && socket.descriptor != except) {
            ::close(socket.descriptor);
        }
    }
    active.clear();
}

class ActiveSocketsGuard final {
public:
    explicit ActiveSocketsGuard(std::vector<ActiveSocket>& active) noexcept
        : active_(active) {}
    ~ActiveSocketsGuard() { closeActive(active_); }

    ActiveSocketsGuard(const ActiveSocketsGuard&) = delete;
    ActiveSocketsGuard& operator=(const ActiveSocketsGuard&) = delete;

private:
    std::vector<ActiveSocket>& active_;
};

std::string numericHost(const ResolvedAddress& address) {
    char host[NI_MAXHOST] = {0};
    if (::getnameinfo(reinterpret_cast<const sockaddr*>(&address.storage),
                      address.length, host, sizeof(host), nullptr, 0,
                      NI_NUMERICHOST) == 0) {
        return host;
    }
    return {};
}

ConnectResult connectedResult(ActiveSocket winner,
                              std::vector<ActiveSocket>& active,
                              const ConnectOptions& options,
                              std::size_t attempted) {
    ConnectResult result;
    ScopedDescriptor winnerGuard(winner.descriptor);
    closeActive(active, winner.descriptor);
    if (cancellationRequested(options.cancelled)) {
        result.status = ConnectStatus::Cancelled;
        result.lastError = ECANCELED;
        result.attemptedCandidates = attempted;
        return result;
    }
    if (options.restoreBlocking &&
        ::fcntl(winner.descriptor, F_SETFL, winner.originalFlags) != 0) {
        result.lastError = errno;
        result.status = ConnectStatus::Failed;
        result.attemptedCandidates = attempted;
        return result;
    }
#if defined(RDP_TESTS_ONLY)
    if (options.afterRestoreForTest) {
        try {
            options.afterRestoreForTest();
        } catch (...) {
            result.status = ConnectStatus::Cancelled;
            result.lastError = ECANCELED;
            result.attemptedCandidates = attempted;
            return result;
        }
    }
#endif
    // Cancellation can race the fcntl restoration above. The descriptor is
    // still guarded here, so cancellation wins until the exact handoff.
    if (cancellationRequested(options.cancelled)) {
        result.status = ConnectStatus::Cancelled;
        result.lastError = ECANCELED;
        result.attemptedCandidates = attempted;
        return result;
    }
    result.status = ConnectStatus::Connected;
    result.family = winner.address.family;
    result.attemptedCandidates = attempted;
    result.numericAddress = numericHost(winner.address);
    result.descriptor = winnerGuard.release();
    return result;
}

} // namespace

std::vector<ResolvedAddress> InterleaveAddresses(
    const std::vector<ResolvedAddress>& addresses,
    std::size_t maxCandidates) {
    if (maxCandidates == 0U) { return {}; }
    int firstFamily = AF_UNSPEC;
    std::vector<ResolvedAddress> first;
    std::vector<ResolvedAddress> second;
    first.reserve(std::min(addresses.size(), maxCandidates));
    second.reserve(std::min(addresses.size(), maxCandidates));
    for (const ResolvedAddress& address : addresses) {
        if (address.length == 0 ||
            (address.family != AF_INET && address.family != AF_INET6)) {
            continue;
        }
        if (firstFamily == AF_UNSPEC) { firstFamily = address.family; }
        std::vector<ResolvedAddress>& family =
            address.family == firstFamily ? first : second;
        if (family.size() >= maxCandidates) { continue; }
        const bool duplicate = std::any_of(
            family.begin(), family.end(), [&](const ResolvedAddress& existing) {
                return sameAddress(existing, address);
            });
        if (!duplicate) { family.push_back(address); }
    }
    std::vector<ResolvedAddress> result;
    result.reserve(std::min(maxCandidates, first.size() + second.size()));
    for (std::size_t index = 0; result.size() < maxCandidates; ++index) {
        bool appended = false;
        if (index < first.size() && result.size() < maxCandidates) {
            result.push_back(first[index]);
            appended = true;
        }
        if (index < second.size() && result.size() < maxCandidates) {
            result.push_back(second[index]);
            appended = true;
        }
        if (!appended) { break; }
    }
    return result;
}

ResolveResult ResolveTcpAddresses(
    const std::string& rawHost,
    const std::string& service,
    std::chrono::steady_clock::time_point deadline,
    const std::function<bool()>& cancelled,
    int family,
    std::size_t maxCandidates) {
    ResolveResult output;
    if (rawHost.empty() || service.empty() || maxCandidates == 0U) {
        output.gaiError = EAI_NONAME;
        return output;
    }
    if (cancellationRequested(cancelled)) {
        output.status = ResolveStatus::Cancelled;
        output.gaiError = EAI_AGAIN;
        return output;
    }
    if (std::chrono::steady_clock::now() >= deadline) {
        output.status = ResolveStatus::TimedOut;
        output.gaiError = EAI_AGAIN;
        return output;
    }

    const std::string host = stripBrackets(rawHost);
    addrinfo numericHints{};
    numericHints.ai_family = family;
    numericHints.ai_socktype = SOCK_STREAM;
    numericHints.ai_protocol = IPPROTO_TCP;
    numericHints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV;
    addrinfo* numericRaw = nullptr;
    const int numericError = ::getaddrinfo(host.c_str(), service.c_str(),
                                           &numericHints, &numericRaw);
    std::unique_ptr<addrinfo, decltype(&::freeaddrinfo)> numeric(
        numericRaw, &::freeaddrinfo);
    if (numericError == 0 && numeric != nullptr) {
        try {
            copyResolved(numeric.get(), maxCandidates, output.addresses);
            output.addresses = InterleaveAddresses(output.addresses, maxCandidates);
        } catch (...) {
            output.addresses.clear();
            output.status = ResolveStatus::ResourceExhausted;
            output.gaiError = EAI_MEMORY;
            return output;
        }
        output.status = output.addresses.empty() ? ResolveStatus::Failed : ResolveStatus::Ready;
        output.gaiError = output.addresses.empty() ? EAI_NONAME : 0;
        return output;
    }

    std::shared_ptr<ResolveState> state;
    std::shared_ptr<ResolverPermit> resolverPermit;
    try {
        state = std::make_shared<ResolveState>();
        resolverPermit = std::make_shared<ResolverPermit>();
    } catch (...) {
        output.status = ResolveStatus::ResourceExhausted;
        output.gaiError = EAI_MEMORY;
        return output;
    }
    if (!resolverPermit->acquire()) {
        output.status = ResolveStatus::ResourceExhausted;
        output.gaiError = EAI_AGAIN;
        return output;
    }

    std::thread worker;
    try {
        worker = std::thread([state, resolverPermit, host, service, family, maxCandidates]() {
            (void)resolverPermit;
            addrinfo hints{};
            hints.ai_family = family;
            hints.ai_socktype = SOCK_STREAM;
            hints.ai_protocol = IPPROTO_TCP;
            addrinfo* raw = nullptr;
            int error = EAI_FAIL;
            std::vector<ResolvedAddress> copied;
            try {
                error = ::getaddrinfo(host.c_str(), service.c_str(), &hints, &raw);
                if (error == 0 && raw != nullptr) {
                    copyResolved(raw, maxCandidates, copied);
                    copied = InterleaveAddresses(copied, maxCandidates);
                }
            } catch (...) {
                error = EAI_MEMORY;
                copied.clear();
            }
            if (raw != nullptr) { ::freeaddrinfo(raw); }
            {
                std::lock_guard<std::mutex> lock(state->mutex);
                state->gaiError = error;
                if (!state->abandoned) { state->addresses = std::move(copied); }
                state->done = true;
            }
            state->condition.notify_one();
        });
    } catch (...) {
        output.status = ResolveStatus::ResourceExhausted;
        output.gaiError = EAI_MEMORY;
        return output;
    }

    bool done = false;
    {
        std::unique_lock<std::mutex> lock(state->mutex);
        while (!state->done) {
            if (cancellationRequested(cancelled)) {
                state->abandoned = true;
                output.status = ResolveStatus::Cancelled;
                output.gaiError = EAI_AGAIN;
                break;
            }
            const auto now = std::chrono::steady_clock::now();
            if (now >= deadline) {
                state->abandoned = true;
                output.status = ResolveStatus::TimedOut;
                output.gaiError = EAI_AGAIN;
                break;
            }
            state->condition.wait_for(lock, std::min(
                kCancellationSlice,
                std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now)));
        }
        done = state->done;
        if (done) {
            output.gaiError = state->gaiError;
            output.addresses = std::move(state->addresses);
            output.status = output.gaiError == 0 && !output.addresses.empty()
                ? ResolveStatus::Ready : ResolveStatus::Failed;
        }
    }
    if (done) { worker.join(); } else { worker.detach(); }
    return output;
}

ConnectResult ConnectTcpCandidates(
    const std::vector<ResolvedAddress>& addresses,
    const ConnectOptions& options) {
    ConnectResult result;
    try {
    const std::vector<ResolvedAddress> candidates =
        InterleaveAddresses(addresses, options.maxCandidates);
    if (candidates.empty()) {
        result.lastError = EHOSTUNREACH;
        return result;
    }
    if (cancellationRequested(options.cancelled)) {
        result.status = ConnectStatus::Cancelled;
        result.lastError = ECANCELED;
        return result;
    }

    std::vector<ActiveSocket> active;
    active.reserve(candidates.size());
    ActiveSocketsGuard activeGuard(active);
    std::size_t nextCandidate = 0;
    auto nextLaunch = std::chrono::steady_clock::now();
    const auto fallbackDelay = std::max(std::chrono::milliseconds(0),
                                        options.fallbackDelay);

    while (true) {
        if (cancellationRequested(options.cancelled)) {
            closeActive(active);
            result.status = ConnectStatus::Cancelled;
            result.lastError = ECANCELED;
            return result;
        }
        auto now = std::chrono::steady_clock::now();
        if (now >= options.deadline) {
            closeActive(active);
            result.status = ConnectStatus::TimedOut;
            result.lastError = ETIMEDOUT;
            return result;
        }

        while (nextCandidate < candidates.size() &&
               (active.empty() || now >= nextLaunch)) {
            const ResolvedAddress& address = candidates[nextCandidate++];
            ++result.attemptedCandidates;
            const int descriptor = ::socket(address.family, address.socktype,
                                             address.protocol);
            if (descriptor < 0) {
                result.lastError = errno;
                now = std::chrono::steady_clock::now();
                continue;
            }
            ScopedDescriptor descriptorGuard(descriptor);
            const int flags = ::fcntl(descriptor, F_GETFL, 0);
            const int descriptorFlags = ::fcntl(descriptor, F_GETFD, 0);
            if (flags < 0 || ::fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != 0) {
                result.lastError = errno;
                now = std::chrono::steady_clock::now();
                continue;
            }
            if (descriptorFlags >= 0) {
                (void)::fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC);
            }
            ActiveSocket attempt{descriptor, flags, address};
            const int connectResult = ::connect(
                descriptor, reinterpret_cast<const sockaddr*>(&address.storage),
                address.length);
            if (connectResult == 0) {
                active.push_back(attempt);
                (void)descriptorGuard.release();
                return connectedResult(attempt, active, options,
                                       result.attemptedCandidates);
            }
            const int connectError = errno;
            if (connectError == EINPROGRESS || connectError == EALREADY ||
                connectError == EINTR || connectError == EWOULDBLOCK) {
                active.push_back(attempt);
                (void)descriptorGuard.release();
                nextLaunch = std::chrono::steady_clock::now() + fallbackDelay;
                break;
            }
            result.lastError = connectError;
            now = std::chrono::steady_clock::now();
        }

        if (active.empty() && nextCandidate >= candidates.size()) {
            result.status = ConnectStatus::Failed;
            if (result.lastError == 0) { result.lastError = EHOSTUNREACH; }
            return result;
        }

        std::vector<pollfd> descriptors;
        descriptors.reserve(active.size());
        for (const ActiveSocket& socket : active) {
            descriptors.push_back(pollfd{socket.descriptor,
                                         static_cast<short>(POLLOUT | POLLERR | POLLHUP), 0});
        }
        now = std::chrono::steady_clock::now();
        auto wait = std::min(
            kCancellationSlice,
            std::chrono::duration_cast<std::chrono::milliseconds>(options.deadline - now));
        if (nextCandidate < candidates.size() && nextLaunch > now) {
            wait = std::min(wait,
                            std::chrono::duration_cast<std::chrono::milliseconds>(
                                nextLaunch - now));
        } else if (nextCandidate < candidates.size()) {
            wait = std::chrono::milliseconds(0);
        }
        const int pollResult = ::poll(descriptors.data(), descriptors.size(),
                                     static_cast<int>(std::max<std::int64_t>(
                                         0, wait.count())));
        if (pollResult < 0) {
            if (errno == EINTR) { continue; }
            result.lastError = errno;
            closeActive(active);
            return result;
        }
        if (pollResult == 0) { continue; }

        for (std::size_t index = 0; index < active.size();) {
            if (descriptors[index].revents == 0) {
                ++index;
                continue;
            }
            int socketError = 0;
            socklen_t errorLength = sizeof(socketError);
            if (::getsockopt(active[index].descriptor, SOL_SOCKET, SO_ERROR,
                             &socketError, &errorLength) == 0 && socketError == 0) {
                ActiveSocket winner = active[index];
                return connectedResult(winner, active, options,
                                       result.attemptedCandidates);
            }
            result.lastError = socketError == 0 ? errno : socketError;
            ::close(active[index].descriptor);
            active.erase(active.begin() + static_cast<std::ptrdiff_t>(index));
            descriptors.erase(descriptors.begin() + static_cast<std::ptrdiff_t>(index));
        }
        if (active.empty() && nextCandidate < candidates.size()) {
            nextLaunch = std::chrono::steady_clock::now();
        }
    }
    } catch (...) {
        result.status = ConnectStatus::Failed;
        result.descriptor = -1;
        result.lastError = ENOMEM;
        return result;
    }
}

ResolveResult ResolveAndConnectTcp(
    const std::string& host,
    const std::string& service,
    const ConnectOptions& options,
    ConnectResult& connection,
    int family) {
    ResolveResult resolution = ResolveTcpAddresses(
        host, service, options.deadline, options.cancelled, family,
        options.maxCandidates);
    if (resolution.status != ResolveStatus::Ready) { return resolution; }
    connection = ConnectTcpCandidates(resolution.addresses, options);
    return resolution;
}

} // namespace remotedesk::net
