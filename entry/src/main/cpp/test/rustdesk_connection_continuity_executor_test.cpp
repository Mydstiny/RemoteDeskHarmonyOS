#include "rustdesk/rustdesk_connection_continuity_executor.h"
#include "test_runner.h"

#include <condition_variable>
#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#if defined(RDP_NATIVE_CALLBACK_TESTING)
namespace {
RustDeskConnectionContinuityExecutor::AttemptTicket MakeExplicitTestTicket() {
    static std::atomic<uint64_t> token {1};
    RustDeskConnectionContinuityExecutor::AttemptTicket ticket;
    ticket.sessionId = 1;
    ticket.sessionGeneration = 1;
    ticket.ownerToken = 1;
    ticket.admissionEpoch = 1;
    ticket.attemptToken = token.fetch_add(1, std::memory_order_relaxed);
    ticket.validator = []() { return true; };
    return ticket;
}
}
#endif

RDP_TEST_CASE(rustdesk_continuity_executor_consumes_transport_action_and_reconnects) {
    std::mutex mutex;
    std::vector<std::string> events;
    int attempts = 0;
    RustDeskConnectionContinuityExecutor::Callbacks callbacks;
    callbacks.fastQuiesce = [&]() { events.emplace_back("QUIESCE"); };
    callbacks.publishVisibleState = [&](const std::string& event) {
        std::lock_guard<std::mutex> lock(mutex);
        events.push_back(event);
    };
    callbacks.startAttempt = [&](uint32_t attempt) {
        std::lock_guard<std::mutex> lock(mutex);
        ++attempts;
        events.push_back("START_" + std::to_string(attempt));
        return true;
    };
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    callbacks.testAttemptTicketFactory = MakeExplicitTestTicket;
#endif

    RustDeskConnectionContinuityExecutor executor(std::move(callbacks), false);
    executor.begin(17, 23, 1000);
    const auto action = executor.onTransportEvent({
        true, RustDeskTransportErrorClass::Reset, 4, false, true, 1100});
    RDP_ASSERT(action.startAttempt);
    executor.pumpForTesting(1100);
    RDP_ASSERT_EQ(attempts, 1);
    RDP_ASSERT(events.front() == "QUIESCE");
    RDP_ASSERT(events.back() == "START_1");
}

RDP_TEST_CASE(rustdesk_continuity_executor_records_failure_and_uses_retry_timer) {
    int attempts = 0;
    RustDeskConnectionContinuityExecutor::Callbacks callbacks;
    callbacks.startAttempt = [&](uint32_t) {
        ++attempts;
        return true;
    };
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    callbacks.testAttemptTicketFactory = MakeExplicitTestTicket;
#endif
    RustDeskConnectionContinuityExecutor executor(std::move(callbacks), false);
    executor.begin(18, 24, 1000);
    RDP_ASSERT(executor.onTransportEvent({
        true, RustDeskTransportErrorClass::Timeout, 5, false, true, 1100}).startAttempt);
    executor.pumpForTesting(1100);
    RDP_ASSERT_EQ(attempts, 1);
    executor.recordAttemptResult(false, 1200);
    RDP_ASSERT_EQ(executor.state(), RustDeskContinuityState::RetryPending);
    RDP_ASSERT(executor.nextRetryMs() > 1200);
    executor.pumpForTesting(executor.nextRetryMs());
    RDP_ASSERT_EQ(attempts, 2);
}

RDP_TEST_CASE(rustdesk_continuity_executor_cancel_removes_pending_attempt) {
    int attempts = 0;
    bool cancelled = false;
    RustDeskConnectionContinuityExecutor::Callbacks callbacks;
    callbacks.startAttempt = [&](uint32_t) {
        ++attempts;
        return true;
    };
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    callbacks.testAttemptTicketFactory = MakeExplicitTestTicket;
#endif
    callbacks.cancelAttempt = [&]() { cancelled = true; };
    RustDeskConnectionContinuityExecutor executor(std::move(callbacks), false);
    executor.begin(19, 25, 0);
    RDP_ASSERT(executor.onTransportEvent({
        true, RustDeskTransportErrorClass::BrokenPipe, 7, false, true, 1}).startAttempt);
    executor.cancel();
    executor.pumpForTesting(1);
    RDP_ASSERT_EQ(attempts, 0);
    RDP_ASSERT(cancelled);
}

RDP_TEST_CASE(rustdesk_continuity_executor_replaces_retired_network_attempt) {
    int attempts = 0;
    int cancellations = 0;
    RustDeskConnectionContinuityExecutor::Callbacks callbacks;
    callbacks.startAttempt = [&](uint32_t) {
        ++attempts;
        return true;
    };
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    callbacks.testAttemptTicketFactory = MakeExplicitTestTicket;
#endif
    callbacks.cancelAttempt = [&]() { ++cancellations; };
    RustDeskConnectionContinuityExecutor executor(std::move(callbacks), false);
    executor.begin(190, 250, 0);

    RDP_ASSERT(!executor.onNetworkChanged(true, 70, 1).startAttempt);
    const auto changed = executor.onNetworkChanged(true, 71, 2);
    RDP_ASSERT(changed.cancelAttempt);
    RDP_ASSERT(changed.startAttempt);
    RDP_ASSERT_EQ(cancellations, 1);
    executor.pumpForTesting(2);
    RDP_ASSERT_EQ(attempts, 1);

    const auto unavailable = executor.onNetworkChanged(false, 72, 3);
    RDP_ASSERT(unavailable.cancelAttempt);
    RDP_ASSERT(!unavailable.startAttempt);
    RDP_ASSERT_EQ(cancellations, 2);
    executor.pumpForTesting(3);
    RDP_ASSERT_EQ(attempts, 1);
}

RDP_TEST_CASE(rustdesk_continuity_quiesce_closes_all_producers_and_reopens_after_frame) {
    RustDeskContinuityQuiesceState state;
    state.closeForTransportLoss();
    const auto closed = state.snapshot();
    RDP_ASSERT(!closed.inputForward);
    RDP_ASSERT(!closed.heldKeys);
    RDP_ASSERT(!closed.inputCoalescing);
    RDP_ASSERT(!closed.clipboardProducer);
    RDP_ASSERT(!closed.fileProducer);
    RDP_ASSERT(!closed.controlInbox);
    RDP_ASSERT(!closed.audioProducer);
    RDP_ASSERT(!closed.decoderAdmission);
    RDP_ASSERT(!closed.oldSink);
    RDP_ASSERT(closed.deferredDestroyRequested);
    RDP_ASSERT_EQ(closed.quiesceCount, static_cast<uint64_t>(1));
    state.recordFastQuiesceDuration(42);
    RDP_ASSERT_EQ(state.snapshot().lastQuiesceDurationMs, static_cast<uint64_t>(42));
    RDP_ASSERT(state.snapshot().lastQuiesceWithinBudget);
    state.recordFastQuiesceDuration(501);
    RDP_ASSERT(!state.snapshot().lastQuiesceWithinBudget);

    state.markDeferredDestroyComplete();
    state.reopenPresentationAfterFirstFrame();
    state.reopenAudioAfterPrebuffer();
    const auto reopened = state.snapshot();
    RDP_ASSERT(reopened.inputForward);
    RDP_ASSERT(reopened.heldKeys);
    RDP_ASSERT(reopened.inputCoalescing);
    RDP_ASSERT(reopened.clipboardProducer);
    RDP_ASSERT(reopened.fileProducer);
    RDP_ASSERT(reopened.controlInbox);
    RDP_ASSERT(reopened.audioProducer);
    RDP_ASSERT(reopened.decoderAdmission);
    RDP_ASSERT(reopened.oldSink);
    RDP_ASSERT(reopened.deferredDestroyComplete);
}

RDP_TEST_CASE(rustdesk_continuity_executor_reopens_input_only_after_first_frame) {
    bool firstGenerationReady = false;
    std::vector<std::string> events;
    RustDeskConnectionContinuityExecutor::Callbacks callbacks;
    callbacks.startAttempt = [&](uint32_t) { return true; };
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    callbacks.testAttemptTicketFactory = MakeExplicitTestTicket;
#endif
    callbacks.firstGenerationReady = [&]() { firstGenerationReady = true; };
    callbacks.publishVisibleState = [&](const std::string& event) {
        events.push_back(event);
    };
    RustDeskConnectionContinuityExecutor executor(std::move(callbacks), false);
    executor.begin(20, 26, 1000);
    RDP_ASSERT(executor.onTransportEvent({
        true, RustDeskTransportErrorClass::Reset, 8, false, true, 1100}).startAttempt);
    executor.pumpForTesting(1100);
    RDP_ASSERT(!firstGenerationReady);
    executor.firstGenerationFrameArrived();
    RDP_ASSERT(firstGenerationReady);
    RDP_ASSERT(!events.empty() && events.back() == "CONNECTED");
}

RDP_TEST_CASE(rustdesk_continuity_executor_shutdown_budget_retains_blocked_worker) {
    std::mutex mutex;
    std::condition_variable condition;
    bool entered = false;
    bool release = false;
    RustDeskConnectionContinuityExecutor::Callbacks callbacks;
    callbacks.maintenancePoll = [&](uint64_t) {
        std::unique_lock<std::mutex> lock(mutex);
        entered = true;
        condition.notify_all();
        condition.wait(lock, [&]() { return release; });
    };

    RustDeskConnectionContinuityExecutor executor(std::move(callbacks), true);
    executor.begin(21, 27, 1000);
    {
        std::unique_lock<std::mutex> lock(mutex);
        RDP_ASSERT(condition.wait_for(lock, std::chrono::seconds(1),
                                      [&]() { return entered; }));
    }
    RDP_ASSERT(!executor.shutdownWithin(std::chrono::milliseconds(50)));
    RDP_ASSERT(executor.remainingCount() >= 1);
    {
        std::lock_guard<std::mutex> lock(mutex);
        release = true;
    }
    condition.notify_all();
    RDP_ASSERT(executor.shutdownWithin(std::chrono::seconds(1)));
    RDP_ASSERT_EQ(executor.remainingCount(), static_cast<std::size_t>(0));
}

RDP_TEST_CASE(rustdesk_continuity_executor_deferred_owner_reclaims_after_release) {
    auto mutex = std::make_shared<std::mutex>();
    auto condition = std::make_shared<std::condition_variable>();
    auto entered = std::make_shared<bool>(false);
    auto release = std::make_shared<bool>(false);
    RustDeskConnectionContinuityExecutor::Callbacks callbacks;
    callbacks.maintenancePoll = [mutex, condition, entered, release](uint64_t) {
        std::unique_lock<std::mutex> lock(*mutex);
        *entered = true;
        condition->notify_all();
        condition->wait(lock, [release]() { return *release; });
    };

    auto executor = std::make_shared<RustDeskConnectionContinuityExecutor>(
        std::move(callbacks), true);
    executor->begin(22, 28, 1000);
    {
        std::unique_lock<std::mutex> lock(*mutex);
        RDP_ASSERT(condition->wait_for(lock, std::chrono::seconds(1), [&]() {
            return *entered;
        }));
    }

    std::atomic<bool> shutdownReturned {false};
    std::thread shutdownThread([executor, &shutdownReturned]() {
        executor->shutdown();
        shutdownReturned.store(true, std::memory_order_release);
    });
    const auto shutdownDeadline = std::chrono::steady_clock::now() +
        std::chrono::milliseconds(900);
    while (!shutdownReturned.load(std::memory_order_acquire) &&
           std::chrono::steady_clock::now() < shutdownDeadline) {
        std::this_thread::yield();
    }
    RDP_ASSERT(shutdownReturned.load(std::memory_order_acquire));
    shutdownThread.join();
    RDP_ASSERT(RustDeskConnectionContinuityExecutor::deferredRemaining() >= 1);

    {
        std::lock_guard<std::mutex> lock(*mutex);
        *release = true;
    }
    condition->notify_all();
    RDP_ASSERT(RustDeskConnectionContinuityExecutor::drainDeferredWithin(
        std::chrono::seconds(1)));
    RDP_ASSERT(RustDeskConnectionContinuityExecutor::shutdownDeferredWithin(
        std::chrono::seconds(1)));
    RDP_ASSERT_EQ(RustDeskConnectionContinuityExecutor::deferredRemaining(),
                  static_cast<std::size_t>(0));
    executor.reset();
}
