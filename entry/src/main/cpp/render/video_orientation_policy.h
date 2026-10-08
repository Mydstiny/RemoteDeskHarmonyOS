#pragma once

#include "native_image_context_policy.h"

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>

namespace Render {

/**
 * The orientation self-test decodes a known picture (four solid quadrants)
 * through the real decoder, NativeImage and GPU path and reads back what the
 * renderer would put on screen. These helpers turn the four read-back corner
 * colours into an orientation class and that class into the texture-coordinate
 * correction that undoes it. Classes use the sampling-coordinate convention of
 * ClassifyNativeImageProducerTransform: a class describes which source point
 * is shown at each screen point.
 */
namespace OrientationQuadrant {
// Source picture: top-left red, top-right green, bottom-left blue, bottom-right white.
enum : int32_t { Red = 0, Green = 1, Blue = 2, White = 3, Unknown = -1 };
} // namespace OrientationQuadrant

/** RGBA packed as 0xRRGGBBAA. */
inline uint32_t PackRgba(uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    return (static_cast<uint32_t>(r) << 24) | (static_cast<uint32_t>(g) << 16) |
        (static_cast<uint32_t>(b) << 8) | static_cast<uint32_t>(a);
}

/** Which source quadrant a read-back colour belongs to; Unknown when it is not clearly one of them. */
inline int32_t ClassifyQuadrantColour(uint32_t rgba) {
    const int r = static_cast<int>((rgba >> 24) & 0xffU);
    const int g = static_cast<int>((rgba >> 16) & 0xffU);
    const int b = static_cast<int>((rgba >> 8) & 0xffU);
    const int references[4][3] = { {255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {255, 255, 255} };
    int best = OrientationQuadrant::Unknown;
    int bestDistance = 1 << 30;
    int secondDistance = 1 << 30;
    for (int index = 0; index < 4; ++index) {
        const int dr = r - references[index][0];
        const int dg = g - references[index][1];
        const int db = b - references[index][2];
        const int distance = dr * dr + dg * dg + db * db;
        if (distance < bestDistance) {
            secondDistance = bestDistance;
            bestDistance = distance;
            best = index;
        } else if (distance < secondDistance) {
            secondDistance = distance;
        }
    }
    // Codec and colour-range losses stay well inside 90 per channel; the next
    // reference must be clearly further away so a grey or black read never passes.
    if (bestDistance > 3 * 90 * 90 || secondDistance < bestDistance * 4) {
        return OrientationQuadrant::Unknown;
    }
    return best;
}

/**
 * Orientation of the screen relative to the source, from the colours read at
 * the screen's top-left, top-right, bottom-left and bottom-right quadrant
 * centres. ReadFailed when a corner is not recognisable or two corners agree.
 */
inline NativeImageTransformClass ClassifyQuadrantCorners(const std::array<uint32_t, 4>& corners) {
    std::array<int32_t, 4> shown {};
    bool seen[4] = { false, false, false, false };
    for (size_t index = 0; index < 4; ++index) {
        shown[index] = ClassifyQuadrantColour(corners[index]);
        if (shown[index] < 0 || seen[shown[index]]) {
            return NativeImageTransformClass::ReadFailed;
        }
        seen[shown[index]] = true;
    }
    using Q = std::array<int32_t, 4>;
    const auto is = [&shown](const Q& pattern) { return shown == pattern; };
    if (is(Q { 0, 1, 2, 3 })) return NativeImageTransformClass::Identity;
    if (is(Q { 1, 0, 3, 2 })) return NativeImageTransformClass::FlipX;
    if (is(Q { 2, 3, 0, 1 })) return NativeImageTransformClass::FlipY;
    if (is(Q { 3, 2, 1, 0 })) return NativeImageTransformClass::Rotate180;
    // x'=y, y'=1-x: screen TL shows source BL.
    if (is(Q { 2, 0, 3, 1 })) return NativeImageTransformClass::Rotate90;
    // x'=1-y, y'=x: screen TL shows source TR.
    if (is(Q { 1, 3, 0, 2 })) return NativeImageTransformClass::Rotate270;
    if (is(Q { 0, 2, 1, 3 })) return NativeImageTransformClass::Transpose;
    if (is(Q { 3, 1, 2, 0 })) return NativeImageTransformClass::Transverse;
    return NativeImageTransformClass::Other;
}

/** The texture-coordinate matrix (column-major, top-left basis) of an axis-aligned class. */
inline NativeImageTransform NativeImageTransformForClass(NativeImageTransformClass transformClass) {
    NativeImageTransform matrix = IdentityNativeImageTransform();
    switch (transformClass) {
        case NativeImageTransformClass::FlipX:
            matrix[0] = -1.0f; matrix[12] = 1.0f; break;
        case NativeImageTransformClass::FlipY:
            matrix[5] = -1.0f; matrix[13] = 1.0f; break;
        case NativeImageTransformClass::Rotate180:
            matrix[0] = -1.0f; matrix[5] = -1.0f; matrix[12] = 1.0f; matrix[13] = 1.0f; break;
        case NativeImageTransformClass::Rotate90:
            matrix[0] = 0.0f; matrix[5] = 0.0f; matrix[4] = 1.0f; matrix[1] = -1.0f; matrix[13] = 1.0f; break;
        case NativeImageTransformClass::Rotate270:
            matrix[0] = 0.0f; matrix[5] = 0.0f; matrix[4] = -1.0f; matrix[1] = 1.0f; matrix[12] = 1.0f; break;
        case NativeImageTransformClass::Transpose:
            matrix[0] = 0.0f; matrix[5] = 0.0f; matrix[4] = 1.0f; matrix[1] = 1.0f; break;
        case NativeImageTransformClass::Transverse:
            matrix[0] = 0.0f; matrix[5] = 0.0f; matrix[4] = -1.0f; matrix[1] = -1.0f;
            matrix[12] = 1.0f; matrix[13] = 1.0f; break;
        default:
            break;
    }
    return matrix;
}

/** The class that undoes `shown`: every class is its own inverse except the quarter turns. */
inline NativeImageTransformClass InverseOrientationClass(NativeImageTransformClass shown) {
    if (shown == NativeImageTransformClass::Rotate90) return NativeImageTransformClass::Rotate270;
    if (shown == NativeImageTransformClass::Rotate270) return NativeImageTransformClass::Rotate90;
    return shown;
}

/** Whether a measured orientation can be corrected (an axis-aligned class other than identity). */
inline bool OrientationIsCorrectable(NativeImageTransformClass shown) {
    switch (shown) {
        case NativeImageTransformClass::FlipX:
        case NativeImageTransformClass::FlipY:
        case NativeImageTransformClass::Rotate180:
        case NativeImageTransformClass::Rotate90:
        case NativeImageTransformClass::Rotate270:
        case NativeImageTransformClass::Transpose:
        case NativeImageTransformClass::Transverse:
            return true;
        default:
            return false;
    }
}

/** Column-major product left * right (right is applied to the coordinate first). */
inline NativeImageTransform MultiplyNativeImageTransforms(const NativeImageTransform& left,
                                                          const NativeImageTransform& right) {
    NativeImageTransform result {};
    for (size_t column = 0; column < 4; ++column) {
        for (size_t row = 0; row < 4; ++row) {
            float sum = 0.0f;
            for (size_t k = 0; k < 4; ++k) {
                sum += left[k * 4 + row] * right[column * 4 + k];
            }
            result[column * 4 + row] = sum;
        }
    }
    return result;
}

/**
 * The axis-aligned class of a texture transform that may also crop (the signs
 * of its linear part); Other when it is not axis-aligned.
 */
inline NativeImageTransformClass AxisClassOfNativeImageTransform(const NativeImageTransform& matrix) {
    const auto zero = [](float value) { return std::fabs(value) <= 0.0001f; };
    if (zero(matrix[4]) && zero(matrix[1]) && !zero(matrix[0]) && !zero(matrix[5])) {
        const bool x = matrix[0] > 0.0f;
        const bool y = matrix[5] > 0.0f;
        if (x && y) return NativeImageTransformClass::Identity;
        if (!x && y) return NativeImageTransformClass::FlipX;
        if (x && !y) return NativeImageTransformClass::FlipY;
        return NativeImageTransformClass::Rotate180;
    }
    if (zero(matrix[0]) && zero(matrix[5]) && !zero(matrix[4]) && !zero(matrix[1])) {
        const bool xFromY = matrix[4] > 0.0f;
        const bool yFromX = matrix[1] > 0.0f;
        if (xFromY && !yFromX) return NativeImageTransformClass::Rotate90;
        if (!xFromY && yFromX) return NativeImageTransformClass::Rotate270;
        if (xFromY && yFromX) return NativeImageTransformClass::Transpose;
        return NativeImageTransformClass::Transverse;
    }
    return NativeImageTransformClass::Other;
}

/**
 * The class a texture-space correction undoes. With the texture's own turn T
 * (what sampling with no transform showed) and the applied matrix M, sampling
 * through C^-1 * M shows source point T(C^-1(M(s))), which is upright when
 * C = M * T: the applied matrix's class after the texture's turn (T alone is
 * right only when M has no turn of its own). Other when the applied matrix is
 * not axis-aligned or the turn is unknown (correct in screen space instead).
 */
inline NativeImageTransformClass TextureSpaceCorrectionClass(const NativeImageTransform& applied,
                                                            NativeImageTransformClass textureShown) {
    const NativeImageTransformClass appliedClass = AxisClassOfNativeImageTransform(applied);
    if (appliedClass == NativeImageTransformClass::Other ||
        (textureShown != NativeImageTransformClass::Identity && !OrientationIsCorrectable(textureShown))) {
        return NativeImageTransformClass::Other;
    }
    const NativeImageTransform product = MultiplyNativeImageTransforms(
        NativeImageTransformForClass(appliedClass), NativeImageTransformForClass(textureShown));
    return ClassifyNativeImageProducerTransform(0, product.data());
}

/**
 * The sampling transform that shows the source upright when `applied` was
 * measured to show it as `shown`.
 *
 * Screen space (applied * inverse): the screen coordinate is mapped back
 * through the inverse orientation before `applied` — right when `applied`
 * itself introduced the turn (a producer matrix that disagrees with the
 * texture). Texture space (inverse * applied): the texture coordinate is
 * mapped after `applied` — right when the GPU's texture itself is turned, so
 * a crop inside `applied` keeps addressing the picture rows, not padding
 * (`shown` is then TextureSpaceCorrectionClass, not the measured class).
 */
inline NativeImageTransform CorrectedNativeImageTransform(const NativeImageTransform& applied,
                                                          NativeImageTransformClass shown,
                                                          bool textureSpace = false) {
    if (!OrientationIsCorrectable(shown)) {
        return applied;
    }
    const NativeImageTransform inverse = NativeImageTransformForClass(InverseOrientationClass(shown));
    return textureSpace ? MultiplyNativeImageTransforms(inverse, applied) :
        MultiplyNativeImageTransforms(applied, inverse);
}

} // namespace Render
