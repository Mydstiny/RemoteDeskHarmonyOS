/**
 * rdp_frame_pump.cpp - owned latest-frame render worker for FreeRDP GDI frames
 */

#include "rdp_frame_pump.h"
#include "render/gl_renderer.h"

#include <algorithm>
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
    refreshRequested_ = false;
    frame_ = RdpFrameSubmission();
    fullResyncRequired_.store(true, std::memory_order_release);
    metrics_.reset(SteadyNowUs());
    scheduler_.reset();
    glUploadGate_.reset();
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
        refreshRequested_ = false;
        frame_ = RdpFrameSubmission();
        refreshSource_.reset();
    }
    cv_.notify_all();
    if (worker_.joinable()) {
        worker_.join();
    }
}

bool RdpFramePump::submitLatest(RdpFrameSubmission&& submission) {
    if (!submission.damageSource) {
        return false;
    }

    const int64_t enqueuedAtUs = submission.enqueuedAtUs;
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
        metrics_.recordSubmission(enqueuedAtUs, 0, 0, callbackUs, replaced);
    }
    if (!replaced) {
        cv_.notify_one();
    }
    return true;
}

void RdpFramePump::requestRefresh() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!running_ || !refreshSource_) {
            return;
        }
        refreshRequested_ = true;
    }
    cv_.notify_one();
}

void RdpFramePump::setRefreshSource(std::shared_ptr<RdpDamageAccumulator> source) {
    std::lock_guard<std::mutex> lock(mutex_);
    refreshSource_ = std::move(source);
}

void RdpFramePump::invalidatePending() {
    bool rejectedPending = false;
    uint64_t rendererGeneration = 0;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        ++pumpGeneration_;
        rejectedPending = hasFrame_;
        hasFrame_ = false;
        refreshRequested_ = false;
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
    cv_.notify_all();
}

void RdpFramePump::loop() {
    OH_LOG_INFO(LOG_APP, "[RDP-PUMP] render worker started");
    int64_t nextPresentAtUs = 0;
    while (true) {
        RdpFrameSubmission frame;
        std::shared_ptr<RdpDamageAccumulator> refreshSource;
        bool refreshRequested = false;
        uint64_t refreshPumpGeneration = 0;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            while (running_) {
                const int64_t nowUs = SteadyNowUs();
                if (refreshRequested_) {
                    // A transform refresh is an explicit visual deadline. It
                    // must wake even while normal frame pacing is waiting.
                    refreshRequested = true;
                    refreshRequested_ = false;
                    refreshSource = refreshSource_;
                    refreshPumpGeneration = pumpGeneration_;
                    // The retained source contains the newest pixels, so a
                    // queued submission is superseded by this full snapshot.
                    frame_ = RdpFrameSubmission();
                    hasFrame_ = false;
                    break;
                }

                if (hasFrame_ && RdpFrameScheduler::IsDue(nowUs, nextPresentAtUs)) {
                    frame = std::move(frame_);
                    frame_ = RdpFrameSubmission();
                    hasFrame_ = false;
                    if (frame.pumpGeneration == pumpGeneration_) {
                        break;
                    }
                    frame = RdpFrameSubmission();
                    continue;
                }

                if (!hasFrame_) {
                    cv_.wait(lock, [this]() {
                        return !running_ || hasFrame_ || refreshRequested_;
                    });
                    continue;
                }

                // A frame is queued but normal pacing has not reached its
                // deadline. Refresh requests are allowed to interrupt this
                // wait; ordinary frame submissions remain latest-value-wins.
                const int64_t waitUs = std::max<int64_t>(1, nextPresentAtUs - nowUs);
                cv_.wait_for(lock, std::chrono::microseconds(waitUs), [this]() {
                    return !running_ || refreshRequested_;
                });
            }
            if (!running_) {
                break;
            }
        }

        if (!frame.damageSource && refreshRequested && refreshSource) {
            const RdpPresentationTarget target = RendererNapi::GetActivePresentationTarget();
            if (target.ready() && refreshSource->requestFullSnapshot(target.generation)) {
                frame.damageSource = std::move(refreshSource);
                frame.pumpGeneration = refreshPumpGeneration;
                frame.enqueuedAtUs = SteadyNowUs();
            }
        }
        if (!frame.damageSource) {
            continue;
        }

        const int64_t queueWaitUs =
            frame.enqueuedAtUs > 0 ? SteadyNowUs() - frame.enqueuedAtUs : 0;
        const int64_t snapshotBeginUs = SteadyNowUs();
        RdpDamageSnapshot snapshot = frame.damageSource->takeSnapshot();
        const int64_t snapshotCopyUs = SteadyNowUs() - snapshotBeginUs;
        if (snapshot.valid) {
            metrics_.recordCopy(SteadyNowUs(), snapshot.snapshotCopiedBytes, snapshotCopyUs);
        } else if (!frame.damageSource->hasPending()) {
            continue;
        }

        RdpPresentMetrics present;
        present.generation = snapshot.rendererGeneration;
        try {
            if (!snapshot.valid || snapshot.pixels.empty()) {
                present.result = RdpPresentResult::InvalidFrame;
            } else {
                present = !snapshot.fullFrame ?
                RendererNapi::PresentRawBgraRectActive(
                    snapshot.pixels.data(), snapshot.pixels.size(), snapshot.width, snapshot.height,
                    snapshot.stride, snapshot.damage.x, snapshot.damage.y, snapshot.damage.width,
                    snapshot.damage.height, snapshot.rendererGeneration) :
                RendererNapi::PresentRawBgraActive(
                    snapshot.pixels.data(), snapshot.pixels.size(), snapshot.width, snapshot.height,
                    snapshot.stride, snapshot.rendererGeneration);
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
        scheduler_.recordPresent(present);
        glUploadGate_.recordPresent(present);
        metrics_.recordPresent(SteadyNowUs(), present);
        nextPresentAtUs = scheduler_.nextDeadlineUs(SteadyNowUs());

        RdpPresentationMetricsSnapshot window;
        if (metrics_.takeCompletedWindow(window)) {
            const RdpGlUploadGateSnapshot uploadGate = glUploadGate_.snapshot();
            OH_LOG_INFO(LOG_APP,
                "[RDP-PRESENT] submitted=%{public}llu presented=%{public}llu replaced=%{public}llu"
                " rejected=%{public}llu detached=%{public}llu copied=%{public}llu"
                " callbackP95=%{public}lldus queueP95=%{public}lldus uploadP95=%{public}lldus"
                " drawP95=%{public}lldus swapP95=%{public}lldus workerP95=%{public}lldus"
                " targetFps=%{public}d schedulerP95=%{public}lldus adaptations=%{public}llu"
                " uploadGate=%{public}s uploadSwapP95=%{public}lldus"
                " uploadShare=%{public}dpermille gateSamples=%{public}llu",
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
                static_cast<long long>(window.workerUs.p95),
                scheduler_.targetFps(),
                static_cast<long long>(scheduler_.lastP95Us()),
                static_cast<unsigned long long>(scheduler_.adaptationCount()),
                RdpGlUploadGate::DecisionName(uploadGate.decision),
                static_cast<long long>(uploadGate.uploadSwapP95Us),
                uploadGate.uploadSwapSharePermille,
                static_cast<unsigned long long>(uploadGate.evaluatedSamples));
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

RdpPresentationMetricsSnapshot RdpFramePump::metricsSnapshot(int64_t nowUs) {
    return metrics_.snapshot(nowUs);
}

int64_t RdpFramePump::lastWorkerCostUs() const {
    return lastWorkerCostUs_.load(std::memory_order_acquire);
}

int RdpFramePump::targetFps() const {
    return scheduler_.targetFps();
}

int64_t RdpFramePump::targetIntervalUs() const {
    return scheduler_.targetIntervalUs();
}

uint64_t RdpFramePump::adaptationCount() const {
    return scheduler_.adaptationCount();
}

RdpGlUploadGateSnapshot RdpFramePump::glUploadGateSnapshot() const {
    return glUploadGate_.snapshot();
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
