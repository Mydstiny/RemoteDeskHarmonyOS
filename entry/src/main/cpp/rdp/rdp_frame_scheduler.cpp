#include "rdp_frame_scheduler.h"

#include <algorithm>

void RdpFrameScheduler::reset() {
    std::lock_guard<std::mutex> lock(mutex_);
    samples_.fill(0);
    sampleCount_ = 0;
    targetFps_ = 60;
    lastP95Us_ = 0;
    adaptationCount_ = 0;
}

void RdpFrameScheduler::recordPresent(const RdpPresentMetrics& present) {
    if (!present.presented()) {
        return;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    samples_[sampleCount_++] = std::max<int64_t>(0, present.workerUs());
    if (sampleCount_ < kDecisionSamples) {
        return;
    }

    std::array<int64_t, kDecisionSamples> sorted = samples_;
    std::sort(sorted.begin(), sorted.end());
    constexpr size_t kP95Index = (kDecisionSamples * 95 + 99) / 100 - 1;
    lastP95Us_ = sorted[kP95Index];
    sampleCount_ = 0;
    adaptLocked(lastP95Us_);
}

void RdpFrameScheduler::adaptLocked(int64_t p95Us) {
    const int previousFps = targetFps_;
    if (targetFps_ == 60) {
        if (p95Us > kInterval30FpsUs) {
            targetFps_ = 20;
        } else if (p95Us > kInterval60FpsUs) {
            targetFps_ = 30;
        }
    } else if (targetFps_ == 30) {
        if (p95Us > kInterval30FpsUs) {
            targetFps_ = 20;
        } else if (p95Us <= 13333) {
            targetFps_ = 60;
        }
    } else if (p95Us <= 26667) {
        targetFps_ = 30;
    }

    if (targetFps_ != previousFps) {
        ++adaptationCount_;
    }
}

int RdpFrameScheduler::targetFps() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return targetFps_;
}

int64_t RdpFrameScheduler::targetIntervalUs() const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (targetFps_ == 20) {
        return kInterval20FpsUs;
    }
    if (targetFps_ == 30) {
        return kInterval30FpsUs;
    }
    return kInterval60FpsUs;
}

int64_t RdpFrameScheduler::nextDeadlineUs(int64_t completedAtUs) const {
    return completedAtUs + targetIntervalUs();
}

bool RdpFrameScheduler::IsDue(int64_t nowUs, int64_t deadlineUs) {
    return deadlineUs <= 0 || nowUs >= deadlineUs;
}

size_t RdpFrameScheduler::validSamples() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return sampleCount_;
}

int64_t RdpFrameScheduler::lastP95Us() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return lastP95Us_;
}

uint64_t RdpFrameScheduler::adaptationCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return adaptationCount_;
}
