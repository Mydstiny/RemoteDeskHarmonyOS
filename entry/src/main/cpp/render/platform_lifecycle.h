/**
 * platform_lifecycle.h - serialized native platform-resource lifecycle.
 *
 * The lifecycle mutex protects state only. Platform calls run after the
 * transition has been reserved, so Destroy can invalidate an in-flight Init
 * without holding a lock that a platform callback may re-enter. Init owns
 * every resource it has created until completion publishes it.
 */

#ifndef PLATFORM_LIFECYCLE_H
#define PLATFORM_LIFECYCLE_H

#include <condition_variable>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <thread>

namespace Render {

class PlatformLifecycle {
public:
    enum class State {
        IDLE,
        INITIALIZING,
        READY,
        FAILED,
        DESTROYING,
        DESTROYED,
    };

    struct InitToken {
        uint64_t epoch = 0;
        bool valid = false;
    };

    struct DestroyToken {
        uint64_t epoch = 0;
        bool valid = false;
        bool deferredToInitOwner = false;
    };

    enum class InitCompletion {
        Published,
        Failed,
        DestroyRequested,
        DestroyDeferredToInitOwner,
    };

    InitToken beginInit() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (state_ != State::IDLE && state_ != State::FAILED) {
            return InitToken {};
        }
        ++epoch_;
        initEpoch_ = epoch_;
        state_ = State::INITIALIZING;
        initInFlight_ = true;
        initThread_ = std::this_thread::get_id();
        return InitToken {epoch_, true};
    }

    /**
     * Complete Init after all platform calls and local cleanup decisions.
     * The caller must publish only when this returns Published.
     */
    InitCompletion completeInit(const InitToken& token, bool platformReady) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!token.valid || !initInFlight_ || token.epoch != initEpoch_) {
            return InitCompletion::Failed;
        }
        initInFlight_ = false;
        initThread_ = std::thread::id {};
        if (destroyRequested_ || state_ != State::INITIALIZING) {
            state_ = State::DESTROYING;
            cv_.notify_all();
            const bool initOwnsDestroy =
                destroyThread_ == std::this_thread::get_id() || destroyOwnerAbandoned_;
            if (initOwnsDestroy) {
                destroyThread_ = std::this_thread::get_id();
            }
            return initOwnsDestroy ? InitCompletion::DestroyDeferredToInitOwner :
                InitCompletion::DestroyRequested;
        }
        state_ = platformReady ? State::READY : State::FAILED;
        cv_.notify_all();
        return platformReady ? InitCompletion::Published : InitCompletion::Failed;
    }

    /** Begin destruction without holding any lifecycle lock over callbacks. */
    DestroyToken beginDestroy() {
        std::unique_lock<std::mutex> lock(mutex_);
        const auto currentThread = std::this_thread::get_id();
        if (state_ == State::DESTROYED) {
            return DestroyToken {};
        }
        if (state_ == State::DESTROYING) {
            if (destroyThread_ == currentThread) {
                return DestroyToken {};
            }
            // A second destroy caller must not become an unbounded joiner.
            // The first owner remains responsible for completing the
            // transition; this caller fails closed after the bounded handoff
            // window.
            (void)cv_.wait_for(lock, std::chrono::milliseconds(500),
                [this]() { return state_ == State::DESTROYED; });
            return DestroyToken {};
        }
        ++epoch_;
        destroyRequested_ = true;
        destroyOwnerAbandoned_ = false;
        destroyThread_ = currentThread;
        state_ = State::DESTROYING;
        if (initInFlight_) {
            if (initThread_ == currentThread) {
                return DestroyToken {epoch_, true, true};
            }
        }
        return DestroyToken {epoch_, true, false};
    }

    /** Wait for a different thread's platform Init after callback admission is closed. */
    bool waitForInit(const DestroyToken& token) {
        if (!token.valid || token.deferredToInitOwner) {
            return true;
        }
        std::unique_lock<std::mutex> lock(mutex_);
        const bool completed = cv_.wait_for(lock, std::chrono::milliseconds(500),
            [this]() { return !initInFlight_; });
        if (!completed) {
            // The Init owner becomes the safe cleanup owner after this
            // bounded handoff expires. It must release its local platform
            // resources and complete the terminal transition.
            destroyOwnerAbandoned_ = true;
            cv_.notify_all();
        }
        return completed;
    }

    /** Complete destruction after the caller has released platform objects. */
    bool finishDestroy(const DestroyToken& token) {
        std::unique_lock<std::mutex> lock(mutex_);
        if (!token.valid || state_ != State::DESTROYING) {
            return false;
        }
        if (!cv_.wait_for(lock, std::chrono::milliseconds(500),
                [this]() { return !initInFlight_; })) {
            return false;
        }
        if (state_ != State::DESTROYING) {
            return false;
        }
        state_ = State::DESTROYED;
        destroyThread_ = std::thread::id {};
        cv_.notify_all();
        return true;
    }

    bool finishDeferredDestroy() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (state_ != State::DESTROYING ||
            (destroyThread_ != std::this_thread::get_id() && !destroyOwnerAbandoned_)) {
            return false;
        }
        destroyThread_ = std::this_thread::get_id();
        state_ = State::DESTROYED;
        destroyThread_ = std::thread::id {};
        cv_.notify_all();
        return true;
    }

    State state() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return state_;
    }

    bool destroyRequested() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return destroyRequested_;
    }

    uint64_t currentEpoch() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return epoch_;
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    State state_ = State::IDLE;
    uint64_t epoch_ = 0;
    uint64_t initEpoch_ = 0;
    bool initInFlight_ = false;
    bool destroyRequested_ = false;
    bool destroyOwnerAbandoned_ = false;
    std::thread::id initThread_;
    std::thread::id destroyThread_;
};

} // namespace Render

#endif // PLATFORM_LIFECYCLE_H
