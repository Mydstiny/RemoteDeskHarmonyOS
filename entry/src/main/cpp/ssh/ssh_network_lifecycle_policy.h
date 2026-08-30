/**
 * Network event admission rules for SSH recovery.
 *
 * Platform callbacks may be duplicated or arrive after a newer network
 * generation has already been applied. Keep these decisions payload-free so
 * they can be tested without a live NetConn instance.
 */
#ifndef SSH_NETWORK_LIFECYCLE_POLICY_H
#define SSH_NETWORK_LIFECYCLE_POLICY_H

#include <cstdint>

struct SshNetworkLifecyclePolicy final {
    static inline bool acceptsGeneration(uint64_t lastGeneration,
                                         uint64_t incomingGeneration) noexcept {
        return incomingGeneration != 0 && incomingGeneration > lastGeneration;
    }

    static inline bool shouldRequestRecovery(bool available,
                                             bool reactorRunning,
                                             bool connected) noexcept {
        (void)available;
        // Every accepted generation invalidates the current route, including
        // available=true capability/properties callbacks for VPN, DNS, prefix,
        // and interface changes that have no unavailable interval.
        return reactorRunning && connected;
    }

    static inline bool shouldWakeRecovery(bool available,
                                          bool reactorRunning) noexcept {
        return available && reactorRunning;
    }
};

#endif // SSH_NETWORK_LIFECYCLE_POLICY_H
