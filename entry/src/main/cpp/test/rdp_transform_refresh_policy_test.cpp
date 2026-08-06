#include "test_runner.h"
#include "rdp/rdp_transform_refresh_policy.h"

RDP_TEST_CASE(rdp_transform_refresh_prioritizes_due_source_frame) {
    const RdpTransformRefreshDecision decision = DecideRdpTransformRefresh(
        true, true, 1000, 1000, 1000);
    RDP_ASSERT(decision.action == RdpTransformRefreshAction::PresentSourceFrame);
}

RDP_TEST_CASE(rdp_transform_refresh_coalesces_until_sixty_fps_deadline) {
    const RdpTransformRefreshDecision early = DecideRdpTransformRefresh(
        false, true, 1015, 0, 1016);
    RDP_ASSERT(early.action == RdpTransformRefreshAction::Wait);
    RDP_ASSERT_EQ(early.waitUntilUs, static_cast<int64_t>(1016));

    const RdpTransformRefreshDecision due = DecideRdpTransformRefresh(
        false, true, 1016, 0, 1016);
    RDP_ASSERT(due.action == RdpTransformRefreshAction::PresentRetainedFrame);
    RDP_ASSERT_EQ(NextRdpTransformRefreshDeadlineUs(1016),
                  static_cast<int64_t>(1016 + RdpFrameScheduler::kInterval60FpsUs));
}

RDP_TEST_CASE(rdp_transform_refresh_does_not_block_pending_source_deadline) {
    const RdpTransformRefreshDecision decision = DecideRdpTransformRefresh(
        true, false, 1000, 5000, 0);
    RDP_ASSERT(decision.action == RdpTransformRefreshAction::Wait);
    RDP_ASSERT_EQ(decision.waitUntilUs, static_cast<int64_t>(5000));
}

RDP_TEST_CASE(rdp_transform_refresh_releases_latest_source_after_queue_bound) {
    const RdpTransformRefreshDecision decision = DecideRdpTransformRefresh(
        true, false, 51000, 60000, 0, 1000);
    RDP_ASSERT(decision.action == RdpTransformRefreshAction::PresentSourceFrame);
}

RDP_TEST_CASE(rdp_transform_refresh_keeps_fresh_source_on_pacing_deadline) {
    const RdpTransformRefreshDecision decision = DecideRdpTransformRefresh(
        true, false, 11000, 16000, 0, 10000);
    RDP_ASSERT(decision.action == RdpTransformRefreshAction::Wait);
    RDP_ASSERT_EQ(decision.waitUntilUs, static_cast<int64_t>(16000));
}
