/**
 * audio_capturer.cpp — OHAudio 音频采集器真实实现 + NAPI 包装
 */

#include "audio_capturer.h"
#include "render/opaque_handle_registry.h"
#include <napi/native_api.h>
#include <hilog/log.h>
#include <ohaudio/native_audiocapturer.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <algorithm>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0011
#define LOG_TAG "AUDIO_CAP"

namespace {

static OpaqueHandleRegistry<AudioCapturer> g_audioCapturerRegistry;

static void ReleaseCapturerResources(OH_AudioCapturer* capturer,
                                     OH_AudioStreamBuilder* builder);

static void RetireAudioCapturerContext(
    std::shared_ptr<Render::CallbackAdmissionContext> context,
    OH_AudioCapturer* capturer,
    OH_AudioStreamBuilder* builder,
    bool testResourceLive,
    std::shared_ptr<std::atomic<int>> testDestroyCount) {
    auto cleanup = [capturer, builder, testResourceLive,
                    testDestroyCount = std::move(testDestroyCount)]() {
        ReleaseCapturerResources(capturer, builder);
        if (testResourceLive && testDestroyCount) {
            testDestroyCount->fetch_add(1, std::memory_order_release);
        }
    };
    if (!context) {
        cleanup();
        return;
    }
    const bool drained = context->closeAndWait();
    const bool cleanupCompleted = context->deferCleanupAfterDrain(std::move(cleanup));
    if (!drained && cleanupCompleted) {
        OH_LOG_WARN(LOG_APP,
                    "[AudioCap] callback admission timed out before deferred capturer cleanup");
    }
}

static void ReleaseCapturerResources(OH_AudioCapturer* capturer,
                                     OH_AudioStreamBuilder* builder) {
    if (capturer) {
        (void)OH_AudioCapturer_Stop(capturer);
        (void)OH_AudioCapturer_Flush(capturer);
        (void)OH_AudioCapturer_Release(capturer);
    }
    if (builder) {
        (void)OH_AudioStreamBuilder_Destroy(builder);
    }
}

} // namespace

AudioCapturer::AudioCapturer(Render::DecoderSessionIdentity owner)
    : capturer_(nullptr), builder_(nullptr), sampleRate_(16000), channels_(1),
      owner_(owner), state_(AudioCapturerState::IDLE),
      callbackContext_(std::make_shared<Render::CallbackAdmissionContext>(owner)) {}

AudioCapturer::~AudioCapturer() { Destroy(); }

int AudioCapturer::Init(int sampleRate, int channels) {
    const int safeRate = sampleRate > 0 ? sampleRate : 16000;
    const int safeChannels = channels > 0 ? channels : 1;
    OH_LOG_INFO(LOG_APP, "[AudioCap] init capturer: %{public}dHz, %{public}dch",
                safeRate, safeChannels);
    std::shared_ptr<AudioCapturer> initKeepAlive;
    try {
        initKeepAlive = shared_from_this();
    } catch (const std::bad_weak_ptr&) {
        // Stack-owned tests have no shared owner; they must not be destroyed
        // concurrently with Init. Production registry objects are shared-owned.
    }
    const auto initToken = platformLifecycle_.beginInit();
    if (!initToken.valid || !callbackContext_) {
        OH_LOG_WARN(LOG_APP, "[AudioCap] Init rejected by lifecycle state");
        return -1;
    }
    {
        std::lock_guard<std::mutex> lock(lifecycleMutex_);
        initLifetimeHold_ = initKeepAlive;
    }
    const auto releaseInitHold = [this]() { ReleaseInitLifetimeHold(); };
    {
        std::lock_guard<std::mutex> lock(lifecycleMutex_);
        sampleRate_ = safeRate;
        channels_ = safeChannels;
    }

    OH_AudioStreamBuilder* builder = nullptr;
    OH_AudioCapturer* capturer = nullptr;
    OH_AudioStream_Result ret = OH_AudioStreamBuilder_Create(
        &builder, AUDIOSTREAM_TYPE_CAPTURER);
    if (ret != AUDIOSTREAM_SUCCESS || !builder) {
        OH_LOG_ERROR(LOG_APP, "[AudioCap] builder create failed: %{public}d", ret);
        ReleaseCapturerResources(capturer, builder);
        const auto completion = platformLifecycle_.completeInit(initToken, false);
        if (completion == Render::PlatformLifecycle::InitCompletion::DestroyDeferredToInitOwner) {
            CompleteDeferredDestroyOnInitOwner();
        } else if (completion == Render::PlatformLifecycle::InitCompletion::Failed) {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            state_ = AudioCapturerState::IDLE;
        }
        releaseInitHold();
        return -2;
    }
    OH_AudioStreamBuilder_SetSamplingRate(builder, safeRate);
    OH_AudioStreamBuilder_SetChannelCount(builder, safeChannels);
    OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE);
    OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
    OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_FAST);
    OH_AudioStreamBuilder_SetCapturerInfo(builder, AUDIOSTREAM_SOURCE_TYPE_MIC);
    ret = OH_AudioStreamBuilder_SetCapturerReadDataCallback(
        builder, AudioCapturer::OnReadData, callbackContext_.get());
    if (ret != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "[AudioCap] read callback registration failed: %{public}d", ret);
        ReleaseCapturerResources(capturer, builder);
        const auto completion = platformLifecycle_.completeInit(initToken, false);
        if (completion == Render::PlatformLifecycle::InitCompletion::DestroyDeferredToInitOwner) {
            CompleteDeferredDestroyOnInitOwner();
        } else if (completion == Render::PlatformLifecycle::InitCompletion::Failed) {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            state_ = AudioCapturerState::IDLE;
        }
        releaseInitHold();
        return -3;
    }
    ret = OH_AudioStreamBuilder_GenerateCapturer(builder, &capturer);
    if (ret != AUDIOSTREAM_SUCCESS || !capturer) {
        OH_LOG_ERROR(LOG_APP, "[AudioCap] GenerateCapturer failed: %{public}d", ret);
        ReleaseCapturerResources(capturer, builder);
        const auto completion = platformLifecycle_.completeInit(initToken, false);
        if (completion == Render::PlatformLifecycle::InitCompletion::DestroyDeferredToInitOwner) {
            CompleteDeferredDestroyOnInitOwner();
        } else if (completion == Render::PlatformLifecycle::InitCompletion::Failed) {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            state_ = AudioCapturerState::IDLE;
        }
        releaseInitHold();
        return -4;
    }
    Render::PlatformLifecycle::InitCompletion completion;
    {
        std::lock_guard<std::mutex> lock(lifecycleMutex_);
        completion = platformLifecycle_.completeInit(initToken, true);
        if (completion == Render::PlatformLifecycle::InitCompletion::Published) {
            builder_ = builder;
            capturer_ = capturer;
            builder = nullptr;
            capturer = nullptr;
            capturerStopped_ = false;
            destroying_ = false;
            state_ = AudioCapturerState::INITIALIZED;
        }
    }
    if (completion != Render::PlatformLifecycle::InitCompletion::Published) {
        ReleaseCapturerResources(capturer, builder);
        if (completion == Render::PlatformLifecycle::InitCompletion::DestroyDeferredToInitOwner) {
            CompleteDeferredDestroyOnInitOwner();
        }
        releaseInitHold();
        return -1;
    }
    releaseInitHold();
    return 0;
}

int AudioCapturer::Start() {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    if (!capturer_ || destroying_ || state_ == AudioCapturerState::RELEASED) {
        return -1;
    }
    if (state_ == AudioCapturerState::RUNNING) {
        return 0;
    }
    const OH_AudioStream_Result ret = OH_AudioCapturer_Start(capturer_);
    if (ret != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "[AudioCap] start failed: %{public}d", ret);
        state_ = AudioCapturerState::STOPPED;
        return -2;
    }
    capturerStopped_ = false;
    state_ = AudioCapturerState::RUNNING;
    OH_LOG_INFO(LOG_APP, "[AudioCap] capture started");
    return 0;
}

int AudioCapturer::Stop() {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    if (!capturer_ || state_ == AudioCapturerState::RELEASED || capturerStopped_) {
        return 0;
    }
    capturerStopped_ = true;
    const OH_AudioStream_Result stopRet = OH_AudioCapturer_Stop(capturer_);
    const OH_AudioStream_Result flushRet = OH_AudioCapturer_Flush(capturer_);
    state_ = AudioCapturerState::STOPPED;
    if (stopRet != AUDIOSTREAM_SUCCESS || flushRet != AUDIOSTREAM_SUCCESS) {
        OH_LOG_WARN(LOG_APP,
                    "[AudioCap] stop/flush result stop=%{public}d flush=%{public}d",
                    stopRet, flushRet);
        return -3;
    }
    return 0;
}

void AudioCapturer::Destroy() {
    const auto destroyToken = platformLifecycle_.beginDestroy();
    if (!destroyToken.valid) {
        return;
    }
    if (destroyToken.deferredToInitOwner) {
        return;
    }
    // Close callback admission before waiting for Init or touching the stream.
    BeginCallbackTeardown();
    captureCallbackGate_.ClearAndWait();
    if (!platformLifecycle_.waitForInit(destroyToken)) {
        OH_LOG_WARN(LOG_APP,
                    "[AudioCap] Destroy deferred: Init did not quiesce within 500ms");
        return;
    }
    OH_AudioCapturer* capturer = nullptr;
    OH_AudioStreamBuilder* builder = nullptr;
    bool testResourceLive = false;
    {
        std::lock_guard<std::mutex> lock(lifecycleMutex_);
        destroying_ = true;
        capturer = capturer_;
        builder = builder_;
        capturer_ = nullptr;
        builder_ = nullptr;
#if defined(RDP_NATIVE_CALLBACK_TESTING)
        testResourceLive = testPlatformResourceLive_;
        testPlatformResourceLive_ = false;
#endif
    }
    {
        std::lock_guard<std::mutex> lock(lifecycleMutex_);
        capturerStopped_ = true;
        state_ = AudioCapturerState::RELEASED;
    }
    RetireAudioCapturerContext(std::move(callbackContext_), capturer, builder,
                               testResourceLive, callbackResourceDestroyCount_);
    platformLifecycle_.finishDestroy(destroyToken);
}

void AudioCapturer::SetCaptureCallback(AudioCaptureCallback callback) {
    captureCallbackGate_.Set(std::move(callback));
}

bool AudioCapturer::BindCallbackHandle(int64_t handle) {
    return callbackContext_ && callbackContext_->bind(handle, owner_, owner_.generation);
}

void AudioCapturer::BeginCallbackTeardown() {
    if (callbackContext_) {
        const bool drained = callbackContext_->closeAndWait();
        if (!drained) {
            OH_LOG_WARN(LOG_APP,
                        "[AudioCap] callback admission remains leased; platform cleanup deferred");
        }
    }
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
bool AudioCapturer::HoldCallbackAdmissionForTesting() {
    if (callbackTestLease_ || !callbackContext_) {
        return static_cast<bool>(callbackTestLease_);
    }
    auto lease = callbackContext_->tryAcquire();
    if (!lease) {
        return false;
    }
    callbackTestLease_ = std::make_unique<Render::CallbackAdmissionContext::Lease>(
        std::move(lease));
    return true;
}

void AudioCapturer::ReleaseCallbackAdmissionForTesting() {
    callbackTestLease_.reset();
}

void AudioCapturer::MarkPlatformResourceLiveForTesting() {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    testPlatformResourceLive_ = true;
}

int AudioCapturer::PlatformResourceDestroyCountForTesting() const {
    return callbackResourceDestroyCount_
        ? callbackResourceDestroyCount_->load(std::memory_order_acquire) : 0;
}
#endif

void AudioCapturer::CompleteDeferredDestroyOnInitOwner() {
    BeginCallbackTeardown();
    captureCallbackGate_.ClearAndWait();
    {
        std::lock_guard<std::mutex> lock(lifecycleMutex_);
        destroying_ = true;
        capturerStopped_ = true;
        state_ = AudioCapturerState::RELEASED;
    }
    platformLifecycle_.finishDeferredDestroy();
    ReleaseInitLifetimeHold();
}

void AudioCapturer::ReleaseInitLifetimeHold() {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    initLifetimeHold_.reset();
}

AudioCapturerState AudioCapturer::GetState() const {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    return state_;
}

void AudioCapturer::OnReadData(OH_AudioCapturer* /*capturer*/, void* userData,
                               void* audioData, int32_t audioDataSize) {
    auto* context = static_cast<Render::CallbackAdmissionContext*>(userData);
    if (!context || audioData == nullptr || audioDataSize <= 0) {
        return;
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    context->invokeBeforeAcquireHookForTesting();
#endif
    auto callbackLease = context->tryAcquire();
    if (!callbackLease) {
        return;
    }
    const auto snapshot = callbackLease.snapshot();
    auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(snapshot.owner);
    if (!ownerLease) {
        return;
    }
    const auto capturerLease = g_audioCapturerRegistry.acquire(
        snapshot.token, snapshot.owner);
    if (!capturerLease) {
        return;
    }
    capturerLease->captureCallbackGate_.Invoke(
        static_cast<const uint8_t*>(audioData), static_cast<size_t>(audioDataSize));
}

// ============================================================
// NAPI 包装
// ============================================================

namespace {
using AudioCapturerLease = OpaqueHandleRegistry<AudioCapturer>::Lease;

struct AudioCapturerAccess {
    Render::SessionSinkOwnerLease::Lease ownerLease;
    AudioCapturerLease capturer;
};

static void QuiesceAudioCapturer(
    int64_t handle, const Render::DecoderSessionIdentity& owner) {
    if (handle <= 0) {
        return;
    }
    const auto lease = g_audioCapturerRegistry.acquire(handle, owner);
    if (lease) {
        lease->BeginCallbackTeardown();
    }
}

static AudioCapturerAccess AcquireAudioCapturer(int64_t handle) {
    AudioCapturerAccess access;
    const Render::DecoderSessionIdentity owner =
        Render::SharedSessionSinkOwnerLease().snapshot();
    if (!owner.valid()) {
        return access;
    }
    access.ownerLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (access.ownerLease) {
        access.capturer = g_audioCapturerRegistry.acquire(handle, owner);
    }
    return access;
}

static bool ReadAudioCapturerHandle(napi_env env, napi_callback_info info,
                                    int64_t& handle) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
        argc != 1 || args[0] == nullptr ||
        napi_get_value_int64(env, args[0], &handle) != napi_ok || handle <= 0) {
        handle = 0;
        return false;
    }
    return true;
}

napi_value NapiInitAudioCapturer(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t sr = 16000, ch = 1;
    if (argc >= 1) napi_get_value_int32(env, args[0], &sr);
    if (argc >= 2) napi_get_value_int32(env, args[1], &ch);
    const Render::DecoderSessionIdentity owner =
        Render::SharedSessionSinkOwnerLease().snapshot();
    const auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!ownerLease) {
        napi_value error;
        napi_create_int32(env, -1, &error);
        return error;
    }
    auto cap = std::shared_ptr<AudioCapturer>(new AudioCapturer(owner));
    const int64_t handle = g_audioCapturerRegistry.registerObject(cap, owner);
    if (handle <= 0 || !cap->BindCallbackHandle(handle) || cap->Init(sr, ch) != 0) {
        if (handle > 0) {
            cap->BeginCallbackTeardown();
            g_audioCapturerRegistry.destroy(handle, owner);
        }
        cap->Destroy();
        napi_value error;
        napi_create_int32(env, -1, &error);
        return error;
    }
    napi_value h; napi_create_int64(env, handle, &h);
    return h;
}

napi_value NapiStartCapture(napi_env env, napi_callback_info info) {
    int64_t handle = 0;
    const bool validArg = ReadAudioCapturerHandle(env, info, handle);
    auto access = validArg ? AcquireAudioCapturer(handle) : AudioCapturerAccess {};
    const int r = validArg && access.capturer ? access.capturer->Start() : -1;
    napi_value ret; napi_create_int32(env, r, &ret); return ret;
}

napi_value NapiStopCapture(napi_env env, napi_callback_info info) {
    int64_t handle = 0;
    const bool validArg = ReadAudioCapturerHandle(env, info, handle);
    auto access = validArg ? AcquireAudioCapturer(handle) : AudioCapturerAccess {};
    const int r = validArg && access.capturer ? access.capturer->Stop() : -1;
    napi_value ret; napi_create_int32(env, r, &ret); return ret;
}

napi_value NapiDestroyAudioCapturer(napi_env env, napi_callback_info info) {
    int64_t handle = 0;
    if (!ReadAudioCapturerHandle(env, info, handle)) {
        napi_value u; napi_get_undefined(env, &u); return u;
    }
    const Render::DecoderSessionIdentity owner =
        Render::SharedSessionSinkOwnerLease().snapshot();
    if (owner.valid()) {
        const auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
        if (ownerLease) {
            QuiesceAudioCapturer(handle, owner);
            const auto capturer = g_audioCapturerRegistry.destroy(handle, owner);
            if (capturer) {
                capturer->Destroy();
            }
        }
    }
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

#if defined(RDP_NATIVE_CALLBACK_TESTING)
std::shared_ptr<AudioCapturer> AudioCapturerNapi::RegisterCallbackTestCapturer(
    const Render::DecoderSessionIdentity& owner, int64_t& handle) {
    handle = 0;
    const auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!owner.valid() || !ownerLease) {
        return nullptr;
    }
    auto capturer = std::make_shared<AudioCapturer>(owner);
    handle = g_audioCapturerRegistry.registerObject(capturer, owner);
    if (handle <= 0 || !capturer->BindCallbackHandle(handle)) {
        if (handle > 0) {
            g_audioCapturerRegistry.destroy(handle, owner);
        }
        handle = 0;
        capturer->Destroy();
        return nullptr;
    }
    return capturer;
}

void AudioCapturerNapi::DestroyCallbackTestCapturer(
    int64_t handle, const Render::DecoderSessionIdentity& owner) {
    QuiesceAudioCapturer(handle, owner);
    const auto capturer = g_audioCapturerRegistry.destroy(handle, owner);
    if (capturer) {
        capturer->Destroy();
    }
}
#endif
