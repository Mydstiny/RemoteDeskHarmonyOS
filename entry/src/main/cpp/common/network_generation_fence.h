#pragma once

#include <cstdint>
#include <functional>
#include <mutex>
#include <utility>

namespace remotedesk::net {

struct NetworkGenerationSnapshot final {
    uint64_t generation = 0;
    bool available = false;
};

class NetworkGenerationAdmission final {
public:
    NetworkGenerationAdmission(NetworkGenerationAdmission&&) noexcept = default;
    NetworkGenerationAdmission& operator=(NetworkGenerationAdmission&&) noexcept =
        default;
    NetworkGenerationAdmission(const NetworkGenerationAdmission&) = delete;
    NetworkGenerationAdmission& operator=(const NetworkGenerationAdmission&) =
        delete;

    bool current() const noexcept { return current_; }
    explicit operator bool() const noexcept { return current(); }

private:
    friend class NetworkGenerationFence;
    NetworkGenerationAdmission(
        std::unique_lock<std::mutex>&& lock, bool current) noexcept
        : lock_(std::move(lock)), current_(current) {}

    std::unique_lock<std::mutex> lock_;
    bool current_ = false;
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

    /** Hold the generation update lock across a short admission primitive. */
    NetworkGenerationAdmission acquireAdmission(
        const NetworkGenerationSnapshot& captured) const;

    /**
     * Serialize one non-blocking route-admission primitive with generation
     * updates. The callback must not call this fence again or block waiting
     * for a network update. A successful return defines the point after which
     * a caller must treat a later route change as a post-admission outcome.
     */
    bool admitIfCurrent(
        const NetworkGenerationSnapshot& captured,
        const std::function<void()>& admission) const;

private:
    mutable std::mutex mutex_;
    NetworkGenerationSnapshot current_;
};

/** Shared fence fed by the native default-network observer. */
NetworkGenerationFence& ProcessNetworkGenerationFence();

} // namespace remotedesk::net
