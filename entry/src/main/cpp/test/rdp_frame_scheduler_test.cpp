#include "test_runner.h"
#include "rdp/rdp_frame_scheduler.h"

namespace {

RdpPresentMetrics PresentedAtCost(int64_t workerUs) {
    RdpPresentMetrics present;
    present.result = RdpPresentResult::Presented;
    present.uploadUs = workerUs / 2;
    present.drawUs = workerUs / 4;
    present.swapUs = workerUs - present.uploadUs - present.drawUs;
    return present;
}

void RecordPresented(RdpFrameScheduler& scheduler, int count, int64_t workerUs) {
    for (int i = 0; i < count; ++i) {
        scheduler.recordPresent(PresentedAtCost(workerUs));
    }
}

} // namespace

RDP_TEST_CASE(rdp_frame_scheduler_requires_full_valid_window_before_downgrade) {
    RdpFrameScheduler scheduler;
    RecordPresented(scheduler, 119, 20000);
    RDP_ASSERT_EQ(scheduler.targetFps(), 60);
    RDP_ASSERT_EQ(scheduler.validSamples(), static_cast<size_t>(119));

    RecordPresented(scheduler, 1, 20000);
    RDP_ASSERT_EQ(scheduler.targetFps(), 30);
    RDP_ASSERT_EQ(scheduler.validSamples(), static_cast<size_t>(0));
    RDP_ASSERT_EQ(scheduler.lastP95Us(), static_cast<int64_t>(20000));
}

RDP_TEST_CASE(rdp_frame_scheduler_excludes_rejected_presents) {
    RdpFrameScheduler scheduler;
    RdpPresentMetrics rejected;
    rejected.result = RdpPresentResult::SurfaceDetached;
    for (int i = 0; i < 200; ++i) {
        scheduler.recordPresent(rejected);
    }
    RDP_ASSERT_EQ(scheduler.targetFps(), 60);
    RDP_ASSERT_EQ(scheduler.validSamples(), static_cast<size_t>(0));
}

RDP_TEST_CASE(rdp_frame_scheduler_selects_twenty_fps_for_severe_p95) {
    RdpFrameScheduler scheduler;
    RecordPresented(scheduler, 120, 40000);
    RDP_ASSERT_EQ(scheduler.targetFps(), 20);
    RDP_ASSERT_EQ(scheduler.targetIntervalUs(), static_cast<int64_t>(50000));
}

RDP_TEST_CASE(rdp_frame_scheduler_uses_p95_not_max_or_average) {
    RdpFrameScheduler belowP95;
    RecordPresented(belowP95, 114, 10000);
    RecordPresented(belowP95, 6, 40000);
    RDP_ASSERT_EQ(belowP95.lastP95Us(), static_cast<int64_t>(10000));
    RDP_ASSERT_EQ(belowP95.targetFps(), 60);

    RdpFrameScheduler atP95;
    RecordPresented(atP95, 113, 10000);
    RecordPresented(atP95, 7, 40000);
    RDP_ASSERT_EQ(atP95.lastP95Us(), static_cast<int64_t>(40000));
    RDP_ASSERT_EQ(atP95.targetFps(), 20);
}

RDP_TEST_CASE(rdp_frame_scheduler_recovers_one_level_per_stable_window) {
    RdpFrameScheduler scheduler;
    RecordPresented(scheduler, 120, 40000);
    RDP_ASSERT_EQ(scheduler.targetFps(), 20);

    RecordPresented(scheduler, 120, 10000);
    RDP_ASSERT_EQ(scheduler.targetFps(), 30);
    RecordPresented(scheduler, 120, 10000);
    RDP_ASSERT_EQ(scheduler.targetFps(), 60);
    RDP_ASSERT_EQ(scheduler.adaptationCount(), static_cast<uint64_t>(3));
}

RDP_TEST_CASE(rdp_frame_scheduler_deadline_releases_final_pending_frame) {
    RdpFrameScheduler scheduler;
    const int64_t deadlineUs = scheduler.nextDeadlineUs(1000);
    RDP_ASSERT_EQ(deadlineUs, static_cast<int64_t>(17667));
    RDP_ASSERT(!RdpFrameScheduler::IsDue(17666, deadlineUs));
    RDP_ASSERT(RdpFrameScheduler::IsDue(17667, deadlineUs));
}
