#include "test_runner.h"
#include "render/frame_callback_gate.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <stdexcept>
#include <thread>

RDP_TEST_CASE(software_decoder_callback_gate_waits_for_inflight_callback) {
    SoftwareDecoderFrameCallbackGate gate;
    std::mutex stateMutex;
    std::condition_variable stateCv;
    bool entered = false;
    bool release = false;
    std::atomic<int> callCount {0};

    gate.Set([&](const uint8_t*, size_t, int, int, int) {
        std::unique_lock<std::mutex> lock(stateMutex);
        entered = true;
        stateCv.notify_all();
        stateCv.wait(lock, [&]() { return release; });
        callCount.fetch_add(1);
        return 0;
    });

    std::thread renderThread([&]() {
        gate.Invoke(nullptr, 0, 1, 1, 4);
    });

    {
        std::unique_lock<std::mutex> lock(stateMutex);
        RDP_ASSERT(stateCv.wait_for(lock, std::chrono::seconds(1), [&]() { return entered; }));
    }

    std::atomic<bool> clearFinished {false};
    std::thread clearThread([&]() {
        gate.ClearAndWait();
        clearFinished.store(true);
    });

    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    RDP_ASSERT(!clearFinished.load());

    {
        std::lock_guard<std::mutex> lock(stateMutex);
        release = true;
    }
    stateCv.notify_all();
    renderThread.join();
    clearThread.join();

    RDP_ASSERT(clearFinished.load());
    RDP_ASSERT_EQ(callCount.load(), 1);
    RDP_ASSERT_EQ(gate.Invoke(nullptr, 0, 1, 1, 4), 0);
    RDP_ASSERT_EQ(callCount.load(), 1);
}

RDP_TEST_CASE(software_decoder_callback_gate_contains_callback_exception) {
    SoftwareDecoderFrameCallbackGate gate;
    gate.Set([](const uint8_t*, size_t, int, int, int) -> int {
        throw std::runtime_error("renderer callback failure");
    });

    RDP_ASSERT_EQ(gate.Invoke(nullptr, 0, 1, 1, 4), -1);
    gate.ClearAndWait();
    RDP_ASSERT_EQ(gate.Invoke(nullptr, 0, 1, 1, 4), 0);
}
