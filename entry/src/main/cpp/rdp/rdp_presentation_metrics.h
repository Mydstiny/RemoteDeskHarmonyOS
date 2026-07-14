#ifndef RDP_PRESENTATION_METRICS_H
#define RDP_PRESENTATION_METRICS_H

#include <algorithm>
#include <cstdint>
#include <mutex>
#include <vector>

enum class RdpPresentResult : int32_t {
    Presented = 0,
    NoActiveRenderer = -1,
    RendererNotReady = -2,
    SurfaceDetached = -3,
    GenerationMismatch = -4,
    InvalidFrame = -5,
    MakeCurrentFailed = -6,
    SwapFailed = -7,
    Exception = -98,
};

struct RdpPresentationTarget {
    uint64_t generation = 0;
    RdpPresentResult rejection = RdpPresentResult::NoActiveRenderer;

    bool ready() const {
        return generation != 0 && rejection == RdpPresentResult::Presented;
    }
};

struct RdpPresentMetrics {
    RdpPresentResult result = RdpPresentResult::RendererNotReady;
    uint64_t generation = 0;
    int64_t queueWaitUs = 0;
    int64_t uploadUs = 0;
    int64_t drawUs = 0;
    int64_t swapUs = 0;

    bool presented() const {
        return result == RdpPresentResult::Presented;
    }

    int64_t workerUs() const {
        return uploadUs + drawUs + swapUs;
    }
};

struct RdpPresentationLatencyStats {
    int64_t p50 = 0;
    int64_t p95 = 0;
    int64_t max = 0;
};

struct RdpPresentationMetricsSnapshot {
    uint64_t invalidEvents = 0;
    uint64_t invalidPixels = 0;
    uint64_t copiedBytes = 0;
    uint64_t submittedFrames = 0;
    uint64_t replacedFrames = 0;
    uint64_t rejectedFrames = 0;
    uint64_t presentedFrames = 0;
    uint64_t surfaceDetachedRejections = 0;
    uint64_t generationRejections = 0;
    uint64_t windowSamples = 0;
    int32_t lastPresentResult = static_cast<int32_t>(RdpPresentResult::RendererNotReady);
    uint64_t lastGeneration = 0;
    RdpPresentationLatencyStats callbackUs;
    RdpPresentationLatencyStats copyUs;
    RdpPresentationLatencyStats queueWaitUs;
    RdpPresentationLatencyStats uploadUs;
    RdpPresentationLatencyStats drawUs;
    RdpPresentationLatencyStats swapUs;
    RdpPresentationLatencyStats workerUs;
};

class RdpPresentationMetrics {
public:
    static constexpr int64_t kWindowUs = 1000000;

    void reset(int64_t nowUs = 0) {
        std::lock_guard<std::mutex> lock(mutex_);
        totals_ = RdpPresentationMetricsSnapshot();
        current_ = Window();
        completed_ = Window();
        windowStartUs_ = nowUs;
        completedReady_ = false;
    }

    void recordInvalid(int64_t nowUs, uint64_t pixels, int64_t callbackUs = 0) {
        std::lock_guard<std::mutex> lock(mutex_);
        rollWindowLocked(nowUs);
        ++totals_.invalidEvents;
        totals_.invalidPixels += pixels;
        ++current_.invalidEvents;
        current_.invalidPixels += pixels;
        appendNonNegative(current_.callbackUs, callbackUs);
    }

    void recordSubmission(int64_t nowUs, uint64_t copiedBytes, int64_t copyUs,
                          int64_t callbackUs, bool replaced) {
        std::lock_guard<std::mutex> lock(mutex_);
        rollWindowLocked(nowUs);
        totals_.copiedBytes += copiedBytes;
        ++totals_.submittedFrames;
        current_.copiedBytes += copiedBytes;
        ++current_.submittedFrames;
        if (replaced) {
            ++totals_.replacedFrames;
            ++current_.replacedFrames;
        }
        appendNonNegative(current_.copyUs, copyUs);
        (void)callbackUs;
    }

    void recordPresent(int64_t nowUs, const RdpPresentMetrics& present) {
        std::lock_guard<std::mutex> lock(mutex_);
        rollWindowLocked(nowUs);
        totals_.lastPresentResult = static_cast<int32_t>(present.result);
        totals_.lastGeneration = present.generation;
        if (!present.presented()) {
            ++totals_.rejectedFrames;
            ++current_.rejectedFrames;
            if (present.result == RdpPresentResult::SurfaceDetached) {
                ++totals_.surfaceDetachedRejections;
                ++current_.surfaceDetachedRejections;
            } else if (present.result == RdpPresentResult::GenerationMismatch) {
                ++totals_.generationRejections;
                ++current_.generationRejections;
            }
            return;
        }

        ++totals_.presentedFrames;
        ++current_.presentedFrames;
        appendNonNegative(current_.queueWaitUs, present.queueWaitUs);
        appendNonNegative(current_.uploadUs, present.uploadUs);
        appendNonNegative(current_.drawUs, present.drawUs);
        appendNonNegative(current_.swapUs, present.swapUs);
        appendNonNegative(current_.workerUs, present.workerUs());
    }

    RdpPresentationMetricsSnapshot snapshot(int64_t nowUs) {
        std::lock_guard<std::mutex> lock(mutex_);
        rollWindowLocked(nowUs);
        const Window& latencyWindow = completedReady_ ? completed_ : current_;
        return buildSnapshotLocked(latencyWindow);
    }

    bool takeCompletedWindow(RdpPresentationMetricsSnapshot& snapshot) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!completedReady_) {
            return false;
        }
        snapshot = buildWindowSnapshotLocked(completed_);
        completedReady_ = false;
        return true;
    }

private:
    struct Window {
        uint64_t invalidEvents = 0;
        uint64_t invalidPixels = 0;
        uint64_t copiedBytes = 0;
        uint64_t submittedFrames = 0;
        uint64_t replacedFrames = 0;
        uint64_t rejectedFrames = 0;
        uint64_t presentedFrames = 0;
        uint64_t surfaceDetachedRejections = 0;
        uint64_t generationRejections = 0;
        std::vector<int64_t> callbackUs;
        std::vector<int64_t> copyUs;
        std::vector<int64_t> queueWaitUs;
        std::vector<int64_t> uploadUs;
        std::vector<int64_t> drawUs;
        std::vector<int64_t> swapUs;
        std::vector<int64_t> workerUs;
    };

    static void appendNonNegative(std::vector<int64_t>& samples, int64_t value) {
        samples.push_back(value < 0 ? 0 : value);
    }

    static int64_t percentile(const std::vector<int64_t>& samples, int numerator,
                              int denominator) {
        if (samples.empty()) {
            return 0;
        }
        std::vector<int64_t> sorted(samples);
        std::sort(sorted.begin(), sorted.end());
        const size_t rank =
            (sorted.size() * static_cast<size_t>(numerator) + denominator - 1) /
            static_cast<size_t>(denominator);
        return sorted[rank == 0 ? 0 : rank - 1];
    }

    static RdpPresentationLatencyStats summarize(const std::vector<int64_t>& samples) {
        RdpPresentationLatencyStats result;
        if (samples.empty()) {
            return result;
        }
        result.p50 = percentile(samples, 50, 100);
        result.p95 = percentile(samples, 95, 100);
        result.max = *std::max_element(samples.begin(), samples.end());
        return result;
    }

    void rollWindowLocked(int64_t nowUs) {
        if (windowStartUs_ == 0) {
            windowStartUs_ = nowUs;
            return;
        }
        if (nowUs < windowStartUs_ || nowUs - windowStartUs_ < kWindowUs) {
            return;
        }
        completed_ = std::move(current_);
        current_ = Window();
        windowStartUs_ = nowUs;
        completedReady_ = true;
    }

    RdpPresentationMetricsSnapshot buildSnapshotLocked(const Window& window) const {
        RdpPresentationMetricsSnapshot result = totals_;
        result.windowSamples = window.presentedFrames;
        result.callbackUs = summarize(window.callbackUs);
        result.copyUs = summarize(window.copyUs);
        result.queueWaitUs = summarize(window.queueWaitUs);
        result.uploadUs = summarize(window.uploadUs);
        result.drawUs = summarize(window.drawUs);
        result.swapUs = summarize(window.swapUs);
        result.workerUs = summarize(window.workerUs);
        return result;
    }

    RdpPresentationMetricsSnapshot buildWindowSnapshotLocked(const Window& window) const {
        RdpPresentationMetricsSnapshot result;
        result.invalidEvents = window.invalidEvents;
        result.invalidPixels = window.invalidPixels;
        result.copiedBytes = window.copiedBytes;
        result.submittedFrames = window.submittedFrames;
        result.replacedFrames = window.replacedFrames;
        result.rejectedFrames = window.rejectedFrames;
        result.presentedFrames = window.presentedFrames;
        result.surfaceDetachedRejections = window.surfaceDetachedRejections;
        result.generationRejections = window.generationRejections;
        result.windowSamples = window.presentedFrames;
        result.lastPresentResult = totals_.lastPresentResult;
        result.lastGeneration = totals_.lastGeneration;
        result.callbackUs = summarize(window.callbackUs);
        result.copyUs = summarize(window.copyUs);
        result.queueWaitUs = summarize(window.queueWaitUs);
        result.uploadUs = summarize(window.uploadUs);
        result.drawUs = summarize(window.drawUs);
        result.swapUs = summarize(window.swapUs);
        result.workerUs = summarize(window.workerUs);
        return result;
    }

    mutable std::mutex mutex_;
    RdpPresentationMetricsSnapshot totals_;
    Window current_;
    Window completed_;
    int64_t windowStartUs_ = 0;
    bool completedReady_ = false;
};

#endif // RDP_PRESENTATION_METRICS_H
