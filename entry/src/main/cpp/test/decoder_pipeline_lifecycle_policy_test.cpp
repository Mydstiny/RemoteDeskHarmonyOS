#include "test_runner.h"
#include "render/decoder_pipeline_lifecycle_policy.h"

RDP_TEST_CASE(decoder_pipeline_lifecycle_rejects_detached_or_stopping_frames) {
    RDP_ASSERT(Render::ShouldAcceptSoftwareDecoderFrame(true, false));
    RDP_ASSERT(!Render::ShouldAcceptSoftwareDecoderFrame(false, false));
    RDP_ASSERT(!Render::ShouldAcceptSoftwareDecoderFrame(true, true));
    RDP_ASSERT(!Render::ShouldAcceptSoftwareDecoderFrame(false, true));
}
