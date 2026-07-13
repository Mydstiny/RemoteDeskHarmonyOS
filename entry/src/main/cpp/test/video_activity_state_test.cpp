#include "test_runner.h"
#include "video/video_activity_state.h"

RDP_TEST_CASE(video_activity_starts_inactive_until_frame_arrives) {
    VideoActivityState state;
    RDP_ASSERT(!state.hasReceivedFrame());
    state.recordFrame(1920 * 1080 * 4, 1920, 1080);
    RDP_ASSERT(state.hasReceivedFrame());
    RDP_ASSERT(state.frameCount() == 1);
}

RDP_TEST_CASE(video_activity_ignores_invalid_frames) {
    VideoActivityState state;
    state.recordFrame(0, 1920, 1080);
    state.recordFrame(32, 0, 1080);
    state.recordFrame(32, 1920, 0);
    RDP_ASSERT(!state.hasReceivedFrame());
    RDP_ASSERT(state.frameCount() == 0);
}

RDP_TEST_CASE(video_activity_reset_clears_frame_state) {
    VideoActivityState state;
    state.recordFrame(4096, 64, 64);
    state.reset();
    RDP_ASSERT(!state.hasReceivedFrame());
    RDP_ASSERT(state.frameCount() == 0);
}

RDP_TEST_CASE(remote_video_activity_helpers_share_global_state) {
    resetRemoteVideoActivity();
    RDP_ASSERT(!isRemoteVideoPlaybackActive());

    recordRemoteVideoFrame(0, 1920, 1080);
    RDP_ASSERT(!isRemoteVideoPlaybackActive());

    recordRemoteVideoFrame(1920 * 1080 * 4, 1920, 1080);
    RDP_ASSERT(isRemoteVideoPlaybackActive());

    resetRemoteVideoActivity();
    RDP_ASSERT(!isRemoteVideoPlaybackActive());
}
