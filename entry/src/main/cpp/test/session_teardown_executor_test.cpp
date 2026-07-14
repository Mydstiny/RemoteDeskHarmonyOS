/**
 * session_teardown_executor_test.cpp - asynchronous teardown execution contracts
 */

#include "test_runner.h"
#include "extensions/session_teardown_executor.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
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
