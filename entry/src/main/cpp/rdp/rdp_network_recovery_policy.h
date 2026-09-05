#pragma once

#include <cstdint>
#include <mutex>

struct RdpNetworkRecoveryAction final {
    bool accepted = false;
    bool networkAvailable = false;
    bool cancelTransport = false;
    bool reconnectNow = false;
    uint64_t networkGeneration = 0;
    uint64_t token = 0;
    // Network migration is a continuity transition, never a user-visible
    // terminal disconnect.
    bool publishDisconnectedOnTeardown = false;
};

/**
 * Admission gate for asynchronous RDP network-recovery work.
 *
 * The policy does not perform I/O. It gives every accepted network event a
 * token, rejects stale generations, and lets an explicit connect/disconnect
 * retire already queued work before that work can reconnect the adapter.
 */
class RdpNetworkRecoveryPolicy final {
public:
    uint64_t admitConnectionOwner() {
        std::lock_guard<std::mutex> lock(mutex_);
        ownerAdmitted_ = true;
        return ++token_;
    }

    uint64_t retireConnectionOwner() {
        std::lock_guard<std::mutex> lock(mutex_);
        ownerAdmitted_ = false;
        return ++token_;
    }

    RdpNetworkRecoveryAction onNetworkChanged(
        bool available, uint64_t generation) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (generation == 0 || generation <= networkGeneration_) {
            return {};
        }
        networkGeneration_ = generation;
        networkAvailable_ = available;
        if (!ownerAdmitted_) {
            return {};
        }
        ++token_;
        return RdpNetworkRecoveryAction {
            true,
            available,
            true,
            available,
            generation,
            token_,
        };
    }

    bool isCurrent(uint64_t token, bool requireAvailable = false) const {
        std::lock_guard<std::mutex> lock(mutex_);
        return ownerAdmitted_ && token != 0 && token == token_ &&
            (!requireAvailable || networkAvailable_);
    }

    bool isRetired(uint64_t token) const {
        std::lock_guard<std::mutex> lock(mutex_);
        return !ownerAdmitted_ && token != 0 && token == token_;
    }

    uint64_t networkGeneration() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return networkGeneration_;
    }

    bool networkAvailable() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return networkAvailable_;
    }

private:
    mutable std::mutex mutex_;
    uint64_t networkGeneration_ = 0;
    uint64_t token_ = 0;
    bool ownerAdmitted_ = false;
    bool networkAvailable_ = true;
};
