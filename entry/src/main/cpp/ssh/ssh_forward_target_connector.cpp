#include "ssh_forward_target_connector.h"

#include "common/happy_eyeballs_connector.h"

#include <cerrno>
#include <cstddef>
#include <sys/socket.h>
#include <unistd.h>
#include <utility>

namespace {

constexpr std::size_t kMaxProcessTargetConnectWorkers = 8;
std::atomic<std::size_t> gTargetConnectWorkers{0};

bool tryAcquireTargetConnectWorker() noexcept {
    std::size_t active = gTargetConnectWorkers.load(std::memory_order_acquire);
    while (active < kMaxProcessTargetConnectWorkers) {
        if (gTargetConnectWorkers.compare_exchange_weak(
                active, active + 1, std::memory_order_acq_rel,
                std::memory_order_acquire)) {
            return true;
        }
    }
    return false;
}

class TargetConnectWorkerPermit final {
public:
    ~TargetConnectWorkerPermit() {
        gTargetConnectWorkers.fetch_sub(1, std::memory_order_acq_rel);
    }
};

SshForwardTargetConnectResult connectTarget(
    std::string host, int port, std::chrono::steady_clock::time_point deadline,
    const std::shared_ptr<std::atomic<bool>>& cancellation) noexcept {
    SshForwardTargetConnectResult result;
    try {
        if (host.size() >= 2 && host.front() == '[' && host.back() == ']') {
            host = host.substr(1, host.size() - 2);
        }
        remotedesk::net::ConnectOptions options;
        options.deadline = deadline;
        options.cancelled = [cancellation]() noexcept {
            return cancellation->load(std::memory_order_acquire);
        };
        options.restoreBlocking = false;

        remotedesk::net::ConnectResult connection;
        const remotedesk::net::ResolveResult resolution =
            remotedesk::net::ResolveAndConnectTcp(
                host, std::to_string(port), options, connection);
        if (resolution.status != remotedesk::net::ResolveStatus::Ready) {
            if (resolution.status == remotedesk::net::ResolveStatus::Cancelled) {
                result.errorCode = ECANCELED;
            } else if (resolution.status == remotedesk::net::ResolveStatus::TimedOut) {
                result.errorCode = ETIMEDOUT;
            } else if (resolution.status ==
                       remotedesk::net::ResolveStatus::ResourceExhausted) {
                result.errorCode = ENOMEM;
            } else {
                result.errorCode = EHOSTUNREACH;
            }
            return result;
        }
        if (connection.status != remotedesk::net::ConnectStatus::Connected ||
            connection.descriptor < 0) {
            if (connection.status == remotedesk::net::ConnectStatus::Cancelled) {
                result.errorCode = ECANCELED;
            } else if (connection.status == remotedesk::net::ConnectStatus::TimedOut) {
                result.errorCode = ETIMEDOUT;
            } else {
                result.errorCode = connection.lastError == 0
                    ? EHOSTUNREACH : connection.lastError;
            }
            return result;
        }
        result.descriptor = connection.descriptor;
        return result;
    } catch (...) {
        result.errorCode = ENOMEM;
        return result;
    }
}

} // namespace

SshForwardTargetConnectTask::~SshForwardTargetConnectTask() {
    cancelAndClose();
}

SshForwardTargetConnectTask::SshForwardTargetConnectTask(
    SshForwardTargetConnectTask&& other) noexcept
    : cancellation_(std::move(other.cancellation_)),
      completion_(std::move(other.completion_)) {}

SshForwardTargetConnectTask& SshForwardTargetConnectTask::operator=(
    SshForwardTargetConnectTask&& other) noexcept {
    if (this != &other) {
        cancelAndClose();
        cancellation_ = std::move(other.cancellation_);
        completion_ = std::move(other.completion_);
    }
    return *this;
}

bool SshForwardTargetConnectTask::start(
    const std::string& host, int port, std::chrono::milliseconds timeout) noexcept {
    cancelAndClose();
    if (host.empty() || port <= 0 || port > 65535 || timeout.count() <= 0) {
        return false;
    }
    if (!tryAcquireTargetConnectWorker()) {
        return false;
    }
    try {
        cancellation_ = std::make_shared<std::atomic<bool>>(false);
        const auto deadline = std::chrono::steady_clock::now() + timeout;
        completion_ = std::async(
            std::launch::async,
            [host, port, deadline, cancellation = cancellation_]() mutable noexcept {
                const TargetConnectWorkerPermit permit;
                return connectTarget(std::move(host), port, deadline, cancellation);
            });
        return true;
    } catch (...) {
        gTargetConnectWorkers.fetch_sub(1, std::memory_order_acq_rel);
        cancellation_.reset();
        return false;
    }
}

bool SshForwardTargetConnectTask::pending() const noexcept {
    return completion_.valid();
}

bool SshForwardTargetConnectTask::ready() const noexcept {
    return completion_.valid() &&
        completion_.wait_for(std::chrono::milliseconds(0)) == std::future_status::ready;
}

SshForwardTargetConnectResult SshForwardTargetConnectTask::take() noexcept {
    SshForwardTargetConnectResult result;
    if (!completion_.valid()) {
        result.errorCode = EINVAL;
        cancellation_.reset();
        return result;
    }
    try {
        result = completion_.get();
    } catch (...) {
        result.errorCode = ENOMEM;
    }
    cancellation_.reset();
    return result;
}

void SshForwardTargetConnectTask::cancelAndClose() noexcept {
    if (cancellation_ != nullptr) {
        cancellation_->store(true, std::memory_order_release);
    }
    if (completion_.valid()) {
        const SshForwardTargetConnectResult result = take();
        if (result.descriptor >= 0) {
            (void)::shutdown(result.descriptor, SHUT_RDWR);
            (void)::close(result.descriptor);
        }
    }
    cancellation_.reset();
}

#if defined(RDP_TESTS_ONLY)
bool SshForwardTargetConnectTask::startForTest(TestConnector connector) noexcept {
    cancelAndClose();
    if (!connector) {
        return false;
    }
    if (!tryAcquireTargetConnectWorker()) {
        return false;
    }
    try {
        cancellation_ = std::make_shared<std::atomic<bool>>(false);
        completion_ = std::async(
            std::launch::async,
            [connector = std::move(connector), cancellation = cancellation_]() mutable noexcept {
                const TargetConnectWorkerPermit permit;
                try {
                    return connector(cancellation);
                } catch (...) {
                    return SshForwardTargetConnectResult{-1, ENOMEM};
                }
            });
        return true;
    } catch (...) {
        gTargetConnectWorkers.fetch_sub(1, std::memory_order_acq_rel);
        cancellation_.reset();
        return false;
    }
}
#endif
