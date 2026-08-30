#pragma once

#include "common/network_generation_fence.h"

/**
 * Combines caller cancellation with the process default-network generation.
 * Every SSH resolver/dial attempt must use one captured snapshot for its
 * complete route so a VPN, DNS, prefix, or interface change cannot promote a
 * candidate from an obsolete network.
 */
struct SshNetworkGenerationPolicy final {
    static bool shouldCancel(
        bool callerCancelled,
        const remotedesk::net::NetworkGenerationFence& fence,
        const remotedesk::net::NetworkGenerationSnapshot& captured) {
        return callerCancelled || fence.shouldCancel(captured);
    }
};
