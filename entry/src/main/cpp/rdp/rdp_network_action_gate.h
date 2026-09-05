#pragma once

#include "rdp_network_recovery_policy.h"

#include <mutex>
#include <utility>

/**
 * Serialization lane shared by explicit RDP ownership changes and queued
 * network actions. The token is revalidated only after acquiring the lane,
 * so an old event cannot abort a newer explicit connect.
 */
class RdpNetworkActionGate final {
public:
    std::recursive_mutex& mutex() { return mutex_; }

    template <typename Action>
    bool runIfCurrent(
        const RdpNetworkRecoveryPolicy& policy, uint64_t token,
        bool requireAvailable, Action&& action) {
        std::lock_guard<std::recursive_mutex> lock(mutex_);
        if (!policy.isCurrent(token, requireAvailable)) {
            return false;
        }
        std::forward<Action>(action)();
        return true;
    }

private:
    std::recursive_mutex mutex_;
};
