#ifndef REMOTEDESK_MOONLIGHT_SESSION_OWNER_H
#define REMOTEDESK_MOONLIGHT_SESSION_OWNER_H

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>

#if defined(__GNUC__)
#define REMOTEDESK_MOONLIGHT_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_HIDDEN
#endif

namespace remotedesk::moonlight {

struct REMOTEDESK_MOONLIGHT_HIDDEN MoonlightSessionKey final {
    std::uint64_t sessionId = 0;
    std::uint64_t generation = 0;
    std::uint64_t ownerToken = 0;

    constexpr bool valid() const noexcept {
        return sessionId != 0 && generation != 0 && ownerToken != 0;
    }
};

REMOTEDESK_MOONLIGHT_HIDDEN constexpr bool operator==(
    const MoonlightSessionKey& left,
    const MoonlightSessionKey& right) noexcept {
    return left.sessionId == right.sessionId &&
           left.generation == right.generation &&
           left.ownerToken == right.ownerToken;
}

REMOTEDESK_MOONLIGHT_HIDDEN constexpr bool operator!=(
    const MoonlightSessionKey& left,
    const MoonlightSessionKey& right) noexcept {
    return !(left == right);
}

enum class MoonlightSessionPhase : std::uint8_t {
    Idle = 0,
    Starting,
    Running,
    Stopping,
    Stopped,
    Failed,
};

enum class MoonlightStartStatus : std::uint8_t {
    Accepted = 0,
    InvalidRequest,
    InvalidDriver,
    Busy,
    OwnerTokenExhausted,
    ShuttingDown,
};

enum class MoonlightStopStatus : std::uint8_t {
    Stopped = 0,
    AlreadyTerminal,
    InvalidKey,
    StaleOwner,
    TimedOut,
    DriverFailure,
    StopRequested,
};

enum class MoonlightDriverFailure : std::uint8_t {
    None = 0,
    StartException,
    InterruptException,
    StopException,
};

enum class MoonlightLeaseKind : std::uint8_t {
    Callback = 0,
    Worker,
};

struct REMOTEDESK_MOONLIGHT_HIDDEN MoonlightSessionSnapshot final {
    bool matched = false;
    MoonlightSessionKey key {};
    MoonlightSessionPhase phase = MoonlightSessionPhase::Idle;
    bool cancellationRequested = false;
    bool admissionOpen = false;
    bool startInvoked = false;
    bool startInterruptible = false;
    bool startReturned = false;
    bool interruptInvoked = false;
    bool stopInvoked = false;
    bool stopCompleted = false;
    std::size_t inFlightCallbacks = 0;
    std::size_t inFlightWorkers = 0;
    int startResult = 0;
    MoonlightDriverFailure driverFailure = MoonlightDriverFailure::None;
};

struct REMOTEDESK_MOONLIGHT_HIDDEN MoonlightStartResult final {
    MoonlightStartStatus status = MoonlightStartStatus::InvalidRequest;
    MoonlightSessionKey key {};
};

// Owns the sole process-wide common-c operation lane. Product callers can only
// obtain the process instance; native tests receive an isolated instance behind
// the existing test-only compile definition.
class REMOTEDESK_MOONLIGHT_HIDDEN MoonlightSessionOwner final {
private:
    struct State;
    struct Impl;

public:
    class REMOTEDESK_MOONLIGHT_HIDDEN StartContext final {
    public:
        StartContext(const StartContext&) = delete;
        StartContext& operator=(const StartContext&) = delete;

        const MoonlightSessionKey& key() const noexcept;
        bool cancellationRequested() const noexcept;

        // The future common-c bridge calls this from the first stage callback,
        // after common-c has initialized its interrupt flag. A pending cancel
        // then invokes interrupt exactly once without the pre-start lost-cancel
        // race described by LiInterruptConnection().
        bool markInterruptible() noexcept;

    private:
        friend class MoonlightSessionOwner;
        StartContext(MoonlightSessionOwner* owner,
                     std::shared_ptr<State> state) noexcept;

        MoonlightSessionOwner* owner_ = nullptr;
        std::shared_ptr<State> state_;
    };

    struct Driver final {
        std::function<int(StartContext&)> start;
        std::function<void()> interrupt;
        std::function<void()> stop;

        bool valid() const noexcept {
            return static_cast<bool>(start) &&
                   static_cast<bool>(interrupt) &&
                   static_cast<bool>(stop);
        }
    };

    class REMOTEDESK_MOONLIGHT_HIDDEN AdmissionLease final {
    public:
        AdmissionLease() noexcept = default;
        ~AdmissionLease();

        AdmissionLease(const AdmissionLease&) = delete;
        AdmissionLease& operator=(const AdmissionLease&) = delete;
        AdmissionLease(AdmissionLease&& other) noexcept;
        AdmissionLease& operator=(AdmissionLease&& other) noexcept;

        bool valid() const noexcept;
        MoonlightLeaseKind kind() const noexcept;
        MoonlightSessionKey key() const noexcept;
        void reset() noexcept;

    private:
        friend class MoonlightSessionOwner;
        AdmissionLease(MoonlightSessionOwner* owner,
                       std::shared_ptr<State> state,
                       MoonlightLeaseKind kind) noexcept;

        MoonlightSessionOwner* owner_ = nullptr;
        std::shared_ptr<State> state_;
        MoonlightLeaseKind kind_ = MoonlightLeaseKind::Callback;
    };

    static MoonlightSessionOwner& process();

#if defined(RDP_NATIVE_CALLBACK_TESTING)
    static std::unique_ptr<MoonlightSessionOwner> createForTesting();
#endif

    ~MoonlightSessionOwner();
    MoonlightSessionOwner(const MoonlightSessionOwner&) = delete;
    MoonlightSessionOwner& operator=(const MoonlightSessionOwner&) = delete;

    MoonlightStartResult start(std::uint64_t sessionId,
                               std::uint64_t generation,
                               Driver driver);
    // Closes admission and schedules the exact owner's interrupt/stop path,
    // but never waits for start, callbacks, workers, or driver.stop to drain.
    MoonlightStopStatus requestStop(const MoonlightSessionKey& key) noexcept;
    MoonlightStopStatus stop(
        const MoonlightSessionKey& key,
        std::chrono::milliseconds timeout = std::chrono::seconds(5));

    AdmissionLease acquireCallback(const MoonlightSessionKey& key) noexcept;
    AdmissionLease acquireWorker(const MoonlightSessionKey& key) noexcept;
    MoonlightSessionSnapshot snapshot(const MoonlightSessionKey& key) const noexcept;
    bool waitForPhase(const MoonlightSessionKey& key,
                      MoonlightSessionPhase phase,
                      std::chrono::milliseconds timeout) const noexcept;

private:
    MoonlightSessionOwner();

    bool cancellationRequested(const std::shared_ptr<State>& state) const noexcept;
    bool markStartInterruptible(const std::shared_ptr<State>& state) noexcept;
    MoonlightStopStatus requestStopInternal(
        const MoonlightSessionKey& key,
        std::shared_ptr<State>& state) noexcept;
    void invokeInterrupt(const std::shared_ptr<State>& state) noexcept;
    void releaseAdmission(const std::shared_ptr<State>& state,
                          MoonlightLeaseKind kind) noexcept;
    AdmissionLease acquire(const MoonlightSessionKey& key,
                           MoonlightLeaseKind kind) noexcept;
    void workerLoop() noexcept;
    void runStart(const std::shared_ptr<State>& state) noexcept;
    void runStop(const std::shared_ptr<State>& state) noexcept;
    MoonlightSessionSnapshot snapshotLocked(
        const MoonlightSessionKey& key) const noexcept;
    MoonlightSessionSnapshot snapshotStateLocked(
        const std::shared_ptr<State>& state) const noexcept;
    void reapActiveLocked(const std::shared_ptr<State>& state) noexcept;

    std::unique_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_SESSION_OWNER_H
