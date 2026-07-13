/**
 * video_perf_counters.cpp - shared video pipeline telemetry counters
 */

#include "video_perf_counters.h"

#include <algorithm>

namespace Render {

void VideoPerfCounters::recordIngressFrame(const char* source, int width, int height, size_t bytes, bool keyframe) {
    std::lock_guard<std::mutex> lock(mutex_);
    current_.source = source ? source : "";
    current_.ingressFrames++;
    current_.width = width;
    current_.height = height;
    current_.bytesTotal += static_cast<uint64_t>(bytes);
    if (keyframe) {
        current_.keyframes++;
    }
}

void VideoPerfCounters::recordDecodeResult(int ret, size_t queueDepth, uint64_t dropped, uint64_t waitDrops) {
    std::lock_guard<std::mutex> lock(mutex_);
    current_.decodeQueueMax = std::max(current_.decodeQueueMax, queueDepth);
    current_.decodeDrops = std::max(current_.decodeDrops, dropped + waitDrops);
    if (ret == 0) {
        current_.decodeOk++;
    } else if (ret == -1) {
        current_.decodeNotReady++;
    } else if (ret == -3) {
        current_.decodeMismatch++;
    }
}

void VideoPerfCounters::recordRenderCostUs(int64_t uploadUs, int64_t drawUs, int64_t swapUs, int64_t totalUs) {
    std::lock_guard<std::mutex> lock(mutex_);
    current_.renderFrames++;
    current_.uploadMaxUs = std::max(current_.uploadMaxUs, uploadUs);
    current_.drawMaxUs = std::max(current_.drawMaxUs, drawUs);
    current_.swapMaxUs = std::max(current_.swapMaxUs, swapUs);
    current_.renderTotalMaxUs = std::max(current_.renderTotalMaxUs, totalUs);
}

VideoPerfSnapshot VideoPerfCounters::snapshotAndReset() {
    std::lock_guard<std::mutex> lock(mutex_);
    VideoPerfSnapshot snapshot = current_;
    current_ = VideoPerfSnapshot {};
    return snapshot;
}

VideoPressureLevel classifyVideoPressure(const VideoPerfSnapshot& snapshot) {
    if (snapshot.decodeQueueMax >= 12 || snapshot.decodeDrops >= 10 || snapshot.renderTotalMaxUs >= 40000) {
        return VideoPressureLevel::Severe;
    }
    if (snapshot.decodeQueueMax >= 8 || snapshot.decodeDrops >= 4 || snapshot.renderTotalMaxUs >= 28000) {
        return VideoPressureLevel::Moderate;
    }
    if (snapshot.decodeQueueMax >= 4 || snapshot.renderTotalMaxUs >= 18000 || snapshot.swapMaxUs >= 16000) {
        return VideoPressureLevel::Mild;
    }
    return VideoPressureLevel::Normal;
}

const char* videoPressureName(VideoPressureLevel level) {
    switch (level) {
        case VideoPressureLevel::Mild:
            return "mild";
        case VideoPressureLevel::Moderate:
            return "moderate";
        case VideoPressureLevel::Severe:
            return "severe";
        case VideoPressureLevel::Normal:
        default:
            return "normal";
    }
}

} // namespace Render
