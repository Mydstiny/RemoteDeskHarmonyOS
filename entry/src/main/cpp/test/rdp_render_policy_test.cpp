/**
 * rdp_render_policy_test.cpp - RDP first-frame rendering policy tests
 */

#include "test_runner.h"
#include "rdp/rdp_render_policy.h"

RDP_TEST_CASE(rdp_render_policy_keeps_first_frames_on_direct_path) {
    RDP_ASSERT(RdpRenderPolicy::ShouldRenderDirect(0, true));
    RDP_ASSERT(RdpRenderPolicy::ShouldRenderDirect(1, true));
    RDP_ASSERT(RdpRenderPolicy::ShouldRenderDirect(2, true));
    RDP_ASSERT(!RdpRenderPolicy::ShouldRenderDirect(3, true));
}

RDP_TEST_CASE(rdp_render_policy_falls_back_when_pump_queue_fails) {
    RDP_ASSERT(RdpRenderPolicy::ShouldRenderDirect(10, false));
}

RDP_TEST_CASE(rdp_render_policy_accepts_small_dirty_rect_after_first_frames) {
    RdpRenderPolicy::DirtyRect rect =
        RdpRenderPolicy::NormalizeDirtyRect(1920, 1080, 100, 80, 320, 180);
    RDP_ASSERT(rect.valid);
    RDP_ASSERT_EQ(rect.x, 100);
    RDP_ASSERT_EQ(rect.y, 80);
    RDP_ASSERT_EQ(rect.width, 320);
    RDP_ASSERT_EQ(rect.height, 180);
    RDP_ASSERT(RdpRenderPolicy::ShouldUseDirtyRect(3, rect, 1920 * 1080 * 4, false));
}

RDP_TEST_CASE(rdp_render_policy_rejects_dirty_rect_when_texture_resync_required) {
    RdpRenderPolicy::DirtyRect rect =
        RdpRenderPolicy::NormalizeDirtyRect(1920, 1080, 100, 80, 320, 180);
    RDP_ASSERT(rect.valid);
    RDP_ASSERT(!RdpRenderPolicy::ShouldUseDirtyRect(3, rect, 1920 * 1080 * 4, true));
}

RDP_TEST_CASE(rdp_render_policy_rejects_dirty_rect_when_uploads_disabled) {
    RdpRenderPolicy::DirtyRect rect =
        RdpRenderPolicy::NormalizeDirtyRect(1920, 1080, 100, 80, 320, 180);
    RDP_ASSERT(rect.valid);
    RDP_ASSERT(!RdpRenderPolicy::ShouldUseDirtyRect(3, rect, 1920 * 1080 * 4, false, false));
}

RDP_TEST_CASE(rdp_render_policy_rejects_out_of_bounds_dirty_rect) {
    RdpRenderPolicy::DirtyRect rect =
        RdpRenderPolicy::NormalizeDirtyRect(1920, 1080, 1900, 1000, 200, 160);
    RDP_ASSERT(!rect.valid);
    RDP_ASSERT(!RdpRenderPolicy::ShouldUseDirtyRect(10, rect, 1920 * 1080 * 4, false));
}

RDP_TEST_CASE(rdp_render_policy_rejects_large_dirty_rects) {
    RdpRenderPolicy::DirtyRect rect =
        RdpRenderPolicy::NormalizeDirtyRect(1920, 1080, 0, 0, 1700, 1000);
    RDP_ASSERT(rect.valid);
    RDP_ASSERT(!RdpRenderPolicy::ShouldUseDirtyRect(10, rect, 1920 * 1080 * 4, false));
}

RDP_TEST_CASE(rdp_render_policy_escalates_pump_replacement_to_full_frame) {
    RDP_ASSERT(!RdpRenderPolicy::ShouldEscalatePumpSubmitToFullFrame(false, false, true));
    RDP_ASSERT(RdpRenderPolicy::ShouldEscalatePumpSubmitToFullFrame(true, true, false));
    RDP_ASSERT(RdpRenderPolicy::ShouldEscalatePumpSubmitToFullFrame(true, false, true));
}
