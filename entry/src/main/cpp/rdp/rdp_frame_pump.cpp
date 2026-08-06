/**
 * rdp_frame_pump.cpp - owned latest-frame render worker for FreeRDP GDI frames
 */

#include "rdp_frame_pump.h"
#include "render/gl_renderer.h"
#include "rdp_transform_refresh_policy.h"

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <exception>
#include <hilog/log.h>
#include <deque>
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

class RdpFramePumpReaper {
public:
    RdpFramePumpReaper() : worker_([this]() { run(); }) {}

    void enqueue(std::shared_ptr<RdpFramePump> pump) {
        if (!pump) return;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            pending_.push_back(std::move(pump));
        }
        cv_.notify_one();
    }

    bool drainWithin(std::chrono::milliseconds timeout) {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, timeout, [this]() {
            return pending_.empty() && active_ == 0;
        });
    }

    std::size_t remaining() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return pending_.size() + active_;
    }

    bool shutdownWithin(std::chrono::milliseconds timeout) {
        const auto deadline = std::chrono::steady_clock::now() + timeout;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopping_ = true;
        }
        cv_.notify_all();
        std::unique_lock<std::mutex> lock(mutex_);
        if (!cv_.wait_until(lock, deadline, [this]() { return workerDone_; })) {
            return false;
        }
        lock.unlock();
        if (worker_.joinable()) worker_.join();
        return true;
    }

private:
    void run() {
        for (;;) {
            std::shared_ptr<RdpFramePump> pump;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                cv_.wait(lock, [this]() { return stopping_ || !pending_.empty(); });
                if (pending_.empty() && stopping_) {
                    workerDone_ = true;
                    cv_.notify_all();
                    return;
                }
                pump = std::move(pending_.front());
                pending_.pop_front();
                ++active_;
            }
            // Request stop with zero caller budget. Do not block the single
            // reaper behind one stalled pump: completed records behind it must
            // still be joined and released.
            (void)pump->stopWithin(std::chrono::milliseconds(0));
            if (!pump->workerDoneForDeferredJoin()) {
                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    pending_.push_back(std::move(pump));
                    --active_;
                }
                cv_.notify_all();
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }
            pump->joinAfterWorkerDone();
            {
                std::lock_guard<std::mutex> lock(mutex_);
                --active_;
                cv_.notify_all();
            }
        }
    }

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::deque<std::shared_ptr<RdpFramePump>> pending_;
    std::thread worker_;
    bool stopping_ = false;
    bool workerDone_ = false;
    std::size_t active_ = 0;
};

std::mutex g_framePumpReaperMutex;
RdpFramePumpReaper* g_framePumpReaper = nullptr;

RdpFramePumpReaper& framePumpReaper() {
    std::lock_guard<std::mutex> lock(g_framePumpReaperMutex);
    if (!g_framePumpReaper) g_framePumpReaper = new RdpFramePumpReaper();
    return *g_framePumpReaper;
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
    workerDone_ = false;
    hasFrame_ = false;
    transformRefreshRequested_ = false;
    transformRefreshSequence_ = 0;
    owner_ = Render::DecoderSessionIdentity {};
    frame_ = RdpFrameSubmission();
    fullResyncRequired_.store(true, std::memory_order_release);
    metrics_.reset(SteadyNowUs());
    scheduler_.reset();
    glUploadGate_.reset();
    pboExperimentEnabled_ = false;
    pboExperimentComplete_ = false;
    pboBaselineWorkerP95Us_ = 0;
    pboTrialSampleCount_ = 0;
    pboTrialWorkerSamples_.fill(0);
    submitted_.store(0, std::memory_order_relaxed);
    rendered_.store(0, std::memory_order_relaxed);
    replaced_.store(0, std::memory_order_relaxed);
    rejected_.store(0, std::memory_order_relaxed);
    lastWorkerCostUs_.store(0, std::memory_order_relaxed);
    try {
        worker_ = std::thread(&RdpFramePump::loop, this);
    } catch (const std::exception& e) {
        running_ = false;
        workerDone_ = true;
        OH_LOG_ERROR(LOG_APP, "[RDP-PUMP] start failed: %{public}s", e.what());
        return false;
    } catch (...) {
        running_ = false;
        workerDone_ = true;
        OH_LOG_ERROR(LOG_APP, "[RDP-PUMP] start failed: unknown exception");
        return false;
    }
    return true;
}

void RdpFramePump::stop() {
    if (stopWithin(std::chrono::milliseconds(500))) return;
    try {
        deferStopAndJoin(shared_from_this());
    } catch (const std::bad_weak_ptr&) {
        std::abort();
    }
}

bool RdpFramePump::stopWithin(std::chrono::milliseconds timeout) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!running_ && !worker_.joinable()) {
            return true;
        }
        running_ = false;
        ++pumpGeneration_;
        hasFrame_ = false;
        transformRefreshRequested_ = false;
        transformRefreshSequence_ = 0;
        owner_ = Render::DecoderSessionIdentity {};
        frame_ = RdpFrameSubmission();
    }
    cv_.notify_all();
    if (!worker_.joinable()) return true;
    if (worker_.get_id() == std::this_thread::get_id()) return false;
    std::unique_lock<std::mutex> lock(mutex_);
    if (!cv_.wait_for(lock, timeout, [this]() { return workerDone_; })) {
        return false;
    }
    lock.unlock();
    worker_.join();
    return true;
}

void RdpFramePump::waitForWorkerDone() {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_.wait(lock, [this]() { return workerDone_ || !worker_.joinable(); });
}

void RdpFramePump::joinAfterWorkerDone() {
    if (!worker_.joinable() || worker_.get_id() == std::this_thread::get_id()) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!workerDone_) {
            return;
        }
    }
    worker_.join();
}

void RdpFramePump::deferStopAndJoin(std::shared_ptr<RdpFramePump> pump) {
    if (!pump) return;
    framePumpReaper().enqueue(std::move(pump));
}

bool RdpFramePump::drainDeferredJoinsWithin(std::chrono::milliseconds timeout) {
    return framePumpReaper().drainWithin(timeout);
}

bool RdpFramePump::shutdownDeferredJoinsWithin(std::chrono::milliseconds timeout) {
    RdpFramePumpReaper* owner = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_framePumpReaperMutex);
        owner = g_framePumpReaper;
    }
    if (!owner) return true;
    const bool done = owner->shutdownWithin(timeout);
    if (done) {
        std::lock_guard<std::mutex> lock(g_framePumpReaperMutex);
        if (g_framePumpReaper == owner) {
            g_framePumpReaper = nullptr;
            // A caller may still hold the raw reference returned by
            // framePumpReaper() after shutdown releases the global slot. The
            // worker is already joined; retain the retired owner until process
            // exit instead of deleting it under concurrent callers.
        }
    }
    return done;
}

std::size_t RdpFramePump::deferredJoinRemaining() {
    std::lock_guard<std::mutex> lock(g_framePumpReaperMutex);
    return g_framePumpReaper ? g_framePumpReaper->remaining() : 0;
}

bool RdpFramePump::workerDoneForDeferredJoin() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return workerDone_ || !worker_.joinable();
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
        if (submission.owner.valid()) {
            owner_ = submission.owner;
        }
        frame_ = std::move(submission);
        hasFrame_ = true;
        submitted_.fetch_add(1, std::memory_order_relaxed);
        metrics_.recordSubmission(enqueuedAtUs, 0, 0, callbackUs, replaced);
    }
    // Wake even when this submission replaced an already pending frame. The
    // worker may be sleeping until the old pacing deadline; without a wake it
    // cannot apply the latest-frame queue-age bound promptly.
    cv_.notify_one();
    return true;
}

void RdpFramePump::requestTransformRefresh() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!running_) {
            return;
        }
        transformRefreshRequested_ = true;
        ++transformRefreshSequence_;
    }
    cv_.notify_one();
}

void RdpFramePump::invalidatePending() {
    bool rejectedPending = false;
    uint64_t rendererGeneration = 0;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        ++pumpGeneration_;
        rejectedPending = hasFrame_;
        hasFrame_ = false;
        transformRefreshRequested_ = false;
        transformRefreshSequence_ = 0;
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
    struct WorkerCompletion final {
        RdpFramePump* pump;
        ~WorkerCompletion() noexcept {
            try {
                {
                    std::lock_guard<std::mutex> lock(pump->mutex_);
                    pump->workerDone_ = true;
                }
                pump->cv_.notify_all();
            } catch (...) {
                // The owner still retains the joinable thread. Never allow a
                // diagnostic notification failure to escape a std::thread.
            }
        }
    } completion {this};
    try {
    OH_LOG_INFO(LOG_APP, "[RDP-PUMP] render worker started");
    int64_t nextPresentAtUs = 0;
    int64_t nextTransformPresentAtUs = 0;
    while (true) {
        RdpFrameSubmission frame;
        bool renderRetainedTransform = false;
        uint64_t selectedPumpGeneration = 0;
        Render::DecoderSessionIdentity selectedOwner;
        uint64_t transformSequenceAtSourceSelection = 0;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            while (running_) {
                const int64_t nowUs = SteadyNowUs();
                const RdpTransformRefreshDecision decision = DecideRdpTransformRefresh(
                    hasFrame_, transformRefreshRequested_, nowUs,
                    nextPresentAtUs, nextTransformPresentAtUs,
                    hasFrame_ ? frame_.enqueuedAtUs : 0);
                if (decision.action == RdpTransformRefreshAction::PresentSourceFrame) {
                    frame = std::move(frame_);
                    frame_ = RdpFrameSubmission();
                    hasFrame_ = false;
                    if (frame.pumpGeneration == pumpGeneration_) {
                        selectedPumpGeneration = pumpGeneration_;
                        selectedOwner = frame.owner;
                        transformSequenceAtSourceSelection = transformRefreshSequence_;
                        break;
                    }
                    frame = RdpFrameSubmission();
                    continue;
                }
                if (decision.action == RdpTransformRefreshAction::PresentRetainedFrame) {
                    transformRefreshRequested_ = false;
                    selectedPumpGeneration = pumpGeneration_;
                    selectedOwner = owner_;
                    renderRetainedTransform = true;
                    break;
                }

                if (decision.waitUntilUs == 0) {
                    cv_.wait(lock, [this]() {
                        return !running_ || hasFrame_ || transformRefreshRequested_;
                    });
                    continue;
                }
                const int64_t waitUs = std::max<int64_t>(1, decision.waitUntilUs - nowUs);
                cv_.wait_for(lock, std::chrono::microseconds(waitUs));
            }
            if (!running_) {
                break;
            }
        }

        if (renderRetainedTransform) {
            RdpPresentMetrics present;
            present.retainedFrame = true;
            const RdpPresentationTarget target = selectedOwner.valid() ?
                RendererNapi::GetActivePresentationTarget(selectedOwner) :
                RendererNapi::GetActivePresentationTarget();
            try {
                present.generation = target.generation;
                present = target.ready() ?
                    (selectedOwner.valid() ?
                        RendererNapi::PresentRetainedActive(selectedOwner, target.generation) :
                        RendererNapi::PresentRetainedActive(target.generation)) : RdpPresentMetrics();
                if (!target.ready()) {
                    present.result = target.rejection;
                    present.generation = target.generation;
                    present.retainedFrame = true;
                }
            } catch (const std::exception& e) {
                present.result = RdpPresentResult::Exception;
                OH_LOG_ERROR(LOG_APP, "[RDP-PUMP] retained transform exception: %{public}s", e.what());
            } catch (...) {
                present.result = RdpPresentResult::Exception;
                OH_LOG_ERROR(LOG_APP, "[RDP-PUMP] retained transform exception: unknown");
            }
            if (present.presented()) {
                rendered_.fetch_add(1, std::memory_order_relaxed);
                lastWorkerCostUs_.store(present.workerUs(), std::memory_order_release);
            } else {
                rejected_.fetch_add(1, std::memory_order_relaxed);
            }
            metrics_.recordPresent(SteadyNowUs(), present);
            nextTransformPresentAtUs = NextRdpTransformRefreshDeadlineUs(SteadyNowUs());
            emitPresentationMetricsWindow();
            continue;
        }
        if (!frame.damageSource) {
            continue;
        }

        const int64_t queueWaitUs =
            frame.enqueuedAtUs > 0 ? SteadyNowUs() - frame.enqueuedAtUs : 0;
        const int64_t snapshotBeginUs = SteadyNowUs();
        RdpDamageSnapshot snapshot = frame.damageSource->takeSnapshot();
        const int64_t snapshotCopyUs = SteadyNowUs() - snapshotBeginUs;
        if (snapshot.deferred) {
            const int64_t retryNowUs = SteadyNowUs();
            const int64_t retryAtUs = snapshot.retryAtUs > retryNowUs ?
                snapshot.retryAtUs : retryNowUs + 1000;
            metrics_.recordDeferred(retryNowUs);
            if (retryAtUs > nextPresentAtUs) {
                nextPresentAtUs = retryAtUs;
            }
            std::lock_guard<std::mutex> lock(mutex_);
            if (running_ && !hasFrame_ && frame.pumpGeneration == pumpGeneration_) {
                frame_ = std::move(frame);
                hasFrame_ = true;
            }
            continue;
        }
        if (snapshot.valid) {
            metrics_.recordCopy(SteadyNowUs(), snapshot.snapshotCopiedBytes, snapshotCopyUs);
        } else {
            // Allocation/buffer-pressure failures must not spin the render
            // worker while the producer still owns the pending frame.  Keep
            // the latest submission and retry after a short bounded backoff;
            // the next GDI callback or snapshot recycle will wake progress.
            if (!frame.damageSource->hasPending()) {
                continue;
            }
            nextPresentAtUs = std::max(nextPresentAtUs, SteadyNowUs() + 1000);
            std::lock_guard<std::mutex> lock(mutex_);
            if (running_ && !hasFrame_ && frame.pumpGeneration == pumpGeneration_) {
                frame_ = std::move(frame);
                hasFrame_ = true;
            }
            continue;
        }

        RdpPresentMetrics present;
        present.generation = snapshot.rendererGeneration;
        present.fullFrame = snapshot.fullFrame;
        try {
            if (!snapshot.valid || snapshot.pixels.empty()) {
                present.result = RdpPresentResult::InvalidFrame;
            } else {
                present = !snapshot.fullFrame ?
                (frame.owner.valid() ? RendererNapi::PresentRawBgraRectCompactActive(
                    frame.owner, snapshot.pixels.data(), snapshot.pixels.size(), snapshot.width,
                    snapshot.height, snapshot.stride, snapshot.damage.x, snapshot.damage.y,
                    snapshot.damage.width, snapshot.damage.height, snapshot.rendererGeneration) :
                 RendererNapi::PresentRawBgraRectCompactActive(
                    snapshot.pixels.data(), snapshot.pixels.size(), snapshot.width, snapshot.height,
                    snapshot.stride, snapshot.damage.x, snapshot.damage.y, snapshot.damage.width,
                    snapshot.damage.height, snapshot.rendererGeneration)) :
                (frame.owner.valid() ? RendererNapi::PresentRawBgraActive(
                    frame.owner, snapshot.pixels.data(), snapshot.pixels.size(), snapshot.width,
                    snapshot.height, snapshot.stride, snapshot.rendererGeneration) :
                 RendererNapi::PresentRawBgraActive(
                    snapshot.pixels.data(), snapshot.pixels.size(), snapshot.width, snapshot.height,
                    snapshot.stride, snapshot.rendererGeneration));
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
            // The source frame sampled the newest transform. Clear only the
            // request that existed before it began so a newer UI update still
            // receives its own retained redraw.
            std::lock_guard<std::mutex> lock(mutex_);
            if (running_ && selectedPumpGeneration == pumpGeneration_ &&
                transformRefreshRequested_ &&
                transformRefreshSequence_ == transformSequenceAtSourceSelection) {
                transformRefreshRequested_ = false;
            }
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
        recordPboExperiment(present, frame);
        maybeBeginPboExperiment(frame, glUploadGate_.snapshot());
        metrics_.recordPresent(SteadyNowUs(), present);
        // Return the immutable snapshot storage after the renderer has
        // finished reading it.  Full-frame snapshots are recycled by the
        // accumulator only when no newer producer version arrived; dirty
        // snapshots return their bounded scratch buffer unconditionally.
        frame.damageSource->recycleSnapshot(std::move(snapshot));
        // A frame that arrived while the renderer was busy is already the
        // newest source state. Do not add another pacing interval before it;
        // pacing only applies when the source queue is empty.
        bool sourcePending = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            sourcePending = running_ && hasFrame_;
        }
        nextPresentAtUs = sourcePending ? SteadyNowUs() :
            scheduler_.nextDeadlineUs(SteadyNowUs());
        nextTransformPresentAtUs = NextRdpTransformRefreshDeadlineUs(SteadyNowUs());
        emitPresentationMetricsWindow();
    }
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[RDP-PUMP] worker exception: %{public}s", e.what());
    } catch (...) {
        OH_LOG_ERROR(LOG_APP, "[RDP-PUMP] worker exception: unknown");
    }
    OH_LOG_INFO(LOG_APP, "[RDP-PUMP] render worker stopped");
}

void RdpFramePump::maybeBeginPboExperiment(
    const RdpFrameSubmission& frame, const RdpGlUploadGateSnapshot& uploadGate) {
    if (pboExperimentEnabled_ || pboExperimentComplete_ ||
        uploadGate.decision != RdpGlUploadDecision::PboExperimentEligible) {
        return;
    }
    if (uploadGate.workerP95Us <= 0 || !glUploadGate_.beginPboExperiment()) {
        return;
    }

    const bool enabled = frame.owner.valid() ?
        RendererNapi::SetActivePboUpload(frame.owner, true) :
        RendererNapi::SetActivePboUpload(true);
    if (!enabled) {
        glUploadGate_.finishPboExperiment(false, 0);
        pboExperimentComplete_ = true;
        OH_LOG_WARN(LOG_APP,
                    "[RDP-PUMP] PBO experiment unavailable; keeping direct upload");
        return;
    }

    pboExperimentEnabled_ = true;
    pboExperimentComplete_ = false;
    pboBaselineWorkerP95Us_ = uploadGate.workerP95Us;
    pboTrialSampleCount_ = 0;
    pboTrialWorkerSamples_.fill(0);
    OH_LOG_INFO(LOG_APP,
                "[RDP-PUMP] enabling GLES3 PBO upload after baseline"
                " uploadSwapP95=%{public}lldus workerP95=%{public}lldus",
                static_cast<long long>(uploadGate.uploadSwapP95Us),
                static_cast<long long>(uploadGate.workerP95Us));
}

void RdpFramePump::abortPboExperiment(const RdpFrameSubmission& frame,
                                      const char* reason, int64_t experimentP95Us) {
    if (frame.owner.valid()) {
        (void)RendererNapi::SetActivePboUpload(frame.owner, false);
    } else {
        (void)RendererNapi::SetActivePboUpload(false);
    }
    pboExperimentEnabled_ = false;
    pboExperimentComplete_ = true;
    pboTrialSampleCount_ = 0;
    glUploadGate_.finishPboExperiment(false, experimentP95Us);
    OH_LOG_WARN(LOG_APP,
                "[RDP-PUMP] PBO experiment rejected; direct upload restored"
                " reason=%{public}s baselineP95=%{public}lldus trialP95=%{public}lldus",
                reason ? reason : "unknown",
                static_cast<long long>(pboBaselineWorkerP95Us_),
                static_cast<long long>(experimentP95Us));
}

void RdpFramePump::recordPboExperiment(const RdpPresentMetrics& present,
                                       const RdpFrameSubmission& frame) {
    if (!pboExperimentEnabled_) {
        return;
    }
    if (pboExperimentComplete_) {
        // A retained PBO can still be invalidated by a later EGL/context
        // transition. If the renderer silently fell back to direct upload,
        // close the retained decision instead of reporting stale state.
        const RdpGlUploadGateSnapshot uploadGate = glUploadGate_.snapshot();
        if (uploadGate.pboRetained && present.presented() && !present.pboUpload) {
            abortPboExperiment(frame, "pbo-retained-path-lost");
        }
        return;
    }
    // A map/unmap failure disables the renderer's PBO flag and falls back to
    // direct upload in the same present. Never count that fallback as a PBO
    // sample, otherwise a broken experiment could appear successful.
    if (!present.presented() || !present.pboUpload) {
        abortPboExperiment(frame, "pbo-path-not-used");
        return;
    }
    if (pboTrialSampleCount_ >= RdpGlUploadGate::kDecisionSamples) {
        return;
    }
    pboTrialWorkerSamples_[pboTrialSampleCount_++] =
        std::max<int64_t>(0, present.workerUs());
    if (pboTrialSampleCount_ < RdpGlUploadGate::kDecisionSamples) {
        return;
    }

    std::array<int64_t, RdpGlUploadGate::kDecisionSamples> sorted =
        pboTrialWorkerSamples_;
    std::sort(sorted.begin(), sorted.end());
    constexpr size_t kP95Index =
        (RdpGlUploadGate::kDecisionSamples * 95 + 99) / 100 - 1;
    const int64_t experimentP95Us = sorted[kP95Index];
    const bool retain = RdpGlUploadGate::ShouldRetainPbo(
        pboBaselineWorkerP95Us_, experimentP95Us, false, true, true);
    if (retain) {
        pboExperimentComplete_ = true;
        pboTrialSampleCount_ = 0;
        glUploadGate_.finishPboExperiment(true, experimentP95Us);
        OH_LOG_INFO(LOG_APP,
                    "[RDP-PUMP] PBO retained after trial"
                    " baselineP95=%{public}lldus trialP95=%{public}lldus",
                    static_cast<long long>(pboBaselineWorkerP95Us_),
                    static_cast<long long>(experimentP95Us));
        return;
    }
    abortPboExperiment(frame, "insufficient-improvement", experimentP95Us);
}

void RdpFramePump::emitPresentationMetricsWindow() {
    RdpPresentationMetricsSnapshot window;
    if (!metrics_.takeCompletedWindow(window)) {
        return;
    }
    const RdpGlUploadGateSnapshot uploadGate = glUploadGate_.snapshot();
    OH_LOG_INFO(LOG_APP,
        "[RDP-PRESENT] submitted=%{public}llu presented=%{public}llu replaced=%{public}llu"
        " rejected=%{public}llu detached=%{public}llu copied=%{public}llu"
        " full=%{public}llu dirty=%{public}llu transform=%{public}llu deferred=%{public}llu"
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
        static_cast<unsigned long long>(window.fullFramePresents),
        static_cast<unsigned long long>(window.dirtyRectPresents),
        static_cast<unsigned long long>(window.retainedFramePresents),
        static_cast<unsigned long long>(window.deferredSnapshots),
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
