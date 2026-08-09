/**
 * callback_admission_context.h - stable platform-callback admission barrier.
 *
 * Platform callback APIs retain a raw userData pointer and may deliver a late
 * callback after the native object has been detached.  This context is the
 * only value a callback may dereference first.  Each owner must close the
 * admission gate, quiesce/unregister its platform source, wait for in-flight
 * leases, and then reclaim the context. If the bounded wait expires, the
 * resource cleanup remains owned by this shared admission context and runs
 * exactly once when the final lease drains.
 */

#ifndef CALLBACK_ADMISSION_CONTEXT_H
#define CALLBACK_ADMISSION_CONTEXT_H

#include "render/video_perf_counters.h"

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <utility>

namespace Render {

class CallbackAdmissionContext : public std::enable_shared_from_this<CallbackAdmissionContext> {
public:
    struct Snapshot {
        int64_t token = 0;
        DecoderSessionIdentity owner;
        uint64_t generation = 0;
    };

    class Lease {
    public:
        Lease() = default;
        Lease(Lease&& other) noexcept
            : context_(other.context_), snapshot_(other.snapshot_),
              keepAlive_(std::move(other.keepAlive_)) {
            other.context_ = nullptr;
        }
        Lease& operator=(Lease&& other) noexcept {
            if (this != &other) {
                reset();
                context_ = other.context_;
                snapshot_ = other.snapshot_;
                keepAlive_ = std::move(other.keepAlive_);
                other.context_ = nullptr;
            }
            return *this;
        }
        Lease(const Lease&) = delete;
        Lease& operator=(const Lease&) = delete;
        ~Lease() { reset(); }

        explicit operator bool() const { return context_ != nullptr; }

        const Snapshot& snapshot() const { return snapshot_; }

        void reset() {
            if (context_ != nullptr) {
                context_->release();
                context_ = nullptr;
            }
            keepAlive_.reset();
        }

    private:
        friend class CallbackAdmissionContext;
        Lease(CallbackAdmissionContext* context, Snapshot snapshot,
              std::shared_ptr<CallbackAdmissionContext> keepAlive)
            : context_(context), snapshot_(std::move(snapshot)),
              keepAlive_(std::move(keepAlive)) {}

        CallbackAdmissionContext* context_ = nullptr;
        Snapshot snapshot_;
        std::shared_ptr<CallbackAdmissionContext> keepAlive_;
    };

    explicit CallbackAdmissionContext(const DecoderSessionIdentity& owner = {})
        : owner_(owner), generation_(owner.generation) {
        liveCount_.fetch_add(1, std::memory_order_relaxed);
    }

    ~CallbackAdmissionContext() {
        liveCount_.fetch_sub(1, std::memory_order_relaxed);
    }

    CallbackAdmissionContext(const CallbackAdmissionContext&) = delete;
    CallbackAdmissionContext& operator=(const CallbackAdmissionContext&) = delete;

    static size_t liveCount() {
        return liveCount_.load(std::memory_order_acquire);
    }

    /** Bind before the platform callback source is started. */
    bool bind(int64_t token, const DecoderSessionIdentity& owner, uint64_t generation) {
        std::lock_guard<std::mutex> lock(mutex_);
        // The session owner generation and the source/decoder generation are
        // distinct monotonic domains.  A decoder recreate may advance the
        // latter while the session remains active; binding must retain both
        // values instead of requiring them to be numerically equal.
        if (accepting_ || inFlight_ != 0 || token <= 0 || !owner.valid() ||
            generation == 0) {
            return false;
        }
        token_ = token;
        owner_ = owner;
        generation_ = generation;
        accepting_ = true;
        return true;
    }

    /** First operation in a platform callback; never touches the target object. */
    Lease tryAcquire() {
        std::lock_guard<std::mutex> lock(mutex_);
        // The owner/session generation and the decoder/source generation are
        // independent domains.  A re-created decoder may advance the source
        // generation while it is still attached to the same session owner;
        // admission must validate both as captured values, not require their
        // numeric values to match.
        if (!accepting_ || token_ <= 0 || !owner_.valid() ||
            generation_ == 0) {
            return Lease();
        }
        ++inFlight_;
        std::shared_ptr<CallbackAdmissionContext> keepAlive;
        try {
            keepAlive = shared_from_this();
        } catch (const std::bad_weak_ptr&) {
            // Stack-owned test contexts have an enclosing lifetime. Production
            // contexts are shared_ptr-owned and retain themselves in Lease.
        }
        return Lease(this, Snapshot {token_, owner_, generation_}, std::move(keepAlive));
    }

    /** Prevent new callbacks and drain admitted callbacks within a hard bound. */
    bool closeAndWait() {
        std::unique_lock<std::mutex> lock(mutex_);
        if (closeAttempted_) {
            return inFlight_ == 0;
        }
        closeAttempted_ = true;
        accepting_ = false;
        const bool drained = callbackCv_.wait_for(lock, std::chrono::milliseconds(500),
            [this]() { return inFlight_ == 0; });
        closeTimedOut_ = !drained;
        return drained;
    }

    /**
     * Retain a platform-resource cleanup until all admitted callbacks drain.
     * Returns true when cleanup ran synchronously, false when it was retained
     * for the final lease release (or an earlier cleanup already owns it).
     */
    bool deferCleanupAfterDrain(std::function<void()> cleanup) {
        if (!cleanup) {
            return true;
        }
        std::function<void()> runNow;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            accepting_ = false;
            if (cleanupScheduled_) {
                return false;
            }
            cleanupScheduled_ = true;
            if (inFlight_ == 0) {
                runNow = std::move(cleanup);
            } else {
                deferredCleanup_ = std::move(cleanup);
            }
        }
        if (runNow) {
            runNow();
            return true;
        }
        return false;
    }

#if defined(RDP_NATIVE_CALLBACK_TESTING)
    // Test-only barrier used to stop a production callback after it has
    // received platform userData but before it attempts admission. This is
    // deliberately owned by the stable context, so the test exercises the
    // same first step as OHAudio/OH_AVCodec rather than a parallel fake path.
    using BeforeAcquireHook = std::function<void()>;
    using AfterAcquireHook = std::function<void()>;

    void setBeforeAcquireHook(BeforeAcquireHook hook) {
        std::lock_guard<std::mutex> lock(mutex_);
        beforeAcquireHook_ = std::move(hook);
    }

    void invokeBeforeAcquireHookForTesting() const {
        BeforeAcquireHook hook;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            hook = beforeAcquireHook_;
        }
        if (hook) {
            hook();
        }
    }

    void setAfterAcquireHook(AfterAcquireHook hook) {
        std::lock_guard<std::mutex> lock(mutex_);
        afterAcquireHook_ = std::move(hook);
    }

    void invokeAfterAcquireHookForTesting() const {
        AfterAcquireHook hook;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            hook = afterAcquireHook_;
        }
        if (hook) {
            hook();
        }
    }
#endif

private:
    void release() {
        std::function<void()> cleanup;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (inFlight_ > 0) {
                --inFlight_;
            }
            if (inFlight_ == 0) {
                cleanup = std::move(deferredCleanup_);
                callbackCv_.notify_all();
            }
        }
        if (cleanup) {
            cleanup();
        }
    }

    mutable std::mutex mutex_;
    std::condition_variable callbackCv_;
    int64_t token_ = 0;
    DecoderSessionIdentity owner_;
    uint64_t generation_ = 0;
    size_t inFlight_ = 0;
    bool accepting_ = false;
    bool closeAttempted_ = false;
    bool closeTimedOut_ = false;
    bool cleanupScheduled_ = false;
    std::function<void()> deferredCleanup_;
    inline static std::atomic<size_t> liveCount_ {0};
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    BeforeAcquireHook beforeAcquireHook_;
    AfterAcquireHook afterAcquireHook_;
#endif
};

} // namespace Render

#endif // CALLBACK_ADMISSION_CONTEXT_H
