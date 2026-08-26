#pragma once

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace Render {

using NativeImageTransform = std::array<float, 16>;

enum class NativeImagePresentationMode : uint8_t {
    Identity = 0,
    ProducerTransform = 1,
};

inline NativeImagePresentationMode NativeImageModeForDesktopSurface(
    bool desktopSurfaceCompatibility) noexcept {
    return desktopSurfaceCompatibility
        ? NativeImagePresentationMode::ProducerTransform
        : NativeImagePresentationMode::Identity;
}

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
 * The transform source is an explicit protocol decision. Moonlight and the
 * released mobile paths retain the renderer's top-left identity contract,
 * while a RustDesk PC session connected to a Windows peer consumes the valid
 * NativeImage producer matrix to bridge the AVCodec texture-origin mismatch.
 */
inline NativeImageTransform ResolveNativeImagePresentationTransform(
    NativeImagePresentationMode mode,
    int32_t readResult,
    const float matrix[16],
    const NativeImageTransform& previous) {
    if (mode != NativeImagePresentationMode::ProducerTransform) {
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

inline const char* NativeImagePresentationModeName(
    NativeImagePresentationMode mode) {
    return mode == NativeImagePresentationMode::ProducerTransform
        ? "producer" : "identity";
}

inline bool ShouldRenderNativeImageImmediately(bool desktopSurfaceCompatibility) {
    return desktopSurfaceCompatibility;
}

constexpr int kNativeErrorNoBuffer = 40601000;
// A failed acquire can be a short producer/consumer handoff race. Bound the
// retry work so a missing surface buffer cannot monopolize the render thread.
// API 23 drop-buffer mode can emit several stale callbacks in one display
// interval. One short handoff retry is enough; waiting 2+4+8 ms for every
// stale callback can occupy nearly the full 60 Hz frame budget and looks like
// a frozen stream even though decode continues. The next producer callback
// carries the newest buffer, so coalesce immediately after this single retry.
constexpr int kNativeImageUpdateRetryBudget = 1;
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
