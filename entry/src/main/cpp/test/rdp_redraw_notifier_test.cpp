/**
 * rdp_redraw_notifier_test.cpp - callback teardown barrier contracts
 */

#include "test_runner.h"
#include "rdp/rdp_redraw_notifier.h"

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>

RDP_TEST_CASE(rdp_redraw_notifier_waits_for_inflight_callback) {
    RdpRedrawNotifier notifier;
    std::mutex mutex;
    std::condition_variable cv;
    bool entered = false;
    bool release = false;
    std::atomic<int> callbackCount {0};

    notifier.bind([&]() {
        callbackCount.fetch_add(1, std::memory_order_relaxed);
        std::unique_lock<std::mutex> lock(mutex);
        entered = true;
        cv.notify_all();
        cv.wait(lock, [&]() { return release; });
    });

    std::thread callbackThread([&]() { notifier.notify(); });
    {
        std::unique_lock<std::mutex> lock(mutex);
        cv.wait(lock, [&]() { return entered; });
    }

    std::atomic<bool> disabled {false};
    std::thread disableThread([&]() {
        notifier.disableAndWait();
        disabled.store(true, std::memory_order_release);
    });

    RDP_ASSERT(!disabled.load(std::memory_order_acquire));
    {
        std::lock_guard<std::mutex> lock(mutex);
        release = true;
    }
    cv.notify_all();

    callbackThread.join();
    disableThread.join();
    RDP_ASSERT(disabled.load(std::memory_order_acquire));
    notifier.notify();
    RDP_ASSERT_EQ(callbackCount.load(std::memory_order_relaxed), 1);
}

RDP_TEST_CASE(rdp_redraw_notifier_can_be_rebound_after_teardown) {
    RdpRedrawNotifier notifier;
    int firstCount = 0;
    int secondCount = 0;
    notifier.bind([&]() { ++firstCount; });
    notifier.notify();
    notifier.disableAndWait();
    notifier.bind([&]() { ++secondCount; });
    notifier.notify();
    RDP_ASSERT_EQ(firstCount, 1);
    RDP_ASSERT_EQ(secondCount, 1);
}
