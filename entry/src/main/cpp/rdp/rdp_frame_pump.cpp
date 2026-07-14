/**
 * rdp_frame_pump.cpp - owned latest-frame render worker for FreeRDP GDI frames
 */

#include "rdp_frame_pump.h"
#include "render/gl_renderer.h"

#include <chrono>
#include <exception>
#include <hilog/log.h>
#include <utility>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0004
#define LOG_TAG "RDP_FRAME_PUMP"

namespace {

int64_t SteadyNowUs() {
    return std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

} // namespace

RdpFramePump::RdpFramePump() = default;

RdpFramePump::~RdpFramePump() {
    stop();
}

bool RdpFramePump::start() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (running_) {
        return true;
    }
    ++pumpGeneration_;
    running_ = true;
    hasFrame_ = false;
    frame_ = RdpFrameSubmission();
    fullResyncRequired_.store(true, std::memory_order_release);
    metrics_.reset(SteadyNowUs());
    submitted_.store(0, std::memory_order_relaxed);
    rendered_.store(0, std::memory_order_relaxed);
    replaced_.store(0, std::memory_order_relaxed);
    rejected_.store(0, std::memory_order_relaxed);
    lastWorkerCostUs_.store(0, std::memory_order_relaxed);
    try {
        worker_ = std::thread(&RdpFramePump::loop, this);
    } catch (const std::exception& e) {
        running_ = false;
        OH_LOG_ERROR(LOG_APP, "[RDP-PUMP] start failed: %{public}s", e.what());
        return false;
    } catch (...) {
        running_ = false;
        OH_LOG_ERROR(LOG_APP, "[RDP-PUMP] start failed: unknown exception");
        return false;
    }
    return true;
}

void RdpFramePump::stop() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!running_ && !worker_.joinable()) {
            return;
        }
        running_ = false;
        ++pumpGeneration_;
        hasFrame_ = false;
        frame_ = RdpFrameSubmission();
    }
    cv_.notify_all();
    if (worker_.joinable()) {
        worker_.join();
    }
}

bool RdpFramePump::submitLatest(RdpFrameSubmission&& submission) {
    const bool validOwnedPixels = !submission.pixels.empty() &&
        submission.width > 0 && submission.height > 0 && submission.stride > 0 &&
        submission.rendererGeneration != 0;
    if (!submission.damageSource && !validOwnedPixels) {
        return false;
    }

    const int64_t enqueuedAtUs = submission.enqueuedAtUs;
    const uint64_t copiedBytes = submission.copiedBytes;
    const int64_t copyUs = submission.copyUs;
    const int64_t callbackUs = submission.callbackUs;
    bool replaced = false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!running_) {
            return false;
        }
        replaced = hasFrame_;
        if (replaced) {
            replaced_.fetch_add(1, std::memory_order_relaxed);
        }
        submission.pumpGeneration = pumpGeneration_;
        frame_ = std::move(submission);
        hasFrame_ = true;
        submitted_.fetch_add(1, std::memory_order_relaxed);
        metrics_.recordSubmission(enqueuedAtUs, copiedBytes, copyUs, callbackUs, replaced);
    }
    cv_.notify_one();
    return true;
}

void RdpFramePump::invalidatePending() {
    bool rejectedPending = false;
    uint64_t rendererGeneration = 0;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        ++pumpGeneration_;
        rejectedPending = hasFrame_;
        rendererGeneration = frame_.rendererGeneration;
        hasFrame_ = false;
        frame_ = RdpFrameSubmission();
        fullResyncRequired_.store(true, std::memory_order_release);
    }
    if (rejectedPending) {
        rejected_.fetch_add(1, std::memory_order_relaxed);
        RdpPresentMetrics rejected;
        rejected.result = RdpPresentResult::GenerationMismatch;
        rejected.generation = rendererGeneration;
        metrics_.recordPresent(SteadyNowUs(), rejected);
    }
}

void RdpFramePump::loop() {
    OH_LOG_INFO(LOG_APP, "[RDP-PUMP] render worker started");
    while (true) {
        RdpFrameSubmission frame;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            cv_.wait(lock, [this]() { return !running_ || hasFrame_; });
            if (!running_) {
                break;
            }
            frame = std::move(frame_);
            frame_ = RdpFrameSubmission();
            hasFrame_ = false;
            if (frame.pumpGeneration != pumpGeneration_) {
                continue;
            }
        }

        RdpPresentMetrics present;
        present.generation = frame.rendererGeneration;
        const int64_t queueWaitUs =
            frame.enqueuedAtUs > 0 ? SteadyNowUs() - frame.enqueuedAtUs : 0;
        if (frame.damageSource) {
            const int64_t snapshotBeginUs = SteadyNowUs();
            RdpDamageSnapshot snapshot = frame.damageSource->takeSnapshot();
            const int64_t snapshotCopyUs = SteadyNowUs() - snapshotBeginUs;
            if (snapshot.valid) {
                metrics_.recordCopy(SteadyNowUs(), snapshot.snapshotCopiedBytes, snapshotCopyUs);
                frame.pixels = std::move(snapshot.pixels);
                frame.width = snapshot.width;
                frame.height = snapshot.height;
                frame.stride = snapshot.stride;
                frame.dirtyX = snapshot.damage.x;
                frame.dirtyY = snapshot.damage.y;
                frame.dirtyWidth = snapshot.damage.width;
                frame.dirtyHeight = snapshot.damage.height;
                frame.dirtyValid = !snapshot.fullFrame;
                frame.rendererGeneration = snapshot.rendererGeneration;
            }
        }
        try {
            if (frame.pixels.empty()) {
                present.result = RdpPresentResult::InvalidFrame;
                present.generation = frame.rendererGeneration;
            } else {
                present = frame.dirtyValid ?
                RendererNapi::PresentRawBgraRectActive(
                    frame.pixels.data(), frame.pixels.size(), frame.width, frame.height,
                    frame.stride, frame.dirtyX, frame.dirtyY, frame.dirtyWidth,
                    frame.dirtyHeight, frame.rendererGeneration) :
                RendererNapi::PresentRawBgraActive(
                    frame.pixels.data(), frame.pixels.size(), frame.width, frame.height,
                    frame.stride, frame.rendererGeneration);
            }
            present.queueWaitUs = queueWaitUs;
        } catch (const std::exception& e) {
            present.result = RdpPresentResult::Exception;
            OH_LOG_ERROR(LOG_APP, "[RDP-PUMP] render exception: %{public}s", e.what());
        } catch (...) {
            present.result = RdpPresentResult::Exception;
            OH_LOG_ERROR(LOG_APP, "[RDP-PUMP] render exception: unknown");
        }

        if (present.presented()) {
            rendered_.fetch_add(1, std::memory_order_relaxed);
            lastWorkerCostUs_.store(present.workerUs(), std::memory_order_release);
        } else {
            rejected_.fetch_add(1, std::memory_order_relaxed);
            if (present.result == RdpPresentResult::SurfaceDetached ||
                present.result == RdpPresentResult::GenerationMismatch ||
                present.result == RdpPresentResult::RendererNotReady ||
                present.result == RdpPresentResult::InvalidFrame) {
                fullResyncRequired_.store(true, std::memory_order_release);
            }
        }
        metrics_.recordPresent(SteadyNowUs(), present);

        RdpPresentationMetricsSnapshot window;
        if (metrics_.takeCompletedWindow(window)) {
            OH_LOG_INFO(LOG_APP,
                "[RDP-PRESENT] submitted=%{public}llu presented=%{public}llu replaced=%{public}llu"
                " rejected=%{public}llu detached=%{public}llu copied=%{public}llu"
                " callbackP95=%{public}lldus queueP95=%{public}lldus uploadP95=%{public}lldus"
                " drawP95=%{public}lldus swapP95=%{public}lldus workerP95=%{public}lldus",
                static_cast<unsigned long long>(window.submittedFrames),
                static_cast<unsigned long long>(window.presentedFrames),
                static_cast<unsigned long long>(window.replacedFrames),
                static_cast<unsigned long long>(window.rejectedFrames),
                static_cast<unsigned long long>(window.surfaceDetachedRejections),
                static_cast<unsigned long long>(window.copiedBytes),
                static_cast<long long>(window.callbackUs.p95),
                static_cast<long long>(window.queueWaitUs.p95),
                static_cast<long long>(window.uploadUs.p95),
                static_cast<long long>(window.drawUs.p95),
                static_cast<long long>(window.swapUs.p95),
                static_cast<long long>(window.workerUs.p95));
        }
    }
    OH_LOG_INFO(LOG_APP, "[RDP-PUMP] render worker stopped");
}

void RdpFramePump::recordInvalid(uint64_t pixels, int64_t callbackUs, int64_t nowUs) {
    metrics_.recordInvalid(nowUs, pixels, callbackUs);
}

void RdpFramePump::recordCopy(uint64_t copiedBytes, int64_t copyUs, int64_t nowUs) {
    metrics_.recordCopy(nowUs, copiedBytes, copyUs);
}

void RdpFramePump::recordDirectPresent(const RdpPresentMetrics& present, int64_t nowUs) {
    if (present.presented()) {
        lastWorkerCostUs_.store(present.workerUs(), std::memory_order_release);
    }
    metrics_.recordPresent(nowUs, present);
}

RdpPresentationMetricsSnapshot RdpFramePump::metricsSnapshot(int64_t nowUs) {
    return metrics_.snapshot(nowUs);
}

int64_t RdpFramePump::lastWorkerCostUs() const {
    return lastWorkerCostUs_.load(std::memory_order_acquire);
}

bool RdpFramePump::consumeFullResyncRequired() {
    return fullResyncRequired_.exchange(false, std::memory_order_acq_rel);
}

uint64_t RdpFramePump::submitted() const {
    return submitted_.load(std::memory_order_relaxed);
}

uint64_t RdpFramePump::rendered() const {
    return rendered_.load(std::memory_order_relaxed);
}

uint64_t RdpFramePump::replaced() const {
    return replaced_.load(std::memory_order_relaxed);
}

uint64_t RdpFramePump::rejected() const {
    return rejected_.load(std::memory_order_relaxed);
}

bool RdpFramePump::isRunning() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return running_;
}
