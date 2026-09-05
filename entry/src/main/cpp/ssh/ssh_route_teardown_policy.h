#pragma once

#include <chrono>
#include <cstdint>

enum class SshRouteTeardownDecision : std::uint8_t {
    Complete = 0,
    RetryCurrentRoute,
    RetireTransport,
};

/**
 * Keeps graceful libssh2 teardown bounded without weakening the network
 * generation fence. Every EAGAIN retry must reacquire route admission. If the
 * route is stale, or the shared teardown budget expires, the socket is shut
 * down before libssh2 is allowed to release its local state.
 */
struct SshRouteTeardownPolicy final {
    using Clock = std::chrono::steady_clock;
    using TimePoint = Clock::time_point;

    static constexpr int kGracefulBudgetMilliseconds = 250;
    static constexpr int kPollSliceMilliseconds = 10;
    static constexpr std::uint32_t kLocalReleaseAttempts = 4;

    static TimePoint deadline(TimePoint startedAt) noexcept {
        return startedAt +
            std::chrono::milliseconds(kGracefulBudgetMilliseconds);
    }

    static SshRouteTeardownDecision decide(
        bool admitted, int result, int wouldBlockResult,
        TimePoint now, TimePoint gracefulDeadline) noexcept {
        if (!admitted) {
            return SshRouteTeardownDecision::RetireTransport;
        }
        if (result != wouldBlockResult) {
            return SshRouteTeardownDecision::Complete;
        }
        return now >= gracefulDeadline
            ? SshRouteTeardownDecision::RetireTransport
            : SshRouteTeardownDecision::RetryCurrentRoute;
    }
};
