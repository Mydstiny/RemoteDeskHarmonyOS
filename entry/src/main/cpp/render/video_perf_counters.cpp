/**
 * video_perf_counters.cpp - shared video pipeline telemetry counters
 */

#include "video_perf_counters.h"

#include <algorithm>
#include <limits>

namespace Render {

namespace {

uint64_t SaturatingAdd(uint64_t left, uint64_t right) {
    const uint64_t max = std::numeric_limits<uint64_t>::max();
    return left > max - right ? max : left + right;
}

uint64_t SaturatingIncrement(uint64_t value) {
    return value == std::numeric_limits<uint64_t>::max() ? value : value + 1;
}

} // namespace

SessionSinkOwnerLease& SharedSessionSinkOwnerLease() {
    static SessionSinkOwnerLease lease;
    return lease;
}

SessionActivationTransaction& SharedSessionActivationTransaction() {
    static SessionActivationTransaction transaction;
    return transaction;
}

void VideoPerfCounters::recordIngressFrame(const char* source, int width, int height, size_t bytes, bool keyframe) {
    std::lock_guard<std::mutex> lock(mutex_);
    current_.source = source ? source : "";
    current_.ingressFrames = SaturatingIncrement(current_.ingressFrames);
    current_.width = width;
    current_.height = height;
    current_.bytesTotal = SaturatingAdd(current_.bytesTotal, static_cast<uint64_t>(bytes));
    if (keyframe) {
        current_.keyframes = SaturatingIncrement(current_.keyframes);
    }
}

void VideoPerfCounters::recordDecodeResult(int ret, size_t queueDepth, uint64_t inputDropped,
                                           uint64_t waitDrops, uint64_t counterGeneration) {
    std::lock_guard<std::mutex> lock(mutex_);
    // Decoder diagnostics expose cumulative counters. The first sample only
    // establishes a baseline. A changed generation or a decrease is an
    // explicit reset/wrap boundary; never turn it into a huge delta.
    const bool generationChanged = dropBaselineInitialized_ &&
        counterGeneration != lastDropCounterGeneration_;
    const bool counterReset = dropBaselineInitialized_ &&
        (inputDropped < lastDroppedTotal_ || waitDrops < lastWaitDropsTotal_);
    if (!dropBaselineInitialized_ || generationChanged || counterReset) {
        if (dropBaselineInitialized_) {
            const uint64_t resetCount = SaturatingIncrement(current_.dropCounterResets);
            // A counter reset is also a hard telemetry-window boundary. Do
            // not carry input/wait deltas, decode errors, queue pressure, or
            // frame counts from the pre-reset decoder into the new baseline.
            const std::string source = current_.source;
            const int width = current_.width;
            const int height = current_.height;
            current_ = VideoPerfSnapshot {};
            current_.source = source;
            current_.width = width;
            current_.height = height;
            current_.dropCounterResets = resetCount;
        }
        dropBaselineInitialized_ = true;
        lastDropCounterGeneration_ = counterGeneration;
        effectiveDropCounterGeneration_ = generationChanged ? counterGeneration :
            (counterReset ? SaturatingIncrement(effectiveDropCounterGeneration_) :
                counterGeneration);
        lastDroppedTotal_ = inputDropped;
        lastWaitDropsTotal_ = waitDrops;
        current_.dropCounterGeneration = effectiveDropCounterGeneration_;
        current_.decodeDropsTotal = SaturatingAdd(inputDropped, waitDrops);
    } else {
        const uint64_t droppedDelta = inputDropped - lastDroppedTotal_;
        const uint64_t waitDropsDelta = waitDrops - lastWaitDropsTotal_;
        lastDroppedTotal_ = inputDropped;
        lastWaitDropsTotal_ = waitDrops;
        current_.dropCounterGeneration = effectiveDropCounterGeneration_;
        current_.inputDropsDelta = SaturatingAdd(current_.inputDropsDelta, droppedDelta);
        current_.waitKeyframeDropsDelta = SaturatingAdd(
            current_.waitKeyframeDropsDelta, waitDropsDelta);
        current_.decodeDrops = SaturatingAdd(
            current_.decodeDrops, SaturatingAdd(droppedDelta, waitDropsDelta));
        current_.decodeDropsTotal = SaturatingAdd(inputDropped, waitDrops);
    }
    current_.decodeQueueMax = std::max(current_.decodeQueueMax, queueDepth);
    current_.decodeSamples = SaturatingIncrement(current_.decodeSamples);
    if (ret == 0) {
        current_.decodeOk = SaturatingIncrement(current_.decodeOk);
    } else if (ret == -1) {
        current_.decodeNotReady = SaturatingIncrement(current_.decodeNotReady);
        current_.decodeErrors = SaturatingIncrement(current_.decodeErrors);
    } else if (ret == -2) {
        current_.decodeBadCodec = SaturatingIncrement(current_.decodeBadCodec);
        current_.decodeErrors = SaturatingIncrement(current_.decodeErrors);
    } else if (ret == -3) {
        current_.decodeMismatch = SaturatingIncrement(current_.decodeMismatch);
        current_.decodeErrors = SaturatingIncrement(current_.decodeErrors);
    } else if (ret < 0) {
        current_.decodeOther = SaturatingIncrement(current_.decodeOther);
        current_.decodeErrors = SaturatingIncrement(current_.decodeErrors);
    }
}

void VideoPerfCounters::recordRenderCostUs(int64_t uploadUs, int64_t drawUs, int64_t swapUs, int64_t totalUs) {
    std::lock_guard<std::mutex> lock(mutex_);
    current_.renderFrames = SaturatingIncrement(current_.renderFrames);
    current_.uploadMaxUs = std::max(current_.uploadMaxUs, uploadUs);
    current_.drawMaxUs = std::max(current_.drawMaxUs, drawUs);
    current_.swapMaxUs = std::max(current_.swapMaxUs, swapUs);
    current_.renderTotalMaxUs = std::max(current_.renderTotalMaxUs, totalUs);
}

VideoPerfSnapshot VideoPerfCounters::snapshot() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return current_;
}

VideoPerfSnapshot VideoPerfCounters::snapshotAndReset() {
    std::lock_guard<std::mutex> lock(mutex_);
    VideoPerfSnapshot snapshot = current_;
    current_ = VideoPerfSnapshot {};
    return snapshot;
}

void VideoPerfCounters::reset() {
    std::lock_guard<std::mutex> lock(mutex_);
    current_ = VideoPerfSnapshot {};
    dropBaselineInitialized_ = false;
    lastDropCounterGeneration_ = 0;
    effectiveDropCounterGeneration_ = 0;
    lastDroppedTotal_ = 0;
    lastWaitDropsTotal_ = 0;
}

VideoPressureController::VideoPressureController(uint32_t overloadWindowsToEscalate,
                                                 uint32_t cleanWindowsToRecover,
                                                 std::chrono::milliseconds windowDuration,
                                                 std::chrono::milliseconds telemetryTimeout)
    : overloadWindowsToEscalate_(std::max<uint32_t>(1, overloadWindowsToEscalate)),
      cleanWindowsToRecover_(std::max<uint32_t>(1, cleanWindowsToRecover)),
      windowDuration_(std::max(std::chrono::milliseconds(1), windowDuration)),
      minimumResidency_(windowDuration_),
      telemetryTimeout_(std::max(windowDuration_, telemetryTimeout)) {}

VideoPressureLevel VideoPressureController::observe(const VideoPerfSnapshot& snapshot) {
    return observeAt(snapshot, std::chrono::steady_clock::now()).level;
}

VideoPressureDecision VideoPressureController::observeAt(
    const VideoPerfSnapshot& snapshot, std::chrono::steady_clock::time_point now) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!clockInitialized_) {
        clockInitialized_ = true;
        windowStartedAt_ = now;
        lastTelemetryAt_ = now;
        levelEnteredAt_ = now;
    }
    if (now < windowStartedAt_) {
        now = windowStartedAt_;
    }
    const VideoPressureLevel previous = level_;
    lastSnapshot_ = snapshot;
    if (snapshot.decodeSamples == 0) {
        if (now - lastTelemetryAt_ >= telemetryTimeout_) {
            timedOut_ = true;
            // A static remote desktop legitimately produces no encoded video
            // and therefore no decoder samples.  Only ingress without a
            // matching decode sample proves that the local decoder pipeline
            // has stalled; silence alone must not create backpressure.
            if (snapshot.ingressFrames > 0 && level_ != VideoPressureLevel::Severe) {
                level_ = VideoPressureLevel::Severe;
                levelEnteredAt_ = now;
            }
        }
        windowStartedAt_ = now;
        return VideoPressureDecision {
            level_, level_ != previous, true, false, timedOut_};
    }

    telemetrySeen_ = true;
    timedOut_ = false;
    lastTelemetryAt_ = now;
    // An absent sample is not proof of a healthy decoder. Do not let a
    // callback gap silently recover an otherwise pressured session.
    const VideoPressureLevel observed = classifyVideoPressure(snapshot);
    if (observed != VideoPressureLevel::Normal) {
        cleanWindows_ = 0;
        if (overloadWindows_ < overloadWindowsToEscalate_) {
            ++overloadWindows_;
        }
        if (overloadWindows_ >= overloadWindowsToEscalate_) {
            overloadWindows_ = 0;
            // Escalation may jump to the level supported by the window, but
            // never drops an already higher level while the window is bad.
            if (static_cast<int>(observed) > static_cast<int>(level_)) {
                level_ = observed;
                levelEnteredAt_ = now;
            }
        }
        windowStartedAt_ = now;
        return VideoPressureDecision {level_, level_ != previous, true, true, false};
    }

    overloadWindows_ = 0;
    if (level_ == VideoPressureLevel::Normal) {
        cleanWindows_ = 0;
        windowStartedAt_ = now;
        return VideoPressureDecision {level_, level_ != previous, true, true, false};
    }
    if (now - levelEnteredAt_ < minimumResidency_) {
        cleanWindows_ = 0;
        windowStartedAt_ = now;
        return VideoPressureDecision {level_, level_ != previous, true, true, false};
    }
    if (cleanWindows_ < cleanWindowsToRecover_) {
        ++cleanWindows_;
    }
    if (cleanWindows_ >= cleanWindowsToRecover_) {
        cleanWindows_ = 0;
        level_ = static_cast<VideoPressureLevel>(static_cast<int>(level_) - 1);
        levelEnteredAt_ = now;
    }
    windowStartedAt_ = now;
    return VideoPressureDecision {level_, level_ != previous, true, true, false};
}

VideoPressureDecision VideoPressureController::tick(std::chrono::steady_clock::time_point now) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!clockInitialized_) {
        clockInitialized_ = true;
        windowStartedAt_ = now;
        lastTelemetryAt_ = now;
        levelEnteredAt_ = now;
        return VideoPressureDecision {level_, false, false, false, false};
    }
    if (now < lastTelemetryAt_) {
        now = lastTelemetryAt_;
    }
    const VideoPressureLevel previous = level_;
    if (now - lastTelemetryAt_ >= telemetryTimeout_) {
        timedOut_ = true;
        // tick() has no ingress sample.  Treat the gap as unavailable
        // telemetry, not as decoder overload; observeAt() handles the real
        // ingress-without-decode stall case.
    }
    return VideoPressureDecision {
        level_, level_ != previous, false, telemetrySeen_ && !timedOut_, timedOut_};
}

bool VideoPressureController::windowDue(std::chrono::steady_clock::time_point now) const {
    std::lock_guard<std::mutex> lock(mutex_);
    return !clockInitialized_ || now < windowStartedAt_ ||
        now - windowStartedAt_ >= windowDuration_;
}

VideoPressureLevel VideoPressureController::level() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return level_;
}

VideoPerfSnapshot VideoPressureController::lastSnapshot() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return lastSnapshot_;
}

uint64_t VideoPressureController::lastDropDelta() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return lastSnapshot_.decodeDrops;
}

bool VideoPressureController::timedOut() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return timedOut_;
}

void VideoPressureController::reset() {
    std::lock_guard<std::mutex> lock(mutex_);
    level_ = VideoPressureLevel::Normal;
    overloadWindows_ = 0;
    cleanWindows_ = 0;
    clockInitialized_ = false;
    telemetrySeen_ = false;
    timedOut_ = false;
    windowStartedAt_ = std::chrono::steady_clock::time_point {};
    lastTelemetryAt_ = std::chrono::steady_clock::time_point {};
    levelEnteredAt_ = std::chrono::steady_clock::time_point {};
    lastSnapshot_ = VideoPerfSnapshot {};
}

VideoPressureLevel classifyVideoPressure(const VideoPerfSnapshot& snapshot) {
    if (snapshot.decodeQueueMax >= 12 || snapshot.decodeDrops >= 10 ||
        snapshot.decodeErrors >= 10 || snapshot.renderTotalMaxUs >= 40000) {
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
