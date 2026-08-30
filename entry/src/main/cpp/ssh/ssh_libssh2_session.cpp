#include "ssh_libssh2_session.h"

#include <algorithm>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>

namespace {

constexpr std::size_t kDeferredReaperAttemptLimit = 8;
constexpr auto kDeferredReaperInitialDelay = std::chrono::milliseconds(5);
constexpr auto kDeferredReaperMaximumDelay = std::chrono::milliseconds(250);

/**
 * One joinable worker owns active retries for quarantined libssh2 sessions.
 * Each external notification receives at most eight attempts; a persistent
 * failure remains in the fail-closed intrusive queue until a later SSH event.
 * This avoids both an unbounded retry loop and unsafe destruction of a live
 * libssh2 object.
 *
 * The constructor initializes queue/registry dependencies before starting the
 * thread. Function-static destruction therefore stops and joins this service
 * before those dependencies are destroyed or the native module is unloaded.
 */
class SshLibssh2DeferredReaperService final {
public:
    SshLibssh2DeferredReaperService() {
        (void)sshSensitiveAllocationRegistry();
        (void)sshDeferredTrackedLibssh2SessionHead();
        (void)sshDeferredTrackedLibssh2SessionCountStorage();
        worker_ = std::thread([this]() noexcept { run(); });
    }

    ~SshLibssh2DeferredReaperService() noexcept {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopRequested_ = true;
        }
        workCondition_.notify_all();
        if (worker_.joinable()) {
            worker_.join();
        }
        // One final local pass is bounded and cannot recursively schedule.
        // A pathological persistent failure stays quarantined; dropping its
        // raw owner would be less safe than retaining it until process exit.
        sshReapDeferredTrackedLibssh2SessionsPass(false);
    }

    SshLibssh2DeferredReaperService(
        const SshLibssh2DeferredReaperService&) = delete;
    SshLibssh2DeferredReaperService& operator=(
        const SshLibssh2DeferredReaperService&) = delete;

    void notify() noexcept {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            ++requestGeneration_;
        }
        workCondition_.notify_one();
    }

#ifdef RDP_NATIVE_CALLBACK_TESTING
    bool waitForIdle(std::chrono::milliseconds timeout) noexcept {
        std::unique_lock<std::mutex> lock(mutex_);
        return idleCondition_.wait_for(lock, timeout, [this]() {
            return !active_ &&
                handledGeneration_ == requestGeneration_;
        });
    }
#endif

private:
    void run() noexcept {
        std::unique_lock<std::mutex> lock(mutex_);
        while (true) {
            workCondition_.wait(lock, [this]() {
                return stopRequested_ ||
                    handledGeneration_ != requestGeneration_;
            });
            if (stopRequested_) {
                active_ = false;
                idleCondition_.notify_all();
                return;
            }

            handledGeneration_ = requestGeneration_;
            active_ = true;
            lock.unlock();

            auto retryDelay = kDeferredReaperInitialDelay;
            for (std::size_t attempt = 0;
                 attempt < kDeferredReaperAttemptLimit;
                 ++attempt) {
                sshReapDeferredTrackedLibssh2SessionsPass(false);
                if (sshDeferredTrackedLibssh2SessionCount() == 0) {
                    break;
                }

                std::unique_lock<std::mutex> delayLock(mutex_);
                if (workCondition_.wait_for(
                        delayLock, retryDelay,
                        [this]() { return stopRequested_; })) {
                    active_ = false;
                    idleCondition_.notify_all();
                    return;
                }
                retryDelay = std::min(
                    retryDelay * 2, kDeferredReaperMaximumDelay);
            }

            lock.lock();
            active_ = false;
            idleCondition_.notify_all();
            // If another owner published work during this bounded burst, the
            // generation predicate immediately starts one additional burst.
        }
    }

    std::mutex mutex_;
    std::condition_variable workCondition_;
    std::condition_variable idleCondition_;
    bool stopRequested_ = false;
    bool active_ = false;
    std::uint64_t requestGeneration_ = 0;
    std::uint64_t handledGeneration_ = 0;
    // Last by design: every state field exists before the worker can start.
    std::thread worker_;
};

SshLibssh2DeferredReaperService& deferredReaperService() {
    static SshLibssh2DeferredReaperService service;
    return service;
}

} // namespace

void sshScheduleDeferredTrackedLibssh2Reaper() noexcept {
    if (!sshDeferredTrackedLibssh2AutoReapEnabled()) {
        return;
    }
    try {
        deferredReaperService().notify();
    } catch (...) {
        // Thread creation/resource failure receives exactly one synchronous
        // pass with rescheduling suppressed. A later SSH event retries service
        // construction; this path cannot recurse through quarantine.
        sshReapDeferredTrackedLibssh2SessionsPass(false);
    }
}

#ifdef RDP_NATIVE_CALLBACK_TESTING
bool sshWaitForDeferredTrackedLibssh2ReaperIdleForTesting(
    std::chrono::milliseconds timeout) noexcept {
    try {
        return deferredReaperService().waitForIdle(timeout);
    } catch (...) {
        return false;
    }
}
#endif
