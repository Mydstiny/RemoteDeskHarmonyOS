/**
 * audio_player.cpp — OHAudio 音频播放器 (R5: 真实实现)
 */

#include "audio_player.h"
#include "audio_activity_state.h"
#include "audio_queue_policy.h"
#include "render/opaque_handle_registry.h"
#include <napi/native_api.h>
#include <hilog/log.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <memory>
#include <ohaudio/native_audiorenderer.h>
#include <ohaudio/native_audiostreambuilder.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0010
#define LOG_TAG "AUDIO_PLAYER"

static std::mutex g_activeAudioMutex;
static std::shared_ptr<AudioPlayer> g_activeAudioPlayer = nullptr;
static Render::DecoderSessionIdentity g_activeAudioOwner;
static int64_t g_activeAudioHandle = 0;
static AudioActivityState g_audioActivityState;
static OpaqueHandleRegistry<AudioPlayer> g_audioRegistry;

struct AudioPlayerRegistration {
    std::shared_ptr<AudioPlayer> player;
    int64_t handle = 0;
};

static void ReleaseRendererResources(OH_AudioRenderer* renderer,
                                     OH_AudioStreamBuilder* builder);

static void RetireAudioCallbackContext(
    std::shared_ptr<Render::CallbackAdmissionContext> context,
    OH_AudioRenderer* renderer,
    OH_AudioStreamBuilder* builder,
    bool testResourceLive,
    std::shared_ptr<std::atomic<int>> testDestroyCount) {
    auto cleanup = [renderer, builder, testResourceLive,
                    testDestroyCount = std::move(testDestroyCount)]() {
        ReleaseRendererResources(renderer, builder);
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
                    "[Audio] callback admission timed out before deferred renderer cleanup");
    }
}

static uint64_t AudioNowMs() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

static void ReleaseRendererResources(OH_AudioRenderer* renderer,
                                     OH_AudioStreamBuilder* builder) {
    if (renderer) {
        (void)OH_AudioRenderer_Stop(renderer);
        (void)OH_AudioRenderer_Flush(renderer);
        (void)OH_AudioRenderer_Release(renderer);
    }
    if (builder) {
        (void)OH_AudioStreamBuilder_Destroy(builder);
    }
}

static AudioPlayerRegistration CreateAudioPlayer(
    int sampleRate, int channels, const Render::DecoderSessionIdentity& owner) {
    const int safeRate = sampleRate > 0 ? sampleRate : 48000;
    const int safeChannels = channels > 0 ? channels : 2;
    auto player = std::shared_ptr<AudioPlayer>(new AudioPlayer(owner));
    const int64_t handle = g_audioRegistry.registerObject(player, owner);
    if (handle <= 0 || !player->BindCallbackHandle(handle)) {
        if (handle > 0) {
            g_audioRegistry.destroy(handle, owner);
        }
        player->Destroy();
        return {};
    }
    int ret = player->Init(safeRate, safeChannels);
    if (ret != 0) {
        OH_LOG_ERROR(LOG_APP,
            "[Audio] lazy init failed ret=%{public}d rate=%{public}d channels=%{public}d",
            ret,
            safeRate,
            safeChannels);
        player->BeginCallbackTeardown();
        const std::shared_ptr<AudioPlayer> discarded = g_audioRegistry.destroy(handle, owner);
        if (discarded) {
            discarded->Destroy();
        }
        return {};
    }
    OH_LOG_INFO(LOG_APP,
        "[Audio] lazy active player ready rate=%{public}d channels=%{public}d",
        safeRate,
        safeChannels);
    return AudioPlayerRegistration {std::move(player), handle};
}

// ============================================================
// AudioPlayer 实现 (OHAudio)
// ============================================================

AudioPlayer::AudioPlayer(Render::DecoderSessionIdentity owner)
    : renderer_(nullptr), builder_(nullptr),
      sampleRate_(48000), channels_(2),
      owner_(owner),
      state_(AudioPlayerState::IDLE) {
    callbackContext_ = std::make_shared<Render::CallbackAdmissionContext>(owner_);
    writeCallbackGate_.Set([this](void* audioData, int32_t audioDataSize) {
        FillAudioBuffer(audioData, audioDataSize);
    });
}

AudioPlayer::~AudioPlayer() {
    Destroy();
}

int AudioPlayer::Init(int sampleRate, int channels) {
    OH_LOG_INFO(LOG_APP, "[Audio] Init: %{public}dHz %{public}dch", sampleRate, channels);
    // Keep shared-owned instances alive while a bounded Destroy handoff is
    // waiting for this Init thread. The local also covers the narrow window
    // between beginInit() and publishing the member hold.
    std::shared_ptr<AudioPlayer> initKeepAlive;
    try {
        initKeepAlive = shared_from_this();
    } catch (const std::bad_weak_ptr&) {
        // Stack-owned tests have no shared owner; they must not be destroyed
        // concurrently with Init. Production registry objects are shared-owned.
    }
    const auto initToken = platformLifecycle_.beginInit();
    if (!initToken.valid) {
        OH_LOG_WARN(LOG_APP, "[Audio] Init rejected by lifecycle state");
        return -4;
    }
    {
        std::lock_guard<std::mutex> lock(lifecycleMutex_);
        initLifetimeHold_ = initKeepAlive;
    }
    const auto releaseInitHold = [this]() { ReleaseInitLifetimeHold(); };
    const int safeRate = sampleRate > 0 ? sampleRate : 48000;
    const int safeChannels = channels > 0 ? channels : 2;
    {
        std::lock_guard<std::mutex> lock(lifecycleMutex_);
        sampleRate_ = safeRate;
        channels_ = safeChannels;
    }

    // Init owns these locals until the lifecycle coordinator accepts publish.
    OH_AudioStreamBuilder* builder = nullptr;
    OH_AudioRenderer* renderer = nullptr;
    OH_AudioStream_Result ret = OH_AudioStreamBuilder_Create(&builder,
        AUDIOSTREAM_TYPE_RENDERER);
    if (ret != AUDIOSTREAM_SUCCESS || !builder) {
        OH_LOG_ERROR(LOG_APP, "[Audio] Builder create failed: %{public}d", ret);
        ReleaseRendererResources(renderer, builder);
        const auto completion = platformLifecycle_.completeInit(initToken, false);
        if (completion == Render::PlatformLifecycle::InitCompletion::DestroyDeferredToInitOwner) {
            CompleteDeferredDestroyOnInitOwner();
        } else if (completion == Render::PlatformLifecycle::InitCompletion::Failed) {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            state_ = AudioPlayerState::ERROR;
        }
        releaseInitHold();
        return -1;
    }

    // 配置音频参数: 48kHz, 立体声, S16LE PCM。播放器自身已有
    // 120-300ms 抖动预缓冲，FAST 的约 5ms 拉取周期不会降低端到端延迟，
    // 反而会与软件视频解码争用 CPU，并放大空拉取/平台日志风暴。
    OH_AudioStreamBuilder_SetSamplingRate(builder, safeRate);
    OH_AudioStreamBuilder_SetChannelCount(builder, safeChannels);
    OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE);
    OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
    const OH_AudioStream_Result latencyResult =
        OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_NORMAL);
    OH_LOG_INFO(LOG_APP,
        "[Audio] renderer latency=normal jitterBuffered=true result=%{public}d",
        latencyResult);
    OH_AudioStreamBuilder_SetRendererInfo(builder, AUDIOSTREAM_USAGE_MUSIC);
    OH_AudioStreamBuilder_SetRendererWriteDataCallback(
        builder, AudioPlayer::OnWriteData, callbackContext_.get());

    ret = OH_AudioStreamBuilder_GenerateRenderer(builder, &renderer);
    if (ret != AUDIOSTREAM_SUCCESS || !renderer) {
        OH_LOG_ERROR(LOG_APP, "[Audio] GenerateRenderer failed: %{public}d", ret);
        ReleaseRendererResources(renderer, builder);
        const auto completion = platformLifecycle_.completeInit(initToken, false);
        if (completion == Render::PlatformLifecycle::InitCompletion::DestroyDeferredToInitOwner) {
            CompleteDeferredDestroyOnInitOwner();
        } else if (completion == Render::PlatformLifecycle::InitCompletion::Failed) {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            state_ = AudioPlayerState::ERROR;
        }
        releaseInitHold();
        return -2;
    }

    // 启动播放
    ret = OH_AudioRenderer_Start(renderer);
    if (ret != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "[Audio] Start failed: %{public}d", ret);
        ReleaseRendererResources(renderer, builder);
        const auto completion = platformLifecycle_.completeInit(initToken, false);
        if (completion == Render::PlatformLifecycle::InitCompletion::DestroyDeferredToInitOwner) {
            CompleteDeferredDestroyOnInitOwner();
        } else if (completion == Render::PlatformLifecycle::InitCompletion::Failed) {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            state_ = AudioPlayerState::ERROR;
        }
        releaseInitHold();
        return -3;
    }

    Render::PlatformLifecycle::InitCompletion completion;
    {
        std::lock_guard<std::mutex> lock(lifecycleMutex_);
        completion = platformLifecycle_.completeInit(initToken, true);
        if (completion == Render::PlatformLifecycle::InitCompletion::Published) {
            builder_ = builder;
            renderer_ = renderer;
            builder = nullptr;
            renderer = nullptr;
            rendererStopped_ = false;
            destroying_ = false;
            suspendedForInactivity_ = false;
            state_ = AudioPlayerState::RUNNING;
        }
    }
    if (completion == Render::PlatformLifecycle::InitCompletion::Published) {
        OH_LOG_INFO(LOG_APP, "[Audio] ✓ Renderer running: %{public}dHz %{public}dch",
                    safeRate, safeChannels);
        releaseInitHold();
        return 0;
    }
    ReleaseRendererResources(renderer, builder);
    if (completion == Render::PlatformLifecycle::InitCompletion::DestroyDeferredToInitOwner) {
        CompleteDeferredDestroyOnInitOwner();
    }
    releaseInitHold();
    return -4;
}

bool AudioPlayer::BindCallbackHandle(int64_t handle) {
    return callbackContext_ && callbackContext_->bind(handle, owner_, owner_.generation);
}

void AudioPlayer::BeginCallbackTeardown() {
    if (callbackContext_) {
        const bool drained = callbackContext_->closeAndWait();
        if (!drained) {
            OH_LOG_WARN(LOG_APP,
                        "[Audio] callback admission remains leased; platform cleanup deferred");
        }
    }
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
bool AudioPlayer::HoldCallbackAdmissionForTesting() {
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

void AudioPlayer::ReleaseCallbackAdmissionForTesting() {
    callbackTestLease_.reset();
}

void AudioPlayer::MarkPlatformResourceLiveForTesting() {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    testPlatformResourceLive_ = true;
}

int AudioPlayer::PlatformResourceDestroyCountForTesting() const {
    return callbackResourceDestroyCount_
        ? callbackResourceDestroyCount_->load(std::memory_order_acquire) : 0;
}
#endif

void AudioPlayer::CompleteDeferredDestroyOnInitOwner() {
    // This path is used only when Destroy re-enters the Init owner thread.
    // Platform locals have already been released; publish terminal object
    // state before completing the lifecycle transition.
    BeginCallbackTeardown();
    writeCallbackGate_.ClearAndWait();
    {
        std::lock_guard<std::mutex> lock(lifecycleMutex_);
        destroying_ = true;
        rendererStopped_ = true;
        state_ = AudioPlayerState::RELEASED;
    }
    {
        std::lock_guard<std::mutex> lock(bufferMutex_);
        pcmBuffer_.clear();
        pcmReadOffset_ = 0;
        prebuffering_ = true;
    }
    platformLifecycle_.finishDeferredDestroy();
    ReleaseInitLifetimeHold();
}

void AudioPlayer::ReleaseInitLifetimeHold() {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    initLifetimeHold_.reset();
}

AudioPlayerState AudioPlayer::GetState() const {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    return state_;
}

bool AudioPlayer::IsRunning() const {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    return state_ == AudioPlayerState::RUNNING && renderer_ != nullptr && !destroying_;
}

size_t AudioPlayer::FrameBytes() const {
    const int safeChannels = channels_ > 0 ? channels_ : 2;
    return static_cast<size_t>(safeChannels) * 2;
}

size_t AudioPlayer::QueuedBytesLocked() const {
    return pcmBuffer_.size() > pcmReadOffset_ ? pcmBuffer_.size() - pcmReadOffset_ : 0;
}

void AudioPlayer::LogQueueStatsIfDue(uint64_t nowMs, const char* reason, size_t queuedBytes,
                                     bool prebuffering) {
    const uint64_t lastDiagMs = lastDiagMs_.load();
    if (lastDiagMs != 0 && nowMs - lastDiagMs < 1000) {
        return;
    }
    lastDiagMs_.store(nowMs);
    OH_LOG_INFO(LOG_APP,
        "[AudioDiag] reason=%{public}s queued=%{public}zu prebuffer=%{public}s writes=%{public}llu fills=%{public}llu underruns=%{public}llu prebufferSilence=%{public}llu drops=%{public}llu written=%{public}llu callback=%{public}llu silence=%{public}llu dropped=%{public}llu rate=%{public}d channels=%{public}d",
        reason ? reason : "tick",
        queuedBytes,
        prebuffering ? "true" : "false",
        static_cast<unsigned long long>(writeCount_.load()),
        static_cast<unsigned long long>(fillCount_.load()),
        static_cast<unsigned long long>(underrunCount_.load()),
        static_cast<unsigned long long>(prebufferSilenceCount_.load()),
        static_cast<unsigned long long>(dropCount_.load()),
        static_cast<unsigned long long>(writtenBytes_.load()),
        static_cast<unsigned long long>(callbackBytes_.load()),
        static_cast<unsigned long long>(silenceBytes_.load()),
        static_cast<unsigned long long>(droppedBytes_.load()),
        sampleRate_,
        channels_);
}

int AudioPlayer::Write(const uint8_t* data, size_t size) {
    // Keep the lifecycle lease through the buffer mutation. Destroy waits
    // for this lease before clearing PCM storage, so a writer cannot pass the
    // state check and append after renderer teardown has completed.
    std::unique_lock<std::mutex> lifecycleLock(lifecycleMutex_);
    if ((state_ != AudioPlayerState::RUNNING &&
         !(state_ == AudioPlayerState::PAUSED && suspendedForInactivity_)) ||
        !renderer_ || destroying_) {
        return -1;
    }
    if (!data || size == 0) {
        return 0;
    }
    // OHAudio uses callback-based pull; protocol PCM is buffered here and drained
    // by the renderer callback with a small jitter budget.
    size_t queuedBytes = 0;
    bool prebuffering = true;
    {
        std::lock_guard<std::mutex> lock(bufferMutex_);
        queueConfig_ = AudioQueuePolicyForIncomingPcm(sampleRate_, channels_, size);
        const AudioQueuePolicyConfig config = queueConfig_;
        const size_t bufferedBytes = QueuedBytesLocked();
        size_t dropBytes = AudioDropBytesForOverflow(config, bufferedBytes, size);
        const size_t frameBytes = FrameBytes();
        if (frameBytes > 0 && dropBytes > 0) {
            dropBytes -= dropBytes % frameBytes;
        }
        if (dropBytes > bufferedBytes) {
            dropBytes = bufferedBytes;
        }
        if (dropBytes > 0) {
            pcmReadOffset_ += dropBytes;
            dropCount_.fetch_add(1);
            droppedBytes_.fetch_add(dropBytes);
        }
        if (pcmReadOffset_ > 0 &&
            (pcmReadOffset_ > MaxAudioQueueBytes(config) / 2 || pcmReadOffset_ > pcmBuffer_.size() / 2)) {
            pcmBuffer_.erase(pcmBuffer_.begin(), pcmBuffer_.begin() + static_cast<std::ptrdiff_t>(pcmReadOffset_));
            pcmReadOffset_ = 0;
        }
        pcmBuffer_.insert(pcmBuffer_.end(), data, data + size);
        queuedBytes = QueuedBytesLocked();
        if (prebuffering_ && ShouldReleaseAudioFromPrebuffer(config, queuedBytes)) {
            prebuffering_ = false;
            OH_LOG_INFO(LOG_APP,
                "[AudioDiag] prebuffer ready queued=%{public}zu threshold=%{public}zu prebufferMs=%{public}u maxBufferMs=%{public}u",
                queuedBytes,
                AudioBytesForDurationMs(sampleRate_, channels_, config.prebufferMs),
                config.prebufferMs,
                config.maxBufferMs);
        }
        prebuffering = prebuffering_;
        if (suspendedForInactivity_ &&
            ShouldReleaseAudioFromPrebuffer(queueConfig_, queuedBytes)) {
            const OH_AudioStream_Result resumeResult = OH_AudioRenderer_Start(renderer_);
            if (resumeResult == AUDIOSTREAM_SUCCESS) {
                suspendedForInactivity_ = false;
                rendererStopped_ = false;
                state_ = AudioPlayerState::RUNNING;
                g_audioActivityState.markResumed();
                OH_LOG_INFO(LOG_APP,
                    "[AudioDiag] inactivity resume after prebuffer queued=%{public}zu prebufferMs=%{public}u",
                    queuedBytes, queueConfig_.prebufferMs);
            } else {
                OH_LOG_WARN(LOG_APP,
                    "[AudioDiag] inactivity resume failed result=%{public}d",
                    resumeResult);
            }
        }
    }
    const uint64_t writeCount = writeCount_.fetch_add(1) + 1;
    writtenBytes_.fetch_add(size);
    if (writeCount <= 10 || writeCount % 100 == 0) {
        OH_LOG_INFO(LOG_APP,
            "[Audio] Write #%{public}llu size=%{public}zu queued=%{public}zu rate=%{public}d channels=%{public}d",
            static_cast<unsigned long long>(writeCount),
            size,
            queuedBytes,
            sampleRate_,
            channels_);
    }
    LogQueueStatsIfDue(AudioNowMs(), "write", queuedBytes, prebuffering);
    return static_cast<int>(size);
}

int AudioPlayer::FillAudioBuffer(void* audioData, int32_t audioDataSize) {
    if (!audioData || audioDataSize <= 0) {
        return 0;
    }
    auto* out = static_cast<uint8_t*>(audioData);
    int32_t copied = 0;
    bool prebufferedSilence = false;
    size_t queuedBytes = 0;
    bool prebuffering = true;
    {
        std::lock_guard<std::mutex> lock(bufferMutex_);
        const AudioQueuePolicyConfig config = queueConfig_;
        const size_t available = QueuedBytesLocked();
        if (prebuffering_ && !ShouldReleaseAudioFromPrebuffer(config, available)) {
            prebufferedSilence = true;
        } else {
            if (prebuffering_) {
                prebuffering_ = false;
            }
            const size_t copyBytes = std::min(static_cast<size_t>(audioDataSize), available);
            if (copyBytes > 0) {
                std::memcpy(out, pcmBuffer_.data() + pcmReadOffset_, copyBytes);
                pcmReadOffset_ += copyBytes;
                copied = static_cast<int32_t>(copyBytes);
            }
        }
        if (pcmReadOffset_ == pcmBuffer_.size()) {
            pcmBuffer_.clear();
            pcmReadOffset_ = 0;
        } else if (pcmReadOffset_ > 8192 && pcmReadOffset_ > pcmBuffer_.size() / 2) {
            pcmBuffer_.erase(pcmBuffer_.begin(), pcmBuffer_.begin() + static_cast<std::ptrdiff_t>(pcmReadOffset_));
            pcmReadOffset_ = 0;
        }
        queuedBytes = QueuedBytesLocked();
        prebuffering = prebuffering_;
    }
    if (copied < audioDataSize) {
        std::memset(out + copied, 0, static_cast<size_t>(audioDataSize - copied));
        silenceBytes_.fetch_add(static_cast<uint64_t>(audioDataSize - copied));
        if (prebufferedSilence) {
            const uint64_t prebufferSilenceCount = prebufferSilenceCount_.fetch_add(1) + 1;
            if (prebufferSilenceCount <= 10 || prebufferSilenceCount % 100 == 0) {
                OH_LOG_INFO(LOG_APP,
                    "[Audio] Fill prebuffer silence #%{public}llu request=%{public}d queued=%{public}zu",
                    static_cast<unsigned long long>(prebufferSilenceCount),
                    audioDataSize,
                    queuedBytes);
            }
        } else {
            {
                std::lock_guard<std::mutex> lock(bufferMutex_);
                prebuffering_ = true;
                prebuffering = true;
            }
            const uint64_t underrunCount = underrunCount_.fetch_add(1) + 1;
            if (underrunCount <= 10 || underrunCount % 100 == 0) {
                OH_LOG_INFO(LOG_APP,
                    "[Audio] Fill underrun #%{public}llu request=%{public}d copied=%{public}d queued=%{public}zu",
                    static_cast<unsigned long long>(underrunCount),
                    audioDataSize,
                    copied,
                    queuedBytes);
            }
        }
    } else {
        const uint64_t fillCount = fillCount_.fetch_add(1) + 1;
        if (fillCount <= 10 || fillCount % 200 == 0) {
            OH_LOG_INFO(LOG_APP,
                "[Audio] Fill ok #%{public}llu request=%{public}d",
                static_cast<unsigned long long>(fillCount),
                audioDataSize);
        }
    }
    callbackBytes_.fetch_add(static_cast<uint64_t>(audioDataSize));
    LogQueueStatsIfDue(AudioNowMs(), copied < audioDataSize ? "silence" : "fill", queuedBytes,
                       prebuffering);
    return audioDataSize;
}

OH_AudioData_Callback_Result AudioPlayer::OnWriteData(
    OH_AudioRenderer* /*renderer*/, void* userData, void* audioData, int32_t audioDataSize) {
    // The platform may resume a callback after teardown has started.  The
    // first dereference is therefore limited to this stable admission
    // context; AudioPlayer is reached only through the registry token after
    // the context and owner leases are held.
    auto* context = static_cast<Render::CallbackAdmissionContext*>(userData);
    if (!context) {
        return AUDIO_DATA_CALLBACK_RESULT_INVALID;
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    context->invokeBeforeAcquireHookForTesting();
#endif
    auto callbackLease = context->tryAcquire();
    if (!callbackLease) {
        return AUDIO_DATA_CALLBACK_RESULT_INVALID;
    }
    const auto callbackSnapshot = callbackLease.snapshot();
    auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(callbackSnapshot.owner);
    if (!ownerLease) {
        return AUDIO_DATA_CALLBACK_RESULT_INVALID;
    }
    const auto playerLease = g_audioRegistry.acquire(
        callbackSnapshot.token, callbackSnapshot.owner);
    if (!playerLease) {
        return AUDIO_DATA_CALLBACK_RESULT_INVALID;
    }
    // OHAudio can have one callback in flight while teardown releases the
    // renderer. The context admission and registry lease pin the object until
    // the pull callback returns; a late callback never dereferences it.
    playerLease->writeCallbackGate_.Invoke(audioData, audioDataSize);
    return AUDIO_DATA_CALLBACK_RESULT_VALID;
}

void AudioPlayer::Pause() {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    if (state_ == AudioPlayerState::RUNNING && renderer_ && !destroying_) {
        const OH_AudioStream_Result result = OH_AudioRenderer_Pause(renderer_);
        if (result == AUDIOSTREAM_SUCCESS) {
            suspendedForInactivity_ = false;
            state_ = AudioPlayerState::PAUSED;
            OH_LOG_INFO(LOG_APP, "[Audio] Paused");
        } else {
            OH_LOG_WARN(LOG_APP, "[Audio] Pause failed: %{public}d", result);
        }
    }
}

void AudioPlayer::Resume() {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    if (state_ == AudioPlayerState::PAUSED && renderer_ && !destroying_) {
        const OH_AudioStream_Result result = OH_AudioRenderer_Start(renderer_);
        if (result == AUDIOSTREAM_SUCCESS) {
            suspendedForInactivity_ = false;
            rendererStopped_ = false;
            state_ = AudioPlayerState::RUNNING;
            OH_LOG_INFO(LOG_APP, "[Audio] Resumed");
        } else {
            OH_LOG_WARN(LOG_APP, "[Audio] Resume failed: %{public}d", result);
        }
    }
}

void AudioPlayer::Stop() {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    if (!renderer_ || state_ == AudioPlayerState::RELEASED || rendererStopped_) {
        return;
    }
    // Stop is legal for every created renderer state, including PAUSED and
    // ERROR after Start failed.  Mark it stopped before calling the platform
    // so repeated teardown is bounded and idempotent.
    rendererStopped_ = true;
    suspendedForInactivity_ = false;
    const OH_AudioStream_Result stopResult = OH_AudioRenderer_Stop(renderer_);
    const OH_AudioStream_Result flushResult = OH_AudioRenderer_Flush(renderer_);
    state_ = AudioPlayerState::STOPPED;
    if (stopResult != AUDIOSTREAM_SUCCESS || flushResult != AUDIOSTREAM_SUCCESS) {
        OH_LOG_WARN(LOG_APP,
            "[Audio] Stop/Flush result stop=%{public}d flush=%{public}d",
            stopResult, flushResult);
    } else {
        OH_LOG_INFO(LOG_APP, "[Audio] Stopped and flushed");
    }
}

void AudioPlayer::SuspendForInactivity() {
    std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
    if (!renderer_ || destroying_ || state_ == AudioPlayerState::RELEASED ||
        rendererStopped_) {
        return;
    }
    const OH_AudioStream_Result pauseResult = OH_AudioRenderer_Pause(renderer_);
    if (pauseResult != AUDIOSTREAM_SUCCESS && state_ != AudioPlayerState::PAUSED) {
        OH_LOG_WARN(LOG_APP,
            "[AudioDiag] inactivity pause failed result=%{public}d", pauseResult);
        return;
    }
    state_ = AudioPlayerState::PAUSED;
    suspendedForInactivity_ = true;
    {
        std::lock_guard<std::mutex> bufferLock(bufferMutex_);
        pcmBuffer_.clear();
        pcmReadOffset_ = 0;
        prebuffering_ = true;
    }
    OH_LOG_INFO(LOG_APP,
        "[AudioDiag] inactivity suspend thresholdMs=1500 queueCleared=true");
}

void AudioPlayer::Destroy() {
    const auto destroyToken = platformLifecycle_.beginDestroy();
    if (!destroyToken.valid) {
        return;
    }
    if (destroyToken.deferredToInitOwner) {
        // The Init owner will clean its local platform resources after the
        // re-entrant callback returns; waiting here would self-deadlock.
        return;
    }
    // Close admission before waiting for Init or touching platform resources.
    BeginCallbackTeardown();
    writeCallbackGate_.ClearAndWait();
    if (!platformLifecycle_.waitForInit(destroyToken)) {
        OH_LOG_WARN(LOG_APP,
                    "[Audio] Destroy deferred: Init did not quiesce within 500ms");
        return;
    }
    OH_AudioRenderer* renderer = nullptr;
    OH_AudioStreamBuilder* builder = nullptr;
    bool testResourceLive = false;
    {
        std::lock_guard<std::mutex> lock(lifecycleMutex_);
        destroying_ = true;
        suspendedForInactivity_ = false;
        renderer = renderer_;
        builder = builder_;
        renderer_ = nullptr;
        builder_ = nullptr;
#if defined(RDP_NATIVE_CALLBACK_TESTING)
        testResourceLive = testPlatformResourceLive_;
        testPlatformResourceLive_ = false;
#endif
    }
    {
        std::lock_guard<std::mutex> lock(lifecycleMutex_);
        rendererStopped_ = true;
        state_ = AudioPlayerState::RELEASED;
    }
    {
        std::lock_guard<std::mutex> lock(bufferMutex_);
        pcmBuffer_.clear();
        pcmReadOffset_ = 0;
        prebuffering_ = true;
    }
    RetireAudioCallbackContext(std::move(callbackContext_), renderer, builder,
                               testResourceLive, callbackResourceDestroyCount_);
    platformLifecycle_.finishDestroy(destroyToken);
    OH_LOG_INFO(LOG_APP, "[Audio] Destroyed");
}

// ============================================================
// NAPI 包装
// ============================================================

namespace {

static void QuiesceRegisteredAudioPlayer(
    int64_t handle, const Render::DecoderSessionIdentity* owner) {
    if (handle <= 0) {
        return;
    }
    std::shared_ptr<AudioPlayer> player;
    if (owner != nullptr && owner->valid()) {
        const auto lease = g_audioRegistry.acquire(handle, *owner);
        if (lease) {
            player = lease.shared();
        }
    } else {
        player = g_audioRegistry.retain(handle);
    }
    if (player) {
        player->BeginCallbackTeardown();
    }
}

napi_value NapiInitAudioPlayer(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sampleRate = 48000, channels = 2;
    if (argc >= 1) { napi_get_value_int32(env, args[0], &sampleRate); }
    if (argc >= 2) { napi_get_value_int32(env, args[1], &channels); }

    const Render::DecoderSessionIdentity owner =
        Render::SharedSessionSinkOwnerLease().snapshot();
    const auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        napi_value errVal;
        napi_create_int32(env, -1, &errVal);
        return errVal;
    }

    g_audioActivityState.reset();
    auto registration = CreateAudioPlayer(sampleRate, channels, owner);
    auto player = registration.player;
    if (!player || registration.handle <= 0) {
        napi_value errVal;
        napi_create_int32(env, -1, &errVal);
        return errVal;
    }
    const int64_t handle = registration.handle;
    {
        std::lock_guard<std::mutex> lock(g_activeAudioMutex);
        g_activeAudioPlayer = player;
        g_activeAudioOwner = owner;
        g_activeAudioHandle = handle;
    }
    napi_value result;
    napi_create_int64(env, handle, &result);
    return result;
}

napi_value NapiDestroyAudioPlayer(napi_env env, napi_callback_info info) {
    napi_value undefined;
    napi_get_undefined(env, &undefined);

    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 1) {
        return undefined;
    }

    int64_t handleVal = 0;
    if (napi_get_value_int64(env, args[0], &handleVal) != napi_ok || handleVal <= 0) {
        return undefined;
    }

    const Render::DecoderSessionIdentity owner =
        Render::SharedSessionSinkOwnerLease().snapshot();
    if (!owner.valid()) {
        return undefined;
    }
    const auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return undefined;
    }
    QuiesceRegisteredAudioPlayer(handleVal, &owner);
    const std::shared_ptr<AudioPlayer> player = g_audioRegistry.destroy(handleVal, owner);
    if (!player) {
        return undefined;
    }

    player->Destroy();
    {
        std::lock_guard<std::mutex> lock(g_activeAudioMutex);
        if (g_activeAudioHandle == handleVal) {
            g_activeAudioPlayer = nullptr;
            g_activeAudioOwner = Render::DecoderSessionIdentity {};
            g_activeAudioHandle = 0;
        }
    }
    return undefined;
}

napi_value NapiSetAudioMute(napi_env env, napi_callback_info info) {
    napi_value undefined;
    napi_get_undefined(env, &undefined);

    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        OH_LOG_WARN(LOG_APP, "[Audio] setAudioMute: insufficient arguments");
        return undefined;
    }

    int64_t handleVal = 0;
    if (napi_get_value_int64(env, args[0], &handleVal) != napi_ok || handleVal <= 0) {
        OH_LOG_WARN(LOG_APP, "[Audio] setAudioMute: invalid handle");
        return undefined;
    }

    bool mute = false;
    napi_get_value_bool(env, args[1], &mute);
    const Render::DecoderSessionIdentity owner =
        Render::SharedSessionSinkOwnerLease().snapshot();
    if (!owner.valid()) {
        OH_LOG_WARN(LOG_APP, "[Audio] setAudioMute: no active session owner");
        return undefined;
    }
    const auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        OH_LOG_WARN(LOG_APP, "[Audio] setAudioMute: stale session owner");
        return undefined;
    }
    const auto playerLease = g_audioRegistry.acquire(handleVal, owner);
    if (!playerLease) {
        OH_LOG_WARN(LOG_APP, "[Audio] setAudioMute: null context or player");
        return undefined;
    }
    g_audioActivityState.setMuted(mute);

    if (mute) {
        playerLease->Pause();
        OH_LOG_INFO(LOG_APP, "[Audio] setAudioMute: muted");
    } else {
        playerLease->Resume();
        OH_LOG_INFO(LOG_APP, "[Audio] setAudioMute: unmuted");
    }
    return undefined;
}

napi_value NapiSetActiveAudioMute(napi_env env, napi_callback_info info) {
    napi_value undefined;
    napi_get_undefined(env, &undefined);

    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 1) {
        OH_LOG_WARN(LOG_APP, "[Audio] setActiveAudioMute: insufficient arguments");
        return undefined;
    }

    bool mute = false;
    napi_get_value_bool(env, args[0], &mute);
    AudioPlayerNapi::SetActiveAudioMuted(mute);
    OH_LOG_INFO(LOG_APP, "[Audio] setActiveAudioMute: muted=%{public}s", mute ? "true" : "false");
    return undefined;
}

napi_value NapiIsAudioPlaybackActive(napi_env env, napi_callback_info /*info*/) {
    napi_value active;
    napi_get_boolean(env, AudioPlayerNapi::IsActivePlaybackReceiving(), &active);
    return active;
}

} // anonymous namespace

napi_value AudioPlayerNapi::Init(napi_env env, napi_value exports) {
    napi_value fn;
    napi_create_function(env, "initAudioPlayer", NAPI_AUTO_LENGTH, NapiInitAudioPlayer, nullptr, &fn);
    napi_set_named_property(env, exports, "initAudioPlayer", fn);
    napi_create_function(env, "destroyAudioPlayer", NAPI_AUTO_LENGTH, NapiDestroyAudioPlayer, nullptr, &fn);
    napi_set_named_property(env, exports, "destroyAudioPlayer", fn);
    napi_create_function(env, "setAudioMute", NAPI_AUTO_LENGTH, NapiSetAudioMute, nullptr, &fn);
    napi_set_named_property(env, exports, "setAudioMute", fn);
    napi_create_function(env, "setActiveAudioMute", NAPI_AUTO_LENGTH, NapiSetActiveAudioMute, nullptr, &fn);
    napi_set_named_property(env, exports, "setActiveAudioMute", fn);
    napi_create_function(env, "isAudioPlaybackActive", NAPI_AUTO_LENGTH, NapiIsAudioPlaybackActive, nullptr, &fn);
    napi_set_named_property(env, exports, "isAudioPlaybackActive", fn);
    return exports;
}

int AudioPlayerNapi::DispatchActiveNative(const uint8_t* data, size_t size, int sampleRate, int channels) {
    const Render::DecoderSessionIdentity owner =
        Render::SharedSessionSinkOwnerLease().snapshot();
    if (!owner.valid()) {
        return -1;
    }
    return DispatchActiveNative(owner, data, size, sampleRate, channels);
}

int AudioPlayerNapi::DispatchActiveNative(
    const Render::DecoderSessionIdentity& owner, const uint8_t* data, size_t size,
    int sampleRate, int channels) {
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return -1;
    }
    const int safeRate = sampleRate > 0 ? sampleRate : 48000;
    const int safeChannels = channels > 0 ? channels : 2;
    const size_t bytesPerFrame = static_cast<size_t>(safeChannels) * 2;
    size_t writableSize = size;
    if (bytesPerFrame > 0 && (writableSize % bytesPerFrame) != 0) {
        const size_t alignedSize = writableSize - (writableSize % bytesPerFrame);
        static std::atomic<uint64_t> unalignedCount {0};
        const uint64_t unaligned =
            unalignedCount.fetch_add(1, std::memory_order_relaxed) + 1;
        if (unaligned <= 10 || unaligned % 100 == 0) {
            OH_LOG_WARN(LOG_APP,
                "[Audio] unaligned PCM trimmed #%{public}llu size=%{public}zu aligned=%{public}zu rate=%{public}d channels=%{public}d",
                static_cast<unsigned long long>(unaligned),
                writableSize,
                alignedSize,
                safeRate,
                safeChannels);
        }
        writableSize = alignedSize;
        if (writableSize == 0) {
            return -2;
        }
    }

    g_audioActivityState.recordPcmFrame(writableSize);
    if (g_audioActivityState.shouldDropIncomingPcm()) {
        static std::atomic<uint64_t> mutedDropCount {0};
        const uint64_t mutedDrop =
            mutedDropCount.fetch_add(1, std::memory_order_relaxed) + 1;
        if (mutedDrop <= 5 || mutedDrop % 100 == 0) {
            OH_LOG_INFO(LOG_APP,
                "[Audio] muted PCM drop #%{public}llu size=%{public}zu rate=%{public}d channels=%{public}d",
                static_cast<unsigned long long>(mutedDrop),
                writableSize,
                safeRate,
                safeChannels);
        }
        return 0;
    }

    int64_t handle = 0;
    {
        std::lock_guard<std::mutex> lock(g_activeAudioMutex);
        // RustDesk audio is intentionally lazy: SetActiveSessionOwner installs
        // the session identity before the first PCM arrives, while the player
        // handle is still zero. Reject only a stale owner and let the normal
        // create/install path handle that first frame.
        if (g_activeAudioOwner != owner) {
            return -1;
        }
        handle = g_activeAudioHandle;
    }

    auto playerLease = g_audioRegistry.acquire(handle, owner);
    const bool formatMismatch = playerLease && playerLease->IsRunning() &&
        (playerLease->SampleRate() != safeRate || playerLease->Channels() != safeChannels);
    if (playerLease && playerLease->IsRunning() && !formatMismatch) {
        return playerLease->Write(data, writableSize);
    }
    playerLease = {};

    if (handle > 0) {
        QuiesceRegisteredAudioPlayer(handle, &owner);
        const std::shared_ptr<AudioPlayer> oldPlayer = g_audioRegistry.destroy(handle, owner);
        if (oldPlayer) {
            OH_LOG_INFO(LOG_APP,
                "[Audio] %s, recreate renderer handle=%{public}lld rate=%{public}d channels=%{public}d",
                formatMismatch ? "format changed" : "active renderer unavailable",
                static_cast<long long>(handle), safeRate, safeChannels);
            oldPlayer->Destroy();
        }
        std::lock_guard<std::mutex> lock(g_activeAudioMutex);
        if (g_activeAudioHandle == handle && g_activeAudioOwner == owner) {
            g_activeAudioPlayer = nullptr;
            g_activeAudioHandle = 0;
        }
    }

    auto registration = CreateAudioPlayer(safeRate, safeChannels, owner);
    auto newPlayer = registration.player;
    const int64_t newHandle = registration.handle;
    if (!newPlayer || newHandle <= 0) {
        return -3;
    }
    bool installed = false;
    {
        std::lock_guard<std::mutex> lock(g_activeAudioMutex);
        if (g_activeAudioOwner == owner &&
            (g_activeAudioHandle == 0 || g_activeAudioHandle == handle)) {
            g_activeAudioPlayer = newPlayer;
            g_activeAudioHandle = newHandle;
            installed = true;
        }
    }
    if (!installed) {
        QuiesceRegisteredAudioPlayer(newHandle, &owner);
        const std::shared_ptr<AudioPlayer> discarded = g_audioRegistry.destroy(newHandle, owner);
        if (discarded) {
            discarded->Destroy();
        }
        return -1;
    }
    playerLease = g_audioRegistry.acquire(newHandle, owner);
    if (!playerLease) {
        return -1;
    }
    return playerLease->Write(data, writableSize);
}

void AudioPlayerNapi::DestroyActiveNative() {
    std::shared_ptr<AudioPlayer> player = TakeActiveNative();
    if (player) {
        player->Destroy();
    }
}

std::shared_ptr<AudioPlayer> AudioPlayerNapi::TakeActiveNative() {
    std::shared_ptr<AudioPlayer> player;
    int64_t handle = 0;
    Render::DecoderSessionIdentity owner;
    {
        std::lock_guard<std::mutex> lock(g_activeAudioMutex);
        player = g_activeAudioPlayer;
        handle = g_activeAudioHandle;
        owner = g_activeAudioOwner;
        g_activeAudioPlayer = nullptr;
        g_activeAudioOwner = Render::DecoderSessionIdentity {};
        g_activeAudioHandle = 0;
    }
    if (handle > 0) {
        const Render::DecoderSessionIdentity* ownerPtr = owner.valid() ? &owner : nullptr;
        QuiesceRegisteredAudioPlayer(handle, ownerPtr);
        const std::shared_ptr<AudioPlayer> registered = owner.valid() ?
            g_audioRegistry.destroy(handle, owner) : g_audioRegistry.destroy(handle);
        if (registered) {
            player = registered;
        }
    }
    g_audioActivityState.reset();
    return player;
}

std::shared_ptr<AudioPlayer> AudioPlayerNapi::TakeActiveNative(
    const Render::DecoderSessionIdentity& owner) {
    std::shared_ptr<AudioPlayer> player;
    int64_t handle = 0;
    {
        std::lock_guard<std::mutex> lock(g_activeAudioMutex);
        if (g_activeAudioOwner != owner) {
            return nullptr;
        }
        player = g_activeAudioPlayer;
        handle = g_activeAudioHandle;
        g_activeAudioPlayer = nullptr;
        g_activeAudioOwner = Render::DecoderSessionIdentity {};
        g_activeAudioHandle = 0;
    }
    if (handle > 0) {
        QuiesceRegisteredAudioPlayer(handle, &owner);
        const std::shared_ptr<AudioPlayer> registered = g_audioRegistry.destroy(handle, owner);
        if (registered) {
            player = registered;
        }
    }
    g_audioActivityState.reset();
    return player;
}

void AudioPlayerNapi::SetActiveSessionOwner(
    const Render::DecoderSessionIdentity& owner) {
    std::shared_ptr<AudioPlayer> stalePlayer;
    int64_t staleHandle = 0;
    Render::DecoderSessionIdentity staleOwner;
    int64_t activeHandle = 0;
    bool ownerChanged = false;
    {
        std::lock_guard<std::mutex> lock(g_activeAudioMutex);
        if (g_activeAudioOwner != owner) {
            // The active player is a sink, not a reusable process-global
            // session object. Do not let S2 inherit S1's OHAudio renderer
            // merely because the adapter singleton changed owners.
            stalePlayer = std::move(g_activeAudioPlayer);
            staleHandle = g_activeAudioHandle;
            staleOwner = g_activeAudioOwner;
            g_activeAudioOwner = owner;
            g_activeAudioHandle = 0;
            ownerChanged = true;
        } else {
            activeHandle = g_activeAudioHandle;
        }
    }
    if (staleHandle > 0) {
        const Render::DecoderSessionIdentity* ownerPtr = staleOwner.valid() ? &staleOwner : nullptr;
        QuiesceRegisteredAudioPlayer(staleHandle, ownerPtr);
        const std::shared_ptr<AudioPlayer> registered = staleOwner.valid() ?
            g_audioRegistry.destroy(staleHandle, staleOwner) :
            g_audioRegistry.destroy(staleHandle);
        if (registered) {
            stalePlayer = registered;
        }
    }
    if (stalePlayer) {
        stalePlayer->Destroy();
    }
    if (ownerChanged || stalePlayer) {
        g_audioActivityState.reset();
    }
    if (activeHandle > 0 && owner.valid()) {
        g_audioRegistry.activate(activeHandle, owner);
    }
}

void AudioPlayerNapi::ClearActiveSessionOwner(
    const Render::DecoderSessionIdentity& owner) {
    bool cleared = false;
    {
        std::lock_guard<std::mutex> lock(g_activeAudioMutex);
        if (g_activeAudioOwner == owner) {
            g_activeAudioOwner = Render::DecoderSessionIdentity {};
            cleared = true;
        }
    }
    if (cleared) {
        g_audioActivityState.reset();
    }
}

void AudioPlayerNapi::DestroyDetachedNative(
    int64_t handle, std::shared_ptr<AudioPlayer> activePlayer) {
    QuiesceRegisteredAudioPlayer(handle, nullptr);
    const std::shared_ptr<AudioPlayer> handlePlayer =
        handle > 0 ? g_audioRegistry.destroy(handle) : nullptr;
    if (handlePlayer) {
        handlePlayer->Destroy();
    }
    if (activePlayer && activePlayer != handlePlayer) {
        activePlayer->Destroy();
    }
}

void AudioPlayerNapi::DestroyDetachedNative(
    int64_t handle, std::shared_ptr<AudioPlayer> activePlayer,
    const Render::DecoderSessionIdentity& owner) {
    QuiesceRegisteredAudioPlayer(handle, &owner);
    const std::shared_ptr<AudioPlayer> handlePlayer =
        handle > 0 ? g_audioRegistry.destroy(handle, owner) : nullptr;
    if (handle > 0 && !handlePlayer) {
        OH_LOG_INFO(LOG_APP,
            "[Audio] reject stale detached token owner session=%{public}llu generation=%{public}llu",
            static_cast<unsigned long long>(owner.sessionId),
            static_cast<unsigned long long>(owner.generation));
    }
    if (handlePlayer) {
        handlePlayer->Destroy();
    }
    if (activePlayer && activePlayer != handlePlayer) {
        activePlayer->Destroy();
    }
}

bool AudioPlayerNapi::IsActivePlaybackReceiving() {
    return g_audioActivityState.hasReceivedPcm();
}

bool AudioPlayerNapi::SuspendActiveNative(
    const Render::DecoderSessionIdentity& owner) {
    const auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return false;
    }
    std::shared_ptr<AudioPlayer> player;
    {
        std::lock_guard<std::mutex> lock(g_activeAudioMutex);
        if (g_activeAudioOwner != owner || g_activeAudioHandle <= 0) {
            return false;
        }
        const auto playerLease = g_audioRegistry.acquire(g_activeAudioHandle, owner);
        if (!playerLease) {
            return false;
        }
        player = playerLease.shared();
    }
    if (!player) {
        return false;
    }
    player->SuspendForInactivity();
    return true;
}

bool AudioPlayerNapi::PollActiveAudioInactivity(
    const Render::DecoderSessionIdentity& owner, uint64_t nowMs) {
    if (!g_audioActivityState.pollInactivity(nowMs)) {
        return false;
    }
    if (!SuspendActiveNative(owner)) {
        g_audioActivityState.markResumed();
        return false;
    }
    return true;
}

bool AudioPlayerNapi::IsActiveAudioMuted() {
    return g_audioActivityState.isMuted();
}

void AudioPlayerNapi::SetActiveAudioMuted(bool muted) {
    g_audioActivityState.setMuted(muted);
    int64_t handle = 0;
    Render::DecoderSessionIdentity owner;
    {
        std::lock_guard<std::mutex> lock(g_activeAudioMutex);
        handle = g_activeAudioHandle;
        owner = g_activeAudioOwner;
    }
    const auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return;
    }
    const auto playerLease = g_audioRegistry.acquire(handle, owner);
    if (!playerLease) {
        return;
    }
    if (muted) {
        playerLease->Pause();
    } else {
        playerLease->Resume();
    }
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
std::shared_ptr<AudioPlayer> AudioPlayerNapi::RegisterCallbackTestPlayer(
    const Render::DecoderSessionIdentity& owner, int64_t& handle) {
    handle = 0;
    const auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!owner.valid() || !ownerLease) {
        return nullptr;
    }
    auto player = std::make_shared<AudioPlayer>(owner);
    handle = g_audioRegistry.registerObject(player, owner);
    if (handle <= 0 || !player->BindCallbackHandle(handle)) {
        if (handle > 0) {
            g_audioRegistry.destroy(handle, owner);
        }
        handle = 0;
        player->Destroy();
        return nullptr;
    }
    return player;
}

void AudioPlayerNapi::DestroyCallbackTestPlayer(
    int64_t handle, const Render::DecoderSessionIdentity& owner) {
    QuiesceRegisteredAudioPlayer(handle, &owner);
    const auto player = g_audioRegistry.destroy(handle, owner);
    if (player) {
        player->Destroy();
    }
}
#endif
