#include "test_runner.h"
#include "render/decoder_lifecycle_gate.h"

#include <atomic>
#include <chrono>
#include <thread>

RDP_TEST_CASE(decoder_lifecycle_gate_rejects_stale_generation_after_flush) {
    DecoderLifecycleGate gate;
    RDP_ASSERT(gate.beginInitialization());
    gate.markRunning();
    const uint64_t beforeFlush = gate.generation();
    RDP_ASSERT(gate.isCurrent(beforeFlush));
    RDP_ASSERT(gate.beginFlush());
    RDP_ASSERT(!gate.isCurrent(beforeFlush));
    gate.finishFlush(true);
    RDP_ASSERT(gate.generation() > beforeFlush);
}

RDP_TEST_CASE(decoder_lifecycle_gate_waits_for_callback_before_flush) {
    DecoderLifecycleGate gate;
    RDP_ASSERT(gate.beginInitialization());
    gate.markRunning();
    const DecoderCallbackLease lease = gate.acquireCallback();
    RDP_ASSERT(lease.accepted);

    std::atomic<bool> flushStarted {false};
    std::atomic<bool> flushEntered {false};
    std::thread flushThread([&]() {
        flushStarted.store(true);
        flushEntered.store(gate.beginFlush());
    });
    while (!flushStarted.load()) {
        std::this_thread::yield();
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
    RDP_ASSERT(!flushEntered.load());
    gate.releaseCallback(lease);
    flushThread.join();
    RDP_ASSERT(flushEntered.load());
    gate.finishFlush(true);
}

RDP_TEST_CASE(decoder_lifecycle_gate_makes_destroy_idempotent) {
    DecoderLifecycleGate gate;
    RDP_ASSERT(gate.beginInitialization());
    gate.markRunning();
    RDP_ASSERT(gate.beginDestroy());
    gate.markDestroyed();
    RDP_ASSERT(!gate.beginDestroy());
    RDP_ASSERT_EQ(gate.state(), DecoderLifecycleState::Destroyed);
}

RDP_TEST_CASE(decoder_lifecycle_gate_serializes_destroy_after_flush) {
    DecoderLifecycleGate gate;
    RDP_ASSERT(gate.beginInitialization());
    gate.markRunning();
    RDP_ASSERT(gate.beginFlush());

    std::atomic<bool> destroyStarted {false};
    std::atomic<bool> destroyEntered {false};
    std::thread destroyThread([&]() {
        destroyStarted.store(true);
        destroyEntered.store(gate.beginDestroy());
    });
    while (!destroyStarted.load()) {
        std::this_thread::yield();
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
    RDP_ASSERT(!destroyEntered.load());

    gate.finishFlush(true);
    destroyThread.join();
    RDP_ASSERT(destroyEntered.load());
    RDP_ASSERT_EQ(gate.state(), DecoderLifecycleState::Destroying);
    gate.markDestroyed();
}
