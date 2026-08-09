/**
 * Small, payload-free policy for scheduling SSH protocol keepalives.
 *
 * The native adapter owns the clock and libssh2 calls. Keeping the timing and
 * retry decisions here makes the long-idle behavior testable without a live
 * SSH endpoint.
 */
#ifndef SSH_TERMINAL_KEEPALIVE_POLICY_H
#define SSH_TERMINAL_KEEPALIVE_POLICY_H

#include <cstdint>

struct SshTerminalKeepalivePolicy {
    static constexpr int kIntervalSeconds = 30;
    static constexpr int kRetryWaitMilliseconds = 5;
    static constexpr int kRetryDelayMilliseconds = 250;
    static constexpr uint32_t kMaxConsecutiveFailures = 3;

    static inline int intervalSeconds(int secondsToNext) noexcept {
        return secondsToNext > 0 ? secondsToNext : kIntervalSeconds;
    }

    static inline bool retryableFailure(uint32_t consecutiveFailures) noexcept {
        return consecutiveFailures < kMaxConsecutiveFailures;
    }
};

#endif // SSH_TERMINAL_KEEPALIVE_POLICY_H
