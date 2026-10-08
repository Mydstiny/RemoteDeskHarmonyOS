#include "test_runner.h"
#include "render/native_image_context_policy.h"
#include "rustdesk/rustdesk_peer_presentation_policy.h"

#include <limits>
#include "render/decoder_attempt_diagnostics.h"

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

RDP_TEST_CASE(native_image_policy_selects_producer_transform_only_for_desktop_surface) {
    RDP_ASSERT(Render::NativeImageModeForDesktopSurface(false) ==
        Render::NativeImagePresentationMode::Identity);
    RDP_ASSERT(Render::NativeImageModeForDesktopSurface(true) ==
        Render::NativeImagePresentationMode::TopLeftProducerTransform);
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

RDP_TEST_CASE(native_image_policy_validated_producer_accepts_axis_aligned_flip) {
    const float flipY[16] = {
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, -1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 1.0f
    };
    const Render::NativeImageTransform identity =
        Render::IdentityNativeImageTransform();
    const Render::NativeImageTransform resolved =
        Render::ResolveNativeImagePresentationTransform(
            Render::NativeImagePresentationMode::ValidatedProducerTransform,
            0, flipY, identity);
    RDP_ASSERT(resolved[5] == -1.0f);
    RDP_ASSERT(resolved[13] == 1.0f);
}

RDP_TEST_CASE(native_image_policy_validated_producer_accepts_axis_swapping_orientations) {
    const float rotate90[16] = {
        0.0f, -1.0f, 0.0f, 0.0f,
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 1.0f
    };
    const float rotate270[16] = {
        0.0f, 1.0f, 0.0f, 0.0f,
        -1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        1.0f, 0.0f, 0.0f, 1.0f
    };
    const float transpose[16] = {
        0.0f, 1.0f, 0.0f, 0.0f,
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 0.0f, 0.0f, 1.0f
    };
    const float transverse[16] = {
        0.0f, -1.0f, 0.0f, 0.0f,
        -1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        1.0f, 1.0f, 0.0f, 1.0f
    };
    const Render::NativeImageTransform identity =
        Render::IdentityNativeImageTransform();
    RDP_ASSERT(Render::ClassifyNativeImageProducerTransform(0, rotate90) ==
        Render::NativeImageTransformClass::Rotate90);
    RDP_ASSERT(Render::ClassifyNativeImageProducerTransform(0, rotate270) ==
        Render::NativeImageTransformClass::Rotate270);
    RDP_ASSERT(Render::ClassifyNativeImageProducerTransform(0, transpose) ==
        Render::NativeImageTransformClass::Transpose);
    RDP_ASSERT(Render::ClassifyNativeImageProducerTransform(0, transverse) ==
        Render::NativeImageTransformClass::Transverse);
    RDP_ASSERT(Render::ResolveNativeImagePresentationTransform(
        Render::NativeImagePresentationMode::ValidatedProducerTransform,
        0, rotate90, identity)[1] == -1.0f);
    RDP_ASSERT(Render::ResolveNativeImagePresentationTransform(
        Render::NativeImagePresentationMode::ValidatedProducerTransform,
        0, rotate270, identity)[4] == -1.0f);
}

RDP_TEST_CASE(native_image_policy_validated_producer_rejects_unclassified_matrix) {
    const float other[16] = {
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.25f, 0.0f, 0.0f, 1.0f
    };
    Render::NativeImageTransform previous =
        Render::IdentityNativeImageTransform();
    previous[13] = 0.5f;
    RDP_ASSERT(Render::ResolveNativeImagePresentationTransform(
        Render::NativeImagePresentationMode::ValidatedProducerTransform,
        0, other, previous) == previous);
}

RDP_TEST_CASE(native_image_policy_vertical_flip_mode_rejects_pc_rotation_and_stale_matrix) {
    const float identityMatrix[16] = {
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 0.0f, 0.0f, 1.0f
    };
    const float flipY[16] = {
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, -1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 1.0f
    };
    const float rotate180[16] = {
        -1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, -1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        1.0f, 1.0f, 0.0f, 1.0f
    };
    const float flipX[16] = {
        -1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        1.0f, 0.0f, 0.0f, 1.0f
    };
    const float rotate90[16] = {
        0.0f, -1.0f, 0.0f, 0.0f,
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 1.0f
    };
    const Render::NativeImageTransform identity =
        Render::IdentityNativeImageTransform();
    const Render::NativeImageTransform acceptedFlip =
        Render::ResolveNativeImagePresentationTransform(
            Render::NativeImagePresentationMode::VerticalFlipProducerTransform,
            0, flipY, identity);
    RDP_ASSERT(acceptedFlip[5] == -1.0f);
    RDP_ASSERT(acceptedFlip[13] == 1.0f);
    RDP_ASSERT(Render::ResolveNativeImagePresentationTransform(
        Render::NativeImagePresentationMode::VerticalFlipProducerTransform,
        0, identityMatrix, acceptedFlip) == identity);
    RDP_ASSERT(Render::ResolveNativeImagePresentationTransform(
        Render::NativeImagePresentationMode::VerticalFlipProducerTransform,
        0, rotate180, acceptedFlip) == identity);
    RDP_ASSERT(Render::ResolveNativeImagePresentationTransform(
        Render::NativeImagePresentationMode::VerticalFlipProducerTransform,
        0, flipX, acceptedFlip) == identity);
    RDP_ASSERT(Render::ResolveNativeImagePresentationTransform(
        Render::NativeImagePresentationMode::VerticalFlipProducerTransform,
        0, rotate90, acceptedFlip) == identity);
    RDP_ASSERT(Render::ResolveNativeImagePresentationTransform(
        Render::NativeImagePresentationMode::VerticalFlipProducerTransform,
        40001000, rotate180, acceptedFlip) == identity);
    RDP_ASSERT(Render::ResolveNativeImagePresentationTransform(
        Render::NativeImagePresentationMode::VerticalFlipProducerTransform,
        40001000, nullptr, acceptedFlip) == identity);
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

RDP_TEST_CASE(native_image_policy_classifies_producer_transform_without_applying_it) {
    const float identity[16] = {
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 0.0f, 0.0f, 1.0f
    };
    const float flipX[16] = {
        -1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        1.0f, 0.0f, 0.0f, 1.0f
    };
    const float flipY[16] = {
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, -1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 1.0f
    };
    const float rotate180[16] = {
        -1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, -1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        1.0f, 1.0f, 0.0f, 1.0f
    };
    float other[16] = {
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.25f, 0.0f, 0.0f, 1.0f
    };
    RDP_ASSERT(Render::ClassifyNativeImageProducerTransform(0, identity) ==
        Render::NativeImageTransformClass::Identity);
    RDP_ASSERT(Render::ClassifyNativeImageProducerTransform(0, flipX) ==
        Render::NativeImageTransformClass::FlipX);
    RDP_ASSERT(Render::ClassifyNativeImageProducerTransform(0, flipY) ==
        Render::NativeImageTransformClass::FlipY);
    RDP_ASSERT(Render::ClassifyNativeImageProducerTransform(0, rotate180) ==
        Render::NativeImageTransformClass::Rotate180);
    RDP_ASSERT(Render::ClassifyNativeImageProducerTransform(0, other) ==
        Render::NativeImageTransformClass::Other);
    other[0] = std::numeric_limits<float>::quiet_NaN();
    RDP_ASSERT(Render::ClassifyNativeImageProducerTransform(0, other) ==
        Render::NativeImageTransformClass::ReadFailed);
    RDP_ASSERT(Render::ClassifyNativeImageProducerTransform(40001000, identity) ==
        Render::NativeImageTransformClass::ReadFailed);
}

RDP_TEST_CASE(rustdesk_peer_presentation_policy_is_platform_invariant) {
    using Render::NativeImagePresentationMode;
    RDP_ASSERT(RustDeskPresentation::NativeImageModeForPeerPlatform(
        "Windows") == NativeImagePresentationMode::TopLeftProducerTransform);
    RDP_ASSERT(RustDeskPresentation::NativeImageModeForPeerPlatform(
        "Windows 11") == NativeImagePresentationMode::TopLeftProducerTransform);
    RDP_ASSERT(RustDeskPresentation::NativeImageModeForPeerPlatform(
        "macOS") == NativeImagePresentationMode::TopLeftProducerTransform);
    RDP_ASSERT(RustDeskPresentation::NativeImageModeForPeerPlatform(
        "Linux") == NativeImagePresentationMode::TopLeftProducerTransform);
    RDP_ASSERT(RustDeskPresentation::NativeImageModeForPeerPlatform(
        "") == NativeImagePresentationMode::TopLeftProducerTransform);
    RDP_ASSERT(RustDeskPresentation::ClassifyPeerPlatform("Windows 11") ==
        RustDeskPresentation::PeerPlatformCategory::Windows);
    RDP_ASSERT(RustDeskPresentation::ClassifyPeerPlatform("Darwin") ==
        RustDeskPresentation::PeerPlatformCategory::MacOS);
    RDP_ASSERT(RustDeskPresentation::ClassifyPeerPlatform("GNU/Linux") ==
        RustDeskPresentation::PeerPlatformCategory::Linux);
    RDP_ASSERT(RustDeskPresentation::ClassifyPeerPlatform("custom-value") ==
        RustDeskPresentation::PeerPlatformCategory::Other);
    RDP_ASSERT(RustDeskPresentation::ClassifyPeerPlatform("") ==
        RustDeskPresentation::PeerPlatformCategory::Unknown);
}

RDP_TEST_CASE(native_image_top_left_basis_preserves_asymmetric_crop_and_manual_flips) {
    // Official V2 for crop top=.1 height=.5: F * C. Right multiplication by
    // the input basis must keep the top .1 crop, not mirror it to the bottom.
    auto raw = Render::IdentityNativeImageTransform();
    raw[5] = -.5f;
    raw[13] = .6f;
    const auto applied = Render::ResolveNativeImagePresentationTransform(
        Render::NativeImagePresentationMode::TopLeftProducerTransform, 0,
        raw.data(), Render::IdentityNativeImageTransform());
    RDP_ASSERT(Render::NativeImageTransformNearlyEqual(applied[5], .5f));
    RDP_ASSERT(Render::NativeImageTransformNearlyEqual(applied[13], .1f));
    // Evaluate distinct labelled top/bottom corners through the actual shader
    // order applied * manual(q); visual correction does not touch input axes.
    for (bool flip : {false, true}) {
        const float top = flip ? 1.f : 0.f;
        const float bottom = flip ? 0.f : 1.f;
        RDP_ASSERT(Render::NativeImageTransformNearlyEqual(
            applied[5] * top + applied[13], flip ? .6f : .1f));
        RDP_ASSERT(Render::NativeImageTransformNearlyEqual(
            applied[5] * bottom + applied[13], flip ? .1f : .6f));
    }
}

RDP_TEST_CASE(native_image_top_left_basis_rejects_bad_reads_without_reapplying_basis) {
    auto raw = Render::IdentityNativeImageTransform();
    raw[5] = -1;
    raw[13] = 1;
    const auto identity = Render::IdentityNativeImageTransform();
    const auto applied = Render::ResolveNativeImagePresentationTransform(
        Render::NativeImagePresentationMode::TopLeftProducerTransform, 0, raw.data(), identity);
    RDP_ASSERT(applied == identity);
    RDP_ASSERT(Render::ResolveNativeImagePresentationTransform(
        Render::NativeImagePresentationMode::TopLeftProducerTransform, -1, raw.data(), applied) == applied);
    for (int index : {0, 3, 15}) {
        auto bad = raw;
        bad[index] = index == 3 ? .5f : 0.f;
        RDP_ASSERT(Render::ResolveNativeImagePresentationTransform(
            Render::NativeImagePresentationMode::TopLeftProducerTransform, 0, bad.data(), applied) == applied);
    }
    raw[0] = std::numeric_limits<float>::quiet_NaN();
    RDP_ASSERT(Render::ResolveNativeImagePresentationTransform(
        Render::NativeImagePresentationMode::TopLeftProducerTransform, 0, raw.data(), applied) == applied);
}

RDP_TEST_CASE(decoder_attempt_failures_survive_producer_lifetime_and_isolate_generations) {
    Render::DecoderAttemptDiagnostics journal;
    const Render::DecoderSessionIdentity first {71, 2, 301};
    const Render::DecoderSessionIdentity replacement {71, 3, 302};
    const auto serial = journal.begin(first, 1, 1920, 1080, 5);
    journal.update(first, serial, [](Render::DecoderAttemptDiagnostic& value) {
        value.stage = static_cast<int>(Render::DecoderAttemptStage::Configure);
        value.result = -1;
        value.platformCode = 401;
    });
    RDP_ASSERT(journal.snapshot(first).back().platformCode == 401);
    journal.update(replacement, serial, [](Render::DecoderAttemptDiagnostic& value) { value.platformCode = 0; });
    RDP_ASSERT(journal.snapshot(first).back().platformCode == 401);
    RDP_ASSERT(journal.snapshot(replacement).empty());
    for (int i = 0; i < 10; ++i) journal.begin(first, 0, 1920, 1080, i + 6);
    RDP_ASSERT(journal.snapshot(first).size() == 4);
    RDP_ASSERT(journal.snapshot(first).back().decoderGeneration == 15);
}
