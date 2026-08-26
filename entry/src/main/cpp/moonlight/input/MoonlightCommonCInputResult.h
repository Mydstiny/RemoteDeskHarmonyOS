#ifndef REMOTEDESK_MOONLIGHT_COMMON_C_INPUT_RESULT_H
#define REMOTEDESK_MOONLIGHT_COMMON_C_INPUT_RESULT_H

#include "moonlight/input/MoonlightInputBridge.h"
#include "moonlight/upstream/moonlight-common-c/src/Limelight.h"
#include "moonlight/upstream/moonlight-common-c/src/LinkedBlockingQueue.h"

namespace remotedesk::moonlight {

constexpr MoonlightInputPortStatus moonlightCommonCInputResult(
    int result) noexcept {
    if (result == 0) {
        return MoonlightInputPortStatus::Accepted;
    }
    if (result == LBQ_BOUND_EXCEEDED) {
        return MoonlightInputPortStatus::Backpressure;
    }
    if (result == LI_ERR_UNSUPPORTED) {
        return MoonlightInputPortStatus::Unsupported;
    }
    return MoonlightInputPortStatus::Failed;
}

} // namespace remotedesk::moonlight

#endif // REMOTEDESK_MOONLIGHT_COMMON_C_INPUT_RESULT_H
