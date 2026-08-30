#pragma once

#include <cstdint>
#include <mutex>

namespace remotedesk::net {

struct NetworkGenerationSnapshot final {
    uint64_t generation = 0;
    bool available = false;
};

/**
 * Process-local view of the platform's default-network generation.
 *
 * A connection attempt captures a snapshot before resolving. The attempt
 * must stop when the generation changes or the current network becomes
 * unavailable, so a socket resolved for a previous interface is never
 * promoted after Wi-Fi/VPN/prefix changes.
 */
class NetworkGenerationFence final {
public:
    explicit NetworkGenerationFence(
        uint64_t initialGeneration = 1, bool initiallyAvailable = true);

    /** Accept only a strictly newer, non-zero platform generation. */
    bool update(bool available, uint64_t generation);

    NetworkGenerationSnapshot snapshot() const;
    bool shouldCancel(const NetworkGenerationSnapshot& captured) const;

private:
    mutable std::mutex mutex_;
    NetworkGenerationSnapshot current_;
};

/** Shared fence fed by the native default-network observer. */
NetworkGenerationFence& ProcessNetworkGenerationFence();

} // namespace remotedesk::net
