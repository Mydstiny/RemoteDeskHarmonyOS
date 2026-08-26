#include "moonlight/core/MoonlightSessionOwner.h"
#include "test_runner.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <stdexcept>
#include <thread>

namespace {

using namespace remotedesk::moonlight;
using namespace std::chrono_literals;

class TestGate final {
public:
    void enterAndWait() {
        std::unique_lock<std::mutex> lock(mutex_);
        entered_ = true;
        cv_.notify_all();
        cv_.wait(lock, [this]() { return released_; });
    }

    void enter() {
        std::lock_guard<std::mutex> lock(mutex_);
        entered_ = true;
        cv_.notify_all();
    }

    bool waitEntered(std::chrono::milliseconds timeout = 1s) {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, timeout, [this]() { return entered_; });
    }

    void release() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            released_ = true;
        }
        cv_.notify_all();
    }

private:
    std::mutex mutex_;
    std::condition_variable cv_;
    bool entered_ = false;
    bool released_ = false;
};

class TwoCallerLine final {
public:
    void arriveAndWait() {
        std::unique_lock<std::mutex> lock(mutex_);
        ++arrived_;
        if (arrived_ == 2) {
            open_ = true;
            cv_.notify_all();
            return;
        }
        cv_.wait(lock, [this]() { return open_; });
    }

private:
    std::mutex mutex_;
    std::condition_variable cv_;
    int arrived_ = 0;
    bool open_ = false;
};

MoonlightSessionOwner::Driver immediateDriver(
    std::atomic<int>& starts,
    std::atomic<int>& interrupts,
    std::atomic<int>& stops,
    int startResult = 0) {
    return {
        [&starts, startResult](MoonlightSessionOwner::StartContext& context) {
            starts.fetch_add(1);
            RDP_ASSERT(context.markInterruptible());
            return startResult;
        },
        [&]() { interrupts.fetch_add(1); },
        [&]() { stops.fetch_add(1); },
    };
}

} // namespace

RDP_TEST_CASE(moonlight_session_owner_rejects_invalid_requests_and_driver) {
    auto owner = MoonlightSessionOwner::createForTesting();
    std::atomic<int> calls {0};
    MoonlightSessionOwner::Driver valid {
        [&](MoonlightSessionOwner::StartContext&) { ++calls; return 0; },
        [&]() { ++calls; },
        [&]() { ++calls; },
    };
    RDP_ASSERT_EQ(owner->start(0, 1, valid).status,
                  MoonlightStartStatus::InvalidRequest);
    RDP_ASSERT_EQ(owner->start(1, 0, valid).status,
                  MoonlightStartStatus::InvalidRequest);
    RDP_ASSERT_EQ(owner->start(1, 1, {}).status,
                  MoonlightStartStatus::InvalidDriver);
    RDP_ASSERT_EQ(owner->stop({}, 10ms), MoonlightStopStatus::InvalidKey);
    RDP_ASSERT(!owner->acquireCallback({}).valid());
    RDP_ASSERT_EQ(calls.load(), 0);
}

RDP_TEST_CASE(moonlight_session_owner_arbitrates_two_starts_and_exact_leases) {
    auto owner = MoonlightSessionOwner::createForTesting();
    TestGate startGate;
    std::atomic<int> starts {0};
    std::atomic<int> interrupts {0};
    std::atomic<int> stops {0};
    MoonlightSessionOwner::Driver first {
        [&](MoonlightSessionOwner::StartContext& context) {
            starts.fetch_add(1);
            RDP_ASSERT(context.markInterruptible());
            startGate.enterAndWait();
            return 0;
        },
        [&]() { interrupts.fetch_add(1); startGate.release(); },
        [&]() { stops.fetch_add(1); },
    };
    const auto accepted = owner->start(10, 1, std::move(first));
    RDP_ASSERT_EQ(accepted.status, MoonlightStartStatus::Accepted);
    RDP_ASSERT(startGate.waitEntered());

    std::atomic<int> unusedStarts {0};
    std::atomic<int> unusedInterrupts {0};
    std::atomic<int> unusedStops {0};
    RDP_ASSERT_EQ(owner->start(11, 1,
                               immediateDriver(unusedStarts, unusedInterrupts,
                                               unusedStops)).status,
                  MoonlightStartStatus::Busy);

    auto exact = owner->acquireCallback(accepted.key);
    RDP_ASSERT(exact.valid());
    auto wrongGeneration = accepted.key;
    ++wrongGeneration.generation;
    RDP_ASSERT(!owner->acquireCallback(wrongGeneration).valid());
    auto wrongToken = accepted.key;
    ++wrongToken.ownerToken;
    RDP_ASSERT(!owner->acquireWorker(wrongToken).valid());
    exact.reset();

    startGate.release();
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Running, 1s));
    RDP_ASSERT_EQ(owner->stop(accepted.key, 1s), MoonlightStopStatus::Stopped);
    RDP_ASSERT_EQ(owner->stop(accepted.key, 1s),
                  MoonlightStopStatus::AlreadyTerminal);
    RDP_ASSERT_EQ(starts.load(), 1);
    RDP_ASSERT_EQ(interrupts.load(), 0);
    RDP_ASSERT_EQ(stops.load(), 1);
    RDP_ASSERT_EQ(unusedStarts.load(), 0);
}

RDP_TEST_CASE(moonlight_session_owner_serializes_simultaneous_start_callers) {
    auto owner = MoonlightSessionOwner::createForTesting();
    TwoCallerLine callerLine;
    TestGate acceptedStartGate;
    std::atomic<int> starts {0};
    std::atomic<int> markFailures {0};
    std::atomic<int> interrupts {0};
    std::atomic<int> stops {0};
    auto makeDriver = [&]() {
        return MoonlightSessionOwner::Driver {
            [&](MoonlightSessionOwner::StartContext& context) {
                starts.fetch_add(1);
                if (!context.markInterruptible()) {
                    markFailures.fetch_add(1);
                }
                acceptedStartGate.enterAndWait();
                return 0;
            },
            [&]() { interrupts.fetch_add(1); acceptedStartGate.release(); },
            [&]() { stops.fetch_add(1); },
        };
    };

    MoonlightStartResult first;
    MoonlightStartResult second;
    std::thread firstCaller([&]() {
        callerLine.arriveAndWait();
        first = owner->start(12, 1, makeDriver());
    });
    std::thread secondCaller([&]() {
        callerLine.arriveAndWait();
        second = owner->start(13, 1, makeDriver());
    });
    firstCaller.join();
    secondCaller.join();

    const bool firstAccepted = first.status == MoonlightStartStatus::Accepted;
    RDP_ASSERT(firstAccepted != (second.status == MoonlightStartStatus::Accepted));
    RDP_ASSERT_EQ(firstAccepted ? second.status : first.status,
                  MoonlightStartStatus::Busy);
    const auto accepted = firstAccepted ? first : second;
    RDP_ASSERT(acceptedStartGate.waitEntered());
    acceptedStartGate.release();
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Running, 1s));
    RDP_ASSERT_EQ(owner->stop(accepted.key, 1s), MoonlightStopStatus::Stopped);
    RDP_ASSERT_EQ(starts.load(), 1);
    RDP_ASSERT_EQ(markFailures.load(), 0);
    RDP_ASSERT_EQ(interrupts.load(), 0);
    RDP_ASSERT_EQ(stops.load(), 1);
}

RDP_TEST_CASE(moonlight_session_owner_stop_during_start_interrupts_then_stops_once) {
    auto owner = MoonlightSessionOwner::createForTesting();
    TestGate startGate;
    std::atomic<int> starts {0};
    std::atomic<int> interrupts {0};
    std::atomic<int> stops {0};
    MoonlightSessionOwner::Driver driver {
        [&](MoonlightSessionOwner::StartContext& context) {
            starts.fetch_add(1);
            RDP_ASSERT(context.markInterruptible());
            startGate.enterAndWait();
            return 0;
        },
        [&]() { interrupts.fetch_add(1); startGate.release(); },
        [&]() { stops.fetch_add(1); },
    };
    const auto accepted = owner->start(20, 3, std::move(driver));
    RDP_ASSERT(startGate.waitEntered());
    RDP_ASSERT_EQ(owner->stop(accepted.key, 1s), MoonlightStopStatus::Stopped);
    const auto terminal = owner->snapshot(accepted.key);
    RDP_ASSERT(terminal.matched);
    RDP_ASSERT_EQ(terminal.phase, MoonlightSessionPhase::Stopped);
    RDP_ASSERT(terminal.cancellationRequested);
    RDP_ASSERT(terminal.interruptInvoked);
    RDP_ASSERT(terminal.stopCompleted);
    RDP_ASSERT_EQ(terminal.inFlightWorkers, static_cast<std::size_t>(0));
    RDP_ASSERT_EQ(starts.load(), 1);
    RDP_ASSERT_EQ(interrupts.load(), 1);
    RDP_ASSERT_EQ(stops.load(), 1);
}

RDP_TEST_CASE(moonlight_session_owner_serializes_interrupt_before_stop_and_next_start) {
    auto owner = MoonlightSessionOwner::createForTesting();
    TestGate startGate;
    TestGate interruptGate;
    TestGate stopGate;
    std::atomic<int> starts {0};
    std::atomic<int> interrupts {0};
    std::atomic<int> stops {0};
    MoonlightSessionOwner::Driver driver {
        [&](MoonlightSessionOwner::StartContext& context) {
            starts.fetch_add(1);
            RDP_ASSERT(context.markInterruptible());
            startGate.enterAndWait();
            return 0;
        },
        [&]() {
            interrupts.fetch_add(1);
            startGate.release();
            interruptGate.enterAndWait();
        },
        [&]() {
            stops.fetch_add(1);
            stopGate.enter();
        },
    };
    const auto accepted = owner->start(21, 1, std::move(driver));
    RDP_ASSERT(startGate.waitEntered());

    std::atomic<int> stopStatus {-1};
    std::thread stopper([&]() {
        stopStatus.store(static_cast<int>(owner->stop(accepted.key, 2s)));
    });
    RDP_ASSERT(interruptGate.waitEntered());
    RDP_ASSERT(owner->waitForPhase(accepted.key,
                                   MoonlightSessionPhase::Stopping, 1s));
    RDP_ASSERT(!stopGate.waitEntered(40ms));

    std::atomic<int> otherStarts {0};
    std::atomic<int> otherInterrupts {0};
    std::atomic<int> otherStops {0};
    RDP_ASSERT_EQ(owner->start(22, 1,
                               immediateDriver(otherStarts, otherInterrupts,
                                               otherStops)).status,
                  MoonlightStartStatus::Busy);

    interruptGate.release();
    RDP_ASSERT(stopGate.waitEntered());
    stopper.join();
    RDP_ASSERT_EQ(stopStatus.load(), static_cast<int>(MoonlightStopStatus::Stopped));
    RDP_ASSERT_EQ(starts.load(), 1);
    RDP_ASSERT_EQ(interrupts.load(), 1);
    RDP_ASSERT_EQ(stops.load(), 1);
    RDP_ASSERT_EQ(otherStarts.load(), 0);
}

RDP_TEST_CASE(moonlight_session_owner_delivers_cancel_at_late_interruptible_fence) {
    auto owner = MoonlightSessionOwner::createForTesting();
    TestGate beforeInterruptible;
    std::atomic<int> interrupts {0};
    std::atomic<int> stops {0};
    MoonlightSessionOwner::Driver driver {
        [&](MoonlightSessionOwner::StartContext& context) {
            beforeInterruptible.enterAndWait();
            RDP_ASSERT(context.cancellationRequested());
            RDP_ASSERT(context.markInterruptible());
            return 0;
        },
        [&]() { interrupts.fetch_add(1); },
        [&]() { stops.fetch_add(1); },
    };
    const auto accepted = owner->start(23, 1, std::move(driver));
    RDP_ASSERT(beforeInterruptible.waitEntered());
    RDP_ASSERT_EQ(owner->stop(accepted.key, 20ms), MoonlightStopStatus::TimedOut);
    RDP_ASSERT_EQ(interrupts.load(), 0);
    MoonlightSessionOwner::Driver blockedDriver {
        [](MoonlightSessionOwner::StartContext&) { return -1; },
        []() {},
        []() {},
    };
    RDP_ASSERT_EQ(owner->start(24, 1, std::move(blockedDriver)).status,
                  MoonlightStartStatus::Busy);
    beforeInterruptible.release();
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Stopped, 1s));
    RDP_ASSERT_EQ(interrupts.load(), 1);
    RDP_ASSERT_EQ(stops.load(), 1);
}

RDP_TEST_CASE(moonlight_session_owner_start_failure_releases_lane_without_double_stop) {
    auto owner = MoonlightSessionOwner::createForTesting();
    std::atomic<int> starts {0};
    std::atomic<int> interrupts {0};
    std::atomic<int> stops {0};
    const auto failed = owner->start(
        30, 1, immediateDriver(starts, interrupts, stops, -42));
    RDP_ASSERT(owner->waitForPhase(failed.key, MoonlightSessionPhase::Failed, 1s));
    const auto firstSnapshot = owner->snapshot(failed.key);
    RDP_ASSERT_EQ(firstSnapshot.startResult, -42);
    RDP_ASSERT(!firstSnapshot.stopInvoked);

    const auto second = owner->start(
        30, 2, immediateDriver(starts, interrupts, stops, -7));
    RDP_ASSERT_EQ(second.status, MoonlightStartStatus::Accepted);
    RDP_ASSERT(second.key.ownerToken != failed.key.ownerToken);
    RDP_ASSERT(owner->waitForPhase(second.key, MoonlightSessionPhase::Failed, 1s));
    RDP_ASSERT_EQ(starts.load(), 2);
    RDP_ASSERT_EQ(interrupts.load(), 0);
    RDP_ASSERT_EQ(stops.load(), 0);
}

RDP_TEST_CASE(moonlight_session_owner_drains_callback_and_worker_leases_before_stop) {
    auto owner = MoonlightSessionOwner::createForTesting();
    std::atomic<int> starts {0};
    std::atomic<int> interrupts {0};
    std::atomic<int> stops {0};
    TestGate stopGate;
    auto driver = immediateDriver(starts, interrupts, stops);
    driver.stop = [&]() { stops.fetch_add(1); stopGate.enter(); };
    const auto accepted = owner->start(40, 1, std::move(driver));
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Running, 1s));
    auto callback = owner->acquireCallback(accepted.key);
    auto worker = owner->acquireWorker(accepted.key);
    RDP_ASSERT(callback.valid());
    RDP_ASSERT(worker.valid());
    auto open = owner->snapshot(accepted.key);
    RDP_ASSERT_EQ(open.inFlightCallbacks, static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(open.inFlightWorkers, static_cast<std::size_t>(1));

    std::atomic<int> stopStatus {-1};
    std::thread stopper([&]() {
        stopStatus.store(static_cast<int>(owner->stop(accepted.key, 2s)));
    });
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Stopping, 1s));
    RDP_ASSERT(!owner->acquireCallback(accepted.key).valid());
    RDP_ASSERT(!stopGate.waitEntered(40ms));
    callback.reset();
    RDP_ASSERT(!stopGate.waitEntered(40ms));
    worker.reset();
    RDP_ASSERT(stopGate.waitEntered(1s));
    stopper.join();
    RDP_ASSERT_EQ(stopStatus.load(), static_cast<int>(MoonlightStopStatus::Stopped));
    RDP_ASSERT_EQ(stops.load(), 1);
}

RDP_TEST_CASE(moonlight_session_owner_drain_timeout_keeps_global_lane_closed) {
    auto owner = MoonlightSessionOwner::createForTesting();
    std::atomic<int> starts {0};
    std::atomic<int> interrupts {0};
    std::atomic<int> stops {0};
    const auto accepted = owner->start(
        50, 1, immediateDriver(starts, interrupts, stops));
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Running, 1s));
    auto callback = owner->acquireCallback(accepted.key);
    RDP_ASSERT(callback.valid());
    RDP_ASSERT_EQ(owner->stop(accepted.key, 20ms), MoonlightStopStatus::TimedOut);
    const auto stopping = owner->snapshot(accepted.key);
    RDP_ASSERT_EQ(stopping.phase, MoonlightSessionPhase::Stopping);
    RDP_ASSERT(!stopping.admissionOpen);

    std::atomic<int> otherStarts {0};
    std::atomic<int> otherInterrupts {0};
    std::atomic<int> otherStops {0};
    RDP_ASSERT_EQ(owner->start(51, 1,
                               immediateDriver(otherStarts, otherInterrupts,
                                               otherStops)).status,
                  MoonlightStartStatus::Busy);
    callback.reset();
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Stopped, 1s));
    RDP_ASSERT_EQ(owner->stop(accepted.key, 1s),
                  MoonlightStopStatus::AlreadyTerminal);
    RDP_ASSERT_EQ(stops.load(), 1);
    RDP_ASSERT_EQ(otherStarts.load(), 0);
}

RDP_TEST_CASE(moonlight_session_owner_request_stop_is_exact_and_non_blocking) {
    auto owner = MoonlightSessionOwner::createForTesting();
    std::atomic<int> starts {0};
    std::atomic<int> interrupts {0};
    std::atomic<int> stops {0};
    TestGate stopGate;
    auto driver = immediateDriver(starts, interrupts, stops);
    driver.stop = [&]() { stops.fetch_add(1); stopGate.enter(); };
    const auto accepted = owner->start(55, 9, std::move(driver));
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Running, 1s));

    auto callback = owner->acquireCallback(accepted.key);
    RDP_ASSERT(callback.valid());
    auto stale = accepted.key;
    ++stale.ownerToken;
    RDP_ASSERT_EQ(owner->requestStop(stale), MoonlightStopStatus::StaleOwner);
    RDP_ASSERT_EQ(owner->requestStop(accepted.key),
                  MoonlightStopStatus::StopRequested);

    const auto stopping = owner->snapshot(accepted.key);
    RDP_ASSERT_EQ(stopping.phase, MoonlightSessionPhase::Stopping);
    RDP_ASSERT(stopping.cancellationRequested);
    RDP_ASSERT(!stopping.admissionOpen);
    RDP_ASSERT(!stopGate.waitEntered(40ms));
    RDP_ASSERT_EQ(stops.load(), 0);

    callback.reset();
    RDP_ASSERT(stopGate.waitEntered(1s));
    RDP_ASSERT(owner->waitForPhase(accepted.key, MoonlightSessionPhase::Stopped, 1s));
    RDP_ASSERT_EQ(owner->requestStop(accepted.key),
                  MoonlightStopStatus::AlreadyTerminal);
    RDP_ASSERT_EQ(starts.load(), 1);
    RDP_ASSERT_EQ(interrupts.load(), 0);
    RDP_ASSERT_EQ(stops.load(), 1);
}

RDP_TEST_CASE(moonlight_session_owner_rejects_old_generation_after_new_start) {
    auto owner = MoonlightSessionOwner::createForTesting();
    std::atomic<int> starts {0};
    std::atomic<int> interrupts {0};
    std::atomic<int> stops {0};
    const auto first = owner->start(
        60, 1, immediateDriver(starts, interrupts, stops));
    RDP_ASSERT(owner->waitForPhase(first.key, MoonlightSessionPhase::Running, 1s));
    RDP_ASSERT_EQ(owner->stop(first.key, 1s), MoonlightStopStatus::Stopped);
    const auto second = owner->start(
        60, 2, immediateDriver(starts, interrupts, stops));
    RDP_ASSERT(owner->waitForPhase(second.key, MoonlightSessionPhase::Running, 1s));
    RDP_ASSERT(second.key.ownerToken != first.key.ownerToken);
    RDP_ASSERT(!owner->acquireCallback(first.key).valid());
    RDP_ASSERT_EQ(owner->stop(first.key, 20ms), MoonlightStopStatus::StaleOwner);
    auto current = owner->acquireCallback(second.key);
    RDP_ASSERT(current.valid());
    current.reset();
    RDP_ASSERT_EQ(owner->stop(second.key, 1s), MoonlightStopStatus::Stopped);
    RDP_ASSERT_EQ(starts.load(), 2);
    RDP_ASSERT_EQ(stops.load(), 2);
}

RDP_TEST_CASE(moonlight_session_owner_contains_driver_exceptions) {
    auto owner = MoonlightSessionOwner::createForTesting();
    std::atomic<int> interrupts {0};
    std::atomic<int> stops {0};
    MoonlightSessionOwner::Driver startThrows {
        [](MoonlightSessionOwner::StartContext&) -> int {
            throw std::runtime_error("start");
        },
        [&]() { interrupts.fetch_add(1); },
        [&]() { stops.fetch_add(1); },
    };
    const auto first = owner->start(70, 1, std::move(startThrows));
    RDP_ASSERT(owner->waitForPhase(first.key, MoonlightSessionPhase::Failed, 1s));
    RDP_ASSERT_EQ(owner->snapshot(first.key).driverFailure,
                  MoonlightDriverFailure::StartException);

    std::atomic<int> starts {0};
    MoonlightSessionOwner::Driver stopThrows {
        [&](MoonlightSessionOwner::StartContext& context) {
            starts.fetch_add(1);
            RDP_ASSERT(context.markInterruptible());
            return 0;
        },
        [&]() { interrupts.fetch_add(1); },
        [&]() { stops.fetch_add(1); throw std::runtime_error("stop"); },
    };
    const auto second = owner->start(70, 2, std::move(stopThrows));
    RDP_ASSERT(owner->waitForPhase(second.key, MoonlightSessionPhase::Running, 1s));
    RDP_ASSERT_EQ(owner->stop(second.key, 1s), MoonlightStopStatus::DriverFailure);
    const auto failedStop = owner->snapshot(second.key);
    RDP_ASSERT_EQ(failedStop.phase, MoonlightSessionPhase::Failed);
    RDP_ASSERT_EQ(failedStop.driverFailure, MoonlightDriverFailure::StopException);
    RDP_ASSERT_EQ(starts.load(), 1);
    RDP_ASSERT_EQ(stops.load(), 1);
}

RDP_TEST_CASE(moonlight_session_owner_records_interrupt_exception_fail_closed) {
    auto owner = MoonlightSessionOwner::createForTesting();
    TestGate startGate;
    std::atomic<int> interrupts {0};
    std::atomic<int> stops {0};
    MoonlightSessionOwner::Driver driver {
        [&](MoonlightSessionOwner::StartContext& context) {
            RDP_ASSERT(context.markInterruptible());
            startGate.enterAndWait();
            return -9;
        },
        [&]() {
            interrupts.fetch_add(1);
            startGate.release();
            throw std::runtime_error("interrupt");
        },
        [&]() { stops.fetch_add(1); },
    };
    const auto accepted = owner->start(80, 1, std::move(driver));
    RDP_ASSERT(startGate.waitEntered());
    RDP_ASSERT_EQ(owner->stop(accepted.key, 1s), MoonlightStopStatus::DriverFailure);
    const auto failed = owner->snapshot(accepted.key);
    RDP_ASSERT_EQ(failed.phase, MoonlightSessionPhase::Failed);
    RDP_ASSERT_EQ(failed.driverFailure, MoonlightDriverFailure::InterruptException);
    RDP_ASSERT_EQ(interrupts.load(), 1);
    RDP_ASSERT_EQ(stops.load(), 0);
}

RDP_TEST_CASE(moonlight_session_owner_destructor_stops_and_joins_owned_lane) {
    std::atomic<int> starts {0};
    std::atomic<int> interrupts {0};
    std::atomic<int> stops {0};
    {
        auto owner = MoonlightSessionOwner::createForTesting();
        const auto accepted = owner->start(
            90, 1, immediateDriver(starts, interrupts, stops));
        RDP_ASSERT(owner->waitForPhase(accepted.key,
                                       MoonlightSessionPhase::Running, 1s));
    }
    RDP_ASSERT_EQ(starts.load(), 1);
    RDP_ASSERT_EQ(interrupts.load(), 0);
    RDP_ASSERT_EQ(stops.load(), 1);
}
