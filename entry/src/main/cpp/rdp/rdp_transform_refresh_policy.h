#ifndef RDP_TRANSFORM_REFRESH_POLICY_H
#define RDP_TRANSFORM_REFRESH_POLICY_H

#include "rdp_frame_scheduler.h"

#include <algorithm>
#include <cstdint>

/**
 * A canvas transform only changes how an already uploaded framebuffer is
 * sampled.  Keep that redraw independent from the remote-frame scheduler so
 * a pinch never asks the owned GDI accumulator to copy a full framebuffer.
 */
enum class RdpTransformRefreshAction {
    Wait,
    PresentSourceFrame,
    PresentRetainedFrame,
};

struct RdpTransformRefreshDecision {
    RdpTransformRefreshAction action = RdpTransformRefreshAction::Wait;
    int64_t waitUntilUs = 0;
};

inline RdpTransformRefreshDecision DecideRdpTransformRefresh(
    bool hasSourceFrame, bool transformRequested, int64_t nowUs,
    int64_t nextSourcePresentAtUs, int64_t nextTransformPresentAtUs) {
    // A real remote frame already applies the newest transform while it
    // uploads, so it wins over an otherwise redundant retained redraw.
    if (hasSourceFrame && RdpFrameScheduler::IsDue(nowUs, nextSourcePresentAtUs)) {
        return {RdpTransformRefreshAction::PresentSourceFrame, nowUs};
    }
    if (transformRequested &&
        RdpFrameScheduler::IsDue(nowUs, nextTransformPresentAtUs)) {
        return {RdpTransformRefreshAction::PresentRetainedFrame, nowUs};
    }

    int64_t waitUntilUs = 0;
    if (hasSourceFrame) {
        waitUntilUs = nextSourcePresentAtUs;
    }
    if (transformRequested &&
        (waitUntilUs == 0 || nextTransformPresentAtUs < waitUntilUs)) {
        waitUntilUs = nextTransformPresentAtUs;
    }
    return {RdpTransformRefreshAction::Wait, waitUntilUs};
}

inline int64_t NextRdpTransformRefreshDeadlineUs(int64_t completedAtUs) {
    return completedAtUs + RdpFrameScheduler::kInterval60FpsUs;
}

#endif // RDP_TRANSFORM_REFRESH_POLICY_H
