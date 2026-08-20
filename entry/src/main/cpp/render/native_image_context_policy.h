#pragma once

#include <array>
#include <cstdint>

namespace Render {

using NativeImageTransform = std::array<float, 16>;

inline NativeImageTransform IdentityNativeImageTransform() {
    return NativeImageTransform {
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 0.0f, 0.0f, 1.0f
    };
}

/**
 * Return the texture transform for an encoded remote-desktop frame.
 *
 * OH_NativeImage_GetTransformMatrixV2 reports metadata set by the producer of
 * the surface. It is not the orientation contract of the decoded desktop
 * image. RustDesk frames are already produced in the renderer's top-left
 * coordinate domain, while the PC surface may still report a producer flip.
 * Applying that metadata to the OES sampling coordinates would therefore
 * invert an otherwise upright desktop. Keep the API value diagnostic-only and
 * never let a failed read retain a stale non-identity transform.
 */
inline NativeImageTransform ResolveNativeImagePresentationTransform(
    bool desktopSurfaceCompatibility,
    int32_t readResult,
    const float matrix[16],
    const NativeImageTransform& previous) {
    // These inputs are deliberately diagnostic-only. The decoded remote
    // desktop frame is already in the renderer's top-left domain, so neither
    // a producer flip nor a previously observed transform may affect sampling.
    (void)desktopSurfaceCompatibility;
    (void)readResult;
    (void)matrix;
    (void)previous;
    return IdentityNativeImageTransform();
}

inline bool ShouldRenderNativeImageImmediately(bool desktopSurfaceCompatibility) {
    return desktopSurfaceCompatibility;
}

constexpr int kNativeErrorNoBuffer = 40601000;
// A failed acquire can be a short producer/consumer handoff race. Bound the
// retry work so a missing surface buffer cannot monopolize the render thread.
constexpr int kNativeImageUpdateRetryBudget = 3;
constexpr int kNativeImageSurfaceRecoveryThreshold = 6;

inline bool ShouldDetachNativeImageOnRenderThreadStop(bool attached, bool hasNativeImage) {
    return attached && hasNativeImage;
}

inline bool ShouldRetryNativeImageAttach(int attachResult, bool alreadyRetried) {
    return attachResult != 0 && !alreadyRetried;
}

inline bool ShouldRetryNativeImageUpdate(int updateResult, int retryCount) {
    return updateResult == kNativeErrorNoBuffer &&
        retryCount < kNativeImageUpdateRetryBudget;
}

// Drop-buffer mode keeps only the newest producer buffer but still emits the
// listener callback for every produced frame. After a bounded handoff wait,
// NO_BUFFER therefore means that this notification was coalesced by the
// surface rather than that the decoder or NativeImage is broken.
inline bool IsCoalescedNativeImageNotification(int updateResult, int retryCount) {
    return updateResult == kNativeErrorNoBuffer &&
        retryCount >= kNativeImageUpdateRetryBudget;
}

inline bool HasUnconsumedNativeImageFrame(uint64_t available, uint64_t consumed) {
    return available > consumed;
}

// A failed GL attachment leaves the newest producer notification unconsumed.
// That notification must not bypass the retry deadline, otherwise the render
// loop spins continuously until the surface is rebound.
inline bool ShouldDeferNativeImageRetry(bool surfaceUpdatePending,
                                        bool retryScheduled,
                                        bool retryDue) {
    return surfaceUpdatePending && retryScheduled && !retryDue;
}

inline uint64_t LatestNativeImageFrameSequence(uint64_t available) {
    return available;
}

inline bool ShouldRequestNativeImageRecovery(int consecutiveFailures) {
    return consecutiveFailures >= kNativeImageSurfaceRecoveryThreshold;
}

inline int NativeImageUpdateRetryDelayMs(int retryCount) {
    switch (retryCount) {
        case 1:
            return 2;
        case 2:
            return 4;
        default:
            return 8;
    }
}

} // namespace Render
