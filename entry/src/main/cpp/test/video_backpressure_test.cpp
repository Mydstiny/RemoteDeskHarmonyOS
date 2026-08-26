/**
 * video_backpressure_test.cpp — 视频过载恢复策略测试
 */

#include "test_runner.h"
#include "render/video_backpressure_controller.h"

using Render::VideoBackpressureController;
using Render::VideoFrameAdmission;

RDP_TEST_CASE(video_backpressure_overflow_enters_keyframe_gate) {
    VideoBackpressureController controller(3);

    VideoFrameAdmission result = controller.admitFrame(3, false);

    RDP_ASSERT(result == VideoFrameAdmission::DropAndWaitForKeyframe);
    RDP_ASSERT(controller.isWaitingForKeyframe());
    RDP_ASSERT(controller.shouldRequestKeyframe());
    RDP_ASSERT_EQ(controller.droppedFrames(), 1ULL);
    RDP_ASSERT_EQ(controller.waitKeyframeDrops(), 0ULL);
    RDP_ASSERT_EQ(controller.keyframeRequests(), 1ULL);
}

RDP_TEST_CASE(video_backpressure_coalesces_overflow_refresh_until_keyframe) {
    VideoBackpressureController controller(3);

    RDP_ASSERT(controller.admitFrame(3, false) ==
               VideoFrameAdmission::DropAndWaitForKeyframe);
    RDP_ASSERT(controller.shouldRequestKeyframe());
    RDP_ASSERT(controller.admitFrame(3, false) ==
               VideoFrameAdmission::DropWaitingKeyframe);
    RDP_ASSERT(controller.shouldRequestKeyframe());
    RDP_ASSERT_EQ(controller.keyframeRequests(), 1ULL);

    RDP_ASSERT(controller.admitFrame(0, true) ==
               VideoFrameAdmission::AcceptRecoveryKeyframe);
    RDP_ASSERT(!controller.shouldRequestKeyframe());

    RDP_ASSERT(controller.admitFrame(3, false) ==
               VideoFrameAdmission::DropAndWaitForKeyframe);
    RDP_ASSERT(controller.shouldRequestKeyframe());
    RDP_ASSERT_EQ(controller.keyframeRequests(), 2ULL);
}

RDP_TEST_CASE(video_backpressure_drops_until_recovery_keyframe) {
    VideoBackpressureController controller(3);
    controller.enterHardWaitForKeyframe();

    VideoFrameAdmission nonKey = controller.admitFrame(0, false);
    VideoFrameAdmission key = controller.admitFrame(0, true);

    RDP_ASSERT(nonKey == VideoFrameAdmission::DropWaitingKeyframe);
    RDP_ASSERT(key == VideoFrameAdmission::AcceptRecoveryKeyframe);
    RDP_ASSERT(!controller.isWaitingForKeyframe());
    RDP_ASSERT(!controller.shouldRequestKeyframe());
    RDP_ASSERT_EQ(controller.droppedFrames(), 0ULL);
    RDP_ASSERT_EQ(controller.waitKeyframeDrops(), 1ULL);
}

RDP_TEST_CASE(video_backpressure_does_not_disable_software_codecs) {
    VideoBackpressureController controller(3);

    VideoFrameAdmission result = controller.admitFrame(3, true);

    RDP_ASSERT(result == VideoFrameAdmission::AcceptRecoveryKeyframe);
    RDP_ASSERT(!controller.isWaitingForKeyframe());
    RDP_ASSERT(!controller.shouldRequestKeyframe());
}
