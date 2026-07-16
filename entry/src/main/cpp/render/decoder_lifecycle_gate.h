#ifndef DECODER_LIFECYCLE_GATE_H
#define DECODER_LIFECYCLE_GATE_H

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <mutex>

enum class DecoderLifecycleState {
    Uninitialized = 0,
    Initializing,
    Running,
    Flushing,
    Stopping,
    Stopped,
    Destroying,
    Destroyed,
};

struct DecoderCallbackLease {
    bool accepted = false;
    uint64_t generation = 0;
};

class DecoderLifecycleGate {
public:
    bool beginInitialization() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (state_ != DecoderLifecycleState::Uninitialized &&
            state_ != DecoderLifecycleState::Destroyed) {
            return false;
        }
        state_ = DecoderLifecycleState::Initializing;
        ++generation_;
        return true;
    }

    void markRunning() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (state_ == DecoderLifecycleState::Initializing) {
            state_ = DecoderLifecycleState::Running;
        }
    }

    DecoderCallbackLease acquireCallback() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (state_ != DecoderLifecycleState::Running) {
            return {};
        }
        ++inFlightCallbacks_;
        return {true, generation_};
    }

    void releaseCallback(const DecoderCallbackLease& lease) {
        if (!lease.accepted) return;
        std::lock_guard<std::mutex> lock(mutex_);
        if (inFlightCallbacks_ > 0) {
            --inFlightCallbacks_;
        }
        if (inFlightCallbacks_ == 0) {
            cv_.notify_all();
        }
    }

    bool beginFlush() {
        std::unique_lock<std::mutex> lock(mutex_);
        if (state_ != DecoderLifecycleState::Running) return false;
        state_ = DecoderLifecycleState::Flushing;
        ++generation_;
        cv_.wait(lock, [this]() { return inFlightCallbacks_ == 0; });
        return true;
    }

    void finishFlush(bool decoderReusable) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (state_ == DecoderLifecycleState::Flushing) {
            state_ = decoderReusable ? DecoderLifecycleState::Running : DecoderLifecycleState::Stopped;
            cv_.notify_all();
        }
    }

    bool beginDestroy() {
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait(lock, [this]() { return state_ != DecoderLifecycleState::Flushing; });
        if (state_ == DecoderLifecycleState::Destroying || state_ == DecoderLifecycleState::Destroyed) {
            return false;
        }
        state_ = DecoderLifecycleState::Destroying;
        ++generation_;
        cv_.wait(lock, [this]() { return inFlightCallbacks_ == 0; });
        return true;
    }

    void markDestroyed() {
        std::lock_guard<std::mutex> lock(mutex_);
        state_ = DecoderLifecycleState::Destroyed;
        cv_.notify_all();
    }

    bool isCurrent(uint64_t generation) const {
        std::lock_guard<std::mutex> lock(mutex_);
        return state_ == DecoderLifecycleState::Running && generation == generation_;
    }

    DecoderLifecycleState state() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return state_;
    }

    uint64_t generation() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return generation_;
    }

    std::size_t inFlightCallbacks() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return inFlightCallbacks_;
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    DecoderLifecycleState state_ = DecoderLifecycleState::Uninitialized;
    uint64_t generation_ = 0;
    std::size_t inFlightCallbacks_ = 0;
};

#endif
