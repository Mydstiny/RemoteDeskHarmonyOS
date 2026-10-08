/**
 * video_orientation_self_test.cpp — decode a known picture through the real
 * decoder → NativeImage → GPU path and read back how it lands on screen.
 *
 * HarmonyOS PCs showed RustDesk hardware-decoded desktops upside down while
 * phones and tablets did not, and the producer matrix alone could not tell
 * why. This test measures the whole path on the device itself.
 */

#include "video_orientation_self_test.h"

#include "gl_renderer.h"
#include "video_orientation_policy.h"
#include "video_orientation_test_streams.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <hilog/log.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avbuffer_info.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avformat.h>
#include <native_image/native_image.h>
#include <native_window/external_window.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0004
#define LOG_TAG "VIDEO_ORIENT"

namespace Render {
namespace {

constexpr int kTargetSize = 64;
constexpr auto kInputWait = std::chrono::milliseconds(1500);
constexpr auto kOutputWait = std::chrono::milliseconds(2500);
constexpr auto kFrameWait = std::chrono::milliseconds(1500);

int64_t NowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
}

/** Keep only printable, bounded text from platform strings. */
std::string SafeText(const char* value, size_t limit = 64) {
    std::string out;
    if (value == nullptr) { return out; }
    for (const char* cursor = value; *cursor != '\0' && out.size() < limit; ++cursor) {
        const char c = *cursor;
        const bool allowed = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
            c == ' ' || c == '.' || c == '_' || c == '-' || c == '(' || c == ')' || c == '/';
        out.push_back(allowed ? c : '_');
    }
    return out;
}

struct DecodeState {
    std::mutex mutex;
    std::condition_variable condition;
    std::deque<std::pair<uint32_t, OH_AVBuffer*>> inputs;
    bool outputReady = false;
    uint32_t outputIndex = 0;
    int32_t error = 0;
    bool formatSeen = false;
    int32_t width = 0;
    int32_t height = 0;
    int32_t stride = 0;
    int32_t sliceHeight = 0;
    int32_t pixelFormat = -1;
    int32_t rotation = -1;
    int32_t transformType = -1;
    int32_t cropTop = -1;
    int32_t cropBottom = -1;
    int32_t cropLeft = -1;
    int32_t cropRight = -1;
    std::atomic<bool> frameAvailable { false };
};

void ReadFormat(DecodeState* state, OH_AVFormat* format) {
    if (state == nullptr || format == nullptr) { return; }
    std::lock_guard<std::mutex> lock(state->mutex);
    state->formatSeen = true;
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_WIDTH, &state->width);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_HEIGHT, &state->height);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_STRIDE, &state->stride);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_SLICE_HEIGHT, &state->sliceHeight);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, &state->pixelFormat);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_ROTATION, &state->rotation);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_TRANSFORM_TYPE, &state->transformType);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_CROP_TOP, &state->cropTop);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_CROP_BOTTOM, &state->cropBottom);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_CROP_LEFT, &state->cropLeft);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_CROP_RIGHT, &state->cropRight);
}

void OnError(OH_AVCodec*, int32_t errorCode, void* userData) {
    auto* state = static_cast<DecodeState*>(userData);
    if (state == nullptr) { return; }
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->error = errorCode != 0 ? errorCode : -1;
    }
    state->condition.notify_all();
}

void OnStreamChanged(OH_AVCodec*, OH_AVFormat* format, void* userData) {
    ReadFormat(static_cast<DecodeState*>(userData), format);
}

void OnNeedInput(OH_AVCodec*, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    auto* state = static_cast<DecodeState*>(userData);
    if (state == nullptr) { return; }
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->inputs.emplace_back(index, buffer);
    }
    state->condition.notify_all();
}

void OnNewOutput(OH_AVCodec*, uint32_t index, OH_AVBuffer*, void* userData) {
    auto* state = static_cast<DecodeState*>(userData);
    if (state == nullptr) { return; }
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (!state->outputReady) {
            state->outputReady = true;
            state->outputIndex = index;
        }
    }
    state->condition.notify_all();
}

void OnFrameAvailable(void* userData) {
    auto* state = static_cast<DecodeState*>(userData);
    if (state == nullptr) { return; }
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->frameAvailable.store(true, std::memory_order_release);
    }
    state->condition.notify_all();
}

const char* kVertexShader = R"(#version 300 es
layout(location = 0) in vec2 aPosition;
layout(location = 1) in vec2 aTexCoord;
uniform mat4 uTexTransform;
out vec2 vTexCoord;
void main() {
    gl_Position = vec4(aPosition, 0.0, 1.0);
    vTexCoord = (uTexTransform * vec4(aTexCoord, 0.0, 1.0)).xy;
}
)";

const char* kFragmentShader = R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;
in vec2 vTexCoord;
uniform samplerExternalOES uTexture;
out vec4 fragColor;
void main() {
    fragColor = texture(uTexture, vTexCoord);
}
)";

/** The reference picture's sampler: an ordinary GL_TEXTURE_2D, as RDP and software decoding present. */
const char* kReferenceFragmentShader = R"(#version 300 es
precision mediump float;
in vec2 vTexCoord;
uniform sampler2D uTexture;
out vec4 fragColor;
void main() {
    fragColor = texture(uTexture, vTexCoord);
}
)";

GLuint CompileProgram(const char* fragmentSource = kFragmentShader) {
    const auto compile = [](GLenum type, const char* source) -> GLuint {
        const GLuint shader = glCreateShader(type);
        if (shader == 0) { return 0; }
        glShaderSource(shader, 1, &source, nullptr);
        glCompileShader(shader);
        GLint ok = 0;
        glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
        if (!ok) { glDeleteShader(shader); return 0; }
        return shader;
    };
    const GLuint vertex = compile(GL_VERTEX_SHADER, kVertexShader);
    const GLuint fragment = compile(GL_FRAGMENT_SHADER, fragmentSource);
    if (vertex == 0 || fragment == 0) {
        if (vertex != 0) { glDeleteShader(vertex); }
        if (fragment != 0) { glDeleteShader(fragment); }
        return 0;
    }
    const GLuint program = glCreateProgram();
    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    glLinkProgram(program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    GLint linked = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) { glDeleteProgram(program); return 0; }
    return program;
}

/**
 * Draw the OES texture as the session renderer does (screen top-left samples
 * texture coordinate (0,0) before the transform) and read the four quadrant
 * centres as TL, TR, BL, BR. glReadPixels rows start at the bottom.
 */
bool RenderAndReadCorners(GLuint program, GLuint texture, const NativeImageTransform& transform,
                          std::array<uint32_t, 4>& corners, GLenum textureTarget = GL_TEXTURE_EXTERNAL_OES) {
    static const GLfloat kVertices[] = {
        -1.0f,  1.0f, 0.0f, 0.0f,  // top-left
        -1.0f, -1.0f, 0.0f, 1.0f,  // bottom-left
         1.0f,  1.0f, 1.0f, 0.0f,  // top-right
         1.0f, -1.0f, 1.0f, 1.0f,  // bottom-right
    };
    glViewport(0, 0, kTargetSize, kTargetSize);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(program);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(textureTarget, texture);
    glUniform1i(glGetUniformLocation(program, "uTexture"), 0);
    glUniformMatrix4fv(glGetUniformLocation(program, "uTexTransform"), 1, GL_FALSE, transform.data());
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glEnableVertexAttribArray(0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), kVertices);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), kVertices + 2);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);
    glFinish();
    std::array<uint8_t, kTargetSize * kTargetSize * 4> pixels {};
    glReadPixels(0, 0, kTargetSize, kTargetSize, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
    if (glGetError() != GL_NO_ERROR) { return false; }
    const auto at = [&pixels](int x, int rowFromBottom) {
        const size_t offset = static_cast<size_t>((rowFromBottom * kTargetSize + x) * 4);
        return PackRgba(pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3]);
    };
    const int quarter = kTargetSize / 4;
    const int threeQuarters = kTargetSize - quarter;
    corners = { at(quarter, threeQuarters), at(threeQuarters, threeQuarters),
                at(quarter, quarter), at(threeQuarters, quarter) };
    return true;
}

/**
 * The four-colour picture as an ordinary GL_TEXTURE_2D (first memory row = picture top, as RDP and software frames
 * are uploaded and shown upright everywhere), drawn and read back in the current framebuffer exactly like the OES
 * texture. It tells how this framebuffer's readback is turned, so the OES measurements can be made relative to it.
 */
NativeImageTransformClass MeasureReference(std::array<uint32_t, 4>& corners) {
    static const uint8_t kPixels[16] = {
        255, 0, 0, 255,    0, 255, 0, 255,      // top row: red, green
        0, 0, 255, 255,    255, 255, 255, 255,  // bottom row: blue, white
    };
    const GLuint program = CompileProgram(kReferenceFragmentShader);
    GLuint reference = 0;
    glGenTextures(1, &reference);
    if (program == 0 || reference == 0) {
        if (program != 0) { glDeleteProgram(program); }
        if (reference != 0) { glDeleteTextures(1, &reference); }
        return NativeImageTransformClass::ReadFailed;
    }
    glBindTexture(GL_TEXTURE_2D, reference);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, kPixels);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    const NativeImageTransformClass shown = RenderAndReadCorners(program, reference, IdentityNativeImageTransform(),
        corners, GL_TEXTURE_2D) ? ClassifyQuadrantCorners(corners) : NativeImageTransformClass::ReadFailed;
    glBindTexture(GL_TEXTURE_2D, 0);
    glDeleteTextures(1, &reference);
    glDeleteProgram(program);
    return shown;
}

struct EglScope {
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    bool leased = false;
    ~EglScope() {
        if (display != EGL_NO_DISPLAY) {
            eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            if (surface != EGL_NO_SURFACE) { eglDestroySurface(display, surface); }
            if (context != EGL_NO_CONTEXT) { eglDestroyContext(display, context); }
            eglReleaseThread();
        }
        if (leased) { ReleaseSharedEglDisplayLease(display); }
    }
};

OrientationSelfTestResult RunOnCurrentThread(OrientationSelfTestCodec codec, NativeImagePresentationMode mode) {
    OrientationSelfTestResult result;
    result.codec = static_cast<int32_t>(codec);
    result.mode = mode;
    const auto started = std::chrono::steady_clock::now();
    const auto finish = [&result, started](OrientationSelfTestStage stage, int32_t code) {
        result.stage = stage;
        result.platformCode = code;
        result.elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started).count();
        result.completedAtMs = NowMs();
        return result;
    };

    EglScope egl;
    if (!AcquireSharedEglDisplayLease(egl.display)) { return finish(OrientationSelfTestStage::Egl, -1); }
    egl.leased = true;
    const EGLint configAttribs[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE
    };
    EGLConfig config = nullptr;
    EGLint configCount = 0;
    if (!eglChooseConfig(egl.display, configAttribs, &config, 1, &configCount) || configCount < 1) {
        return finish(OrientationSelfTestStage::Egl, static_cast<int32_t>(eglGetError()));
    }
    const EGLint contextAttribs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    egl.context = eglCreateContext(egl.display, config, EGL_NO_CONTEXT, contextAttribs);
    const EGLint surfaceAttribs[] = { EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE };
    egl.surface = egl.context == EGL_NO_CONTEXT ? EGL_NO_SURFACE :
        eglCreatePbufferSurface(egl.display, config, surfaceAttribs);
    if (egl.surface == EGL_NO_SURFACE || !eglMakeCurrent(egl.display, egl.surface, egl.surface, egl.context)) {
        return finish(OrientationSelfTestStage::Egl, static_cast<int32_t>(eglGetError()));
    }
    result.glRenderer = SafeText(reinterpret_cast<const char*>(glGetString(GL_RENDERER)));
    result.glVendor = SafeText(reinterpret_cast<const char*>(glGetString(GL_VENDOR)));
    result.glVersion = SafeText(reinterpret_cast<const char*>(glGetString(GL_VERSION)));

    GLuint texture = 0;
    GLuint target = 0;
    GLuint framebuffer = 0;
    GLuint program = 0;
    const auto releaseGl = [&]() {
        if (program != 0) { glDeleteProgram(program); }
        if (framebuffer != 0) { glDeleteFramebuffers(1, &framebuffer); }
        if (target != 0) { glDeleteTextures(1, &target); }
        if (texture != 0) { glDeleteTextures(1, &texture); }
    };
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, texture);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glGenTextures(1, &target);
    glBindTexture(GL_TEXTURE_2D, target);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, kTargetSize, kTargetSize, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target, 0);
    program = CompileProgram();
    if (texture == 0 || program == 0 || glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        releaseGl();
        return finish(OrientationSelfTestStage::Texture, static_cast<int32_t>(glGetError()));
    }
    result.referenceOrientation = MeasureReference(result.referenceCorners);

    OH_NativeImage* image = OH_NativeImage_Create(texture, GL_TEXTURE_EXTERNAL_OES);
    if (image == nullptr) {
        releaseGl();
        return finish(OrientationSelfTestStage::NativeImage, -1);
    }
    // Callbacks reach the state until the decoder is destroyed and the listener removed.
    auto state = std::make_shared<DecodeState>();
    OH_OnFrameAvailableListener listener;
    listener.context = state.get();
    listener.onFrameAvailable = OnFrameAvailable;
    OH_NativeImage_SetOnFrameAvailableListener(image, listener);
    OHNativeWindow* window = OH_NativeImage_AcquireNativeWindow(image);
    const auto releaseImage = [&]() {
        OH_NativeImage_UnsetOnFrameAvailableListener(image);
        OH_NativeImage_Destroy(&image);
        releaseGl();
    };
    if (window == nullptr) {
        releaseImage();
        return finish(OrientationSelfTestStage::NativeWindow, -1);
    }

    const char* mime = codec == OrientationSelfTestCodec::H265 ?
        OH_AVCODEC_MIMETYPE_VIDEO_HEVC : OH_AVCODEC_MIMETYPE_VIDEO_AVC;
    OH_AVCapability* capability = OH_AVCodec_GetCapability(mime, false);
    if (capability != nullptr) {
        result.hardware = OH_AVCapability_IsHardware(capability) ? 1 : 0;
        result.decoderName = SafeText(OH_AVCapability_GetName(capability));
    }
    OH_AVCodec* decoder = OH_VideoDecoder_CreateByMime(mime);
    const auto releaseDecoder = [&]() {
        if (decoder != nullptr) {
            OH_VideoDecoder_Stop(decoder);
            OH_VideoDecoder_Destroy(decoder);
            decoder = nullptr;
        }
    };
    const auto fail = [&](OrientationSelfTestStage stage, int32_t code) {
        releaseDecoder();
        releaseImage();
        return finish(stage, code);
    };
    if (decoder == nullptr) { return fail(OrientationSelfTestStage::CreateDecoder, -1); }
    OH_AVCodecCallback callbacks;
    callbacks.onError = OnError;
    callbacks.onStreamChanged = OnStreamChanged;
    callbacks.onNeedInputBuffer = OnNeedInput;
    callbacks.onNewOutputBuffer = OnNewOutput;
    OH_AVErrCode ret = OH_VideoDecoder_RegisterCallback(decoder, callbacks, state.get());
    if (ret != AV_ERR_OK) { return fail(OrientationSelfTestStage::CreateDecoder, ret); }
    OH_AVFormat* format = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, OrientationTestStreams::kWidth);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, OrientationTestStreams::kHeight);
    if (capability != nullptr && OH_AVCapability_IsFeatureSupported(capability, VIDEO_LOW_LATENCY)) {
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
    }
    ret = OH_VideoDecoder_Configure(decoder, format);
    OH_AVFormat_Destroy(format);
    if (ret != AV_ERR_OK) { return fail(OrientationSelfTestStage::Configure, ret); }
    ret = OH_VideoDecoder_SetSurface(decoder, window);
    if (ret != AV_ERR_OK) { return fail(OrientationSelfTestStage::Surface, ret); }
    ret = OH_VideoDecoder_Prepare(decoder);
    if (ret == AV_ERR_OK) { ret = OH_VideoDecoder_Start(decoder); }
    if (ret != AV_ERR_OK) { return fail(OrientationSelfTestStage::Start, ret); }

    const uint8_t* stream = codec == OrientationSelfTestCodec::H265 ?
        OrientationTestStreams::kH265 : OrientationTestStreams::kH264;
    const size_t streamSize = codec == OrientationSelfTestCodec::H265 ?
        sizeof(OrientationTestStreams::kH265) : sizeof(OrientationTestStreams::kH264);
    // The picture, then end of stream so a decoder that holds frames releases it.
    for (int packet = 0; packet < 2; ++packet) {
        std::pair<uint32_t, OH_AVBuffer*> input { 0, nullptr };
        {
            std::unique_lock<std::mutex> lock(state->mutex);
            state->condition.wait_for(lock, kInputWait, [&state]() {
                return !state->inputs.empty() || state->error != 0;
            });
            if (state->error != 0) { lock.unlock(); return fail(OrientationSelfTestStage::Input, state->error); }
            if (state->inputs.empty()) { lock.unlock(); return fail(OrientationSelfTestStage::Input, -2); }
            input = state->inputs.front();
            state->inputs.pop_front();
        }
        OH_AVCodecBufferAttr attr {};
        attr.pts = 0;
        attr.offset = 0;
        if (packet == 0) {
            uint8_t* address = OH_AVBuffer_GetAddr(input.second);
            const int32_t capacity = OH_AVBuffer_GetCapacity(input.second);
            if (address == nullptr || capacity < static_cast<int32_t>(streamSize)) {
                return fail(OrientationSelfTestStage::Input, -3);
            }
            std::memcpy(address, stream, streamSize);
            attr.size = static_cast<int32_t>(streamSize);
            attr.flags = AVCODEC_BUFFER_FLAGS_NONE;
        } else {
            attr.size = 0;
            attr.flags = AVCODEC_BUFFER_FLAGS_EOS;
        }
        OH_AVBuffer_SetBufferAttr(input.second, &attr);
        ret = OH_VideoDecoder_PushInputBuffer(decoder, input.first);
        if (ret != AV_ERR_OK) { return fail(OrientationSelfTestStage::Input, ret); }
    }

    uint32_t outputIndex = 0;
    {
        std::unique_lock<std::mutex> lock(state->mutex);
        state->condition.wait_for(lock, kOutputWait, [&state]() {
            return state->outputReady || state->error != 0;
        });
        if (!state->outputReady) {
            const int32_t code = state->error != 0 ? state->error : -2;
            lock.unlock();
            return fail(OrientationSelfTestStage::Output, code);
        }
        outputIndex = state->outputIndex;
    }
    bool formatSeen = false;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        formatSeen = state->formatSeen;
    }
    if (!formatSeen) {
        OH_AVFormat* description = OH_VideoDecoder_GetOutputDescription(decoder);
        ReadFormat(state.get(), description);
        if (description != nullptr) { OH_AVFormat_Destroy(description); }
    }
    ret = OH_VideoDecoder_RenderOutputBuffer(decoder, outputIndex);
    if (ret != AV_ERR_OK) { return fail(OrientationSelfTestStage::Output, ret); }
    {
        std::unique_lock<std::mutex> lock(state->mutex);
        state->condition.wait_for(lock, kFrameWait, [&state]() {
            return state->frameAvailable.load(std::memory_order_acquire);
        });
    }
    if (!state->frameAvailable.load(std::memory_order_acquire)) {
        return fail(OrientationSelfTestStage::FrameAvailable, -2);
    }
    int32_t updateRet = -1;
    for (int attempt = 0; attempt < 8 && updateRet != 0; ++attempt) {
        updateRet = OH_NativeImage_UpdateSurfaceImage(image);
        if (updateRet != 0) { std::this_thread::sleep_for(std::chrono::milliseconds(20)); }
    }
    if (updateRet != 0) { return fail(OrientationSelfTestStage::UpdateImage, updateRet); }

    {
        std::lock_guard<std::mutex> lock(state->mutex);
        result.outputWidth = state->width;
        result.outputHeight = state->height;
        result.outputStride = state->stride;
        result.outputSliceHeight = state->sliceHeight;
        result.outputPixelFormat = state->pixelFormat;
        result.outputRotation = state->rotation;
        result.outputTransformType = state->transformType;
        result.outputCropTop = state->cropTop;
        result.outputCropBottom = state->cropBottom;
        result.outputCropLeft = state->cropLeft;
        result.outputCropRight = state->cropRight;
    }
    int32_t bufferTransform = -1;
    if (OH_NativeWindow_NativeWindowHandleOpt(window, GET_TRANSFORM, &bufferTransform) == 0) {
        result.bufferTransform = bufferTransform;
    }
    float v2[16] = {};
    result.v2ReadResult = OH_NativeImage_GetTransformMatrixV2(image, v2);
    result.v2Class = ClassifyNativeImageProducerTransform(result.v2ReadResult, v2);
    for (size_t index = 0; index < 16; ++index) { result.v2Matrix[index] = v2[index]; }
    float v1[16] = {};
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    result.v1ReadResult = OH_NativeImage_GetTransformMatrix(image, v1);
#pragma clang diagnostic pop
    result.v1Class = ClassifyNativeImageProducerTransform(result.v1ReadResult, v1);
    for (size_t index = 0; index < 16; ++index) { result.v1Matrix[index] = v1[index]; }

    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    if (!RenderAndReadCorners(program, texture, IdentityNativeImageTransform(), result.identityCorners)) {
        return fail(OrientationSelfTestStage::Render, static_cast<int32_t>(glGetError()));
    }
    const NativeImageTransform applied = ResolveNativeImagePresentationTransform(
        mode, result.v2ReadResult, v2, IdentityNativeImageTransform());
    if (!RenderAndReadCorners(program, texture, applied, result.appliedCorners)) {
        return fail(OrientationSelfTestStage::ReadPixels, static_cast<int32_t>(glGetError()));
    }
    // Relative to the ordinary-texture reference, so a framebuffer whose readback is itself turned cancels out.
    result.identityOrientation = OrientationRelativeToReference(
        ClassifyQuadrantCorners(result.identityCorners), result.referenceOrientation);
    result.appliedOrientation = OrientationRelativeToReference(
        ClassifyQuadrantCorners(result.appliedCorners), result.referenceOrientation);
    releaseDecoder();
    releaseImage();
    return finish(OrientationSelfTestStage::Done, 0);
}

/**
 * Results, run bookkeeping and the desktop corrections. Allocated once and
 * never destroyed: a detached test may still finish while the process exits.
 */
struct SelfTestRegistry {
    std::mutex resultsMutex;
    std::mutex runMutex;
    std::map<std::pair<int32_t, int32_t>, OrientationSelfTestResult> results;
    std::map<std::pair<int32_t, int32_t>, bool> running;
    std::map<std::pair<int32_t, int32_t>, int> attempts;
    std::map<std::pair<int32_t, int32_t>, std::chrono::steady_clock::time_point> lastAttempt;
    // Packed DesktopOrientationCorrection per codec: shown | textureSpace << 8 | textureShown << 16.
    std::atomic<int32_t> desktopCorrection[2] = {
        { static_cast<int32_t>(NativeImageTransformClass::NotSampled) },
        { static_cast<int32_t>(NativeImageTransformClass::NotSampled) },
    };
};

SelfTestRegistry& Registry() {
    static SelfTestRegistry* registry = new SelfTestRegistry();
    return *registry;
}

constexpr int kMaxSelfTestAttempts = 3;
constexpr auto kSelfTestRetryDelay = std::chrono::seconds(10);

void LogResult(const OrientationSelfTestResult& result) {
    OH_LOG_INFO(LOG_APP,
        "[VideoOrientation] self-test codec=%{public}s mode=%{public}s stage=%{public}s code=%{public}d "
        "hardware=%{public}d decoder=%{public}s gl=%{public}s/%{public}s output=%{public}dx%{public}d "
        "stride=%{public}d slice=%{public}d pixfmt=%{public}d rotation=%{public}d transformType=%{public}d "
        "crop=%{public}d,%{public}d,%{public}d,%{public}d bufferTransform=%{public}d "
        "v2=%{public}s(ret=%{public}d) v1=%{public}s(ret=%{public}d) reference=%{public}s identity=%{public}s "
        "applied=%{public}s corners=%{public}08x,%{public}08x,%{public}08x,%{public}08x elapsedMs=%{public}lld",
        result.codec == 1 ? "h265" : "h264", NativeImagePresentationModeName(result.mode),
        OrientationSelfTestStageName(result.stage), result.platformCode, result.hardware,
        result.decoderName.c_str(), result.glVendor.c_str(), result.glRenderer.c_str(),
        result.outputWidth, result.outputHeight, result.outputStride, result.outputSliceHeight,
        result.outputPixelFormat, result.outputRotation, result.outputTransformType,
        result.outputCropTop, result.outputCropBottom, result.outputCropLeft, result.outputCropRight,
        result.bufferTransform, NativeImageTransformClassName(result.v2Class), result.v2ReadResult,
        NativeImageTransformClassName(result.v1Class), result.v1ReadResult,
        NativeImageTransformClassName(result.referenceOrientation),
        NativeImageTransformClassName(result.identityOrientation),
        NativeImageTransformClassName(result.appliedOrientation),
        result.appliedCorners[0], result.appliedCorners[1], result.appliedCorners[2], result.appliedCorners[3],
        static_cast<long long>(result.elapsedMs));
    OH_LOG_INFO(LOG_APP,
        "[VideoOrientation] self-test codec=%{public}s v2=[%{public}f,%{public}f,%{public}f,%{public}f | "
        "%{public}f,%{public}f,%{public}f,%{public}f | %{public}f,%{public}f,%{public}f,%{public}f] "
        "v1=[%{public}f,%{public}f,%{public}f,%{public}f | %{public}f,%{public}f,%{public}f,%{public}f | "
        "%{public}f,%{public}f,%{public}f,%{public}f] identityCorners=%{public}08x,%{public}08x,%{public}08x,%{public}08x "
        "referenceCorners=%{public}08x,%{public}08x,%{public}08x,%{public}08x",
        result.codec == 1 ? "h265" : "h264",
        result.v2Matrix[0], result.v2Matrix[1], result.v2Matrix[4], result.v2Matrix[5],
        result.v2Matrix[12], result.v2Matrix[13], result.v2Matrix[10], result.v2Matrix[15],
        result.v2Matrix[2], result.v2Matrix[6], result.v2Matrix[8], result.v2Matrix[9],
        result.v1Matrix[0], result.v1Matrix[1], result.v1Matrix[4], result.v1Matrix[5],
        result.v1Matrix[12], result.v1Matrix[13], result.v1Matrix[10], result.v1Matrix[15],
        result.v1Matrix[2], result.v1Matrix[6], result.v1Matrix[8], result.v1Matrix[9],
        result.identityCorners[0], result.identityCorners[1], result.identityCorners[2], result.identityCorners[3],
        result.referenceCorners[0], result.referenceCorners[1], result.referenceCorners[2], result.referenceCorners[3]);
}

void Store(const OrientationSelfTestResult& result) {
    SelfTestRegistry& registry = Registry();
    {
        std::lock_guard<std::mutex> lock(registry.resultsMutex);
        registry.results[{ result.codec, static_cast<int32_t>(result.mode) }] = result;
    }
    if (result.mode == NativeImagePresentationMode::TopLeftProducerTransform &&
        result.stage == OrientationSelfTestStage::Done && result.codec >= 0 && result.codec <= 1) {
        // The GPU texture itself is turned when sampling it with no transform already showed it turned.
        const bool textureSpace = OrientationIsCorrectable(result.identityOrientation);
        registry.desktopCorrection[result.codec].store(
            static_cast<int32_t>(result.appliedOrientation) | (textureSpace ? 0x100 : 0) |
                (static_cast<int32_t>(result.identityOrientation) << 16),
            std::memory_order_release);
    }
}

} // namespace

const char* OrientationSelfTestStageName(OrientationSelfTestStage stage) {
    switch (stage) {
        case OrientationSelfTestStage::Egl: return "egl";
        case OrientationSelfTestStage::Texture: return "texture";
        case OrientationSelfTestStage::NativeImage: return "native_image";
        case OrientationSelfTestStage::NativeWindow: return "native_window";
        case OrientationSelfTestStage::CreateDecoder: return "create_decoder";
        case OrientationSelfTestStage::Configure: return "configure";
        case OrientationSelfTestStage::Surface: return "surface";
        case OrientationSelfTestStage::Start: return "start";
        case OrientationSelfTestStage::Input: return "input";
        case OrientationSelfTestStage::Output: return "output";
        case OrientationSelfTestStage::FrameAvailable: return "frame_available";
        case OrientationSelfTestStage::UpdateImage: return "update_image";
        case OrientationSelfTestStage::Render: return "render";
        case OrientationSelfTestStage::ReadPixels: return "read_pixels";
        case OrientationSelfTestStage::Done: return "done";
        case OrientationSelfTestStage::NotRun:
        default: return "not_run";
    }
}

OrientationSelfTestResult RunVideoOrientationSelfTest(OrientationSelfTestCodec codec,
                                                      NativeImagePresentationMode mode) {
    std::lock_guard<std::mutex> runLock(Registry().runMutex);
    // The decode runs on a fresh thread so no caller's EGL context is disturbed.
    OrientationSelfTestResult result;
    result.codec = static_cast<int32_t>(codec);
    result.mode = mode;
    try {
        std::thread worker([&result, codec, mode]() { result = RunOnCurrentThread(codec, mode); });
        worker.join();
    } catch (...) {
        result.stage = OrientationSelfTestStage::NotRun;
        result.platformCode = -1;
    }
    LogResult(result);
    Store(result);
    return result;
}

bool LatestVideoOrientationSelfTest(OrientationSelfTestCodec codec, NativeImagePresentationMode mode,
                                    OrientationSelfTestResult& result) {
    SelfTestRegistry& registry = Registry();
    std::lock_guard<std::mutex> lock(registry.resultsMutex);
    const auto found = registry.results.find({ static_cast<int32_t>(codec), static_cast<int32_t>(mode) });
    if (found == registry.results.end()) { return false; }
    result = found->second;
    return true;
}

std::vector<OrientationSelfTestResult> AllVideoOrientationSelfTests() {
    SelfTestRegistry& registry = Registry();
    std::lock_guard<std::mutex> lock(registry.resultsMutex);
    std::vector<OrientationSelfTestResult> results;
    for (const auto& entry : registry.results) { results.push_back(entry.second); }
    return results;
}

DesktopOrientationCorrection DesktopOrientationCorrectionFor(int32_t codec) {
    DesktopOrientationCorrection correction;
    if (codec < 0 || codec > 1) { return correction; }
    const int32_t packed = Registry().desktopCorrection[codec].load(std::memory_order_acquire);
    correction.shown = static_cast<NativeImageTransformClass>(packed & 0xff);
    correction.textureSpace = (packed & 0x100) != 0;
    correction.textureShown = static_cast<NativeImageTransformClass>((packed >> 16) & 0xff);
    return correction;
}

void EnsureVideoOrientationSelfTest(OrientationSelfTestCodec codec, NativeImagePresentationMode mode) {
    SelfTestRegistry& registry = Registry();
    const std::pair<int32_t, int32_t> key { static_cast<int32_t>(codec), static_cast<int32_t>(mode) };
    {
        std::lock_guard<std::mutex> lock(registry.resultsMutex);
        const auto found = registry.results.find(key);
        if (registry.running[key] ||
            (found != registry.results.end() && found->second.stage == OrientationSelfTestStage::Done)) {
            return;
        }
        // A test that stopped short (decoder busy, no output in time) is tried again, a few times.
        const auto now = std::chrono::steady_clock::now();
        if (registry.attempts[key] >= kMaxSelfTestAttempts ||
            (registry.attempts[key] > 0 && now - registry.lastAttempt[key] < kSelfTestRetryDelay)) {
            return;
        }
        registry.attempts[key] += 1;
        registry.lastAttempt[key] = now;
        registry.running[key] = true;
    }
    try {
        std::thread([codec, mode, key]() {
            RunVideoOrientationSelfTest(codec, mode);
            SelfTestRegistry& owner = Registry();
            std::lock_guard<std::mutex> lock(owner.resultsMutex);
            owner.running[key] = false;
        }).detach();
    } catch (...) {
        std::lock_guard<std::mutex> lock(registry.resultsMutex);
        registry.running[key] = false;
    }
}

} // namespace Render
