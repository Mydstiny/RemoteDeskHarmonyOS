#include "test_runner.h"
#include "render/native_image_context_policy.h"

RDP_TEST_CASE(native_image_policy_detaches_before_releasing_current_context) {
    RDP_ASSERT(Render::ShouldDetachNativeImageOnRenderThreadStop(true, true));
}

RDP_TEST_CASE(native_image_policy_skips_detach_when_not_attached) {
    RDP_ASSERT(!Render::ShouldDetachNativeImageOnRenderThreadStop(false, true));
    RDP_ASSERT(!Render::ShouldDetachNativeImageOnRenderThreadStop(true, false));
}

RDP_TEST_CASE(native_image_policy_retries_failed_attach_once) {
    RDP_ASSERT(Render::ShouldRetryNativeImageAttach(60001000, false));
    RDP_ASSERT(!Render::ShouldRetryNativeImageAttach(60001000, true));
    RDP_ASSERT(!Render::ShouldRetryNativeImageAttach(0, false));
    RDP_ASSERT(Render::ShouldRetryNativeImageUpdate(Render::kNativeErrorNoBuffer, 0));
    RDP_ASSERT(Render::ShouldRetryNativeImageUpdate(Render::kNativeErrorNoBuffer, 1));
    RDP_ASSERT(Render::ShouldRetryNativeImageUpdate(Render::kNativeErrorNoBuffer, 2));
    RDP_ASSERT(!Render::ShouldRetryNativeImageUpdate(Render::kNativeErrorNoBuffer, 3));
    RDP_ASSERT(!Render::ShouldRetryNativeImageUpdate(41207000, 0));
    RDP_ASSERT(!Render::ShouldRetryNativeImageUpdate(0, 0));
    RDP_ASSERT(!Render::IsCoalescedNativeImageNotification(
        Render::kNativeErrorNoBuffer, 2));
    RDP_ASSERT(Render::IsCoalescedNativeImageNotification(
        Render::kNativeErrorNoBuffer, 3));
    RDP_ASSERT(!Render::IsCoalescedNativeImageNotification(41207000, 3));
    RDP_ASSERT(!Render::IsCoalescedNativeImageNotification(0, 3));
    RDP_ASSERT(Render::NativeImageUpdateRetryDelayMs(1) == 2);
    RDP_ASSERT(Render::NativeImageUpdateRetryDelayMs(2) == 4);
    RDP_ASSERT(Render::NativeImageUpdateRetryDelayMs(3) == 8);
}

RDP_TEST_CASE(native_image_policy_consumes_latest_notification_sequence) {
    RDP_ASSERT(!Render::HasUnconsumedNativeImageFrame(4, 4));
    RDP_ASSERT(Render::HasUnconsumedNativeImageFrame(5, 4));
    RDP_ASSERT(Render::LatestNativeImageFrameSequence(17) == 17);
    RDP_ASSERT(!Render::ShouldRequestNativeImageRecovery(
        Render::kNativeImageSurfaceRecoveryThreshold - 1));
    RDP_ASSERT(Render::ShouldRequestNativeImageRecovery(
        Render::kNativeImageSurfaceRecoveryThreshold));
}
