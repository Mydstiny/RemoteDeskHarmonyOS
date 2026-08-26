#include "moonlight/core/MoonlightSessionOwner.h"

#include <condition_variable>
#include <limits>
#include <mutex>
#include <thread>
#include <utility>

namespace remotedesk::moonlight {
namespace {

constexpr int kStartNotRun = std::numeric_limits<int>::min();

bool isTerminal(MoonlightSessionPhase phase) noexcept {
    return phase == MoonlightSessionPhase::Stopped ||
           phase == MoonlightSessionPhase::Failed;
}

} // namespace

struct MoonlightSessionOwner::State final {
    State(MoonlightSessionKey valueKey, Driver valueDriver)
        : key(valueKey), driver(std::move(valueDriver)) {}

    const MoonlightSessionKey key;
    const Driver driver;
    MoonlightSessionPhase phase = MoonlightSessionPhase::Starting;
    bool cancellationRequested = false;
    bool admissionOpen = true;
    bool startInvoked = false;
    bool startInterruptible = false;
    bool startReturned = false;
    bool interruptInvoked = false;
    bool stopScheduled = false;
    bool stopInvoked = false;
    bool stopCompleted = false;
    std::size_t callbackLeases = 0;
    std::size_t workerLeases = 0;
    std::size_t controlOperations = 0;
    int startResult = kStartNotRun;
    MoonlightDriverFailure driverFailure = MoonlightDriverFailure::None;
};

struct MoonlightSessionOwner::Impl final {
    mutable std::mutex mutex;
    mutable std::condition_variable stateCv;
    std::condition_variable workerCv;
    std::shared_ptr<State> active;
    std::shared_ptr<State> pendingStart;
    std::shared_ptr<State> pendingStop;
    MoonlightSessionSnapshot lastTerminal;
    std::uint64_t nextOwnerToken = 1;
    bool shuttingDown = false;
    std::thread worker;
};

MoonlightSessionOwner::StartContext::StartContext(
    MoonlightSessionOwner* owner,
    std::shared_ptr<State> state) noexcept
    : owner_(owner), state_(std::move(state)) {}

const MoonlightSessionKey& MoonlightSessionOwner::StartContext::key() const noexcept {
    return state_->key;
}

bool MoonlightSessionOwner::StartContext::cancellationRequested() const noexcept {
    return owner_ != nullptr && owner_->cancellationRequested(state_);
}

bool MoonlightSessionOwner::StartContext::markInterruptible() noexcept {
    return owner_ != nullptr && owner_->markStartInterruptible(state_);
}

MoonlightSessionOwner::AdmissionLease::AdmissionLease(
    MoonlightSessionOwner* owner,
    std::shared_ptr<State> state,
    MoonlightLeaseKind kind) noexcept
    : owner_(owner), state_(std::move(state)), kind_(kind) {}

MoonlightSessionOwner::AdmissionLease::~AdmissionLease() {
    reset();
}

MoonlightSessionOwner::AdmissionLease::AdmissionLease(
    AdmissionLease&& other) noexcept
    : owner_(other.owner_), state_(std::move(other.state_)), kind_(other.kind_) {
    other.owner_ = nullptr;
}

MoonlightSessionOwner::AdmissionLease&
MoonlightSessionOwner::AdmissionLease::operator=(AdmissionLease&& other) noexcept {
    if (this != &other) {
        reset();
        owner_ = other.owner_;
        state_ = std::move(other.state_);
        kind_ = other.kind_;
        other.owner_ = nullptr;
    }
    return *this;
}

bool MoonlightSessionOwner::AdmissionLease::valid() const noexcept {
    return owner_ != nullptr && state_ != nullptr;
}

MoonlightLeaseKind MoonlightSessionOwner::AdmissionLease::kind() const noexcept {
    return kind_;
}

MoonlightSessionKey MoonlightSessionOwner::AdmissionLease::key() const noexcept {
    return state_ == nullptr ? MoonlightSessionKey {} : state_->key;
}

void MoonlightSessionOwner::AdmissionLease::reset() noexcept {
    if (owner_ != nullptr && state_ != nullptr) {
        owner_->releaseAdmission(state_, kind_);
    }
    owner_ = nullptr;
    state_.reset();
}

MoonlightSessionOwner& MoonlightSessionOwner::process() {
    static MoonlightSessionOwner instance;
    return instance;
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
std::unique_ptr<MoonlightSessionOwner> MoonlightSessionOwner::createForTesting() {
    return std::unique_ptr<MoonlightSessionOwner>(new MoonlightSessionOwner());
}
#endif

MoonlightSessionOwner::MoonlightSessionOwner() : impl_(std::make_unique<Impl>()) {
    impl_->worker = std::thread([this]() { workerLoop(); });
}

MoonlightSessionOwner::~MoonlightSessionOwner() {
    MoonlightSessionKey activeKey;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (impl_->active != nullptr) {
            activeKey = impl_->active->key;
        }
    }
    if (activeKey.valid()) {
        (void)stop(activeKey, std::chrono::seconds(5));
    }

    {
        std::unique_lock<std::mutex> lock(impl_->mutex);
        // A coordinator cannot be destroyed while callback/worker leases or a
        // driver operation still own it. Waiting is deliberate: detaching here
        // would turn a teardown bug into a use-after-free in a late callback.
        impl_->stateCv.wait(lock, [this]() { return impl_->active == nullptr; });
        impl_->shuttingDown = true;
    }
    impl_->workerCv.notify_all();
    if (impl_->worker.joinable()) {
        impl_->worker.join();
    }
}

MoonlightStartResult MoonlightSessionOwner::start(std::uint64_t sessionId,
                                                   std::uint64_t generation,
                                                   Driver driver) {
    if (sessionId == 0 || generation == 0) {
        return {MoonlightStartStatus::InvalidRequest, {}};
    }
    if (!driver.valid()) {
        return {MoonlightStartStatus::InvalidDriver, {}};
    }

    std::shared_ptr<State> state;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (impl_->shuttingDown) {
            return {MoonlightStartStatus::ShuttingDown, {}};
        }
        if (impl_->active != nullptr) {
            reapActiveLocked(impl_->active);
        }
        if (impl_->active != nullptr) {
            return {MoonlightStartStatus::Busy, {}};
        }
        if (impl_->nextOwnerToken == 0) {
            return {MoonlightStartStatus::OwnerTokenExhausted, {}};
        }

        const MoonlightSessionKey key {
            sessionId,
            generation,
            impl_->nextOwnerToken++,
        };
        state = std::make_shared<State>(key, std::move(driver));
        impl_->active = state;
        impl_->pendingStart = state;
    }
    impl_->workerCv.notify_one();
    return {MoonlightStartStatus::Accepted, state->key};
}

MoonlightStopStatus MoonlightSessionOwner::requestStop(
    const MoonlightSessionKey& key) noexcept {
    std::shared_ptr<State> state;
    return requestStopInternal(key, state);
}

MoonlightStopStatus MoonlightSessionOwner::requestStopInternal(
    const MoonlightSessionKey& key,
    std::shared_ptr<State>& state) noexcept {
    if (!key.valid()) {
        return MoonlightStopStatus::InvalidKey;
    }

    bool invokeInterruptNow = false;
    try {
        {
            std::lock_guard<std::mutex> lock(impl_->mutex);
            state = impl_->active;
            if (state == nullptr) {
                if (impl_->lastTerminal.matched && impl_->lastTerminal.key == key) {
                    return impl_->lastTerminal.driverFailure == MoonlightDriverFailure::None
                               ? MoonlightStopStatus::AlreadyTerminal
                               : MoonlightStopStatus::DriverFailure;
                }
                return MoonlightStopStatus::StaleOwner;
            }
            if (state->key != key) {
                state.reset();
                return MoonlightStopStatus::StaleOwner;
            }
            if (isTerminal(state->phase)) {
                const auto result = state->driverFailure == MoonlightDriverFailure::None
                                        ? MoonlightStopStatus::AlreadyTerminal
                                        : MoonlightStopStatus::DriverFailure;
                reapActiveLocked(state);
                return result;
            }

            state->cancellationRequested = true;
            state->admissionOpen = false;
            if (state->phase == MoonlightSessionPhase::Starting) {
                state->phase = MoonlightSessionPhase::Stopping;
                if (state->startInvoked && state->startInterruptible &&
                    !state->startReturned && !state->interruptInvoked) {
                    state->interruptInvoked = true;
                    ++state->controlOperations;
                    invokeInterruptNow = true;
                }
            } else if (state->phase == MoonlightSessionPhase::Running) {
                state->phase = MoonlightSessionPhase::Stopping;
                if (!state->stopScheduled) {
                    state->stopScheduled = true;
                    impl_->pendingStop = state;
                }
            }
            impl_->stateCv.notify_all();
        }

        if (invokeInterruptNow) {
            invokeInterrupt(state);
        }
        impl_->workerCv.notify_all();
        return MoonlightStopStatus::StopRequested;
    } catch (...) {
        state.reset();
        return MoonlightStopStatus::DriverFailure;
    }
}

MoonlightStopStatus MoonlightSessionOwner::stop(
    const MoonlightSessionKey& key,
    std::chrono::milliseconds timeout) {
    std::shared_ptr<State> state;
    const auto requestStatus = requestStopInternal(key, state);
    if (requestStatus != MoonlightStopStatus::StopRequested) {
        return requestStatus;
    }

    const auto boundedTimeout = timeout < std::chrono::milliseconds::zero()
                                    ? std::chrono::milliseconds::zero()
                                    : timeout;
    const auto deadline = std::chrono::steady_clock::now() + boundedTimeout;
    std::unique_lock<std::mutex> lock(impl_->mutex);
    const bool terminal = impl_->stateCv.wait_until(lock, deadline, [&]() {
        return isTerminal(state->phase);
    });
    if (!terminal) {
        return MoonlightStopStatus::TimedOut;
    }
    const auto result = state->driverFailure == MoonlightDriverFailure::None
                            ? MoonlightStopStatus::Stopped
                            : MoonlightStopStatus::DriverFailure;
    reapActiveLocked(state);
    return result;
}

MoonlightSessionOwner::AdmissionLease MoonlightSessionOwner::acquireCallback(
    const MoonlightSessionKey& key) noexcept {
    return acquire(key, MoonlightLeaseKind::Callback);
}

MoonlightSessionOwner::AdmissionLease MoonlightSessionOwner::acquireWorker(
    const MoonlightSessionKey& key) noexcept {
    return acquire(key, MoonlightLeaseKind::Worker);
}

MoonlightSessionOwner::AdmissionLease MoonlightSessionOwner::acquire(
    const MoonlightSessionKey& key,
    MoonlightLeaseKind kind) noexcept {
    if (!key.valid()) {
        return {};
    }
    try {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        const auto& state = impl_->active;
        if (state == nullptr || state->key != key || !state->admissionOpen ||
            (state->phase != MoonlightSessionPhase::Starting &&
             state->phase != MoonlightSessionPhase::Running)) {
            return {};
        }
        if (kind == MoonlightLeaseKind::Callback) {
            ++state->callbackLeases;
        } else {
            ++state->workerLeases;
        }
        return AdmissionLease(this, state, kind);
    } catch (...) {
        return {};
    }
}

void MoonlightSessionOwner::releaseAdmission(
    const std::shared_ptr<State>& state,
    MoonlightLeaseKind kind) noexcept {
    try {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (kind == MoonlightLeaseKind::Callback) {
            if (state->callbackLeases != 0) {
                --state->callbackLeases;
            }
        } else if (state->workerLeases != 0) {
            --state->workerLeases;
        }
        reapActiveLocked(state);
        impl_->stateCv.notify_all();
    } catch (...) {
        // Destructors cannot report through NAPI and must never throw. Exact
        // counters remain fail-closed if the platform mutex itself fails.
    }
}

bool MoonlightSessionOwner::cancellationRequested(
    const std::shared_ptr<State>& state) const noexcept {
    try {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        return state != nullptr && state->cancellationRequested;
    } catch (...) {
        return true;
    }
}

bool MoonlightSessionOwner::markStartInterruptible(
    const std::shared_ptr<State>& state) noexcept {
    bool invoke = false;
    try {
        {
            std::lock_guard<std::mutex> lock(impl_->mutex);
            if (state == nullptr || impl_->active != state ||
                !state->startInvoked || state->startReturned ||
                (state->phase != MoonlightSessionPhase::Starting &&
                 state->phase != MoonlightSessionPhase::Stopping)) {
                return false;
            }
            state->startInterruptible = true;
            if (state->cancellationRequested && !state->interruptInvoked) {
                state->interruptInvoked = true;
                ++state->controlOperations;
                invoke = true;
            }
            impl_->stateCv.notify_all();
        }
        if (invoke) {
            invokeInterrupt(state);
        }
        return true;
    } catch (...) {
        return false;
    }
}

void MoonlightSessionOwner::invokeInterrupt(
    const std::shared_ptr<State>& state) noexcept {
    bool threw = false;
    try {
        state->driver.interrupt();
    } catch (...) {
        threw = true;
    }

    try {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (state->controlOperations != 0) {
            --state->controlOperations;
        }
        if (threw) {
            if (state->driverFailure == MoonlightDriverFailure::None) {
                state->driverFailure = MoonlightDriverFailure::InterruptException;
            }
            // A start may return while interrupt() is still unwinding. The
            // reserved control operation keeps the owner live until this path
            // can preserve the failure in its terminal snapshot.
            if (isTerminal(state->phase)) {
                state->phase = MoonlightSessionPhase::Failed;
            }
        }
        reapActiveLocked(state);
        impl_->stateCv.notify_all();
    } catch (...) {
    }
}

MoonlightSessionSnapshot MoonlightSessionOwner::snapshot(
    const MoonlightSessionKey& key) const noexcept {
    if (!key.valid()) {
        return {};
    }
    try {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        return snapshotLocked(key);
    } catch (...) {
        return {};
    }
}

bool MoonlightSessionOwner::waitForPhase(
    const MoonlightSessionKey& key,
    MoonlightSessionPhase phase,
    std::chrono::milliseconds timeout) const noexcept {
    if (!key.valid()) {
        return false;
    }
    try {
        const auto boundedTimeout = timeout < std::chrono::milliseconds::zero()
                                        ? std::chrono::milliseconds::zero()
                                        : timeout;
        const auto deadline = std::chrono::steady_clock::now() + boundedTimeout;
        std::unique_lock<std::mutex> lock(impl_->mutex);
        return impl_->stateCv.wait_until(lock, deadline, [&]() {
            const auto current = snapshotLocked(key);
            return current.matched && current.phase == phase;
        });
    } catch (...) {
        return false;
    }
}

MoonlightSessionSnapshot MoonlightSessionOwner::snapshotLocked(
    const MoonlightSessionKey& key) const noexcept {
    if (impl_->active != nullptr && impl_->active->key == key) {
        return snapshotStateLocked(impl_->active);
    }
    if (impl_->lastTerminal.matched && impl_->lastTerminal.key == key) {
        return impl_->lastTerminal;
    }
    return {};
}

MoonlightSessionSnapshot MoonlightSessionOwner::snapshotStateLocked(
    const std::shared_ptr<State>& state) const noexcept {
    MoonlightSessionSnapshot result;
    if (state == nullptr) {
        return result;
    }
    result.matched = true;
    result.key = state->key;
    result.phase = state->phase;
    result.cancellationRequested = state->cancellationRequested;
    result.admissionOpen = state->admissionOpen;
    result.startInvoked = state->startInvoked;
    result.startInterruptible = state->startInterruptible;
    result.startReturned = state->startReturned;
    result.interruptInvoked = state->interruptInvoked;
    result.stopInvoked = state->stopInvoked;
    result.stopCompleted = state->stopCompleted;
    result.inFlightCallbacks = state->callbackLeases;
    result.inFlightWorkers = state->workerLeases + state->controlOperations;
    result.startResult = state->startResult;
    result.driverFailure = state->driverFailure;
    return result;
}

void MoonlightSessionOwner::reapActiveLocked(
    const std::shared_ptr<State>& state) noexcept {
    if (state == nullptr || impl_->active != state || !isTerminal(state->phase) ||
        state->callbackLeases != 0 || state->workerLeases != 0 ||
        state->controlOperations != 0 || impl_->pendingStart == state ||
        impl_->pendingStop == state) {
        return;
    }
    impl_->lastTerminal = snapshotStateLocked(state);
    impl_->active.reset();
    impl_->stateCv.notify_all();
}

void MoonlightSessionOwner::workerLoop() noexcept {
    for (;;) {
        std::shared_ptr<State> state;
        bool startWork = false;
        try {
            {
                std::unique_lock<std::mutex> lock(impl_->mutex);
                impl_->workerCv.wait(lock, [this]() {
                    return impl_->shuttingDown || impl_->pendingStart != nullptr ||
                           impl_->pendingStop != nullptr;
                });
                if (impl_->shuttingDown && impl_->pendingStart == nullptr &&
                    impl_->pendingStop == nullptr) {
                    return;
                }
                if (impl_->pendingStart != nullptr) {
                    state = std::move(impl_->pendingStart);
                    startWork = true;
                } else {
                    state = std::move(impl_->pendingStop);
                }
            }
            if (startWork) {
                runStart(state);
            } else {
                runStop(state);
            }
        } catch (...) {
            // No exception may escape the sole process operation lane. Mark
            // the exact owner failed so a later session cannot be admitted as
            // though teardown had completed.
            try {
                std::lock_guard<std::mutex> lock(impl_->mutex);
                if (state != nullptr) {
                    state->admissionOpen = false;
                    state->phase = MoonlightSessionPhase::Failed;
                    if (state->driverFailure == MoonlightDriverFailure::None) {
                        state->driverFailure = startWork
                                                   ? MoonlightDriverFailure::StartException
                                                   : MoonlightDriverFailure::StopException;
                    }
                    state->controlOperations = 0;
                    reapActiveLocked(state);
                }
                impl_->stateCv.notify_all();
            } catch (...) {
            }
        }
    }
}

void MoonlightSessionOwner::runStart(
    const std::shared_ptr<State>& state) noexcept {
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (impl_->active != state) {
            return;
        }
        if (state->phase == MoonlightSessionPhase::Stopping &&
            state->cancellationRequested && !state->startInvoked) {
            state->admissionOpen = false;
            state->startReturned = true;
            state->startResult = kStartNotRun;
            state->phase = MoonlightSessionPhase::Stopped;
            reapActiveLocked(state);
            impl_->stateCv.notify_all();
            return;
        }
        if (state->phase != MoonlightSessionPhase::Starting) {
            return;
        }
        state->startInvoked = true;
        ++state->controlOperations;
        impl_->stateCv.notify_all();
    }

    int result = kStartNotRun;
    bool threw = false;
    StartContext context(this, state);
    try {
        result = state->driver.start(context);
    } catch (...) {
        threw = true;
    }

    bool scheduleStop = false;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        state->startReturned = true;
        state->startResult = result;
        if (state->controlOperations != 0) {
            --state->controlOperations;
        }
        if (threw) {
            state->admissionOpen = false;
            state->phase = MoonlightSessionPhase::Failed;
            if (state->driverFailure == MoonlightDriverFailure::None) {
                state->driverFailure = MoonlightDriverFailure::StartException;
            }
        } else if (result != 0) {
            state->admissionOpen = false;
            state->phase = state->cancellationRequested &&
                                   state->driverFailure == MoonlightDriverFailure::None
                               ? MoonlightSessionPhase::Stopped
                               : MoonlightSessionPhase::Failed;
        } else if (state->cancellationRequested) {
            state->admissionOpen = false;
            state->phase = MoonlightSessionPhase::Stopping;
            if (!state->stopScheduled) {
                state->stopScheduled = true;
                impl_->pendingStop = state;
                scheduleStop = true;
            }
        } else {
            state->phase = MoonlightSessionPhase::Running;
        }
        reapActiveLocked(state);
        impl_->stateCv.notify_all();
    }
    if (scheduleStop) {
        impl_->workerCv.notify_one();
    }
}

void MoonlightSessionOwner::runStop(
    const std::shared_ptr<State>& state) noexcept {
    {
        std::unique_lock<std::mutex> lock(impl_->mutex);
        if (impl_->active != state || state->phase != MoonlightSessionPhase::Stopping ||
            !state->startReturned || state->startResult != 0 || state->stopInvoked) {
            reapActiveLocked(state);
            impl_->stateCv.notify_all();
            return;
        }
        impl_->stateCv.wait(lock, [&]() {
            return state->callbackLeases == 0 && state->workerLeases == 0 &&
                   state->controlOperations == 0;
        });
        state->stopInvoked = true;
        ++state->controlOperations;
        impl_->stateCv.notify_all();
    }

    bool threw = false;
    try {
        state->driver.stop();
    } catch (...) {
        threw = true;
    }

    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (state->controlOperations != 0) {
            --state->controlOperations;
        }
        state->stopCompleted = true;
        state->admissionOpen = false;
        if (threw && state->driverFailure == MoonlightDriverFailure::None) {
            state->driverFailure = MoonlightDriverFailure::StopException;
        }
        state->phase = state->driverFailure == MoonlightDriverFailure::None
                           ? MoonlightSessionPhase::Stopped
                           : MoonlightSessionPhase::Failed;
        reapActiveLocked(state);
        impl_->stateCv.notify_all();
    }
}

} // namespace remotedesk::moonlight
