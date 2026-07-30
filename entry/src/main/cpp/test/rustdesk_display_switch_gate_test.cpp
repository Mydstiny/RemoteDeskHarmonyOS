#include "test_runner.h"
#include "rustdesk/rustdesk_display_switch_gate.h"

#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>

RDP_TEST_CASE(rustdesk_display_switch_requires_ack_then_target_keyframe) {
    RustDeskDisplaySwitchGate gate;
    const auto initial = gate.observeDisplay(0);
    RDP_ASSERT(initial.publishDisplay);
    RDP_ASSERT_EQ(initial.display, 0);

    const uint64_t generation = gate.begin(1);
    RDP_ASSERT_EQ(generation, 1);
    RDP_ASSERT(gate.snapshot().inputBlocked);

    RDP_ASSERT(!gate.observeDisplay(0).publishDisplay);
    RDP_ASSERT(!gate.observeFrame(1, true).acceptFrame);
    RDP_ASSERT(!gate.observeDisplay(1).publishDisplay);
    RDP_ASSERT(!gate.observeFrame(1, false).acceptFrame);

    const auto committed = gate.observeFrame(1, true);
    RDP_ASSERT(committed.acceptFrame);
    RDP_ASSERT(committed.publishDisplay);
    RDP_ASSERT_EQ(committed.display, 1);
    RDP_ASSERT_EQ(gate.snapshot().readyGeneration, generation);
    RDP_ASSERT(!gate.snapshot().inputBlocked);
}

RDP_TEST_CASE(rustdesk_display_switch_latest_generation_wins) {
    RustDeskDisplaySwitchGate gate;
    gate.observeDisplay(0);
    const uint64_t first = gate.begin(1);
    const uint64_t latest = gate.begin(2);
    RDP_ASSERT(latest > first);

    RDP_ASSERT(!gate.observeDisplay(1).publishDisplay);
    RDP_ASSERT(!gate.observeFrame(1, true).acceptFrame);
    RDP_ASSERT(!gate.observeFrame(2, true).acceptFrame);
    RDP_ASSERT(!gate.observeDisplay(2).publishDisplay);

    const auto committed = gate.observeFrame(2, true);
    RDP_ASSERT(committed.acceptFrame);
    RDP_ASSERT_EQ(gate.snapshot().readyGeneration, latest);
    RDP_ASSERT_EQ(gate.snapshot().confirmedDisplay, 2);

    RDP_ASSERT(gate.observeFrame(2, false).acceptFrame);
}

RDP_TEST_CASE(rustdesk_display_switch_accepts_authoritative_post_commit_fallback) {
    RustDeskDisplaySwitchGate gate;
    gate.observeDisplay(0);
    gate.begin(2);
    gate.observeDisplay(2);
    RDP_ASSERT(gate.observeFrame(2, true).acceptFrame);

    const auto fallback = gate.observeDisplay(1);
    RDP_ASSERT(fallback.publishDisplay);
    RDP_ASSERT_EQ(fallback.display, 1);
    RDP_ASSERT(gate.observeFrame(1, true).acceptFrame);
    RDP_ASSERT(!gate.observeFrame(2, true).acceptFrame);
}

RDP_TEST_CASE(rustdesk_display_switch_can_return_to_the_confirmed_display) {
    RustDeskDisplaySwitchGate gate;
    gate.observeDisplay(0);
    gate.begin(1);
    const uint64_t returnGeneration = gate.begin(0);

    gate.observeDisplay(0);
    const auto committed = gate.observeFrame(0, true);
    RDP_ASSERT(committed.acceptFrame);
    RDP_ASSERT_EQ(gate.snapshot().readyGeneration, returnGeneration);
    RDP_ASSERT_EQ(gate.snapshot().confirmedDisplay, 0);
}

RDP_TEST_CASE(rustdesk_display_switch_dispatch_finishes_before_next_generation_begins) {
    RustDeskDisplaySwitchCoordinator coordinator;
    {
        auto lease = coordinator.acquire();
        lease.observeDisplay(0);
        lease.begin(1);
        lease.observeDisplay(1);
    }

    std::mutex stateMutex;
    std::condition_variable stateChanged;
    bool dispatchEntered = false;
    bool releaseDispatch = false;
    bool beginStarted = false;
    bool beginCompleted = false;
    uint64_t latestGeneration = 0;

    std::thread frameThread([&]() {
        auto lease = coordinator.acquire();
        const auto decision = lease.observeFrame(1, true);
        RDP_ASSERT(decision.acceptFrame);
        {
            std::lock_guard<std::mutex> lock(stateMutex);
            dispatchEntered = true;
        }
        stateChanged.notify_all();

        std::unique_lock<std::mutex> lock(stateMutex);
        RDP_ASSERT(stateChanged.wait_for(lock, std::chrono::seconds(1), [&]() {
            return releaseDispatch;
        }));
    });

    {
        std::unique_lock<std::mutex> lock(stateMutex);
        RDP_ASSERT(stateChanged.wait_for(lock, std::chrono::seconds(1), [&]() {
            return dispatchEntered;
        }));
    }

    std::thread beginThread([&]() {
        {
            std::lock_guard<std::mutex> lock(stateMutex);
            beginStarted = true;
        }
        stateChanged.notify_all();
        auto lease = coordinator.acquire();
        latestGeneration = lease.begin(2);
        {
            std::lock_guard<std::mutex> lock(stateMutex);
            beginCompleted = true;
        }
        stateChanged.notify_all();
    });

    {
        std::unique_lock<std::mutex> lock(stateMutex);
        RDP_ASSERT(stateChanged.wait_for(lock, std::chrono::seconds(1), [&]() {
            return beginStarted;
        }));
        RDP_ASSERT(!stateChanged.wait_for(lock, std::chrono::milliseconds(50), [&]() {
            return beginCompleted;
        }));
        releaseDispatch = true;
    }
    stateChanged.notify_all();
    frameThread.join();
    beginThread.join();

    RDP_ASSERT(beginCompleted);
    RDP_ASSERT(latestGeneration > 1);
    const auto snapshot = coordinator.snapshot();
    RDP_ASSERT_EQ(snapshot.generation, latestGeneration);
    RDP_ASSERT_EQ(snapshot.pendingDisplay, 2);
    RDP_ASSERT(snapshot.inputBlocked);
}
