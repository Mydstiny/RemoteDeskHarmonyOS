#include "test_runner.h"
#include "rdp/rdp_presentation_metrics.h"

RDP_TEST_CASE(rdp_presentation_metrics_separates_submission_and_rejection_counts) {
    RdpPresentationMetrics metrics;
    metrics.recordInvalid(100, 32);
    metrics.recordSubmission(200, 4096, 120, 300, false);
    metrics.recordSubmission(300, 2048, 80, 200, true);

    RdpPresentMetrics detached;
    detached.result = RdpPresentResult::SurfaceDetached;
    detached.queueWaitUs = 400;
    metrics.recordPresent(400, detached);

    const RdpPresentationMetricsSnapshot snapshot = metrics.snapshot(500);
    RDP_ASSERT_EQ(snapshot.invalidEvents, static_cast<uint64_t>(1));
    RDP_ASSERT_EQ(snapshot.invalidPixels, static_cast<uint64_t>(32));
    RDP_ASSERT_EQ(snapshot.copiedBytes, static_cast<uint64_t>(6144));
    RDP_ASSERT_EQ(snapshot.submittedFrames, static_cast<uint64_t>(2));
    RDP_ASSERT_EQ(snapshot.replacedFrames, static_cast<uint64_t>(1));
    RDP_ASSERT_EQ(snapshot.rejectedFrames, static_cast<uint64_t>(1));
    RDP_ASSERT_EQ(snapshot.surfaceDetachedRejections, static_cast<uint64_t>(1));
}

RDP_TEST_CASE(rdp_presentation_metrics_reports_p50_p95_and_max_for_one_second_window) {
    RdpPresentationMetrics metrics;
    for (int i = 1; i <= 20; ++i) {
        RdpPresentMetrics present;
        present.result = RdpPresentResult::Presented;
        present.queueWaitUs = i * 10;
        present.uploadUs = i * 100;
        present.drawUs = i * 20;
        present.swapUs = i * 30;
        metrics.recordPresent(i * 1000, present);
    }

    const RdpPresentationMetricsSnapshot snapshot = metrics.snapshot(1000001);
    RDP_ASSERT_EQ(snapshot.presentedFrames, static_cast<uint64_t>(20));
    RDP_ASSERT_EQ(snapshot.queueWaitUs.p50, static_cast<int64_t>(100));
    RDP_ASSERT_EQ(snapshot.queueWaitUs.p95, static_cast<int64_t>(190));
    RDP_ASSERT_EQ(snapshot.queueWaitUs.max, static_cast<int64_t>(200));
    RDP_ASSERT_EQ(snapshot.workerUs.p50, static_cast<int64_t>(1500));
    RDP_ASSERT_EQ(snapshot.workerUs.p95, static_cast<int64_t>(2850));
    RDP_ASSERT_EQ(snapshot.workerUs.max, static_cast<int64_t>(3000));
}

RDP_TEST_CASE(rdp_presentation_metrics_excludes_rejections_from_worker_latency) {
    RdpPresentationMetrics metrics;
    RdpPresentMetrics rejected;
    rejected.result = RdpPresentResult::GenerationMismatch;
    rejected.uploadUs = 90000;
    rejected.swapUs = 90000;
    metrics.recordPresent(10, rejected);

    const RdpPresentationMetricsSnapshot snapshot = metrics.snapshot(20);
    RDP_ASSERT_EQ(snapshot.generationRejections, static_cast<uint64_t>(1));
    RDP_ASSERT_EQ(snapshot.workerUs.max, static_cast<int64_t>(0));
}

RDP_TEST_CASE(rdp_presentation_metrics_completed_window_uses_interval_counts) {
    RdpPresentationMetrics metrics;
    metrics.recordSubmission(100, 1000, 10, 20, false);
    RdpPresentMetrics first;
    first.result = RdpPresentResult::Presented;
    metrics.recordPresent(200, first);

    metrics.recordSubmission(1000200, 2000, 20, 30, false);
    RdpPresentationMetricsSnapshot window;
    RDP_ASSERT(metrics.takeCompletedWindow(window));
    RDP_ASSERT_EQ(window.submittedFrames, static_cast<uint64_t>(1));
    RDP_ASSERT_EQ(window.presentedFrames, static_cast<uint64_t>(1));
    RDP_ASSERT_EQ(window.copiedBytes, static_cast<uint64_t>(1000));

    const RdpPresentationMetricsSnapshot lifetime = metrics.snapshot(1000300);
    RDP_ASSERT_EQ(lifetime.submittedFrames, static_cast<uint64_t>(2));
    RDP_ASSERT_EQ(lifetime.copiedBytes, static_cast<uint64_t>(3000));
}
