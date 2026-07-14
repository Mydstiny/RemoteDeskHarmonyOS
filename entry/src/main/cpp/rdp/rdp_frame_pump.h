/**
 * rdp_frame_pump.h - latest-frame render worker for FreeRDP GDI frames
 */

#ifndef RDP_FRAME_PUMP_H
#define RDP_FRAME_PUMP_H

#include "rdp_presentation_metrics.h"

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

struct RdpFrameSubmission {
    std::vector<uint8_t> pixels;
    int width = 0;
    int height = 0;
    int stride = 0;
    int dirtyX = 0;
    int dirtyY = 0;
    int dirtyWidth = 0;
    int dirtyHeight = 0;
    bool dirtyValid = false;
    uint64_t rendererGeneration = 0;
    uint64_t pumpGeneration = 0;
    uint64_t copiedBytes = 0;
    int64_t enqueuedAtUs = 0;
    int64_t copyUs = 0;
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
    void recordDirectPresent(const RdpPresentMetrics& present, int64_t nowUs);
    RdpPresentationMetricsSnapshot metricsSnapshot(int64_t nowUs);
    int64_t lastWorkerCostUs() const;
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
    std::atomic<uint64_t> submitted_ {0};
    std::atomic<uint64_t> rendered_ {0};
    std::atomic<uint64_t> replaced_ {0};
    std::atomic<uint64_t> rejected_ {0};
    std::atomic<int64_t> lastWorkerCostUs_ {0};
    std::atomic<bool> fullResyncRequired_ {true};
};

#endif // RDP_FRAME_PUMP_H
