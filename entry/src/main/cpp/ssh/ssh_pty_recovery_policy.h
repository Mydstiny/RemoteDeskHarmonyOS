/**
 * Policy for deciding whether a failed SSH PTY request is safe to retry.
 *
 * A server-side PTY refusal is a real capability/configuration error and must
 * remain visible. Socket and timeout failures, however, can happen after the
 * SSH handshake has completed and are recoverable by rebuilding the transport.
 */
#ifndef SSH_PTY_RECOVERY_POLICY_H
#define SSH_PTY_RECOVERY_POLICY_H

#include <cstdint>

enum class SshPtyFailureClass {
    NONE,
    TRANSIENT_TRANSPORT,
    TRANSIENT_CHANNEL,
    SERVER_REJECTED,
    PERMANENT,
};

struct SshPtyRecoveryPolicy {
    // Initial connection gets one attempt plus two bounded rebuilds. Recovery
    // after an established transport loss is already bounded by its caller.
    static constexpr uint32_t kMaxInitialAttempts = 3;
    static constexpr int kRetryDelayMilliseconds = 250;

    static inline bool retryable(SshPtyFailureClass failure) noexcept {
        return failure == SshPtyFailureClass::TRANSIENT_TRANSPORT ||
               failure == SshPtyFailureClass::TRANSIENT_CHANNEL;
    }

    static inline bool hasRetryBudget(uint32_t attempt) noexcept {
        return attempt + 1 < kMaxInitialAttempts;
    }
};

#endif // SSH_PTY_RECOVERY_POLICY_H
