/**
 * Production continuity action executor.
 *
 * RustDeskConnectionContinuityOwner deliberately only decides what should
 * happen.  This layer is the single consumer of those actions: it closes
 * the native sinks, publishes the visible state, starts the retained
 * connection attempt, and records the result.  The worker is also the
 * bounded monotonic-clock poller used for retry timers and audio maintenance.
 */
#ifndef RUSTDESK_CONNECTION_CONTINUITY_EXECUTOR_H
#define RUSTDESK_CONNECTION_CONTINUITY_EXECUTOR_H

#include "rustdesk_connection_continuity_owner.h"

#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <atomic>
#include <cstdlib>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>

struct RustDeskContinuityQuiesceSnapshot {
    bool inputForward = true;
    bool heldKeys = true;
    bool inputCoalescing = true;
    bool clipboardProducer = true;
    bool fileProducer = true;
    bool controlInbox = true;
    bool audioProducer = true;
    bool decoderAdmission = true;
    bool oldSink = true;
    bool deferredDestroyRequested = false;
    bool deferredDestroyComplete = false;
    uint64_t quiesceCount = 0;
    uint64_t lastQuiesceDurationMs = 0;
    bool lastQuiesceWithinBudget = true;
};

class RustDeskContinuityQuiesceState {
public:
    void reopen() {
        std::lock_guard<std::mutex> lock(mutex_);
        inputForward_ = true;
        heldKeys_ = true;
        inputCoalescing_ = true;
        clipboardProducer_ = true;
        fileProducer_ = true;
        controlInbox_ = true;
        audioProducer_ = true;
        decoderAdmission_ = true;
        oldSink_ = true;
        deferredDestroyRequested_ = false;
        deferredDestroyComplete_ = false;
        lastQuiesceDurationMs_ = 0;
        lastQuiesceWithinBudget_ = true;
    }

    void closeForTransportLoss() {
        std::lock_guard<std::mutex> lock(mutex_);
        inputForward_ = false;
        heldKeys_ = false;
        inputCoalescing_ = false;
        clipboardProducer_ = false;
        fileProducer_ = false;
        controlInbox_ = false;
        audioProducer_ = false;
        decoderAdmission_ = false;
        oldSink_ = false;
        deferredDestroyRequested_ = true;
        deferredDestroyComplete_ = false;
        ++quiesceCount_;
    }

    void recordFastQuiesceDuration(uint64_t durationMs) {
        std::lock_guard<std::mutex> lock(mutex_);
        lastQuiesceDurationMs_ = durationMs;
        lastQuiesceWithinBudget_ = durationMs <= kFastQuiesceBudgetMs;
    }

    void markDeferredDestroyComplete() {
        std::lock_guard<std::mutex> lock(mutex_);
        deferredDestroyComplete_ = true;
    }

    void reopenPresentationAfterFirstFrame() {
        std::lock_guard<std::mutex> lock(mutex_);
        inputForward_ = true;
        heldKeys_ = true;
        inputCoalescing_ = true;
        clipboardProducer_ = true;
        fileProducer_ = true;
        controlInbox_ = true;
        decoderAdmission_ = true;
        oldSink_ = true;
    }

    void reopenGenerationAdmission() {
        std::lock_guard<std::mutex> lock(mutex_);
        audioProducer_ = true;
        decoderAdmission_ = true;
        oldSink_ = true;
    }

    void reopenAudioAfterPrebuffer() {
        std::lock_guard<std::mutex> lock(mutex_);
        audioProducer_ = true;
    }

    RustDeskContinuityQuiesceSnapshot snapshot() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return RustDeskContinuityQuiesceSnapshot {
            inputForward_, heldKeys_, inputCoalescing_, clipboardProducer_,
            fileProducer_, controlInbox_, audioProducer_, decoderAdmission_,
            oldSink_, deferredDestroyRequested_, deferredDestroyComplete_,
            quiesceCount_, lastQuiesceDurationMs_, lastQuiesceWithinBudget_,
        };
    }

    bool inputAllowed() const { return snapshot().inputForward; }
    bool clipboardAllowed() const { return snapshot().clipboardProducer; }
    bool fileAllowed() const { return snapshot().fileProducer; }
    bool controlAllowed() const { return snapshot().controlInbox; }
    bool audioAllowed() const { return snapshot().audioProducer; }
    bool decoderAllowed() const { return snapshot().decoderAdmission; }

private:
    static constexpr uint64_t kFastQuiesceBudgetMs = 500;
    mutable std::mutex mutex_;
    bool inputForward_ = true;
    bool heldKeys_ = true;
    bool inputCoalescing_ = true;
    bool clipboardProducer_ = true;
    bool fileProducer_ = true;
    bool controlInbox_ = true;
    bool audioProducer_ = true;
    bool decoderAdmission_ = true;
    bool oldSink_ = true;
    bool deferredDestroyRequested_ = false;
    bool deferredDestroyComplete_ = false;
    uint64_t quiesceCount_ = 0;
    uint64_t lastQuiesceDurationMs_ = 0;
    bool lastQuiesceWithinBudget_ = true;
};

namespace RustDeskContinuityDeferred {

struct Worker {
    std::thread thread;
    std::shared_ptr<void> keepAlive;
    std::shared_ptr<std::atomic<bool>> done;
    std::function<void()> afterJoin;
};

class Owner {
public:
    Owner() : thread_([this]() { run(); }) {}

    void enqueue(std::thread thread, std::shared_ptr<void> keepAlive,
                 std::shared_ptr<std::atomic<bool>> done,
                 std::function<void()> afterJoin = {}) {
        if (!thread.joinable()) {
            return;
        }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            pending_.push_back(Worker {
                std::move(thread), std::move(keepAlive), std::move(done),
                std::move(afterJoin)});
        }
        cv_.notify_one();
    }

    bool drainWithin(std::chrono::milliseconds timeout) {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, timeout, [this]() {
            return pending_.empty() && active_ == 0;
        });
    }

    std::size_t remaining() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return pending_.size() + active_;
    }

    bool shutdownWithin(std::chrono::milliseconds timeout) {
        const auto deadline = std::chrono::steady_clock::now() + timeout;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopping_ = true;
        }
        cv_.notify_all();
        std::unique_lock<std::mutex> lock(mutex_);
        if (!cv_.wait_until(lock, deadline, [this]() { return done_; })) {
            return false;
        }
        lock.unlock();
        if (thread_.joinable() && thread_.get_id() != std::this_thread::get_id()) {
            thread_.join();
        }
        return true;
    }

private:
    void run() {
        for (;;) {
            Worker worker;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                cv_.wait(lock, [this]() {
                    return stopping_ || !pending_.empty();
                });
                if (pending_.empty() && stopping_) {
                    done_ = true;
                    cv_.notify_all();
                    return;
                }
                worker = std::move(pending_.front());
                pending_.pop_front();
                ++active_;
            }
            // Each worker has an independent completion fence. Do not let a
            // stalled continuity job block completed jobs behind it.
            if (worker.done && !worker.done->load(std::memory_order_acquire)) {
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    pending_.push_back(std::move(worker));
                    --active_;
                }
                cv_.notify_all();
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }
            worker.thread.join();
            if (worker.afterJoin) {
                worker.afterJoin();
            }
            worker.keepAlive.reset();
            {
                std::lock_guard<std::mutex> lock(mutex_);
                --active_;
                cv_.notify_all();
            }
        }
    }

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::deque<Worker> pending_;
    std::thread thread_;
    bool stopping_ = false;
    bool done_ = false;
    std::size_t active_ = 0;
};

inline std::mutex ownerMutex;
inline Owner* owner = nullptr;

inline Owner& getOwner() {
    std::lock_guard<std::mutex> lock(ownerMutex);
    if (!owner) {
        owner = new Owner();
    }
    return *owner;
}

inline bool drainWithin(std::chrono::milliseconds timeout) {
    std::lock_guard<std::mutex> lock(ownerMutex);
    return owner == nullptr || owner->drainWithin(timeout);
}

inline bool shutdownWithin(std::chrono::milliseconds timeout) {
    Owner* current = nullptr;
    {
        std::lock_guard<std::mutex> lock(ownerMutex);
        current = owner;
    }
    if (!current) {
        return true;
    }
    const bool done = current->shutdownWithin(timeout);
    if (done) {
        std::lock_guard<std::mutex> lock(ownerMutex);
        if (owner == current) {
            owner = nullptr;
            // Current callers may still hold the raw Owner reference. Its
            // worker has joined, so retire the object without deleting it;
            // future calls create a fresh owner under ownerMutex.
        }
    }
    return done;
}

inline std::size_t remaining() {
    std::lock_guard<std::mutex> lock(ownerMutex);
    return owner == nullptr ? 0 : owner->remaining();
}

inline void enqueue(std::thread thread, std::shared_ptr<void> keepAlive,
                    std::shared_ptr<std::atomic<bool>> done,
                    std::function<void()> afterJoin = {}) {
    getOwner().enqueue(std::move(thread), std::move(keepAlive), std::move(done),
                       std::move(afterJoin));
}

} // namespace RustDeskContinuityDeferred

class RustDeskConnectionContinuityExecutor
    : public std::enable_shared_from_this<RustDeskConnectionContinuityExecutor> {
public:
    using ActionAdmission = std::function<bool()>;

    struct AttemptTicket {
        uint64_t sessionId = 0;
        uint64_t sessionGeneration = 0;
        uint64_t ownerToken = 0;
        uint64_t admissionEpoch = 0;
        uint64_t attemptToken = 0;
        ActionAdmission validator;

        bool valid() const {
            return sessionId != 0 && sessionGeneration != 0 && ownerToken != 0 &&
                admissionEpoch != 0 && attemptToken != 0 &&
                static_cast<bool>(validator);
        }
    };

    // The source ticket names the generation which observed the transport
    // loss. Preparation is an admission-locked transition to the next
    // decoder/FFI generation; the source ticket is never reused after that
    // rotation.
    struct PreparedAttemptTicket {
        uint64_t sessionId = 0;
        uint64_t sessionGeneration = 0;
        uint64_t ownerToken = 0;
        uint64_t admissionEpoch = 0;
        uint64_t attemptToken = 0;
        ActionAdmission validator;

        bool valid() const {
            return sessionId != 0 && sessionGeneration != 0 && ownerToken != 0 &&
                admissionEpoch != 0 && attemptToken != 0 &&
                static_cast<bool>(validator);
        }
    };

    struct Callbacks {
        std::function<void()> fastQuiesce;
        std::function<void(const std::string&)> publishVisibleState;
        std::function<bool(uint32_t)> startAttempt;
        std::function<void()> cancelAttempt;
        std::function<void(uint64_t)> maintenancePoll;
        std::function<void()> firstGenerationReady;
        std::function<AttemptTicket()> makeAttemptTicket;
        std::function<PreparedAttemptTicket(const AttemptTicket&)> prepareAttemptTicket;
#if defined(RDP_NATIVE_CALLBACK_TESTING)
        // Only test builds may provide a ticket factory without a production
        // session owner. Production drops the action when the factory is
        // absent or returns an invalid ticket.
        std::function<AttemptTicket()> testAttemptTicketFactory;
#endif
        // The legacy callbacks remain only for policy/native test fixtures.
        // Production bridges install prepareAttemptTicket and consume the
        // resulting prepared ticket so a queued attempt cannot cross a
        // session/generation fence.
        std::function<bool(const AttemptTicket&)> startAttemptWithTicket;
        std::function<bool(const PreparedAttemptTicket&)> startAttemptWithPreparedTicket;
    };

    explicit RustDeskConnectionContinuityExecutor(Callbacks callbacks = {},
                                                  bool runWorker = true)
        : callbacks_(std::move(callbacks)), runWorker_(runWorker) {}

    ~RustDeskConnectionContinuityExecutor() {
        (void)shutdown();
    }

    RustDeskConnectionContinuityExecutor(
        const RustDeskConnectionContinuityExecutor&) = delete;
    RustDeskConnectionContinuityExecutor& operator=(
        const RustDeskConnectionContinuityExecutor&) = delete;

    void setCallbacks(Callbacks callbacks) {
        std::lock_guard<std::mutex> lock(workerMutex_);
        callbacks_ = std::move(callbacks);
    }

    void begin(uint64_t sessionId, uint64_t generation, uint64_t nowMs) {
        {
            std::lock_guard<std::mutex> lock(ownerMutex_);
            owner_.begin(sessionId, generation, nowMs);
        }
        if (runWorker_) {
            ensureWorker();
        }
    }

    RustDeskContinuityAction onTransportEvent(const RustDeskTransportEvent& event,
                                              ActionAdmission admission = {}) {
        RustDeskContinuityAction action;
        {
            std::lock_guard<std::mutex> lock(ownerMutex_);
            action = owner_.onTransportEvent(event);
        }
        consumeVisibleAction(action, event.networkAvailable, admission);
        return action;
    }

    RustDeskContinuityAction onNetworkChanged(bool available, uint64_t generation,
                                               uint64_t nowMs) {
        RustDeskContinuityAction action;
        {
            std::lock_guard<std::mutex> lock(ownerMutex_);
            action = owner_.onNetworkChanged(available, generation, nowMs);
        }
        consumeVisibleAction(action, available, {});
        return action;
    }

    void recordAttemptResult(bool succeeded, uint64_t nowMs) {
        RustDeskContinuityState state;
        {
            std::lock_guard<std::mutex> lock(ownerMutex_);
            owner_.recordAttemptResult(succeeded, nowMs);
            state = owner_.state();
        }
        if (succeeded) {
            publish("CONNECTED_WAITING_FOR_FIRST_FRAME");
        } else if (state == RustDeskContinuityState::RetryPending) {
            publish("RECONNECTING_RETRY_SCHEDULED");
            wakeWorker();
        } else {
            publish("FAILED_RETRY_BUDGET_EXHAUSTED");
        }
    }

    void firstGenerationFrameArrived(ActionAdmission admission = {}) {
        if (!isAdmitted(admission)) {
            return;
        }
        {
            std::lock_guard<std::mutex> lock(ownerMutex_);
            if (!isAdmitted(admission)) {
                return;
            }
            owner_.recordAttemptResult(true, nowMs());
        }
        const Callbacks callbacks = callbacksSnapshot();
        if (callbacks.firstGenerationReady && isAdmitted(admission)) {
            callbacks.firstGenerationReady();
        }
        publish("CONNECTED", admission);
    }

    void onNetworkAvailable(bool available, uint64_t generation, uint64_t nowMs) {
        (void)onNetworkChanged(available, generation, nowMs);
    }

    void cancel() {
        {
            std::lock_guard<std::mutex> lock(ownerMutex_);
            owner_.cancel();
        }
        const Callbacks callbacks = callbacksSnapshot();
        if (callbacks.cancelAttempt) {
            callbacks.cancelAttempt();
        }
        {
            std::lock_guard<std::mutex> lock(workerMutex_);
            pendingAttempt_ = false;
            pendingTicket_ = AttemptTicket {};
        }
        wakeWorker();
    }

    RustDeskContinuityAction poll(uint64_t nowMs) {
        RustDeskContinuityAction action;
        {
            std::lock_guard<std::mutex> lock(ownerMutex_);
            action = owner_.poll(nowMs);
        }
        if (action.startAttempt) {
            queueAttempt(action);
        }
        return action;
    }

    /** Deterministic test/diagnostic pump; production uses the worker below. */
    void pumpForTesting(uint64_t nowMs) {
        processPendingAttempt();
        const Callbacks callbacks = callbacksSnapshot();
        if (callbacks.maintenancePoll) {
            callbacks.maintenancePoll(nowMs);
        }
        (void)poll(nowMs);
        processPendingAttempt();
    }

    RustDeskContinuityState state() const {
        std::lock_guard<std::mutex> lock(ownerMutex_);
        return owner_.state();
    }
    uint32_t attempts() const {
        std::lock_guard<std::mutex> lock(ownerMutex_);
        return owner_.attempts();
    }
    uint64_t nextRetryMs() const {
        std::lock_guard<std::mutex> lock(ownerMutex_);
        return owner_.nextRetryMs();
    }
    bool networkAvailable() const {
        std::lock_guard<std::mutex> lock(ownerMutex_);
        return owner_.networkAvailable();
    }

    // Stop accepting work and wait only for the supplied total budget. A
    // timeout deliberately leaves this executor as the owner of its worker;
    // callers release the blocked operation and call again before destruction.
    bool shutdownWithin(std::chrono::milliseconds timeout) {
        const auto deadline = std::chrono::steady_clock::now() + timeout;
        {
            std::lock_guard<std::mutex> lock(workerMutex_);
            stopping_ = true;
            pendingAttempt_ = false;
            pendingTicket_ = AttemptTicket {};
        }
        workerCondition_.notify_all();
        std::unique_lock<std::mutex> lock(workerMutex_);
        const bool done = workerCondition_.wait_until(lock, deadline, [this]() {
            return workerDone_;
        });
        lock.unlock();
        if (!done || !worker_.joinable() ||
            worker_.get_id() == std::this_thread::get_id()) {
            return done && !worker_.joinable();
        }
        worker_.join();
        {
            std::lock_guard<std::mutex> ownerLock(ownerMutex_);
            owner_.cancel();
        }
        return true;
    }

    std::size_t remainingCount() const {
        std::lock_guard<std::mutex> lock(workerMutex_);
        return (pendingAttempt_ ? 1U : 0U) +
            (workerBusy_.load(std::memory_order_acquire) ? 1U : 0U);
    }

    void shutdown() {
        if (shutdownWithin(std::chrono::milliseconds(500))) {
            return;
        }
        deferCurrentWorker();
    }

    static bool drainDeferredWithin(std::chrono::milliseconds timeout) {
        return RustDeskContinuityDeferred::drainWithin(timeout);
    }

    static bool shutdownDeferredWithin(std::chrono::milliseconds timeout) {
        return RustDeskContinuityDeferred::shutdownWithin(timeout);
    }

    static std::size_t deferredRemaining() {
        return RustDeskContinuityDeferred::remaining();
    }

#if defined(RDP_NATIVE_CALLBACK_TESTING)
    using AttemptDequeuedHook = std::function<void()>;

    void setAttemptDequeuedHookForTesting(AttemptDequeuedHook hook) {
        std::lock_guard<std::mutex> lock(workerMutex_);
        attemptDequeuedHook_ = std::move(hook);
    }
#endif

private:
    static uint64_t nowMs() {
        return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
    }

    void ensureWorker() {
        std::lock_guard<std::mutex> lock(workerMutex_);
        if (worker_.joinable()) {
            stopping_ = false;
            workerDone_ = false;
            return;
        }
        stopping_ = false;
        workerDone_ = false;
        auto done = std::make_shared<std::atomic<bool>>(false);
        workerDoneFence_ = done;
        try {
            worker_ = std::thread([this, done]() noexcept {
                try {
                    workerLoop();
                } catch (...) {
                    // A callback is outside the executor's control. An
                    // exception must still publish the worker fence so
                    // shutdown cannot leave a joinable thread behind.
                    std::lock_guard<std::mutex> lock(workerMutex_);
                    stopping_ = true;
                    pendingAttempt_ = false;
                    workerBusy_.store(false, std::memory_order_release);
                    workerDone_ = true;
                }
                done->store(true, std::memory_order_release);
                workerCondition_.notify_all();
            });
        } catch (...) {
            stopping_ = true;
            workerDone_ = true;
            workerBusy_.store(false, std::memory_order_release);
            done->store(true, std::memory_order_release);
            workerCondition_.notify_all();
            return;
        }
    }

    void deferCurrentWorker() {
        std::shared_ptr<RustDeskConnectionContinuityExecutor> retained;
        try {
            retained = shared_from_this();
        } catch (const std::bad_weak_ptr&) {
            // A stack-owned test executor must release its deterministic
            // barrier before destruction. Production bridge executors are
            // shared owners and can safely transfer this worker.
            std::abort();
        }
        std::thread worker;
        std::shared_ptr<std::atomic<bool>> done;
        {
            std::lock_guard<std::mutex> lock(workerMutex_);
            if (!worker_.joinable()) {
                return;
            }
            worker = std::move(worker_);
            done = workerDoneFence_;
            workerDone_ = true;
        }
        RustDeskContinuityDeferred::enqueue(
            std::move(worker), std::move(retained), std::move(done));
    }

    void wakeWorker() { workerCondition_.notify_all(); }

    void queueAttempt(const RustDeskContinuityAction& action,
                      const ActionAdmission& admission = {}) {
        if (!isAdmitted(admission)) {
            return;
        }
        const Callbacks callbacks = callbacksSnapshot();
        AttemptTicket ticket;
        if (callbacks.makeAttemptTicket) {
            ticket = callbacks.makeAttemptTicket();
#if defined(RDP_NATIVE_CALLBACK_TESTING)
        } else if (callbacks.testAttemptTicketFactory) {
            ticket = callbacks.testAttemptTicketFactory();
#endif
        } else {
            // A production continuity action without an owner-bound ticket is
            // fail-closed. The old all-ones/validator=true pseudo-ticket made
            // it possible for a queued action to cross a real session fence.
            return;
        }
        if (!ticket.valid()) {
            return;
        }
        const ActionAdmission ticketAdmission = ticket.validator;
        ticket.validator = [admission, ticketAdmission]() {
            return (!admission || admission()) &&
                (!ticketAdmission || ticketAdmission());
        };
        {
            std::lock_guard<std::mutex> lock(workerMutex_);
            pendingAttempt_ = true;
            pendingAction_ = action;
            pendingTicket_ = std::move(ticket);
        }
        wakeWorker();
    }

    static bool isAdmitted(const ActionAdmission& admission) {
        return !admission || admission();
    }

    void consumeVisibleAction(const RustDeskContinuityAction& action, bool networkAvailable,
                              const ActionAdmission& admission) {
        if (!isAdmitted(admission)) {
            return;
        }
        const Callbacks callbacks = callbacksSnapshot();
        if (action.cancelAttempt) {
            if (callbacks.cancelAttempt) {
                callbacks.cancelAttempt();
            }
            // A queued ticket may still name the resolver generation which
            // was just retired. Drop it before publishing the replacement
            // action; an already-dequeued production ticket is rejected by
            // the bridge admission-epoch rotation in cancelAttempt.
            std::lock_guard<std::mutex> lock(workerMutex_);
            pendingAttempt_ = false;
            pendingTicket_ = AttemptTicket {};
        }
        if (action.fastQuiesce && callbacks.fastQuiesce) {
            callbacks.fastQuiesce();
        }
        if (!isAdmitted(admission)) {
            return;
        }
        if (action.visibleTransportLost) {
            RustDeskContinuityState state;
            {
                std::lock_guard<std::mutex> lock(ownerMutex_);
                state = owner_.state();
            }
            if (state == RustDeskContinuityState::ReauthRequired) {
                publish("REAUTH", admission);
            } else if (action.terminal) {
                publish("FAILED", admission);
            } else if (!networkAvailable) {
                publish("WAITING_NETWORK", admission);
            } else {
                publish("RECONNECTING", admission);
            }
        }
        if (action.startAttempt && isAdmitted(admission)) {
            queueAttempt(action);
        }
    }

    void processPendingAttempt() {
        RustDeskContinuityAction action;
        AttemptTicket ticket;
        {
            std::lock_guard<std::mutex> lock(workerMutex_);
            if (!pendingAttempt_) {
                return;
            }
            pendingAttempt_ = false;
            action = pendingAction_;
            ticket = std::move(pendingTicket_);
        }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
        AttemptDequeuedHook dequeueHook;
        {
            std::lock_guard<std::mutex> lock(workerMutex_);
            dequeueHook = attemptDequeuedHook_;
        }
        if (dequeueHook) {
            dequeueHook();
        }
#endif
        if (!ticket.valid() || !isAdmitted(ticket.validator)) {
            return;
        }
        const Callbacks callbacks = callbacksSnapshot();
        RustDeskContinuityState state;
        {
            std::lock_guard<std::mutex> lock(ownerMutex_);
            state = owner_.state();
        }
        if (state != RustDeskContinuityState::RetryPending ||
            (!callbacks.startAttemptWithPreparedTicket &&
             !callbacks.startAttemptWithTicket && !callbacks.startAttempt)) {
            return;
        }

        PreparedAttemptTicket prepared;
        if (callbacks.prepareAttemptTicket) {
            prepared = callbacks.prepareAttemptTicket(ticket);
        }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
        else if (callbacks.startAttempt && !callbacks.startAttemptWithTicket &&
                 !callbacks.startAttemptWithPreparedTicket) {
            // Policy-only tests explicitly supplied testAttemptTicketFactory;
            // preserve their legacy uint32 callback without creating a
            // production ticket or pretending that a generation was rotated.
            prepared.sessionId = ticket.sessionId;
            prepared.sessionGeneration = ticket.sessionGeneration;
            prepared.ownerToken = ticket.ownerToken;
            prepared.admissionEpoch = ticket.admissionEpoch;
            prepared.attemptToken = ticket.attemptToken;
            prepared.validator = ticket.validator;
        }
#endif
        if (!prepared.valid() || !isAdmitted(prepared.validator)) {
            return;
        }
        publish("RECONNECTING_ATTEMPT", prepared.validator);
        if (!isAdmitted(prepared.validator)) {
            return;
        }
        bool started = false;
        if (callbacks.startAttemptWithPreparedTicket) {
            started = callbacks.startAttemptWithPreparedTicket(prepared);
        } else if (callbacks.startAttemptWithTicket) {
            // Compatibility is test-only; production installs the prepared
            // callback above and cannot consume the source ticket here.
#if defined(RDP_NATIVE_CALLBACK_TESTING)
            started = callbacks.startAttemptWithTicket(ticket);
#endif
        } else if (callbacks.startAttempt) {
            started = callbacks.startAttempt(action.attempt);
        }
        if (!started && isAdmitted(prepared.validator)) {
            recordAttemptResult(false, nowMs());
        }
    }

    void workerLoop() {
        while (true) {
            {
                std::unique_lock<std::mutex> lock(workerMutex_);
                if (stopping_) {
                    workerDone_ = true;
                    workerCondition_.notify_all();
                    return;
                }
                workerCondition_.wait_for(lock, std::chrono::milliseconds(50), [this]() {
                    return stopping_ || pendingAttempt_;
                });
                if (stopping_) {
                    workerDone_ = true;
                    workerCondition_.notify_all();
                    return;
                }
            }
            workerBusy_.store(true, std::memory_order_release);
            const uint64_t currentMs = nowMs();
            const Callbacks callbacks = callbacksSnapshot();
            if (callbacks.maintenancePoll) {
                callbacks.maintenancePoll(currentMs);
            }
            processPendingAttempt();
            (void)poll(currentMs);
            workerBusy_.store(false, std::memory_order_release);
        }
    }

    void publish(const char* message, const ActionAdmission& admission = {}) {
        if (!isAdmitted(admission)) {
            return;
        }
        const Callbacks callbacks = callbacksSnapshot();
        if (callbacks.publishVisibleState) {
            callbacks.publishVisibleState(message ? std::string(message) : std::string());
        }
    }

    Callbacks callbacksSnapshot() const {
        std::lock_guard<std::mutex> lock(workerMutex_);
        return callbacks_;
    }

    RustDeskConnectionContinuityOwner owner_;
    mutable std::mutex ownerMutex_;
    Callbacks callbacks_;
    mutable std::mutex workerMutex_;
    std::condition_variable workerCondition_;
    std::thread worker_;
    std::shared_ptr<std::atomic<bool>> workerDoneFence_ =
        std::make_shared<std::atomic<bool>>(true);
    bool stopping_ = false;
    bool workerDone_ = true;
    std::atomic<bool> workerBusy_ {false};
    bool runWorker_ = true;
    bool pendingAttempt_ = false;
    RustDeskContinuityAction pendingAction_;
    AttemptTicket pendingTicket_;
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    AttemptDequeuedHook attemptDequeuedHook_;
#endif
};

#endif // RUSTDESK_CONNECTION_CONTINUITY_EXECUTOR_H
