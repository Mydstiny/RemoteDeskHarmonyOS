#pragma once

#include <cstdint>
#include <mutex>

struct VncNetworkRecoveryAction final {
    bool accepted = false;
    bool networkAvailable = false;
    bool cancelTransport = false;
    bool reconnectAfterRetirement = false;
    uint64_t networkGeneration = 0;
    uint64_t token = 0;
};

/**
 * Admission gate for VNC default-network recovery.
 *
 * Network callbacks may race an explicit connect/disconnect and may arrive
 * more than once for the same platform generation.  This policy assigns a
 * monotonic action token to the one current session owner, rejects stale
 * generations, and lets user actions retire queued recovery work before it
 * can create another RFB transport.
 */
class VncNetworkRecoveryPolicy final {
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

    bool retireConnectionOwnerIfCurrent(uint64_t token) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!ownerAdmitted_ || token == 0 || token != token_) {
            return false;
        }
        ownerAdmitted_ = false;
        ++token_;
        return true;
    }

    VncNetworkRecoveryAction onNetworkChanged(
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
        return VncNetworkRecoveryAction {
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
