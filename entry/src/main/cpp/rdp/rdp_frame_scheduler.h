#ifndef RDP_FRAME_SCHEDULER_H
#define RDP_FRAME_SCHEDULER_H

#include "rdp_presentation_metrics.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <mutex>

class RdpFrameScheduler {
public:
    static constexpr size_t kDecisionSamples = 120;
    static constexpr int64_t kInterval60FpsUs = 16667;
    static constexpr int64_t kInterval30FpsUs = 33333;
    static constexpr int64_t kInterval20FpsUs = 50000;

    void reset();
    void recordPresent(const RdpPresentMetrics& present);

    int targetFps() const;
    int64_t targetIntervalUs() const;
    int64_t nextDeadlineUs(int64_t completedAtUs) const;
    static bool IsDue(int64_t nowUs, int64_t deadlineUs);
    size_t validSamples() const;
    int64_t lastP95Us() const;
    uint64_t adaptationCount() const;

private:
    void adaptLocked(int64_t p95Us);

    mutable std::mutex mutex_;
    std::array<int64_t, kDecisionSamples> samples_ {};
    size_t sampleCount_ = 0;
    int targetFps_ = 60;
    int64_t lastP95Us_ = 0;
    uint64_t adaptationCount_ = 0;
};

#endif // RDP_FRAME_SCHEDULER_H
