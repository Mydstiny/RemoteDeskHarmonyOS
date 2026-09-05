#pragma once

#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstdint>
#include <mutex>

enum class RdpTeardownRetirementWaitResult {
    Retired,
    Cancelled,
    TimedOut,
};

/**
 * Completion fence for the platform-owned tail of one RDP teardown.
 *
 * The public disconnect path has a bounded caller deadline, but FreeRDP may
 * still be unwinding callbacks or a blocking SDK call after that deadline.
 * Network recovery must wait for that exact session generation to retire
 * before admitting its single replacement attempt. Explicit user actions or
 * a newer network event interrupt the wait through the supplied token check.
 */
class RdpTeardownRetirementFence final {
public:
    void admit(uint64_t generation) {
        std::lock_guard<std::mutex> lock(mutex_);
        pendingGeneration_ = generation;
        cv_.notify_all();
    }

    bool retire(uint64_t generation) {
        bool retired = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (generation != 0 && pendingGeneration_ == generation) {
                pendingGeneration_ = 0;
                retired = true;
            }
        }
        if (retired) {
            cv_.notify_all();
        }
        return retired;
    }

    void interrupt() noexcept {
        // Synchronize with the wait predicate so a token change cannot notify
        // in the narrow window between the predicate check and wait_until().
        try {
            std::lock_guard<std::mutex> lock(mutex_);
        } catch (...) {
            std::abort();
        }
        cv_.notify_all();
    }

    uint64_t pendingGeneration() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return pendingGeneration_;
    }

    template <typename IsCurrent>
    RdpTeardownRetirementWaitResult waitUntilRetired(
        uint64_t generation,
        std::chrono::steady_clock::time_point deadline,
        IsCurrent&& isCurrent) {
        std::unique_lock<std::mutex> lock(mutex_);
        for (;;) {
            if (!isCurrent()) {
                return RdpTeardownRetirementWaitResult::Cancelled;
            }
            if (generation == 0 || pendingGeneration_ != generation) {
                return RdpTeardownRetirementWaitResult::Retired;
            }
            if (cv_.wait_until(lock, deadline) == std::cv_status::timeout) {
                if (!isCurrent()) {
                    return RdpTeardownRetirementWaitResult::Cancelled;
                }
                if (pendingGeneration_ == generation) {
                    return RdpTeardownRetirementWaitResult::TimedOut;
                }
            }
        }
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    uint64_t pendingGeneration_ = 0;
};
