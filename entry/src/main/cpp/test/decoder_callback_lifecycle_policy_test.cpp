#include "test_runner.h"

#include "render/decoder_callback_lifecycle_policy.h"

RDP_TEST_CASE(decoder_callback_lifecycle_requires_current_live_source) {
    const Render::DecoderCallbackKind kinds[] = {
        Render::DecoderCallbackKind::InputBuffer,
        Render::DecoderCallbackKind::OutputBuffer,
        Render::DecoderCallbackKind::FrameAvailable,
        Render::DecoderCallbackKind::StreamChanged,
        Render::DecoderCallbackKind::Error,
    };

    for (const auto kind : kinds) {
        // Pipeline transition state is intentionally absent from this policy:
        // a current codec must drain callbacks while its renderer is rebound.
        RDP_ASSERT(Render::ShouldAdmitDecoderCallback(kind, true, true, true));
        RDP_ASSERT(!Render::ShouldAdmitDecoderCallback(kind, false, true, true));
        RDP_ASSERT(!Render::ShouldAdmitDecoderCallback(kind, true, false, true));
        RDP_ASSERT(!Render::ShouldAdmitDecoderCallback(kind, true, true, false));
    }
}
