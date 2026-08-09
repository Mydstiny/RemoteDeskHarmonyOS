#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <cmath>

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
 * Desktop NativeImage producers can publish a texture-origin transform that
 * differs from Phone/Pad AVCodec surfaces. Mobile presentation is already a
 * released contract, so only the explicit desktop compatibility path consumes
 * the producer matrix. Invalid reads retain the last complete matrix to avoid
 * one-frame orientation flicker.
 */
inline NativeImageTransform ResolveNativeImagePresentationTransform(
    bool desktopSurfaceCompatibility,
    int32_t readResult,
    const float matrix[16],
    const NativeImageTransform& previous) {
    if (!desktopSurfaceCompatibility) {
        return IdentityNativeImageTransform();
    }
    if (readResult != 0 || matrix == nullptr) {
        return previous;
    }
    NativeImageTransform resolved {};
    for (size_t index = 0; index < resolved.size(); ++index) {
        if (!std::isfinite(matrix[index])) {
            return previous;
        }
        resolved[index] = matrix[index];
    }
    return resolved;
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
