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

RDP_TEST_CASE(decoder_recovery_coalesces_and_bounds_surface_failures) {
    RDP_ASSERT(Render::ShouldArmDecoderRecovery(false, false));
    RDP_ASSERT(!Render::ShouldArmDecoderRecovery(true, false));
    RDP_ASSERT(!Render::ShouldArmDecoderRecovery(false, true));
    RDP_ASSERT(Render::CanStartDecoderRecovery(0, false));
    RDP_ASSERT(Render::CanStartDecoderRecovery(1, false));
    RDP_ASSERT(!Render::CanStartDecoderRecovery(
        Render::kMaxDecoderRecoveryAttemptsPerBinding, false));
    RDP_ASSERT(!Render::CanStartDecoderRecovery(0, true));
    RDP_ASSERT(!Render::ShouldEnterTerminalDecoderRecovery(true, 1));
    RDP_ASSERT(Render::ShouldEnterTerminalDecoderRecovery(true, 2));
    RDP_ASSERT(Render::ShouldEnterTerminalDecoderRecovery(false, 1));
}

RDP_TEST_CASE(decoder_recovery_recreates_fixed_surface_after_frame_size_change) {
    RDP_ASSERT(Render::ShouldRecreateDecoderForFrameGeometry(
        1080, 2400, 2400, 1080));
    RDP_ASSERT(!Render::ShouldRecreateDecoderForFrameGeometry(
        1080, 2400, 1080, 2400));
    RDP_ASSERT(!Render::ShouldRecreateDecoderForFrameGeometry(
        1080, 2400, 0, 0));
}
