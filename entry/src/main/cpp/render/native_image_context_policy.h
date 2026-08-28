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
    ValidatedProducerTransform = 2,
};

enum class NativeImageTransformClass : uint8_t {
    NotSampled = 0,
    Identity = 1,
    FlipX = 2,
    FlipY = 3,
    Rotate180 = 4,
    Rotate90 = 5,
    Rotate270 = 6,
    Transpose = 7,
    Transverse = 8,
    Other = 9,
    ReadFailed = 10,
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

inline NativeImageTransformClass ClassifyNativeImageProducerTransform(
    int32_t readResult, const float matrix[16]);

/**
 * Return the texture transform for an encoded remote-desktop frame.
 *
 * The transform source is an explicit protocol decision. A protocol may use
 * identity, trust every finite producer matrix, or accept only the eight
 * axis-aligned transforms understood by this renderer. Peer platform labels
 * never select or reinterpret a matrix.
 */
inline NativeImageTransform ResolveNativeImagePresentationTransform(
    NativeImagePresentationMode mode,
    int32_t readResult,
    const float matrix[16],
    const NativeImageTransform& previous) {
    if (mode == NativeImagePresentationMode::Identity) {
        return IdentityNativeImageTransform();
    }
    if (readResult != 0 || matrix == nullptr) {
        return previous;
    }
    if (mode == NativeImagePresentationMode::ValidatedProducerTransform) {
        const NativeImageTransformClass transformClass =
            ClassifyNativeImageProducerTransform(readResult, matrix);
        if (transformClass == NativeImageTransformClass::Other ||
            transformClass == NativeImageTransformClass::ReadFailed ||
            transformClass == NativeImageTransformClass::NotSampled) {
            return previous;
        }
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

inline bool NativeImageTransformNearlyEqual(float left, float right) {
    return std::isfinite(left) && std::fabs(left - right) <= 0.01f;
}

inline NativeImageTransformClass ClassifyNativeImageProducerTransform(
    int32_t readResult, const float matrix[16]) {
    if (readResult != 0 || matrix == nullptr) {
        return NativeImageTransformClass::ReadFailed;
    }
    for (size_t index = 0; index < 16; ++index) {
        if (!std::isfinite(matrix[index])) {
            return NativeImageTransformClass::ReadFailed;
        }
    }
    const bool common =
        NativeImageTransformNearlyEqual(matrix[2], 0.0f) &&
        NativeImageTransformNearlyEqual(matrix[6], 0.0f) &&
        NativeImageTransformNearlyEqual(matrix[8], 0.0f) &&
        NativeImageTransformNearlyEqual(matrix[9], 0.0f) &&
        NativeImageTransformNearlyEqual(matrix[10], 1.0f) &&
        NativeImageTransformNearlyEqual(matrix[11], 0.0f) &&
        NativeImageTransformNearlyEqual(matrix[3], 0.0f) &&
        NativeImageTransformNearlyEqual(matrix[7], 0.0f) &&
        NativeImageTransformNearlyEqual(matrix[14], 0.0f) &&
        NativeImageTransformNearlyEqual(matrix[15], 1.0f);
    if (!common) {
        return NativeImageTransformClass::Other;
    }
    const bool xPositive = NativeImageTransformNearlyEqual(matrix[0], 1.0f);
    const bool xNegative = NativeImageTransformNearlyEqual(matrix[0], -1.0f);
    const bool xZero = NativeImageTransformNearlyEqual(matrix[0], 0.0f);
    const bool xFromYPositive = NativeImageTransformNearlyEqual(matrix[4], 1.0f);
    const bool xFromYNegative = NativeImageTransformNearlyEqual(matrix[4], -1.0f);
    const bool xFromYZero = NativeImageTransformNearlyEqual(matrix[4], 0.0f);
    const bool yFromXPositive = NativeImageTransformNearlyEqual(matrix[1], 1.0f);
    const bool yFromXNegative = NativeImageTransformNearlyEqual(matrix[1], -1.0f);
    const bool yFromXZero = NativeImageTransformNearlyEqual(matrix[1], 0.0f);
    const bool yPositive = NativeImageTransformNearlyEqual(matrix[5], 1.0f);
    const bool yNegative = NativeImageTransformNearlyEqual(matrix[5], -1.0f);
    const bool yZero = NativeImageTransformNearlyEqual(matrix[5], 0.0f);
    const bool xOrigin = NativeImageTransformNearlyEqual(matrix[12], 0.0f);
    const bool xShift = NativeImageTransformNearlyEqual(matrix[12], 1.0f);
    const bool yOrigin = NativeImageTransformNearlyEqual(matrix[13], 0.0f);
    const bool yShift = NativeImageTransformNearlyEqual(matrix[13], 1.0f);
    if (xPositive && xFromYZero && yFromXZero && yPositive &&
        xOrigin && yOrigin) {
        return NativeImageTransformClass::Identity;
    }
    if (xNegative && xFromYZero && yFromXZero && yPositive &&
        xShift && yOrigin) {
        return NativeImageTransformClass::FlipX;
    }
    if (xPositive && xFromYZero && yFromXZero && yNegative &&
        xOrigin && yShift) {
        return NativeImageTransformClass::FlipY;
    }
    if (xNegative && xFromYZero && yFromXZero && yNegative &&
        xShift && yShift) {
        return NativeImageTransformClass::Rotate180;
    }
    // x'=y, y'=1-x
    if (xZero && xFromYPositive && yFromXNegative && yZero &&
        xOrigin && yShift) {
        return NativeImageTransformClass::Rotate90;
    }
    // x'=1-y, y'=x
    if (xZero && xFromYNegative && yFromXPositive && yZero &&
        xShift && yOrigin) {
        return NativeImageTransformClass::Rotate270;
    }
    // x'=y, y'=x
    if (xZero && xFromYPositive && yFromXPositive && yZero &&
        xOrigin && yOrigin) {
        return NativeImageTransformClass::Transpose;
    }
    // x'=1-y, y'=1-x
    if (xZero && xFromYNegative && yFromXNegative && yZero &&
        xShift && yShift) {
        return NativeImageTransformClass::Transverse;
    }
    return NativeImageTransformClass::Other;
}

inline const char* NativeImageTransformClassName(
    NativeImageTransformClass transformClass) {
    switch (transformClass) {
        case NativeImageTransformClass::Identity: return "identity";
        case NativeImageTransformClass::FlipX: return "flip_x";
        case NativeImageTransformClass::FlipY: return "flip_y";
        case NativeImageTransformClass::Rotate180: return "rotate_180";
        case NativeImageTransformClass::Rotate90: return "rotate_90";
        case NativeImageTransformClass::Rotate270: return "rotate_270";
        case NativeImageTransformClass::Transpose: return "transpose";
        case NativeImageTransformClass::Transverse: return "transverse";
        case NativeImageTransformClass::Other: return "other";
        case NativeImageTransformClass::ReadFailed: return "read_failed";
        case NativeImageTransformClass::NotSampled:
        default: return "not_sampled";
    }
}

inline const char* NativeImagePresentationModeName(
    NativeImagePresentationMode mode) {
    switch (mode) {
        case NativeImagePresentationMode::ProducerTransform:
            return "producer";
        case NativeImagePresentationMode::ValidatedProducerTransform:
            return "validated_producer";
        case NativeImagePresentationMode::Identity:
        default:
            return "identity";
    }
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
