#include "test_runner.h"
#include "render/native_image_context_policy.h"
#include "rustdesk/rustdesk_peer_presentation_policy.h"

#include <limits>

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
    RDP_ASSERT(!Render::ShouldRetryNativeImageUpdate(Render::kNativeErrorNoBuffer, 1));
    RDP_ASSERT(!Render::ShouldRetryNativeImageUpdate(Render::kNativeErrorNoBuffer, 2));
    RDP_ASSERT(!Render::ShouldRetryNativeImageUpdate(Render::kNativeErrorNoBuffer, 3));
    RDP_ASSERT(!Render::ShouldRetryNativeImageUpdate(41207000, 0));
    RDP_ASSERT(!Render::ShouldRetryNativeImageUpdate(0, 0));
    RDP_ASSERT(Render::IsCoalescedNativeImageNotification(
        Render::kNativeErrorNoBuffer, 1));
    RDP_ASSERT(Render::IsCoalescedNativeImageNotification(
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
    RDP_ASSERT(Render::ShouldDeferNativeImageRetry(true, true, false));
    RDP_ASSERT(!Render::ShouldDeferNativeImageRetry(true, true, true));
    RDP_ASSERT(!Render::ShouldDeferNativeImageRetry(true, false, false));
    RDP_ASSERT(!Render::ShouldDeferNativeImageRetry(false, true, false));
    RDP_ASSERT(!Render::ShouldRequestNativeImageRecovery(
        Render::kNativeImageSurfaceRecoveryThreshold - 1));
    RDP_ASSERT(Render::ShouldRequestNativeImageRecovery(
        Render::kNativeImageSurfaceRecoveryThreshold));
}

RDP_TEST_CASE(native_image_policy_keeps_identity_presentation_contract) {
    const float desktopFlip[16] = {
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, -1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 1.0f
    };
    const Render::NativeImageTransform identity =
        Render::IdentityNativeImageTransform();
    const Render::NativeImageTransform desktop =
        Render::ResolveNativeImagePresentationTransform(
            Render::NativeImagePresentationMode::Identity,
            0, desktopFlip, identity);
    RDP_ASSERT(desktop == identity);
    // A producer-side vertical flip must not leak into the renderer's
    // top-left texture contract.
    RDP_ASSERT(desktop[5] != desktopFlip[5]);
    RDP_ASSERT(desktop[13] != desktopFlip[13]);
    RDP_ASSERT(!Render::ShouldRenderNativeImageImmediately(false));
}

RDP_TEST_CASE(native_image_policy_applies_valid_producer_transform_and_keeps_desktop_output_immediate) {
    const float desktopFlip[16] = {
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, -1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 1.0f
    };
    const Render::NativeImageTransform identity =
        Render::IdentityNativeImageTransform();
    const Render::NativeImageTransform desktop =
        Render::ResolveNativeImagePresentationTransform(
            Render::NativeImagePresentationMode::ProducerTransform,
            0, desktopFlip, identity);
    const Render::NativeImageTransform expectedFlip {
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, -1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 1.0f
    };
    RDP_ASSERT(desktop == expectedFlip);
    RDP_ASSERT(Render::ShouldRenderNativeImageImmediately(true));
}

RDP_TEST_CASE(native_image_policy_retains_last_valid_transform_after_failed_read) {
    float invalid[16] = {
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 0.0f, 0.0f, 1.0f
    };
    invalid[6] = std::numeric_limits<float>::quiet_NaN();
    const Render::NativeImageTransform identity =
        Render::IdentityNativeImageTransform();
    Render::NativeImageTransform previous = identity;
    previous[12] = 0.25f;
    RDP_ASSERT(Render::ResolveNativeImagePresentationTransform(
        Render::NativeImagePresentationMode::ProducerTransform,
        40001000, invalid, previous) == previous);
    RDP_ASSERT(Render::ResolveNativeImagePresentationTransform(
        Render::NativeImagePresentationMode::ProducerTransform,
        0, invalid, previous) == previous);
}

RDP_TEST_CASE(rustdesk_peer_presentation_policy_targets_only_windows) {
    using Render::NativeImagePresentationMode;
    RDP_ASSERT(RustDeskPresentation::NativeImageModeForPeerPlatform(
        "Windows") == NativeImagePresentationMode::ProducerTransform);
    RDP_ASSERT(RustDeskPresentation::NativeImageModeForPeerPlatform(
        "Windows 11") == NativeImagePresentationMode::ProducerTransform);
    RDP_ASSERT(RustDeskPresentation::NativeImageModeForPeerPlatform(
        "macOS") == NativeImagePresentationMode::Identity);
    RDP_ASSERT(RustDeskPresentation::NativeImageModeForPeerPlatform(
        "Linux") == NativeImagePresentationMode::Identity);
    RDP_ASSERT(RustDeskPresentation::NativeImageModeForPeerPlatform(
        "") == NativeImagePresentationMode::Identity);
}
