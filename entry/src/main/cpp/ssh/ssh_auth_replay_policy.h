#ifndef SSH_AUTH_REPLAY_POLICY_H
#define SSH_AUTH_REPLAY_POLICY_H

#include "extensions/protocol_adapter.h"

#include <algorithm>
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

    static void clearConsumedResponses(
        std::vector<std::string>& responses, std::size_t first,
        std::size_t count) noexcept {
        const std::size_t end = first > responses.size()
            ? responses.size()
            : std::min(responses.size(), first +
                std::min(count, responses.size() - first));
        for (std::size_t index = first; index < end; ++index) {
            std::string& response = responses[index];
            if (!response.empty()) {
                volatile char* bytes = response.data();
                for (std::size_t offset = 0; offset < response.size(); ++offset) {
                    bytes[offset] = '\0';
                }
            }
            response.clear();
        }
    }
};

#endif // SSH_AUTH_REPLAY_POLICY_H
