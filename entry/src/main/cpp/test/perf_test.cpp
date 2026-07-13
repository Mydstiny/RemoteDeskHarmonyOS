/**
 * perf_test.cpp — 性能计量单元测试
 */
#include "test_runner.h"
#include "render/perf_stats.h"

RDP_TEST_CASE(frame_stats_single_record) {
    Perf::FrameStats stats;
    RDP_ASSERT(stats.frameCount.load() == 0);
    stats.recordFrame(1000000); // 1s
    RDP_ASSERT_EQ(stats.frameCount.load(), 1ULL);
}

RDP_TEST_CASE(frame_stats_fps_calculation) {
    Perf::FrameStats stats;
    // 模拟 60fps: 每 16666us 一帧
    for (int i = 0; i < 60; i++) {
        stats.recordFrame(static_cast<uint64_t>(i) * 16666);
    }
    // avgFpsX100 应该在 6000 附近 (60.00 fps)
    uint32_t fps = stats.avgFpsX100();
    RDP_ASSERT(fps > 5800 && fps < 6200);
}

RDP_TEST_CASE(frame_stats_dropped) {
    Perf::FrameStats stats;
    RDP_ASSERT(stats.droppedFrames.load() == 0);
    stats.recordDrop();
    stats.recordDrop();
    RDP_ASSERT_EQ(stats.droppedFrames.load(), 2ULL);
}

RDP_TEST_CASE(perf_tracker_singleton) {
    Perf::PerfTracker& a = Perf::PerfTracker::instance();
    Perf::PerfTracker& b = Perf::PerfTracker::instance();
    RDP_ASSERT(&a == &b);
}

RDP_TEST_CASE(perf_tracker_reset) {
    auto& tracker = Perf::PerfTracker::instance();
    tracker.videoStats.recordFrame(1000);
    RDP_ASSERT(tracker.videoStats.frameCount.load() > 0);
    tracker.reset();
    RDP_ASSERT(tracker.videoStats.frameCount.load() == 0);
}

RDP_TEST_CASE(perf_macros) {
    auto& tracker = Perf::PerfTracker::instance();
    uint64_t before = tracker.videoStats.frameCount.load();
    RDP_PERF_RECORD_VIDEO(0);
    RDP_ASSERT_EQ(tracker.videoStats.frameCount.load(), before + 1);
    RDP_PERF_DROP_VIDEO();
    RDP_ASSERT_EQ(tracker.videoStats.droppedFrames.load(), 1ULL);
}
