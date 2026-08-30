#pragma once

#include "common/network_generation_fence.h"

#include <algorithm>
#include <chrono>
#include <cstdint>

enum class SshNetworkRetryDecision : std::uint8_t {
    Complete = 0,
    RetryCurrentNetwork,
    WaitForAvailableNetwork,
    StopCancelled,
    StopDeadline,
    StopExhausted,
};

/**
 * Combines caller cancellation with the process default-network generation.
 * Every SSH resolver/dial attempt must use one captured snapshot for its
 * complete route so a VPN, DNS, prefix, or interface change cannot promote a
 * candidate from an obsolete network.
 */
struct SshNetworkGenerationPolicy final {
    using Clock = std::chrono::steady_clock;
    using TimePoint = Clock::time_point;

    static constexpr std::uint32_t kMaxRouteAttempts = 3;
    static constexpr int kRetryPollMilliseconds = 50;
    static constexpr int kInitialRouteDeadlineMilliseconds = 30000;

    static TimePoint initialRouteDeadline(TimePoint startedAt) noexcept {
        return startedAt + std::chrono::milliseconds(
            kInitialRouteDeadlineMilliseconds);
    }

    static TimePoint boundedStageDeadline(
        TimePoint startedAt, TimePoint routeDeadline,
        std::chrono::milliseconds stageBudget) noexcept {
        const TimePoint stageDeadline = startedAt +
            std::max(stageBudget, std::chrono::milliseconds::zero());
        return std::min(stageDeadline, routeDeadline);
    }

    static bool deadlineExpired(TimePoint deadline, TimePoint now) noexcept {
        return now >= deadline;
    }

    static bool shouldCancel(
        bool callerCancelled,
        const remotedesk::net::NetworkGenerationFence& fence,
        const remotedesk::net::NetworkGenerationSnapshot& captured) {
        return callerCancelled || fence.shouldCancel(captured);
    }

    /** Decide only from immutable snapshots and the original deadline.
     * A retry is permitted solely for a strictly newer available generation;
     * stable transport/auth failures remain terminal.
     */
    static SshNetworkRetryDecision retryDecision(
        std::uint32_t attemptsStarted,
        bool callerCancelled,
        bool deadlineExpired,
        const remotedesk::net::NetworkGenerationSnapshot& captured,
        const remotedesk::net::NetworkGenerationSnapshot& current) noexcept {
        if (callerCancelled) {
            return SshNetworkRetryDecision::StopCancelled;
        }
        if (deadlineExpired) {
            return SshNetworkRetryDecision::StopDeadline;
        }
        if (captured.generation != 0 && captured.available &&
            current.available && current.generation == captured.generation) {
            return SshNetworkRetryDecision::Complete;
        }
        if (attemptsStarted >= kMaxRouteAttempts) {
            return SshNetworkRetryDecision::StopExhausted;
        }
        if (current.generation == 0 ||
            current.generation < captured.generation) {
            return SshNetworkRetryDecision::StopExhausted;
        }
        if (!current.available) {
            return SshNetworkRetryDecision::WaitForAvailableNetwork;
        }
        if (current.generation <= captured.generation) {
            return SshNetworkRetryDecision::StopExhausted;
        }
        return SshNetworkRetryDecision::RetryCurrentNetwork;
    }
};
