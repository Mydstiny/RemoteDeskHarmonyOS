#pragma once

#include <cstdint>
#include <cstddef>
#include <map>
#include <memory>
#include <mutex>
#include <utility>
#include <vector>

namespace remotedesk::net {

/**
 * Thread-safe ownership and dispatch-order state for the native default-
 * network observer. Platform registration and callback dispatch stay in the
 * NAPI translation unit; this class makes their ordering contract testable.
 */
template <typename Session>
class NativeNetworkObserverState final {
public:
    struct Target final {
        uint64_t sessionGeneration = 0;
        std::shared_ptr<Session> session;
    };

    struct DispatchSnapshot final {
        bool generationAdvanced = false;
        bool observedDefaultAvailable = false;
        bool routeAttemptAllowed = true;
        bool networkIdKnown = false;
        int32_t networkId = 0;
        uint64_t networkGeneration = 0;
        std::vector<std::pair<int32_t, Target>> targets;
    };

    explicit NativeNetworkObserverState(uint64_t initialGeneration = 1)
        : networkGeneration_(initialGeneration == 0 ? 1 : initialGeneration) {}

    bool hasObserver() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return observerId_ != 0;
    }

    bool installObserverIfAbsent(uint32_t observerId) {
        if (observerId == 0) {
            return false;
        }
        std::lock_guard<std::mutex> lock(mutex_);
        if (observerId_ != 0) {
            return false;
        }
        observerId_ = observerId;
        return true;
    }

    void addTransientConsumer() {
        std::lock_guard<std::mutex> lock(mutex_);
        ++transientConsumers_;
    }

    uint32_t releaseTransientConsumerAndTakeObserverIfIdle() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (transientConsumers_ > 0) {
            --transientConsumers_;
        }
        return takeObserverIfIdleLocked();
    }

    bool track(int32_t sessionId, uint64_t sessionGeneration,
               std::shared_ptr<Session> session) {
        if (sessionId <= 0 || sessionGeneration == 0 || !session) {
            return false;
        }
        std::lock_guard<std::mutex> lock(mutex_);
        targets_[sessionId] = Target {sessionGeneration, std::move(session)};
        return true;
    }

    uint32_t eraseExactAndTakeObserverIfIdle(
        int32_t sessionId, uint64_t sessionGeneration) {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto target = targets_.find(sessionId);
        if (target != targets_.end() &&
            target->second.sessionGeneration == sessionGeneration) {
            targets_.erase(target);
        }
        return takeObserverIfIdleLocked();
    }

    template <typename FencePublisher>
    DispatchSnapshot observeAvailability(
        bool available, int32_t networkId, bool networkIdKnown,
        FencePublisher&& publishFence) {
        std::lock_guard<std::mutex> lock(mutex_);

        if (!availabilityObservationSeen_) {
            availabilityObservationSeen_ = true;
            observedDefaultAvailable_ = available;
            if (networkIdKnown) {
                activeNetworkId_ = networkId;
                activeNetworkIdKnown_ = true;
            }
            return snapshotLocked(false);
        }

        // A lost callback for the previous default network can arrive after
        // the replacement network is already active. It must not retire the
        // replacement transport.
        if (!available && networkIdKnown && activeNetworkIdKnown_ &&
            networkId != activeNetworkId_) {
            return snapshotLocked(false);
        }

        bool changed = observedDefaultAvailable_ != available;
        if (available && observedDefaultAvailable_) {
            if (networkIdKnown && activeNetworkIdKnown_) {
                changed = networkId != activeNetworkId_;
            } else if (networkIdKnown) {
                // Learning the identity of the already-observed network is
                // not itself a route change.
                activeNetworkId_ = networkId;
                activeNetworkIdKnown_ = true;
            }
        }
        if (!changed) {
            return snapshotLocked(false);
        }

        observedDefaultAvailable_ = available;
        if (networkIdKnown) {
            activeNetworkId_ = networkId;
            activeNetworkIdKnown_ = true;
        }
        ++networkGeneration_;

        // A default-network callback proves that the route generation
        // changed, but "no default network" does not prove that a requested
        // LAN, VPN, or link-local endpoint is unreachable. Keep new socket
        // attempts admissible and let their actual I/O result decide.
        // The process fence and target snapshot deliberately share this lock
        // with track(), so old DNS/socket work is still retired exactly.
        publishFence(true, networkGeneration_);

        return snapshotLocked(true);
    }

    uint64_t networkGeneration() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return networkGeneration_;
    }

    size_t targetCount() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return targets_.size();
    }

    size_t transientConsumerCount() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return transientConsumers_;
    }

private:
    DispatchSnapshot snapshotLocked(bool generationAdvanced) const {
        DispatchSnapshot snapshot;
        snapshot.generationAdvanced = generationAdvanced;
        snapshot.observedDefaultAvailable = observedDefaultAvailable_;
        snapshot.networkIdKnown = activeNetworkIdKnown_;
        snapshot.networkId = activeNetworkId_;
        snapshot.networkGeneration = networkGeneration_;
        if (generationAdvanced) {
            snapshot.targets.reserve(targets_.size());
            for (const auto& target : targets_) {
                snapshot.targets.push_back(target);
            }
        }
        return snapshot;
    }

    uint32_t takeObserverIfIdleLocked() {
        if (observerId_ == 0 || transientConsumers_ != 0 || !targets_.empty()) {
            return 0;
        }
        const uint32_t observerId = observerId_;
        observerId_ = 0;
        // No target or transient consumer can own work from the old observer
        // after this point. The first callback from a future registration is
        // therefore a fresh baseline, even if the device changed networks
        // while no observer was installed.
        availabilityObservationSeen_ = false;
        observedDefaultAvailable_ = false;
        activeNetworkIdKnown_ = false;
        activeNetworkId_ = 0;
        return observerId;
    }

    mutable std::mutex mutex_;
    uint32_t observerId_ = 0;
    size_t transientConsumers_ = 0;
    uint64_t networkGeneration_ = 1;
    bool availabilityObservationSeen_ = false;
    bool observedDefaultAvailable_ = false;
    bool activeNetworkIdKnown_ = false;
    int32_t activeNetworkId_ = 0;
    std::map<int32_t, Target> targets_;
};

} // namespace remotedesk::net
