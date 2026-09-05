#include "rdp/rdp_preflight_operation_fence.h"
#include "test_runner.h"

#include <condition_variable>
#include <mutex>
#include <thread>

namespace {

struct AdmissionSnapshotBarrier {
    std::mutex mutex;
    std::condition_variable condition;
    bool snapshotCaptured {false};
    bool resume {false};
};

void WaitAfterAdmissionSnapshot(void* opaque) noexcept {
    auto* barrier = static_cast<AdmissionSnapshotBarrier*>(opaque);
    std::unique_lock<std::mutex> lock(barrier->mutex);
    barrier->snapshotCaptured = true;
    barrier->condition.notify_all();
    barrier->condition.wait(lock, [barrier]() { return barrier->resume; });
}

}  // namespace

RDP_TEST_CASE(rdp_preflight_fence_counts_and_invalidates_active_operations) {
    remotedesk::rdp::RdpPreflightOperationFence fence;
    const auto first = fence.begin();
    const auto second = fence.begin();
    RDP_ASSERT_EQ(fence.active(), static_cast<uint64_t>(2));
    RDP_ASSERT(!fence.shouldCancel(first));
    RDP_ASSERT_EQ(fence.cancelAll(), static_cast<uint64_t>(2));
    RDP_ASSERT(fence.shouldCancel(first));
    RDP_ASSERT(fence.shouldCancel(second));
    fence.end();
    fence.end();
    RDP_ASSERT_EQ(fence.active(), static_cast<uint64_t>(0));
}

RDP_TEST_CASE(rdp_preflight_fence_keeps_new_generation_current) {
    remotedesk::rdp::RdpPreflightOperationFence fence;
    const auto oldToken = fence.begin();
    fence.cancelAll();
    const auto newToken = fence.begin();
    RDP_ASSERT(fence.shouldCancel(oldToken));
    RDP_ASSERT(!fence.shouldCancel(newToken));
    fence.end();
    fence.end();
    // Defensive extra completion must not underflow the active count.
    fence.end();
    RDP_ASSERT_EQ(fence.active(), static_cast<uint64_t>(0));
}

RDP_TEST_CASE(rdp_preflight_fence_closes_admission_until_scope_transition_ends) {
    remotedesk::rdp::RdpPreflightOperationFence fence;
    const auto oldToken = fence.begin();
    RDP_ASSERT(oldToken != 0);
    RDP_ASSERT_EQ(fence.closeAndCancelAll(), static_cast<uint64_t>(1));
    RDP_ASSERT(!fence.admissionOpen());
    RDP_ASSERT(fence.shouldCancel(oldToken));
    RDP_ASSERT_EQ(fence.begin(), static_cast<uint64_t>(0));
    RDP_ASSERT_EQ(fence.active(), static_cast<uint64_t>(1));

    fence.end();
    RDP_ASSERT_EQ(fence.active(), static_cast<uint64_t>(0));
    RDP_ASSERT(fence.reopen());
    const auto newToken = fence.begin();
    RDP_ASSERT(newToken != 0);
    RDP_ASSERT(!fence.shouldCancel(newToken));
    fence.end();
}

RDP_TEST_CASE(rdp_preflight_fence_rejects_a_stale_admission_snapshot_after_reopen) {
    AdmissionSnapshotBarrier barrier;
    remotedesk::rdp::RdpPreflightOperationFence fence(
        WaitAfterAdmissionSnapshot, &barrier);
    remotedesk::rdp::RdpPreflightOperationFence::Token staleToken = 99;
    std::thread staleAdmission([&]() { staleToken = fence.begin(); });
    {
        std::unique_lock<std::mutex> lock(barrier.mutex);
        barrier.condition.wait(lock, [&barrier]() {
            return barrier.snapshotCaptured;
        });
    }
    RDP_ASSERT_EQ(fence.active(), static_cast<uint64_t>(0));
    RDP_ASSERT_EQ(fence.closeAndCancelAll(), static_cast<uint64_t>(0));
    RDP_ASSERT(fence.reopen());
    {
        std::lock_guard<std::mutex> lock(barrier.mutex);
        barrier.resume = true;
    }
    barrier.condition.notify_all();
    staleAdmission.join();
    // The suspended caller captured the old open state before close/reopen.
    // It must not retry into the new generation or leave active inflated.
    RDP_ASSERT_EQ(staleToken, static_cast<uint64_t>(0));
    RDP_ASSERT_EQ(fence.active(), static_cast<uint64_t>(0));

    // Disable the one-shot test barrier before checking a normal new caller.
    barrier.snapshotCaptured = false;
    barrier.resume = true;
    const auto newToken = fence.begin();
    RDP_ASSERT(newToken != 0);
    RDP_ASSERT(!fence.shouldCancel(newToken));
    fence.end();
}
