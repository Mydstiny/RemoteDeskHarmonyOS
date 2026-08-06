/**
 * Bounded SSH recovery policy.
 *
 * Keep policy arithmetic independent from sockets and libssh2 so the exact
 * retry budget can be tested without a live endpoint.
 */
#ifndef SSH_RECONNECT_POLICY_H
#define SSH_RECONNECT_POLICY_H

#include <algorithm>
#include <cstdint>

struct SshReconnectPolicy {
    static constexpr int kKeepaliveSeconds = 30;
    static constexpr uint32_t kKeepaliveFailureThreshold = 3;
    static constexpr uint32_t kMaxAttempts = 8;
    static constexpr int kBaseDelayMilliseconds = 1000;
    static constexpr int kMaxDelayMilliseconds = 30000;
    static constexpr uint32_t kJitterPermille = 200;
    static constexpr int kMaxRecoveryWindowMilliseconds = 10 * 60 * 1000;

    static inline int exponentialDelayMilliseconds(uint32_t zeroBasedAttempt) noexcept {
        uint64_t delay = static_cast<uint64_t>(kBaseDelayMilliseconds);
        for (uint32_t index = 0; index < zeroBasedAttempt &&
             delay < static_cast<uint64_t>(kMaxDelayMilliseconds); ++index) {
            delay = std::min<uint64_t>(delay * 2, kMaxDelayMilliseconds);
        }
        return static_cast<int>(delay);
    }

    /** randomPermille must be in [0, 1000]; callers can inject a stable value in tests. */
    static inline int jitteredDelayMilliseconds(uint32_t zeroBasedAttempt,
                                                uint32_t randomPermille) noexcept {
        const int base = exponentialDelayMilliseconds(zeroBasedAttempt);
        const int spread = static_cast<int>(
            (static_cast<int64_t>(base) * kJitterPermille) / 1000);
        const uint32_t boundedRandom = std::min<uint32_t>(randomPermille, 1000);
        const int signedOffset = static_cast<int>(
            (static_cast<int64_t>(boundedRandom) * (spread * 2)) / 1000) - spread;
        return std::max(0, std::min(kMaxDelayMilliseconds, base + signedOffset));
    }

    static inline bool canAttempt(uint32_t attemptsStarted,
                                  int elapsedMilliseconds) noexcept {
        return attemptsStarted < kMaxAttempts &&
            elapsedMilliseconds < kMaxRecoveryWindowMilliseconds;
    }

    static inline bool keepaliveFailureTriggersRecovery(
        uint32_t consecutiveFailures) noexcept {
        return consecutiveFailures >= kKeepaliveFailureThreshold;
    }
};

#endif // SSH_RECONNECT_POLICY_H
