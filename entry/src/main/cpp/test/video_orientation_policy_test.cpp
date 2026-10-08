#include "render/video_orientation_policy.h"
#include "render/video_stream_inspection.h"
#include "test_runner.h"

#include <cmath>
#include <vector>

namespace {

using Render::NativeImageTransform;
using Render::NativeImageTransformClass;

const uint32_t kRed = Render::PackRgba(250, 4, 2, 255);
const uint32_t kGreen = Render::PackRgba(3, 252, 6, 255);
const uint32_t kBlue = Render::PackRgba(5, 2, 249, 255);
const uint32_t kWhite = Render::PackRgba(252, 253, 251, 255);

const NativeImageTransformClass kAxisClasses[] = {
    NativeImageTransformClass::Identity, NativeImageTransformClass::FlipX,
    NativeImageTransformClass::FlipY, NativeImageTransformClass::Rotate180,
    NativeImageTransformClass::Rotate90, NativeImageTransformClass::Rotate270,
    NativeImageTransformClass::Transpose, NativeImageTransformClass::Transverse,
};

bool NearlyIdentity(const NativeImageTransform& matrix) {
    const NativeImageTransform identity = Render::IdentityNativeImageTransform();
    for (size_t index = 0; index < 16; ++index) {
        if (std::fabs(matrix[index] - identity[index]) > 0.0001f) { return false; }
    }
    return true;
}

/** Corners the screen shows when it samples the source through `shown` (sampling convention). */
std::array<uint32_t, 4> CornersFor(NativeImageTransformClass shown) {
    const NativeImageTransform matrix = Render::NativeImageTransformForClass(shown);
    const float points[4][2] = { {0.25f, 0.25f}, {0.75f, 0.25f}, {0.25f, 0.75f}, {0.75f, 0.75f} };
    std::array<uint32_t, 4> corners {};
    for (size_t index = 0; index < 4; ++index) {
        const float x = points[index][0];
        const float y = points[index][1];
        const float u = matrix[0] * x + matrix[4] * y + matrix[12];
        const float v = matrix[1] * x + matrix[5] * y + matrix[13];
        const bool right = u > 0.5f;
        const bool bottom = v > 0.5f;
        corners[index] = bottom ? (right ? kWhite : kBlue) : (right ? kGreen : kRed);
    }
    return corners;
}

} // namespace

RDP_TEST_CASE(video_orientation_classifies_every_axis_aligned_quadrant_layout) {
    for (NativeImageTransformClass shown : kAxisClasses) {
        RDP_ASSERT(Render::ClassifyQuadrantCorners(CornersFor(shown)) == shown);
    }
}

RDP_TEST_CASE(video_orientation_rejects_unclear_or_repeated_corners) {
    RDP_ASSERT(Render::ClassifyQuadrantCorners({ kRed, kRed, kBlue, kWhite }) ==
        NativeImageTransformClass::ReadFailed);
    RDP_ASSERT(Render::ClassifyQuadrantCorners({ Render::PackRgba(0, 0, 0, 255), kGreen, kBlue, kWhite }) ==
        NativeImageTransformClass::ReadFailed);
    RDP_ASSERT(Render::ClassifyQuadrantCorners({ Render::PackRgba(128, 128, 128, 255), kGreen, kBlue, kWhite }) ==
        NativeImageTransformClass::ReadFailed);
    // Limited-range YUV and chroma loss still classify.
    RDP_ASSERT(Render::ClassifyQuadrantColour(Render::PackRgba(235, 30, 25, 255)) == Render::OrientationQuadrant::Red);
    RDP_ASSERT(Render::ClassifyQuadrantColour(Render::PackRgba(235, 235, 235, 255)) == Render::OrientationQuadrant::White);
}

RDP_TEST_CASE(video_orientation_correction_restores_upright_sampling) {
    // A path whose texture coordinates equal source coordinates shows `shown`
    // when sampled through matrix(shown); the correction must cancel it.
    for (NativeImageTransformClass shown : kAxisClasses) {
        const NativeImageTransform applied = Render::NativeImageTransformForClass(shown);
        const NativeImageTransform corrected = Render::CorrectedNativeImageTransform(applied, shown);
        RDP_ASSERT(NearlyIdentity(corrected));
    }
    // Identity, Other and failures leave the applied transform untouched.
    const NativeImageTransform crop = { 0.9f, 0, 0, 0, 0, -0.8f, 0, 0, 0, 0, 1, 0, 0.05f, 0.9f, 0, 1 };
    RDP_ASSERT(Render::CorrectedNativeImageTransform(crop, NativeImageTransformClass::Identity) == crop);
    RDP_ASSERT(Render::CorrectedNativeImageTransform(crop, NativeImageTransformClass::ReadFailed) == crop);
}

RDP_TEST_CASE(video_orientation_correction_keeps_crop_and_fixes_flip) {
    // Texture coordinates map to source through a vertical origin flip (the
    // driver convention we suspect on PCs); the applied matrix crops 90%.
    const NativeImageTransform crop = { 0.9f, 0, 0, 0, 0, 0.9f, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const auto sourceOf = [](const NativeImageTransform& m, float x, float y, float& sx, float& sy) {
        const float u = m[0] * x + m[4] * y + m[12];
        const float v = m[1] * x + m[5] * y + m[13];
        sx = u;
        sy = 1.0f - v;  // the device shows texture row v at source row 1 - v
    };
    float sx = 0;
    float sy = 0;
    sourceOf(crop, 0.1f, 0.1f, sx, sy);
    RDP_ASSERT(sy > 0.5f);  // upside down before correction
    const NativeImageTransform corrected =
        Render::CorrectedNativeImageTransform(crop, NativeImageTransformClass::FlipY);
    sourceOf(corrected, 0.1f, 0.1f, sx, sy);
    RDP_ASSERT(std::fabs(sx - 0.09f) < 0.001f && std::fabs(sy - 0.19f) < 0.001f);
}

RDP_TEST_CASE(video_orientation_texture_space_correction_keeps_crop_on_turned_textures) {
    // The GPU texture itself is upside down (texture row v holds source row 1 - v);
    // the applied matrix crops 1080 of 1088 rows.
    const float a = 1080.0f / 1088.0f;
    const NativeImageTransform crop = { 1, 0, 0, 0, 0, a, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const auto sourceRow = [](const NativeImageTransform& m, float y) {
        const float v = m[5] * y + m[13];
        return 1.0f - v;  // texture row v shows source row 1 - v
    };
    // Screen space would read padding at the top edge; texture space maps the top to the first picture row.
    const NativeImageTransform screen =
        Render::CorrectedNativeImageTransform(crop, NativeImageTransformClass::FlipY, false);
    const NativeImageTransform texture =
        Render::CorrectedNativeImageTransform(crop, NativeImageTransformClass::FlipY, true);
    RDP_ASSERT(std::fabs(sourceRow(texture, 0.0f) - 0.0f) < 0.0001f);
    RDP_ASSERT(std::fabs(sourceRow(texture, 1.0f) - a) < 0.0001f);
    RDP_ASSERT(std::fabs(sourceRow(screen, 0.0f) - 0.0f) > 0.005f);
}

RDP_TEST_CASE(video_orientation_corrections_are_upright_for_every_texture_turn_and_matrix) {
    // The texture shows source point T(t) at texture point t; the session samples through M.
    // Identity read: class(T); applied read: class(T * M). Both corrections must end upright.
    for (NativeImageTransformClass texture : kAxisClasses) {
        for (NativeImageTransformClass matrixClass : kAxisClasses) {
            const NativeImageTransform turn = Render::NativeImageTransformForClass(texture);
            const NativeImageTransform matrix = Render::NativeImageTransformForClass(matrixClass);
            const NativeImageTransformClass shown = Render::ClassifyNativeImageProducerTransform(
                0, Render::MultiplyNativeImageTransforms(turn, matrix).data());
            if (!Render::OrientationIsCorrectable(shown)) { continue; }
            const NativeImageTransform screen = Render::CorrectedNativeImageTransform(matrix, shown, false);
            RDP_ASSERT(NearlyIdentity(Render::MultiplyNativeImageTransforms(turn, screen)));
            const NativeImageTransformClass undone = Render::TextureSpaceCorrectionClass(matrix, texture);
            RDP_ASSERT(Render::OrientationIsCorrectable(undone));
            const NativeImageTransform inTexture = Render::CorrectedNativeImageTransform(matrix, undone, true);
            RDP_ASSERT(NearlyIdentity(Render::MultiplyNativeImageTransforms(turn, inTexture)));
        }
    }
    // A mirrored texture under a flipping matrix shows Rotate180; undoing the texture alone left it upside down.
    RDP_ASSERT(Render::TextureSpaceCorrectionClass(Render::NativeImageTransformForClass(NativeImageTransformClass::FlipY),
        NativeImageTransformClass::FlipX) == NativeImageTransformClass::Rotate180);
}

RDP_TEST_CASE(video_orientation_texture_space_keeps_crop_on_a_quarter_turned_texture) {
    // Picture rows fill 1080 of 1088 texture rows; the texture content is also turned a quarter.
    // The producer crops for an unturned texture; the texture-space correction restores it exactly.
    const float a = 1080.0f / 1088.0f;
    const NativeImageTransform expected = { 1, 0, 0, 0, 0, 1.0f / a, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const NativeImageTransform crop = { 1, 0, 0, 0, 0, a, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    const NativeImageTransform turn = Render::MultiplyNativeImageTransforms(expected,
        Render::NativeImageTransformForClass(NativeImageTransformClass::Rotate90));
    RDP_ASSERT(Render::AxisClassOfNativeImageTransform(turn) == NativeImageTransformClass::Rotate90);
    RDP_ASSERT(Render::AxisClassOfNativeImageTransform(crop) == NativeImageTransformClass::Identity);
    const NativeImageTransformClass undone =
        Render::TextureSpaceCorrectionClass(crop, NativeImageTransformClass::Rotate90);
    RDP_ASSERT(undone == NativeImageTransformClass::Rotate90);
    const NativeImageTransform corrected = Render::CorrectedNativeImageTransform(crop, undone, true);
    RDP_ASSERT(NearlyIdentity(Render::MultiplyNativeImageTransforms(turn, corrected)));
    // A matrix that is not axis-aligned leaves the choice to screen space.
    const NativeImageTransform skew = { 0.7f, 0.7f, 0, 0, -0.7f, 0.7f, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    RDP_ASSERT(Render::TextureSpaceCorrectionClass(skew, NativeImageTransformClass::FlipY) ==
        NativeImageTransformClass::Other);
}

RDP_TEST_CASE(video_stream_inspection_reads_h264_units_and_display_orientation_sei) {
    // SPS(7), PPS(8), SEI(6) with display orientation (payload 47): cancel=0,
    // hor=0, ver=1, rotation=0x8000, then IDR(5). 3- and 4-byte start codes.
    const std::vector<uint8_t> unit = {
        0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1e,
        0, 0, 1, 0x68, 0xce,
        0, 0, 0, 1, 0x06, 47, 3, 0x30, 0x00, 0x00, 0x80,
        0, 0, 1, 0x65, 0x88, 0x84,
    };
    Render::VideoStreamInspection inspection;
    Render::InspectAnnexBAccessUnit(unit.data(), unit.size(), false, inspection);
    RDP_ASSERT(inspection.annexB);
    RDP_ASSERT(inspection.nalMaskLow == ((1ULL << 7) | (1ULL << 8) | (1ULL << 6) | (1ULL << 5)));
    RDP_ASSERT(inspection.seiMaskHigh == (1ULL << (47 - 32)));
    RDP_ASSERT(inspection.displayOrientation && !inspection.orientationCancel);
    RDP_ASSERT(!inspection.horFlip && inspection.verFlip);
    RDP_ASSERT(inspection.rotation == 0x8000);
    RDP_ASSERT(Render::PackedDisplayOrientation(inspection) == ((1 << 2) | (0x8000LL << 3)));
}

RDP_TEST_CASE(video_stream_inspection_reads_h265_headers_and_emulation_prevention) {
    // VPS(32), SPS(33), prefix SEI(39) with user data (payload 5, an
    // emulation-prevention byte inside), IDR_W_RADL(19).
    const std::vector<uint8_t> unit = {
        0, 0, 0, 1, 0x40, 0x01, 0x0c,
        0, 0, 0, 1, 0x42, 0x01, 0x01,
        0, 0, 0, 1, 0x4e, 0x01, 5, 4, 0x00, 0x00, 0x03, 0x01, 0x02, 0x80,
        0, 0, 0, 1, 0x26, 0x01, 0xaf,
    };
    Render::VideoStreamInspection inspection;
    Render::InspectAnnexBAccessUnit(unit.data(), unit.size(), true, inspection);
    RDP_ASSERT(inspection.nalMaskHigh == ((1ULL << 0) | (1ULL << 1) | (1ULL << 7)));
    RDP_ASSERT(inspection.nalMaskLow == (1ULL << 19));
    RDP_ASSERT(inspection.seiMaskLow == (1ULL << 5));
    RDP_ASSERT(!inspection.displayOrientation);
    RDP_ASSERT(Render::PackedDisplayOrientation(inspection) == -1);
    Render::VideoStreamInspection none;
    const uint8_t length[] = { 0, 0, 0, 12, 0x65, 0x88 };
    Render::InspectAnnexBAccessUnit(length, sizeof(length), false, none);
    RDP_ASSERT(!none.annexB);
}
