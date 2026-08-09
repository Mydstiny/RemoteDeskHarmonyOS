/**
 * session_teardown_executor_test.cpp - asynchronous teardown execution contracts
 */

#include "test_runner.h"
#include "extensions/session_teardown_executor.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <stdexcept>

using SessionTeardown::Executor;
using SessionTeardown::State;

RDP_TEST_CASE(session_teardown_enqueue_returns_without_waiting_for_task) {
    Executor executor;
    std::mutex gateMutex;
    std::condition_variable gateCv;
    bool release = false;

    const auto started = std::chrono::steady_clock::now();
    const uint64_t requestId = executor.enqueue([&]() {
        std::unique_lock<std::mutex> lock(gateMutex);
        gateCv.wait(lock, [&]() { return release; });
    });
    const auto elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started).count();

    RDP_ASSERT(requestId > 0);
    RDP_ASSERT(elapsedMs < 50);
    const State initialState = executor.state(requestId);
    RDP_ASSERT(initialState == State::Queued || initialState == State::Running);

    {
        std::lock_guard<std::mutex> lock(gateMutex);
        release = true;
    }
    gateCv.notify_all();
    RDP_ASSERT(executor.waitFor(requestId, std::chrono::milliseconds(1000)));
    RDP_ASSERT_EQ(executor.state(requestId), State::Complete);
}

RDP_TEST_CASE(session_teardown_executor_drains_on_shutdown) {
    std::atomic<bool> completed {false};
    {
        Executor executor;
        RDP_ASSERT(executor.enqueue([&]() { completed.store(true); }) > 0);
    }
    RDP_ASSERT(completed.load());
}

RDP_TEST_CASE(session_teardown_executor_reports_failed_task) {
    Executor executor;
    const uint64_t requestId = executor.enqueue([]() {
        throw std::runtime_error("expected teardown test failure");
    });

    RDP_ASSERT(executor.waitFor(requestId, std::chrono::milliseconds(1000)));
    RDP_ASSERT_EQ(executor.state(requestId), State::Failed);
}

RDP_TEST_CASE(session_teardown_shutdown_budget_reports_remaining_then_drains) {
    Executor executor;
    std::mutex gateMutex;
    std::condition_variable gateCv;
    bool release = false;
    RDP_ASSERT(executor.enqueue([&]() {
        std::unique_lock<std::mutex> lock(gateMutex);
        gateCv.wait(lock, [&]() { return release; });
    }) > 0);

    const auto started = std::chrono::steady_clock::now();
    RDP_ASSERT(!executor.shutdownWithin(std::chrono::milliseconds(50)));
    const auto elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started).count();
    RDP_ASSERT(elapsedMs < 500);
    RDP_ASSERT_EQ(executor.remainingCount(), static_cast<size_t>(1));

    {
        std::lock_guard<std::mutex> lock(gateMutex);
        release = true;
    }
    gateCv.notify_all();
    RDP_ASSERT(executor.shutdownWithin(std::chrono::milliseconds(1000)));
    RDP_ASSERT_EQ(executor.remainingCount(), static_cast<size_t>(0));
}

RDP_TEST_CASE(session_teardown_blocked_owner_transfers_then_reaps_after_release) {
    auto gateMutex = std::make_shared<std::mutex>();
    auto gateCv = std::make_shared<std::condition_variable>();
    auto release = std::make_shared<std::atomic<bool>>(false);
    auto executor = std::make_unique<Executor>();
    RDP_ASSERT(executor->enqueue([gateMutex, gateCv, release]() {
        std::unique_lock<std::mutex> lock(*gateMutex);
        gateCv->wait(lock, [release]() {
            return release->load(std::memory_order_acquire);
        });
    }) > 0);

    RDP_ASSERT(!executor->shutdownWithin(std::chrono::milliseconds(20)));
    RDP_ASSERT_EQ(executor->remainingCount(), static_cast<size_t>(1));

    // The public owner is allowed to return on its fixed deadline.  Its
    // destructor must transfer the still-live worker, not detach or destroy
    // the task's captured state while the worker is blocked.
    executor.reset();
    RDP_ASSERT(SessionTeardown::deferredRemaining() >= 1);
    release->store(true, std::memory_order_release);
    gateCv->notify_all();
    RDP_ASSERT(SessionTeardown::shutdownDeferredWithin(std::chrono::seconds(1)));
    RDP_ASSERT_EQ(SessionTeardown::deferredRemaining(), static_cast<size_t>(0));
}
