/**
 * video_perf_counters_test.cpp - video telemetry counter tests
 */

#include "test_runner.h"
#include "render/video_perf_counters.h"

using Render::VideoPerfCounters;
using Render::VideoPressureLevel;

RDP_TEST_CASE(video_perf_counters_snapshot_resets_after_read) {
    VideoPerfCounters counters;
    counters.recordIngressFrame("rustdesk", 1600, 900, 12000, true);
    counters.recordDecodeResult(0, 2, 1, 0);
    counters.recordRenderCostUs(6000, 3000, 2000, 11000);

    Render::VideoPerfSnapshot good = counters.snapshotAndReset();

    RDP_ASSERT_EQ(good.ingressFrames, 1ULL);
    RDP_ASSERT_EQ(good.decodeOk, 1ULL);
    RDP_ASSERT_EQ(good.keyframes, 1ULL);
    RDP_ASSERT_EQ(good.bytesTotal, 12000ULL);
    RDP_ASSERT(Render::classifyVideoPressure(good) == VideoPressureLevel::Normal);

    Render::VideoPerfSnapshot empty = counters.snapshotAndReset();

    RDP_ASSERT_EQ(empty.ingressFrames, 0ULL);
    RDP_ASSERT_EQ(empty.decodeOk, 0ULL);
    RDP_ASSERT_EQ(empty.renderFrames, 0ULL);
}

RDP_TEST_CASE(video_perf_counters_classifies_severe_pressure) {
    Render::VideoPerfSnapshot bad {};
    bad.ingressFrames = 60;
    bad.decodeQueueMax = 14;
    bad.decodeDrops = 20;
    bad.renderTotalMaxUs = 42000;

    RDP_ASSERT(Render::classifyVideoPressure(bad) == VideoPressureLevel::Severe);
}
