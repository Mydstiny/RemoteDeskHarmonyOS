/**
 * decoder_callback_lifecycle_policy.h - platform callback admission policy.
 *
 * OH_AVCodec callbacks are part of the codec source lifecycle, not renderer
 * presentation. A current source must keep accepting them while a renderer
 * pipeline is being attached, detached, or recreated; input/output buffers
 * otherwise remain owned by the platform and stop decoding. Presentation
 * readiness is enforced by the callback body and render thread instead.
 */

#ifndef DECODER_CALLBACK_LIFECYCLE_POLICY_H
#define DECODER_CALLBACK_LIFECYCLE_POLICY_H

namespace Render {

enum class DecoderCallbackKind {
    InputBuffer,
    OutputBuffer,
    FrameAvailable,
    StreamChanged,
    Error,
};

inline bool ShouldAdmitDecoderCallback(DecoderCallbackKind kind,
                                       bool callbackLeaseValid,
                                       bool ownerMatches,
                                       bool decoderLeaseValid) {
    switch (kind) {
        case DecoderCallbackKind::InputBuffer:
        case DecoderCallbackKind::OutputBuffer:
        case DecoderCallbackKind::FrameAvailable:
        case DecoderCallbackKind::StreamChanged:
        case DecoderCallbackKind::Error:
            break;
        default:
            return false;
    }
    return callbackLeaseValid && ownerMatches && decoderLeaseValid;
}

} // namespace Render

#endif // DECODER_CALLBACK_LIFECYCLE_POLICY_H
