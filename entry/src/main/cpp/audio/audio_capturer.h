/**
 * audio_capturer.h — 音频采集器 (麦克风)
 *
 * 基于 OHAudio (OH_AudioCapturer) 的 PCM 音频采集。
 * 用于将本地麦克风音频发送到远程主机。
 */

#include <napi/native_api.h>
#ifndef AUDIO_CAPTURER_H
#define AUDIO_CAPTURER_H

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <ohaudio/native_audiocapturer.h>
#include <ohaudio/native_audiostreambuilder.h>
#include "render/callback_admission_context.h"
#include "render/decoder_callback_gate.h"
#include "render/platform_lifecycle.h"
#include "render/video_perf_counters.h"

/** 采集音频数据回调 */
using AudioCaptureCallback = std::function<void(const uint8_t* data, size_t size)>;

enum class AudioCapturerState { IDLE, INITIALIZED, RUNNING, STOPPED, RELEASED };

class AudioCapturer : public std::enable_shared_from_this<AudioCapturer> {
public:
    explicit AudioCapturer(Render::DecoderSessionIdentity owner = {});
    ~AudioCapturer();

    /** 初始化采集器 (默认 16kHz 单声道, 适合语音) */
    int Init(int sampleRate = 16000, int channels = 1);
    int Start();
    int Stop();
    void Destroy();

    /** Bind the opaque registry token before the platform source starts. */
    bool BindCallbackHandle(int64_t handle);
    /** Stop callback admission before stream/object teardown. */
    void BeginCallbackTeardown();

    void SetCaptureCallback(AudioCaptureCallback callback);
    AudioCapturerState GetState() const;

#if defined(RDP_NATIVE_CALLBACK_TESTING)
    void* CallbackUserDataForTesting() const { return callbackContext_.get(); }
    std::shared_ptr<Render::CallbackAdmissionContext> CallbackContextForTesting() const {
        return callbackContext_;
    }
    static void InvokeReadCallbackForTesting(void* userData, void* audioData,
                                             int32_t audioDataSize) {
        OnReadData(nullptr, userData, audioData, audioDataSize);
    }
    bool HoldCallbackAdmissionForTesting();
    void ReleaseCallbackAdmissionForTesting();
    void MarkPlatformResourceLiveForTesting();
    int PlatformResourceDestroyCountForTesting() const;
#endif

private:
    void CompleteDeferredDestroyOnInitOwner();
    OH_AudioCapturer*     capturer_;
    OH_AudioStreamBuilder* builder_;
    int sampleRate_, channels_;
    const Render::DecoderSessionIdentity owner_;
    AudioCapturerState state_;
    DecoderCallbackGate<AudioCaptureCallback> captureCallbackGate_;
    std::shared_ptr<Render::CallbackAdmissionContext> callbackContext_;
    std::shared_ptr<std::atomic<int>> callbackResourceDestroyCount_ =
        std::make_shared<std::atomic<int>>(0);
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    std::unique_ptr<Render::CallbackAdmissionContext::Lease> callbackTestLease_;
    bool testPlatformResourceLive_ = false;
#endif
    Render::PlatformLifecycle platformLifecycle_;
    mutable std::mutex lifecycleMutex_;
    bool capturerStopped_ = false;
    bool destroying_ = false;
    // One-shot self hold for the bounded Destroy -> in-flight Init handoff.
    // It is cleared by every Init completion path and never forms a
    // process-lifetime cycle.
    std::shared_ptr<AudioCapturer> initLifetimeHold_;

    static void OnReadData(OH_AudioCapturer* capturer, void* userData,
                           void* audioData, int32_t audioDataSize);
    void ReleaseInitLifetimeHold();
};

namespace AudioCapturerNapi {
    napi_value Init(napi_env env, napi_value exports);
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    std::shared_ptr<AudioCapturer> RegisterCallbackTestCapturer(
        const Render::DecoderSessionIdentity& owner, int64_t& handle);
    void DestroyCallbackTestCapturer(int64_t handle,
                                     const Render::DecoderSessionIdentity& owner);
#endif
}

#endif // AUDIO_CAPTURER_H
