/**
 * rdp_frame_pump.h - latest-frame render worker for FreeRDP GDI frames
 */

#ifndef RDP_FRAME_PUMP_H
#define RDP_FRAME_PUMP_H

#include "rdp_presentation_metrics.h"
#include "rdp_damage_accumulator.h"
#include "rdp_frame_scheduler.h"

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <memory>
#include <thread>

struct RdpFrameSubmission {
    std::shared_ptr<RdpDamageAccumulator> damageSource;
    uint64_t pumpGeneration = 0;
    int64_t enqueuedAtUs = 0;
    int64_t callbackUs = 0;
};

class RdpFramePump {
public:
    RdpFramePump();
    ~RdpFramePump();

    bool start();
    void stop();
    bool submitLatest(RdpFrameSubmission&& submission);
    void invalidatePending();
    bool isRunning() const;

    void recordInvalid(uint64_t pixels, int64_t callbackUs, int64_t nowUs);
    void recordCopy(uint64_t copiedBytes, int64_t copyUs, int64_t nowUs);
    RdpPresentationMetricsSnapshot metricsSnapshot(int64_t nowUs);
    int64_t lastWorkerCostUs() const;
    int targetFps() const;
    int64_t targetIntervalUs() const;
    uint64_t adaptationCount() const;
    bool consumeFullResyncRequired();

    uint64_t submitted() const;
    uint64_t rendered() const;
    uint64_t replaced() const;
    uint64_t rejected() const;

private:
    void loop();

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::thread worker_;
    bool running_ = false;
    bool hasFrame_ = false;
    uint64_t pumpGeneration_ = 0;
    RdpFrameSubmission frame_;
    RdpPresentationMetrics metrics_;
    RdpFrameScheduler scheduler_;
    std::atomic<uint64_t> submitted_ {0};
    std::atomic<uint64_t> rendered_ {0};
    std::atomic<uint64_t> replaced_ {0};
    std::atomic<uint64_t> rejected_ {0};
    std::atomic<int64_t> lastWorkerCostUs_ {0};
    std::atomic<bool> fullResyncRequired_ {true};
};

#endif // RDP_FRAME_PUMP_H
