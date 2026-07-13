#ifndef DECODER_RECOVERY_POLICY_H
#define DECODER_RECOVERY_POLICY_H

#include <cstdint>

namespace Render {

inline bool ShouldRequestDecoderRecoveryAfterForegroundRestore(bool foregroundRestore,
                                                               int64_t decoderHandle,
                                                               int64_t rendererHandle) {
    return foregroundRestore && decoderHandle > 0 && rendererHandle > 0;
}

inline bool ShouldDecodeFrameTriggerRecovery(bool recoveryRequested, bool frameIsKeyframe) {
    return recoveryRequested && frameIsKeyframe;
}

inline bool ShouldDropFrameWhileWaitingRecoveryKeyframe(bool recoveryRequested, bool frameIsKeyframe) {
    return recoveryRequested && !frameIsKeyframe;
}

} // namespace Render

#endif // DECODER_RECOVERY_POLICY_H
