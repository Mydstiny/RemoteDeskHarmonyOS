#pragma once

#include "native_image_context_policy.h"

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace Render {

/** Where a self-test stopped. Done means every step ran and the corners were read. */
enum class OrientationSelfTestStage : int32_t {
    NotRun = 0,
    Egl = 1,
    Texture = 2,
    NativeImage = 3,
    NativeWindow = 4,
    CreateDecoder = 5,
    Configure = 6,
    Surface = 7,
    Start = 8,
    Input = 9,
    Output = 10,
    FrameAvailable = 11,
    UpdateImage = 12,
    Render = 13,
    ReadPixels = 14,
    Done = 15,
};

/** The codecs the self-test carries a known picture for (values match CodecType). */
enum class OrientationSelfTestCodec : int32_t { H264 = 0, H265 = 1 };

struct OrientationSelfTestResult {
    int32_t codec = 0;
    NativeImagePresentationMode mode = NativeImagePresentationMode::Identity;
    OrientationSelfTestStage stage = OrientationSelfTestStage::NotRun;
    /** Native return value where the step failed (0 when none). */
    int32_t platformCode = 0;
    int32_t hardware = -1;
    std::string decoderName;
    int32_t outputWidth = 0;
    int32_t outputHeight = 0;
    int32_t outputStride = 0;
    int32_t outputSliceHeight = 0;
    int32_t outputPixelFormat = -1;
    int32_t outputRotation = -1;
    int32_t outputTransformType = -1;
    int32_t outputCropTop = -1;
    int32_t outputCropBottom = -1;
    int32_t outputCropLeft = -1;
    int32_t outputCropRight = -1;
    int32_t bufferTransform = -1;
    int32_t v2ReadResult = -1;
    NativeImageTransform v2Matrix = IdentityNativeImageTransform();
    NativeImageTransformClass v2Class = NativeImageTransformClass::NotSampled;
    int32_t v1ReadResult = -1;
    NativeImageTransform v1Matrix = IdentityNativeImageTransform();
    NativeImageTransformClass v1Class = NativeImageTransformClass::NotSampled;
    /** What the screen shows relative to the picture when sampled with no transform. */
    NativeImageTransformClass identityOrientation = NativeImageTransformClass::NotSampled;
    /** The same with the transform the session would apply in `mode` (before manual flips). */
    NativeImageTransformClass appliedOrientation = NativeImageTransformClass::NotSampled;
    std::array<uint32_t, 4> identityCorners {};
    std::array<uint32_t, 4> appliedCorners {};
    std::string glRenderer;
    std::string glVendor;
    std::string glVersion;
    int64_t elapsedMs = 0;
    int64_t completedAtMs = 0;
};

/**
 * Decode the known four-colour picture with the platform decoder for `codec`
 * into a NativeImage on a private EGL context, render it as the session would
 * in `mode`, and read the corners back. Blocking (about a second at most);
 * call it off the UI thread. Results are kept per codec and mode.
 */
OrientationSelfTestResult RunVideoOrientationSelfTest(OrientationSelfTestCodec codec,
                                                      NativeImagePresentationMode mode);

/** The latest result for codec and mode, if one ran in this process. */
bool LatestVideoOrientationSelfTest(OrientationSelfTestCodec codec, NativeImagePresentationMode mode,
                                    OrientationSelfTestResult& result);

/** What the desktop path measured for a codec: how the picture was shown, and where the turn lives. */
struct DesktopOrientationCorrection {
    NativeImageTransformClass shown = NativeImageTransformClass::NotSampled;
    /** The GPU texture itself was turned (sampling with no transform already showed it turned). */
    bool textureSpace = false;
};

/**
 * The orientation the desktop presentation path (TopLeftProducerTransform)
 * measured for `codec`; `shown` is NotSampled until a conclusive test ran.
 * Read on every presented frame; lock-free.
 */
DesktopOrientationCorrection DesktopOrientationCorrectionFor(int32_t codec);

/**
 * Start a background self-test for codec and mode unless one completed or
 * runs already; a test that stopped short is retried (at most three times,
 * ten seconds apart).
 */
void EnsureVideoOrientationSelfTest(OrientationSelfTestCodec codec, NativeImagePresentationMode mode);

/** Every result kept in this process, ordered by codec then mode. */
std::vector<OrientationSelfTestResult> AllVideoOrientationSelfTests();

const char* OrientationSelfTestStageName(OrientationSelfTestStage stage);

} // namespace Render
