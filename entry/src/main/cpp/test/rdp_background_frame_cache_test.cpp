#include "test_runner.h"
#include "rdp/rdp_background_frame_cache.h"

RDP_TEST_CASE(rdp_background_cache_policy_requires_enabled_valid_interval_and_frame) {
    RDP_ASSERT(!ShouldCaptureRdpBackgroundFrame(false, 2000, 0, 1000, 1920, 1080, 7680, 8294400));
    RDP_ASSERT(!ShouldCaptureRdpBackgroundFrame(true, 500, 0, 1000, 1920, 1080, 7680, 8294400));
    RDP_ASSERT(!ShouldCaptureRdpBackgroundFrame(true, 2000, 1500, 1000, 1920, 1080, 7680, 8294400));
    RDP_ASSERT(!ShouldCaptureRdpBackgroundFrame(true, 2000, 0, 1000, 0, 1080, 7680, 8294400));
    RDP_ASSERT(!ShouldCaptureRdpBackgroundFrame(true, 2000, 0, 1000, 1920, 1080, 0, 8294400));
    RDP_ASSERT(ShouldCaptureRdpBackgroundFrame(true, 2000, 0, 1000, 1920, 1080, 7680, 8294400));
}

RDP_TEST_CASE(rdp_background_cache_copies_and_snapshots_latest_frame) {
    RdpBackgroundFrameCache cache;
    const uint8_t frame[16] = {
        1, 2, 3, 4, 5, 6, 7, 8,
        9, 10, 11, 12, 13, 14, 15, 16
    };
    RDP_ASSERT(cache.capture(frame, sizeof(frame), 2, 2, 8, 1234));
    RdpBackgroundFrameSnapshot snapshot = cache.snapshot();
    RDP_ASSERT(snapshot.valid);
    RDP_ASSERT(snapshot.width == 2);
    RDP_ASSERT(snapshot.height == 2);
    RDP_ASSERT(snapshot.stride == 8);
    RDP_ASSERT(snapshot.capturedAtMs == 1234);
    RDP_ASSERT(snapshot.data.size() == sizeof(frame));
    RDP_ASSERT(snapshot.data[0] == 1);
    RDP_ASSERT(snapshot.data[15] == 16);
}

RDP_TEST_CASE(rdp_background_cache_clear_invalidates_snapshot) {
    RdpBackgroundFrameCache cache;
    const uint8_t frame[4] = {1, 2, 3, 4};
    RDP_ASSERT(cache.capture(frame, sizeof(frame), 1, 1, 4, 100));
    cache.clear();
    RDP_ASSERT(!cache.snapshot().valid);
}
