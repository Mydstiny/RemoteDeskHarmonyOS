#ifndef SSH_AUTH_REPLAY_POLICY_H
#define SSH_AUTH_REPLAY_POLICY_H

#include "extensions/protocol_adapter.h"

#include <cstdint>

enum class SshOneShotAuthScope : std::uint8_t {
    RouteOnly = 0,
    RouteAndTarget,
};

/**
 * Explicit keyboard-interactive answers are treated as one-shot material.
 * Passwords and keys remain reusable, while a KBI/OTP answer must never be
 * submitted automatically to a second SSH session.
 */
struct SshAuthReplayPolicy final {
    static bool hasExplicitResponses(
        const ConnectionConfig& config, SshOneShotAuthScope scope) noexcept {
        if (!config.sshProxyKeyboardInteractiveResponses.empty()) {
            return true;
        }
        for (const SshJumpHopHandoff& handoff : config.sshJumpHopHandoffs) {
            if (!handoff.keyboardInteractiveResponses.empty()) {
                return true;
            }
        }
        return scope == SshOneShotAuthScope::RouteAndTarget &&
            !config.sshKeyboardInteractiveResponses.empty();
    }

    static bool allowsAutomaticNewSession(bool explicitResponseConsumed) noexcept {
        return !explicitResponseConsumed;
    }
};

#endif // SSH_AUTH_REPLAY_POLICY_H
