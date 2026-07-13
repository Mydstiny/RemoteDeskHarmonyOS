/**
 * audio_capturer.h — 音频采集器 (麦克风)
 *
 * 基于 OHAudio (OH_AudioCapturer) 的 PCM 音频采集。
 * 用于将本地麦克风音频发送到远程主机。
 */

#include <napi/native_api.h>
#ifndef AUDIO_CAPTURER_H
#define AUDIO_CAPTURER_H

#include <cstdint>
#include <functional>
#include <string>

struct OH_AudioCapturer;
struct OH_AudioStreamBuilder;

/** 采集音频数据回调 */
using AudioCaptureCallback = std::function<void(const uint8_t* data, size_t size)>;

enum class AudioCapturerState { IDLE, INITIALIZED, RUNNING, STOPPED, RELEASED };

class AudioCapturer {
public:
    AudioCapturer();
    ~AudioCapturer();

    /** 初始化采集器 (默认 16kHz 单声道, 适合语音) */
    int Init(int sampleRate = 16000, int channels = 1);
    int Start();
    int Stop();
    void Destroy();

    void SetCaptureCallback(AudioCaptureCallback callback);
    AudioCapturerState GetState() const { return state_; }

private:
    OH_AudioCapturer*     capturer_;
    OH_AudioStreamBuilder* builder_;
    int sampleRate_, channels_;
    AudioCapturerState state_;
    AudioCaptureCallback captureCallback_;
};

namespace AudioCapturerNapi {
    napi_value Init(napi_env env, napi_value exports);
}

#endif // AUDIO_CAPTURER_H
