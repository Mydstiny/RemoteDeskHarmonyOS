/**
 * video_perf_counters.h - shared video pipeline telemetry counters
 */

#ifndef VIDEO_PERF_COUNTERS_H
#define VIDEO_PERF_COUNTERS_H

#include <cstddef>
#include <cstdint>
#include <chrono>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <utility>
#include <vector>

namespace Render {

/** Identity shared by native callback and decoder telemetry gates. */
struct DecoderSessionIdentity {
    uint64_t sessionId = 0;
    uint64_t generation = 0;
    uint64_t ownerToken = 0;

    bool valid() const {
        return sessionId != 0 && generation != 0 && ownerToken != 0;
    }

    bool operator==(const DecoderSessionIdentity& other) const {
        return sessionId == other.sessionId && generation == other.generation &&
            ownerToken == other.ownerToken;
    }

    bool operator!=(const DecoderSessionIdentity& other) const {
        return !(*this == other);
    }
};

inline bool SessionOwnerMatches(const DecoderSessionIdentity& active,
                                const DecoderSessionIdentity& candidate) {
    return active.valid() && candidate.valid() && active == candidate;
}

// A sink callback may synchronously route back through another owner-aware
// native entry (RDP rdpsnd -> AudioPlayer is one such path). Re-taking the
// same std::shared_mutex from that thread is not portable. Track only the
// exact registry instance and owner for the duration of an existing shared
// lease; a different owner or registry still takes the normal lock path.
struct SessionSinkThreadLease {
    const void* registry = nullptr;
    DecoderSessionIdentity owner;
};

inline thread_local std::vector<SessionSinkThreadLease> g_sessionSinkThreadLeases;

inline bool HasSessionSinkThreadLease(const void* registry,
                                      const DecoderSessionIdentity& owner) {
    for (auto it = g_sessionSinkThreadLeases.rbegin();
         it != g_sessionSinkThreadLeases.rend(); ++it) {
        if (it->registry == registry && it->owner == owner) {
            return true;
        }
    }
    return false;
}

inline void RegisterSessionSinkThreadLease(
    const void* registry, const DecoderSessionIdentity& owner) {
    g_sessionSinkThreadLeases.push_back(SessionSinkThreadLease {registry, owner});
}

inline void UnregisterSessionSinkThreadLease(
    const void* registry, const DecoderSessionIdentity& owner) {
    for (auto it = g_sessionSinkThreadLeases.rbegin();
         it != g_sessionSinkThreadLeases.rend(); ++it) {
        if (it->registry == registry && it->owner == owner) {
            auto eraseIt = it.base();
            --eraseIt;
            g_sessionSinkThreadLeases.erase(eraseIt);
            return;
        }
    }
}

/** Small lock-protected owner model used by callback/session race tests. */
class VideoSessionOwnerGate {
public:
    bool activate(const DecoderSessionIdentity& owner) {
        if (!owner.valid()) {
            return false;
        }
        std::lock_guard<std::mutex> lock(mutex_);
        active_ = owner;
        return true;
    }

    bool accepts(const DecoderSessionIdentity& owner) const {
        std::lock_guard<std::mutex> lock(mutex_);
        return SessionOwnerMatches(active_, owner);
    }

    bool deactivateIfActive(const DecoderSessionIdentity& owner) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!SessionOwnerMatches(active_, owner)) {
            return false;
        }
        active_ = DecoderSessionIdentity {};
        return true;
    }

    DecoderSessionIdentity snapshot() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return active_;
    }

private:
    mutable std::mutex mutex_;
    DecoderSessionIdentity active_;
};

/**
 * Shared session lease for every presentation/audio/pressure sink.
 *
 * Activation/deactivation takes the exclusive side. A sink takes a shared
 * operation lease and keeps it until its actual sink write has completed.
 * Therefore a stale S1 callback can either be rejected before the write or
 * finish against S1 before S2 is activated; it cannot pass an identity check
 * and then write S2's renderer/player.
 */
class SessionSinkOwnerLease {
public:
    class Lease {
    public:
        Lease() = default;
        Lease(Lease&& other) noexcept
            : lock_(std::move(other.lock_)), owner_(other.owner_),
              registry_(other.registry_), threadRegistered_(other.threadRegistered_),
              reentrant_(other.reentrant_) {
            other.registry_ = nullptr;
            other.threadRegistered_ = false;
            other.reentrant_ = false;
        }
        Lease& operator=(Lease&& other) noexcept {
            if (this != &other) {
                reset();
                lock_ = std::move(other.lock_);
                owner_ = other.owner_;
                registry_ = other.registry_;
                threadRegistered_ = other.threadRegistered_;
                reentrant_ = other.reentrant_;
                other.registry_ = nullptr;
                other.threadRegistered_ = false;
                other.reentrant_ = false;
            }
            return *this;
        }
        Lease(const Lease&) = delete;
        Lease& operator=(const Lease&) = delete;
        ~Lease() { reset(); }

        explicit operator bool() const {
            return threadRegistered_ && (lock_.owns_lock() || reentrant_);
        }

        const DecoderSessionIdentity& owner() const {
            return owner_;
        }

        void release() {
            reset();
        }

    private:
        friend class SessionSinkOwnerLease;

        Lease(std::shared_lock<std::shared_mutex>&& lock, const void* registry,
              const DecoderSessionIdentity& owner)
            : lock_(std::move(lock)), owner_(owner), registry_(registry),
              threadRegistered_(true) {
            RegisterSessionSinkThreadLease(registry_, owner_);
        }

        Lease(const void* registry, const DecoderSessionIdentity& owner,
              bool reentrant)
            : owner_(owner), registry_(registry), threadRegistered_(true),
              reentrant_(reentrant) {
            RegisterSessionSinkThreadLease(registry_, owner_);
        }

        void reset() {
            if (lock_.owns_lock()) {
                lock_.unlock();
            }
            if (threadRegistered_) {
                UnregisterSessionSinkThreadLease(registry_, owner_);
                threadRegistered_ = false;
            }
            registry_ = nullptr;
            reentrant_ = false;
        }

        std::shared_lock<std::shared_mutex> lock_;
        DecoderSessionIdentity owner_;
        const void* registry_ = nullptr;
        bool threadRegistered_ = false;
        bool reentrant_ = false;
    };

    class ExclusiveLease {
    public:
        ExclusiveLease() = default;
        ExclusiveLease(ExclusiveLease&&) = default;
        ExclusiveLease& operator=(ExclusiveLease&&) = default;
        ExclusiveLease(const ExclusiveLease&) = delete;
        ExclusiveLease& operator=(const ExclusiveLease&) = delete;

        explicit operator bool() const {
            return lock_.owns_lock();
        }

        bool activate(const DecoderSessionIdentity& owner) {
            if (!lock_.owns_lock() || !owner.valid() || registry_ == nullptr) {
                return false;
            }
            registry_->active_ = owner;
            registry_->ready_ = true;
            return true;
        }

        bool beginActivate(const DecoderSessionIdentity& owner) {
            if (!lock_.owns_lock() || !owner.valid() || registry_ == nullptr) {
                return false;
            }
            if (registry_->active_.valid() &&
                !SessionOwnerMatches(registry_->active_, owner)) {
                return false;
            }
            registry_->active_ = owner;
            registry_->ready_ = false;
            return true;
        }

        bool commit(const DecoderSessionIdentity& owner) {
            if (!lock_.owns_lock() || registry_ == nullptr ||
                !SessionOwnerMatches(registry_->active_, owner)) {
                return false;
            }
            registry_->ready_ = true;
            return true;
        }

        bool beginDeactivate(const DecoderSessionIdentity& owner) {
            if (!lock_.owns_lock() || registry_ == nullptr ||
                !SessionOwnerMatches(registry_->active_, owner)) {
                return false;
            }
            registry_->active_ = DecoderSessionIdentity {};
            registry_->ready_ = false;
            return true;
        }

        bool accepts(const DecoderSessionIdentity& owner) const {
            return lock_.owns_lock() && registry_ != nullptr &&
                registry_->ready_ && SessionOwnerMatches(registry_->active_, owner);
        }

        bool deactivateIfActive(const DecoderSessionIdentity& owner) {
            if (!lock_.owns_lock() || registry_ == nullptr ||
                !SessionOwnerMatches(registry_->active_, owner)) {
                return false;
            }
            registry_->active_ = DecoderSessionIdentity {};
            registry_->ready_ = false;
            return true;
        }

        DecoderSessionIdentity snapshot() const {
            return registry_ != nullptr && registry_->ready_ ?
                registry_->active_ : DecoderSessionIdentity {};
        }

        /** Return the transition owner even while a two-phase activation is pending. */
        DecoderSessionIdentity activeSnapshot() const {
            return registry_ != nullptr ? registry_->active_ : DecoderSessionIdentity {};
        }

    private:
        friend class SessionSinkOwnerLease;

        explicit ExclusiveLease(std::unique_lock<std::shared_mutex>&& lock,
                                SessionSinkOwnerLease& registry)
            : lock_(std::move(lock)), registry_(&registry) {}

        std::unique_lock<std::shared_mutex> lock_;
        SessionSinkOwnerLease* registry_ = nullptr;
    };

    ExclusiveLease acquireExclusive() {
        return ExclusiveLease(std::unique_lock<std::shared_mutex>(mutex_), *this);
    }

    ExclusiveLease tryAcquireExclusive() {
        return ExclusiveLease(
            std::unique_lock<std::shared_mutex>(mutex_, std::try_to_lock), *this);
    }

    bool activate(const DecoderSessionIdentity& owner) {
        auto lock = acquireExclusive();
        return lock.activate(owner);
    }

    bool accepts(const DecoderSessionIdentity& owner) const {
        if (HasSessionSinkThreadLease(this, owner)) {
            return true;
        }
        std::shared_lock<std::shared_mutex> lock(mutex_);
        return ready_ && SessionOwnerMatches(active_, owner);
    }

    Lease acquire(const DecoderSessionIdentity& owner) const {
        if (!owner.valid()) {
            return Lease();
        }
        if (HasSessionSinkThreadLease(this, owner)) {
            return Lease(this, owner, true);
        }
        std::shared_lock<std::shared_mutex> lock(mutex_);
        if (!ready_ || !SessionOwnerMatches(active_, owner)) {
            return Lease();
        }
        return Lease(std::move(lock), this, owner);
    }

    bool deactivateIfActive(const DecoderSessionIdentity& owner) {
        auto lock = acquireExclusive();
        return lock.deactivateIfActive(owner);
    }

    DecoderSessionIdentity snapshot() const {
        std::shared_lock<std::shared_mutex> lock(mutex_);
        return ready_ ? active_ : DecoderSessionIdentity {};
    }

private:
    mutable std::shared_mutex mutex_;
    DecoderSessionIdentity active_;
    bool ready_ = false;
};

/** Process-wide registry; identity, not an adapter pointer, is the owner key. */
SessionSinkOwnerLease& SharedSessionSinkOwnerLease();

/**
 * Serializes the complete activation transaction across all native sinks.
 * The lease is deliberately separate from the owner shared_mutex: component
 * publication happens without holding the owner lease, but a second
 * begin/publish/commit cannot interleave with the first transaction.
 */
class SessionActivationTransaction {
public:
    class Lease {
    public:
        Lease() = default;
        Lease(Lease&&) = default;
        Lease& operator=(Lease&&) = default;
        Lease(const Lease&) = delete;
        Lease& operator=(const Lease&) = delete;

        explicit operator bool() const { return lock_.owns_lock(); }

    private:
        friend class SessionActivationTransaction;
        explicit Lease(std::unique_lock<std::mutex>&& lock)
            : lock_(std::move(lock)) {}
        std::unique_lock<std::mutex> lock_;
    };

    Lease acquire() {
        return Lease(std::unique_lock<std::mutex>(mutex_));
    }

private:
    std::mutex mutex_;
};

SessionActivationTransaction& SharedSessionActivationTransaction();

enum class VideoPressureLevel {
    Normal = 0,
    Mild = 1,
    Moderate = 2,
    Severe = 3,
};

struct VideoPerfSnapshot {
    std::string source;
    uint64_t ingressFrames = 0;
    uint64_t decodeOk = 0;
    uint64_t decodeNotReady = 0;
    uint64_t decodeBadCodec = 0;
    uint64_t decodeOther = 0;
    uint64_t decodeErrors = 0;
    uint64_t inputDropsDelta = 0;
    uint64_t waitKeyframeDropsDelta = 0;
    uint64_t decodeDrops = 0;
    uint64_t decodeDropsTotal = 0;
    uint64_t dropCounterGeneration = 0;
    uint64_t dropCounterResets = 0;
    uint64_t decodeMismatch = 0;
    uint64_t decodeSamples = 0;
    uint64_t renderFrames = 0;
    uint64_t keyframes = 0;
    size_t decodeQueueMax = 0;
    int width = 0;
    int height = 0;
    uint64_t bytesTotal = 0;
    int64_t uploadMaxUs = 0;
    int64_t drawMaxUs = 0;
    int64_t swapMaxUs = 0;
    int64_t renderTotalMaxUs = 0;
};

struct VideoDropSample {
    uint64_t counterGeneration = 0;
    uint64_t inputDropped = 0;
    uint64_t waitKeyframeDropped = 0;
};

class VideoPerfCounters {
public:
    void recordIngressFrame(const char* source, int width, int height, size_t bytes, bool keyframe);
    void recordDecodeResult(int ret, size_t queueDepth, uint64_t inputDropped,
                            uint64_t waitDrops, uint64_t counterGeneration = 0);
    void recordRenderCostUs(int64_t uploadUs, int64_t drawUs, int64_t swapUs, int64_t totalUs);
    VideoPerfSnapshot snapshot() const;
    VideoPerfSnapshot snapshotAndReset();
    void reset();

private:
    mutable std::mutex mutex_;
    VideoPerfSnapshot current_;
    bool dropBaselineInitialized_ = false;
    uint64_t lastDropCounterGeneration_ = 0;
    uint64_t effectiveDropCounterGeneration_ = 0;
    uint64_t lastDroppedTotal_ = 0;
    uint64_t lastWaitDropsTotal_ = 0;
};

struct VideoPressureDecision {
    VideoPressureLevel level = VideoPressureLevel::Normal;
    bool changed = false;
    bool windowComplete = false;
    bool hasTelemetry = false;
    bool timedOut = false;
};

/**
 * Session-owned pressure state machine.
 *
 * VideoPerfCounters supplies per-window samples. This class is deliberately
 * separate from the Rust stream loop so only this native/session owner makes
 * hysteresis decisions; Rust only applies the reported level to its stream
 * options.
 */
class VideoPressureController {
public:
    explicit VideoPressureController(uint32_t overloadWindowsToEscalate = 5,
                                     uint32_t cleanWindowsToRecover = 3,
                                     std::chrono::milliseconds windowDuration =
                                         std::chrono::milliseconds(1000),
                                     std::chrono::milliseconds telemetryTimeout =
                                         std::chrono::milliseconds(2500));

    VideoPressureLevel observe(const VideoPerfSnapshot& snapshot);
    VideoPressureDecision observeAt(
        const VideoPerfSnapshot& snapshot,
        std::chrono::steady_clock::time_point now,
        bool escalateImmediately = false);
    VideoPressureDecision tick(std::chrono::steady_clock::time_point now);
    bool windowDue(std::chrono::steady_clock::time_point now) const;
    VideoPressureLevel level() const;
    VideoPerfSnapshot lastSnapshot() const;
    uint64_t lastDropDelta() const;
    bool timedOut() const;
    void reset();

private:
    mutable std::mutex mutex_;
    VideoPressureLevel level_ = VideoPressureLevel::Normal;
    uint32_t overloadWindows_ = 0;
    uint32_t cleanWindows_ = 0;
    uint32_t overloadWindowsToEscalate_ = 5;
    uint32_t cleanWindowsToRecover_ = 3;
    std::chrono::milliseconds windowDuration_ {1000};
    std::chrono::milliseconds minimumResidency_ {1000};
    std::chrono::milliseconds telemetryTimeout_ {2500};
    bool clockInitialized_ = false;
    bool telemetrySeen_ = false;
    bool timedOut_ = false;
    std::chrono::steady_clock::time_point windowStartedAt_ {};
    std::chrono::steady_clock::time_point lastTelemetryAt_ {};
    std::chrono::steady_clock::time_point levelEnteredAt_ {};
    VideoPerfSnapshot lastSnapshot_;
};

VideoPressureLevel classifyVideoPressure(const VideoPerfSnapshot& snapshot);
const char* videoPressureName(VideoPressureLevel level);

} // namespace Render

#endif // VIDEO_PERF_COUNTERS_H
