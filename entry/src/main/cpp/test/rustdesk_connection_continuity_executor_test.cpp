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
    callbacks.fastQuiesce = [&](const auto&) { events.emplace_back("QUIESCE"); };
    callbacks.publishVisibleState = [&](const std::string& event, const auto&) {
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
    callbacks.cancelAttempt = [&](const auto&) { cancelled = true; };
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
    callbacks.cancelAttempt = [&](const auto&) { ++cancellations; };
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

RDP_TEST_CASE(rustdesk_continuity_executor_drops_network_action_when_disconnect_wins) {
    std::atomic<bool> admitted {true};
    int visiblePublications = 0;
    int attempts = 0;
    RustDeskConnectionContinuityExecutor::Callbacks callbacks;
    callbacks.cancelAttempt = [&](const auto&) {
        // Models explicit disconnect completing after the owner produced the
        // network action but before its visible side effects are consumed.
        admitted.store(false, std::memory_order_release);
    };
    callbacks.publishVisibleState = [&](const std::string&, const auto&) {
        ++visiblePublications;
    };
    callbacks.startAttempt = [&](uint32_t) {
        ++attempts;
        return true;
    };
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    callbacks.testAttemptTicketFactory = MakeExplicitTestTicket;
#endif
    RustDeskConnectionContinuityExecutor executor(std::move(callbacks), false);
    executor.begin(191, 251, 0);

    RDP_ASSERT(!executor.onNetworkChanged(true, 80, 1).startAttempt);
    const auto changed = executor.onNetworkChanged(
        true, 81, 2, [&]() { return admitted.load(std::memory_order_acquire); });
    RDP_ASSERT(changed.cancelAttempt);
    RDP_ASSERT(changed.startAttempt);
    executor.pumpForTesting(2);
    RDP_ASSERT_EQ(visiblePublications, 0);
    RDP_ASSERT_EQ(attempts, 0);
}

RDP_TEST_CASE(rustdesk_continuity_executor_forwards_admission_to_final_state_commit) {
    std::atomic<bool> admitted {true};
    std::mutex commitMutex;
    std::mutex barrierMutex;
    std::condition_variable barrierCondition;
    bool callbackEntered = false;
    bool releaseCallback = false;
    int committedPublications = 0;
    RustDeskConnectionContinuityExecutor::Callbacks callbacks;
    callbacks.publishVisibleState = [&](
        const std::string&,
        const RustDeskConnectionContinuityExecutor::ActionAdmission& admission) {
        {
            std::unique_lock<std::mutex> lock(barrierMutex);
            callbackEntered = true;
            barrierCondition.notify_all();
            barrierCondition.wait(lock, [&]() { return releaseCallback; });
        }
        std::lock_guard<std::mutex> commitLock(commitMutex);
        if (!admission || admission()) {
            ++committedPublications;
        }
    };
    RustDeskConnectionContinuityExecutor executor(std::move(callbacks), false);
    executor.begin(192, 252, 0);
    RDP_ASSERT(!executor.onNetworkChanged(true, 90, 1).startAttempt);

    std::thread publisher([&]() {
        (void)executor.onNetworkChanged(
            false, 91, 2,
            [&]() { return admitted.load(std::memory_order_acquire); });
    });
    {
        std::unique_lock<std::mutex> lock(barrierMutex);
        RDP_ASSERT(barrierCondition.wait_for(
            lock, std::chrono::seconds(1), [&]() { return callbackEntered; }));
    }
    {
        std::lock_guard<std::mutex> commitLock(commitMutex);
        admitted.store(false, std::memory_order_release);
    }
    {
        std::lock_guard<std::mutex> lock(barrierMutex);
        releaseCallback = true;
    }
    barrierCondition.notify_all();
    publisher.join();
    RDP_ASSERT_EQ(committedPublications, 0);
}

RDP_TEST_CASE(rustdesk_continuity_executor_newer_network_action_retires_older_side_effects) {
    using Admission = RustDeskConnectionContinuityExecutor::ActionAdmission;
    std::atomic<uint64_t> currentToken {1};
    std::atomic<int> cancelEntries {0};
    std::atomic<int> committedCancellations {0};
    std::atomic<int> committedQuiesces {0};
    std::atomic<int> committedPublications {0};
    std::mutex barrierMutex;
    std::condition_variable barrierCondition;
    bool oldCancelEntered = false;
    bool releaseOldCancel = false;

    RustDeskConnectionContinuityExecutor::Callbacks callbacks;
    callbacks.cancelAttempt = [&](const Admission& admission) {
        if (cancelEntries.fetch_add(1, std::memory_order_acq_rel) == 0) {
            std::unique_lock<std::mutex> lock(barrierMutex);
            oldCancelEntered = true;
            barrierCondition.notify_all();
            barrierCondition.wait(lock, [&]() { return releaseOldCancel; });
        }
        if (!admission || admission()) {
            committedCancellations.fetch_add(1, std::memory_order_relaxed);
        }
    };
    callbacks.fastQuiesce = [&](const Admission& admission) {
        if (!admission || admission()) {
            committedQuiesces.fetch_add(1, std::memory_order_relaxed);
        }
    };
    callbacks.publishVisibleState = [&](const std::string&, const Admission& admission) {
        if (!admission || admission()) {
            committedPublications.fetch_add(1, std::memory_order_relaxed);
        }
    };

    RustDeskConnectionContinuityExecutor executor(std::move(callbacks), false);
    executor.begin(193, 253, 0);
    RDP_ASSERT(!executor.onNetworkChanged(true, 100, 1).startAttempt);
    const auto admissionFor = [&](uint64_t token) -> Admission {
        return [&currentToken, token]() {
            return currentToken.load(std::memory_order_acquire) == token;
        };
    };

    currentToken.store(2, std::memory_order_release);
    std::thread older([&]() {
        (void)executor.onNetworkChanged(false, 101, 2, admissionFor(2));
    });
    {
        std::unique_lock<std::mutex> lock(barrierMutex);
        RDP_ASSERT(barrierCondition.wait_for(
            lock, std::chrono::seconds(1), [&]() { return oldCancelEntered; }));
    }

    currentToken.store(3, std::memory_order_release);
    (void)executor.onNetworkChanged(false, 102, 3, admissionFor(3));
    {
        std::lock_guard<std::mutex> lock(barrierMutex);
        releaseOldCancel = true;
    }
    barrierCondition.notify_all();
    older.join();

    RDP_ASSERT_EQ(cancelEntries.load(std::memory_order_acquire), 2);
    RDP_ASSERT_EQ(committedCancellations.load(std::memory_order_acquire), 1);
    RDP_ASSERT_EQ(committedQuiesces.load(std::memory_order_acquire), 1);
    RDP_ASSERT_EQ(committedPublications.load(std::memory_order_acquire), 1);
}

RDP_TEST_CASE(rustdesk_continuity_executor_rejects_retired_transport_before_owner_commit) {
    RustDeskConnectionContinuityExecutor executor({}, false);
    executor.begin(194, 254, 0);

    const auto action = executor.onTransportEvent(
        {
            true,
            RustDeskTransportErrorClass::Auth,
            120,
            false,
            true,
            10,
        },
        []() { return false; });

    RDP_ASSERT(!action.visibleTransportLost);
    RDP_ASSERT(!action.fastQuiesce);
    RDP_ASSERT(!action.terminal);
    RDP_ASSERT_EQ(executor.state(), RustDeskContinuityState::Connected);
    RDP_ASSERT(executor.networkAvailable());
}

RDP_TEST_CASE(rustdesk_continuity_executor_old_result_cannot_charge_new_network_window) {
    using Admission = RustDeskConnectionContinuityExecutor::ActionAdmission;
    std::atomic<bool> admitted {true};
    std::atomic<int> validationCalls {0};
    std::atomic<int> staleResultPublications {0};
    std::mutex barrierMutex;
    std::condition_variable barrierCondition;
    bool resultCommitEntered = false;
    bool releaseResultCommit = false;

    RustDeskConnectionContinuityExecutor::Callbacks callbacks;
    callbacks.publishVisibleState = [&](const std::string& message, const Admission&) {
        if (message == "RECONNECTING_RETRY_SCHEDULED" ||
            message == "FAILED_RETRY_BUDGET_EXHAUSTED") {
            staleResultPublications.fetch_add(1, std::memory_order_relaxed);
        }
    };
    RustDeskConnectionContinuityExecutor executor(std::move(callbacks), false);
    executor.begin(194, 254, 1000);
    RDP_ASSERT(!executor.onNetworkChanged(true, 110, 1001).startAttempt);
    RDP_ASSERT(executor.onTransportEvent({
        true, RustDeskTransportErrorClass::Reset, 110, false, true, 1010}).startAttempt);

    Admission oldResultAdmission = [&]() {
        if (validationCalls.fetch_add(1, std::memory_order_acq_rel) == 1) {
            std::unique_lock<std::mutex> lock(barrierMutex);
            resultCommitEntered = true;
            barrierCondition.notify_all();
            barrierCondition.wait(lock, [&]() { return releaseResultCommit; });
        }
        return admitted.load(std::memory_order_acquire);
    };
    std::thread oldResult([&]() {
        executor.recordAttemptResult(false, 1020, oldResultAdmission);
    });
    {
        std::unique_lock<std::mutex> lock(barrierMutex);
        RDP_ASSERT(barrierCondition.wait_for(
            lock, std::chrono::seconds(1), [&]() { return resultCommitEntered; }));
    }

    admitted.store(false, std::memory_order_release);
    std::thread newerNetwork([&]() {
        (void)executor.onNetworkChanged(false, 111, 1030, []() { return true; });
    });
    {
        std::lock_guard<std::mutex> lock(barrierMutex);
        releaseResultCommit = true;
    }
    barrierCondition.notify_all();
    oldResult.join();
    newerNetwork.join();

    RDP_ASSERT_EQ(staleResultPublications.load(std::memory_order_acquire), 0);
    RDP_ASSERT_EQ(executor.attempts(), static_cast<uint32_t>(0));
    RDP_ASSERT_EQ(executor.nextRetryMs(), static_cast<uint64_t>(0));
    RDP_ASSERT_EQ(executor.state(), RustDeskContinuityState::TransportLost);
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
    callbacks.firstGenerationReady = [&](const auto&) {
        firstGenerationReady = true;
    };
    callbacks.publishVisibleState = [&](const std::string& event, const auto&) {
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
