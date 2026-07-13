/**
 * audio_capturer.cpp — OHAudio 音频采集器 Mock 实现 + NAPI 包装
 */

#include "audio_capturer.h"
#include <napi/native_api.h>
#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0011
#define LOG_TAG "AUDIO_CAP"

AudioCapturer::AudioCapturer() : capturer_(nullptr), builder_(nullptr), sampleRate_(16000), channels_(1), state_(AudioCapturerState::IDLE) {}
AudioCapturer::~AudioCapturer() { Destroy(); }

int AudioCapturer::Init(int sampleRate, int channels) {
    OH_LOG_INFO(LOG_APP, "[AudioCap] 初始化采集器: %{public}dHz, %{public}d声道", sampleRate, channels);
    sampleRate_ = sampleRate; channels_ = channels;
    // TODO: OH_AudioStreamBuilder_Create(&builder_, AUDIOSTREAM_TYPE_CAPTURER);
    // TODO: OH_AudioStreamBuilder_GenerateCapturer(builder_, &capturer_);
    state_ = AudioCapturerState::INITIALIZED;
    return 0;
}

int AudioCapturer::Start() {
    state_ = AudioCapturerState::RUNNING;
    // TODO: OH_AudioCapturer_Start(capturer_);
    OH_LOG_INFO(LOG_APP, "[AudioCap] 采集已开始");
    return 0;
}

int AudioCapturer::Stop() {
    state_ = AudioCapturerState::STOPPED;
    // TODO: OH_AudioCapturer_Stop(capturer_);
    return 0;
}

void AudioCapturer::Destroy() {
    Stop();
    state_ = AudioCapturerState::RELEASED;
}

void AudioCapturer::SetCaptureCallback(AudioCaptureCallback callback) {
    captureCallback_ = std::move(callback);
}

// ============================================================
// NAPI 包装
// ============================================================

namespace {
struct AudioCapturerContext { std::shared_ptr<AudioCapturer> capturer; };

napi_value NapiInitAudioCapturer(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sr = 16000, ch = 1;
    if (argc >= 1) napi_get_value_int32(env, args[0], &sr);
    if (argc >= 2) napi_get_value_int32(env, args[1], &ch);
    auto cap = std::shared_ptr<AudioCapturer>(new AudioCapturer()); cap->Init(sr, ch);
    auto* ctx = new AudioCapturerContext{cap};
    napi_value h; napi_create_int64(env, reinterpret_cast<int64_t>(ctx), &h);
    return h;
}

napi_value NapiStartCapture(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t hv; napi_get_value_int64(env, args[0], &hv);
    auto* ctx = reinterpret_cast<AudioCapturerContext*>(hv);
    int r = ctx && ctx->capturer ? ctx->capturer->Start() : -1;
    napi_value ret; napi_create_int32(env, r, &ret); return ret;
}

napi_value NapiStopCapture(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t hv; napi_get_value_int64(env, args[0], &hv);
    auto* ctx = reinterpret_cast<AudioCapturerContext*>(hv);
    int r = ctx && ctx->capturer ? ctx->capturer->Stop() : -1;
    napi_value ret; napi_create_int32(env, r, &ret); return ret;
}

napi_value NapiDestroyAudioCapturer(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t hv; napi_get_value_int64(env, args[0], &hv);
    auto* ctx = reinterpret_cast<AudioCapturerContext*>(hv);
    if (ctx) { if (ctx->capturer) ctx->capturer->Destroy(); delete ctx; }
    napi_value u; napi_get_undefined(env, &u); return u;
}
}

napi_value AudioCapturerNapi::Init(napi_env env, napi_value exports) {
    napi_value fn;
    napi_create_function(env, "initAudioCapturer", NAPI_AUTO_LENGTH, NapiInitAudioCapturer, nullptr, &fn);
    napi_set_named_property(env, exports, "initAudioCapturer", fn);
    napi_create_function(env, "startCapture", NAPI_AUTO_LENGTH, NapiStartCapture, nullptr, &fn);
    napi_set_named_property(env, exports, "startCapture", fn);
    napi_create_function(env, "stopCapture", NAPI_AUTO_LENGTH, NapiStopCapture, nullptr, &fn);
    napi_set_named_property(env, exports, "stopCapture", fn);
    napi_create_function(env, "destroyAudioCapturer", NAPI_AUTO_LENGTH, NapiDestroyAudioCapturer, nullptr, &fn);
    napi_set_named_property(env, exports, "destroyAudioCapturer", fn);
    return exports;
}
