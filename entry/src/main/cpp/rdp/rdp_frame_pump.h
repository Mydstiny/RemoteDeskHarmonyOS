/**
 * rdp_frame_pump.h - latest-frame render worker for FreeRDP GDI frames
 */

#ifndef RDP_FRAME_PUMP_H
#define RDP_FRAME_PUMP_H

#include "rdp_presentation_metrics.h"
#include "rdp_damage_accumulator.h"
#include "rdp_frame_scheduler.h"
#include "rdp_gl_upload_gate.h"
#include "render/video_perf_counters.h"

#include <atomic>
#include <array>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <memory>
#include <thread>

struct RdpFrameSubmission {
    std::shared_ptr<RdpDamageAccumulator> damageSource;
    Render::DecoderSessionIdentity owner;
    uint64_t pumpGeneration = 0;
    int64_t enqueuedAtUs = 0;
    int64_t callbackUs = 0;
};

class RdpFramePump : public std::enable_shared_from_this<RdpFramePump> {
public:
    RdpFramePump();
    ~RdpFramePump();

    bool start();
    void stop();
    bool stopWithin(std::chrono::milliseconds timeout);
    // Deferred owners request cancellation on the caller's budget, then wait
    // on this fence outside the caller.  Joining is valid only after the
    // fence is true.
    void waitForWorkerDone();
    void joinAfterWorkerDone();
    bool workerDoneForDeferredJoin() const;
    static void deferStopAndJoin(std::shared_ptr<RdpFramePump> pump);
    static bool drainDeferredJoinsWithin(std::chrono::milliseconds timeout);
    static bool shutdownDeferredJoinsWithin(std::chrono::milliseconds timeout);
    static std::size_t deferredJoinRemaining();
    bool submitLatest(RdpFrameSubmission&& submission);
    /** Request a transform-only redraw; caller only wakes this worker. */
    void requestTransformRefresh();
    void invalidatePending();
    bool isRunning() const;

    void recordInvalid(uint64_t pixels, int64_t callbackUs, int64_t nowUs);
    void recordCopy(uint64_t copiedBytes, int64_t copyUs, int64_t nowUs);
    RdpPresentationMetricsSnapshot metricsSnapshot(int64_t nowUs);
    int64_t lastWorkerCostUs() const;
    int targetFps() const;
    int64_t targetIntervalUs() const;
    uint64_t adaptationCount() const;
    RdpGlUploadGateSnapshot glUploadGateSnapshot() const;
    bool consumeFullResyncRequired();

    uint64_t submitted() const;
    uint64_t rendered() const;
    uint64_t replaced() const;
    uint64_t rejected() const;

private:
    void loop();
    /** Emits a completed one-second window from either source or retained redraws. */
    void emitPresentationMetricsWindow();
    void maybeBeginPboExperiment(const RdpFrameSubmission& frame,
                                 const RdpGlUploadGateSnapshot& uploadGate);
    void recordPboExperiment(const RdpPresentMetrics& present,
                             const RdpFrameSubmission& frame);
    void abortPboExperiment(const RdpFrameSubmission& frame, const char* reason,
                            int64_t experimentP95Us = 0);

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::thread worker_;
    bool running_ = false;
    bool workerDone_ = true;
    bool hasFrame_ = false;
    bool transformRefreshRequested_ = false;
    uint64_t transformRefreshSequence_ = 0;
    uint64_t pumpGeneration_ = 0;
    Render::DecoderSessionIdentity owner_;
    RdpFrameSubmission frame_;
    RdpPresentationMetrics metrics_;
    RdpFrameScheduler scheduler_;
    RdpGlUploadGate glUploadGate_;
    std::atomic<uint64_t> submitted_ {0};
    std::atomic<uint64_t> rendered_ {0};
    std::atomic<uint64_t> replaced_ {0};
    std::atomic<uint64_t> rejected_ {0};
    std::atomic<int64_t> lastWorkerCostUs_ {0};
    std::atomic<bool> fullResyncRequired_ {true};
    bool pboExperimentEnabled_ = false;
    bool pboExperimentComplete_ = false;
    int64_t pboBaselineWorkerP95Us_ = 0;
    size_t pboTrialSampleCount_ = 0;
    std::array<int64_t, RdpGlUploadGate::kDecisionSamples> pboTrialWorkerSamples_ {};
};

#endif // RDP_FRAME_PUMP_H
