#include "test_runner.h"
#include "render/decoder_recovery_policy.h"

RDP_TEST_CASE(decoder_recovery_requests_only_for_foreground_restore_with_bound_pipeline) {
    RDP_ASSERT(Render::ShouldRequestDecoderRecoveryAfterForegroundRestore(true, 11, 22));
    RDP_ASSERT(!Render::ShouldRequestDecoderRecoveryAfterForegroundRestore(false, 11, 22));
    RDP_ASSERT(!Render::ShouldRequestDecoderRecoveryAfterForegroundRestore(true, -1, 22));
    RDP_ASSERT(!Render::ShouldRequestDecoderRecoveryAfterForegroundRestore(true, 11, -1));
}

RDP_TEST_CASE(decoder_recovery_waits_for_keyframe_before_recreate) {
    RDP_ASSERT(Render::ShouldDropFrameWhileWaitingRecoveryKeyframe(true, false));
    RDP_ASSERT(!Render::ShouldDropFrameWhileWaitingRecoveryKeyframe(true, true));
    RDP_ASSERT(Render::ShouldDecodeFrameTriggerRecovery(true, true));
    RDP_ASSERT(!Render::ShouldDecodeFrameTriggerRecovery(true, false));
    RDP_ASSERT(!Render::ShouldDecodeFrameTriggerRecovery(false, true));
}
