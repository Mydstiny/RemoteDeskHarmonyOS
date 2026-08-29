#ifndef DECODER_RECOVERY_POLICY_H
#define DECODER_RECOVERY_POLICY_H

#include <cstdint>

namespace Render {

constexpr uint32_t kMaxDecoderRecoveryAttemptsPerBinding = 2;

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

inline bool ShouldArmDecoderRecovery(bool alreadyRequested, bool terminal) {
    return !alreadyRequested && !terminal;
}

inline bool CanStartDecoderRecovery(uint32_t attempts, bool terminal) {
    return !terminal && attempts < kMaxDecoderRecoveryAttemptsPerBinding;
}

inline bool ShouldEnterTerminalDecoderRecovery(bool recreated, uint32_t attempts) {
    return !recreated || attempts >= kMaxDecoderRecoveryAttemptsPerBinding;
}

/** A platform decoder and its NativeImage surface have fixed output geometry. */
inline bool ShouldRecreateDecoderForFrameGeometry(int currentWidth,
                                                  int currentHeight,
                                                  int frameWidth,
                                                  int frameHeight) {
    return frameWidth > 0 && frameHeight > 0 &&
        currentWidth > 0 && currentHeight > 0 &&
        (currentWidth != frameWidth || currentHeight != frameHeight);
}

} // namespace Render

#endif // DECODER_RECOVERY_POLICY_H
