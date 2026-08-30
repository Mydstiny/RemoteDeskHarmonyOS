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
        bool available = false;
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
    DispatchSnapshot publishAvailability(
        bool available, FencePublisher&& publishFence) {
        std::lock_guard<std::mutex> lock(mutex_);
        ++networkGeneration_;

        // The process fence and target snapshot deliberately share this
        // ordering lock with track(). A session is therefore either in this
        // dispatch batch or starts after the new fence has been published.
        publishFence(available, networkGeneration_);

        DispatchSnapshot snapshot;
        snapshot.available = available;
        snapshot.networkGeneration = networkGeneration_;
        snapshot.targets.reserve(targets_.size());
        for (const auto& target : targets_) {
            snapshot.targets.push_back(target);
        }
        return snapshot;
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
    uint32_t takeObserverIfIdleLocked() {
        if (observerId_ == 0 || transientConsumers_ != 0 || !targets_.empty()) {
            return 0;
        }
        const uint32_t observerId = observerId_;
        observerId_ = 0;
        return observerId;
    }

    mutable std::mutex mutex_;
    uint32_t observerId_ = 0;
    size_t transientConsumers_ = 0;
    uint64_t networkGeneration_ = 1;
    std::map<int32_t, Target> targets_;
};

} // namespace remotedesk::net
