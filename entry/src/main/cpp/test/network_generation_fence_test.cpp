#include "common/network_generation_fence.h"
#include "test_runner.h"

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
