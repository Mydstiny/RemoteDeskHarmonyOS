#include "common/network_generation_fence.h"
#include "test_runner.h"

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>

RDP_TEST_CASE(network_generation_fence_accepts_only_newer_generations) {
    remotedesk::net::NetworkGenerationFence fence(7, true);

    RDP_ASSERT(!fence.update(false, 0));
    RDP_ASSERT(!fence.update(false, 6));
    RDP_ASSERT(!fence.update(false, 7));
    RDP_ASSERT(fence.update(false, 8));

    const auto snapshot = fence.snapshot();
    RDP_ASSERT_EQ(snapshot.generation, static_cast<uint64_t>(8));
    RDP_ASSERT(!snapshot.available);
}

RDP_TEST_CASE(network_generation_fence_cancels_unavailable_and_stale_attempts) {
    remotedesk::net::NetworkGenerationFence fence(20, true);
    const auto original = fence.snapshot();
    RDP_ASSERT(!fence.shouldCancel(original));

    RDP_ASSERT(fence.update(false, 21));
    RDP_ASSERT(fence.shouldCancel(original));
    const auto unavailable = fence.snapshot();
    RDP_ASSERT(fence.shouldCancel(unavailable));

    RDP_ASSERT(fence.update(true, 22));
    RDP_ASSERT(fence.shouldCancel(unavailable));
    const auto restored = fence.snapshot();
    RDP_ASSERT(!fence.shouldCancel(restored));
}

RDP_TEST_CASE(network_generation_fence_rejects_uninitialized_snapshot) {
    remotedesk::net::NetworkGenerationFence fence(3, true);
    RDP_ASSERT(fence.shouldCancel({0, true}));
}

RDP_TEST_CASE(network_generation_fence_serializes_route_admission_with_update) {
    remotedesk::net::NetworkGenerationFence fence(30, true);
    const auto captured = fence.snapshot();
    std::mutex coordinationMutex;
    std::condition_variable coordinationCondition;
    bool admissionEntered = false;
    bool updateStarted = false;
    bool updateAccepted = false;
    std::atomic<bool> updateFinished {false};

    std::thread updater([&]() {
        {
            std::unique_lock<std::mutex> lock(coordinationMutex);
            coordinationCondition.wait(lock, [&]() { return admissionEntered; });
            updateStarted = true;
        }
        coordinationCondition.notify_all();
        updateAccepted = fence.update(true, 31);
        updateFinished.store(true, std::memory_order_release);
    });

    const bool admitted = fence.admitIfCurrent(captured, [&]() {
        {
            std::unique_lock<std::mutex> lock(coordinationMutex);
            admissionEntered = true;
            coordinationCondition.notify_all();
            coordinationCondition.wait(lock, [&]() { return updateStarted; });
        }
        RDP_ASSERT(!updateFinished.load(std::memory_order_acquire));
    });
    updater.join();

    RDP_ASSERT(admitted);
    RDP_ASSERT(updateAccepted);
    RDP_ASSERT(updateFinished.load(std::memory_order_acquire));
    RDP_ASSERT(fence.shouldCancel(captured));
    bool staleAdmissionRan = false;
    RDP_ASSERT(!fence.admitIfCurrent(captured, [&]() {
        staleAdmissionRan = true;
    }));
    RDP_ASSERT(!staleAdmissionRan);
}
