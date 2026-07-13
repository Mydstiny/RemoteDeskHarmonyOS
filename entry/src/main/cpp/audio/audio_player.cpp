/**
 * audio_player.cpp — OHAudio 音频播放器 (R5: 真实实现)
 */

#include "audio_player.h"
#include "audio_activity_state.h"
#include "audio_queue_policy.h"
#include <napi/native_api.h>
#include <hilog/log.h>
#include <algorithm>
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
static AudioActivityState g_audioActivityState;

static uint64_t AudioNowMs() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

static std::shared_ptr<AudioPlayer> CreateAudioPlayer(int sampleRate, int channels) {
    const int safeRate = sampleRate > 0 ? sampleRate : 48000;
    const int safeChannels = channels > 0 ? channels : 2;
    auto player = std::shared_ptr<AudioPlayer>(new AudioPlayer());
    int ret = player->Init(safeRate, safeChannels);
    if (ret != 0) {
        OH_LOG_ERROR(LOG_APP,
            "[Audio] lazy init failed ret=%{public}d rate=%{public}d channels=%{public}d",
            ret,
            safeRate,
            safeChannels);
        return nullptr;
    }
    OH_LOG_INFO(LOG_APP,
        "[Audio] lazy active player ready rate=%{public}d channels=%{public}d",
        safeRate,
        safeChannels);
    return player;
}

// ============================================================
// AudioPlayer 实现 (OHAudio)
// ============================================================

AudioPlayer::AudioPlayer()
    : renderer_(nullptr), builder_(nullptr),
      sampleRate_(48000), channels_(2),
      state_(AudioPlayerState::IDLE) {}

AudioPlayer::~AudioPlayer() {
    Destroy();
}

int AudioPlayer::Init(int sampleRate, int channels) {
    OH_LOG_INFO(LOG_APP, "[Audio] Init: %{public}dHz %{public}dch", sampleRate, channels);
    sampleRate_ = sampleRate;
    channels_ = channels;

    // 创建 OHAudio 流构建器
    OH_AudioStream_Result ret = OH_AudioStreamBuilder_Create(&builder_,
        AUDIOSTREAM_TYPE_RENDERER);
    if (ret != AUDIOSTREAM_SUCCESS || !builder_) {
        OH_LOG_ERROR(LOG_APP, "[Audio] Builder create failed: %{public}d", ret);
        state_ = AudioPlayerState::ERROR;
        return -1;
    }

    // 配置音频参数: 48kHz, 立体声, S16LE PCM, 低延迟
    OH_AudioStreamBuilder_SetSamplingRate(builder_, sampleRate);
    OH_AudioStreamBuilder_SetChannelCount(builder_, channels);
    OH_AudioStreamBuilder_SetSampleFormat(builder_, AUDIOSTREAM_SAMPLE_S16LE);
    OH_AudioStreamBuilder_SetEncodingType(builder_, AUDIOSTREAM_ENCODING_TYPE_RAW);
    OH_AudioStreamBuilder_SetLatencyMode(builder_, AUDIOSTREAM_LATENCY_MODE_FAST);
    OH_AudioStreamBuilder_SetRendererInfo(builder_, AUDIOSTREAM_USAGE_MUSIC);
    OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder_, AudioPlayer::OnWriteData, this);

    ret = OH_AudioStreamBuilder_GenerateRenderer(builder_, &renderer_);
    if (ret != AUDIOSTREAM_SUCCESS || !renderer_) {
        OH_LOG_ERROR(LOG_APP, "[Audio] GenerateRenderer failed: %{public}d", ret);
        state_ = AudioPlayerState::ERROR;
        return -2;
    }

    // 启动播放
    ret = OH_AudioRenderer_Start(renderer_);
    if (ret != AUDIOSTREAM_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "[Audio] Start failed: %{public}d", ret);
        state_ = AudioPlayerState::ERROR;
        return -3;
    }

    state_ = AudioPlayerState::RUNNING;
    OH_LOG_INFO(LOG_APP, "[Audio] ✓ Renderer running: %{public}dHz %{public}dch", sampleRate, channels);
    return 0;
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
    if (state_ != AudioPlayerState::RUNNING || !renderer_) {
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
    auto* player = static_cast<AudioPlayer*>(userData);
    if (!player) {
        return AUDIO_DATA_CALLBACK_RESULT_INVALID;
    }
    player->FillAudioBuffer(audioData, audioDataSize);
    return AUDIO_DATA_CALLBACK_RESULT_VALID;
}

void AudioPlayer::Pause() {
    if (state_ == AudioPlayerState::RUNNING && renderer_) {
        OH_AudioRenderer_Pause(renderer_);
        state_ = AudioPlayerState::PAUSED;
        OH_LOG_INFO(LOG_APP, "[Audio] Paused");
    }
}

void AudioPlayer::Resume() {
    if (state_ == AudioPlayerState::PAUSED && renderer_) {
        OH_AudioRenderer_Start(renderer_);
        state_ = AudioPlayerState::RUNNING;
        OH_LOG_INFO(LOG_APP, "[Audio] Resumed");
    }
}

void AudioPlayer::Stop() {
    if (renderer_ && state_ == AudioPlayerState::RUNNING) {
        OH_AudioRenderer_Stop(renderer_);
        state_ = AudioPlayerState::STOPPED;
        OH_LOG_INFO(LOG_APP, "[Audio] Stopped");
    }
}

void AudioPlayer::Destroy() {
    Stop();
    if (renderer_) {
        OH_AudioRenderer_Release(renderer_);
        renderer_ = nullptr;
    }
    if (builder_) {
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
    }
    {
        std::lock_guard<std::mutex> lock(bufferMutex_);
        pcmBuffer_.clear();
        pcmReadOffset_ = 0;
        prebuffering_ = true;
    }
    state_ = AudioPlayerState::RELEASED;
    OH_LOG_INFO(LOG_APP, "[Audio] Destroyed");
}

// ============================================================
// NAPI 包装
// ============================================================

namespace {

struct AudioPlayerContext {
    std::shared_ptr<AudioPlayer> player;
};

napi_value NapiInitAudioPlayer(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sampleRate = 48000, channels = 2;
    if (argc >= 1) { napi_get_value_int32(env, args[0], &sampleRate); }
    if (argc >= 2) { napi_get_value_int32(env, args[1], &channels); }

    g_audioActivityState.reset();
    auto player = CreateAudioPlayer(sampleRate, channels);
    if (!player) {
        napi_value errVal;
        napi_create_int32(env, -1, &errVal);
        return errVal;
    }

    auto* ctx = new AudioPlayerContext{player};
    {
        std::lock_guard<std::mutex> lock(g_activeAudioMutex);
        g_activeAudioPlayer = player;
    }
    napi_value handle;
    napi_create_int64(env, reinterpret_cast<int64_t>(ctx), &handle);
    return handle;
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

    auto* ctx = reinterpret_cast<AudioPlayerContext*>(handleVal);

    if (!ctx || !ctx->player) {
        return undefined;
    }

    ctx->player->Destroy();
    {
        std::lock_guard<std::mutex> lock(g_activeAudioMutex);
        if (g_activeAudioPlayer == ctx->player) {
            g_activeAudioPlayer = nullptr;
        }
    }
    delete ctx;
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
    AudioPlayerNapi::SetActiveAudioMuted(mute);

    auto* ctx = reinterpret_cast<AudioPlayerContext*>(handleVal);
    if (!ctx || !ctx->player) {
        OH_LOG_WARN(LOG_APP, "[Audio] setAudioMute: null context or player");
        return undefined;
    }

    if (mute) {
        ctx->player->Pause();
        OH_LOG_INFO(LOG_APP, "[Audio] setAudioMute: muted");
    } else {
        ctx->player->Resume();
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
    const int safeRate = sampleRate > 0 ? sampleRate : 48000;
    const int safeChannels = channels > 0 ? channels : 2;
    const size_t bytesPerFrame = static_cast<size_t>(safeChannels) * 2;
    size_t writableSize = size;
    if (bytesPerFrame > 0 && (writableSize % bytesPerFrame) != 0) {
        const size_t alignedSize = writableSize - (writableSize % bytesPerFrame);
        static uint64_t unalignedCount = 0;
        unalignedCount++;
        if (unalignedCount <= 10 || unalignedCount % 100 == 0) {
            OH_LOG_WARN(LOG_APP,
                "[Audio] unaligned PCM trimmed #%{public}llu size=%{public}zu aligned=%{public}zu rate=%{public}d channels=%{public}d",
                static_cast<unsigned long long>(unalignedCount),
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
        static uint64_t mutedDropCount = 0;
        mutedDropCount++;
        if (mutedDropCount <= 5 || mutedDropCount % 100 == 0) {
            OH_LOG_INFO(LOG_APP,
                "[Audio] muted PCM drop #%{public}llu size=%{public}zu rate=%{public}d channels=%{public}d",
                static_cast<unsigned long long>(mutedDropCount),
                writableSize,
                safeRate,
                safeChannels);
        }
        return 0;
    }

    std::shared_ptr<AudioPlayer> player;
    std::shared_ptr<AudioPlayer> oldPlayer;
    {
        std::lock_guard<std::mutex> lock(g_activeAudioMutex);
        player = g_activeAudioPlayer;
        if (player && player->IsRunning() &&
            (player->SampleRate() != safeRate || player->Channels() != safeChannels)) {
            oldPlayer = player;
            g_activeAudioPlayer = nullptr;
            player = nullptr;
        }
    }
    if (oldPlayer) {
        OH_LOG_INFO(LOG_APP,
            "[Audio] format changed, recreate renderer old=%{public}d/%{public}d new=%{public}d/%{public}d",
            oldPlayer->SampleRate(),
            oldPlayer->Channels(),
            safeRate,
            safeChannels);
        oldPlayer->Destroy();
    }

    if (!player || !player->IsRunning()) {
        auto newPlayer = CreateAudioPlayer(safeRate, safeChannels);
        if (!newPlayer) {
            return -3;
        }
        {
            std::lock_guard<std::mutex> lock(g_activeAudioMutex);
            if (!g_activeAudioPlayer || !g_activeAudioPlayer->IsRunning()) {
                g_activeAudioPlayer = newPlayer;
                player = newPlayer;
            } else {
                player = g_activeAudioPlayer;
            }
        }
    }

    return player->Write(data, writableSize);
}

void AudioPlayerNapi::DestroyActiveNative() {
    std::shared_ptr<AudioPlayer> player;
    {
        std::lock_guard<std::mutex> lock(g_activeAudioMutex);
        player = g_activeAudioPlayer;
        g_activeAudioPlayer = nullptr;
    }
    if (player) {
        player->Destroy();
    }
    g_audioActivityState.reset();
}

bool AudioPlayerNapi::IsActivePlaybackReceiving() {
    return g_audioActivityState.hasReceivedPcm();
}

bool AudioPlayerNapi::IsActiveAudioMuted() {
    return g_audioActivityState.isMuted();
}

void AudioPlayerNapi::SetActiveAudioMuted(bool muted) {
    g_audioActivityState.setMuted(muted);
    std::shared_ptr<AudioPlayer> player;
    {
        std::lock_guard<std::mutex> lock(g_activeAudioMutex);
        player = g_activeAudioPlayer;
    }
    if (!player) {
        return;
    }
    if (muted) {
        player->Pause();
    } else {
        player->Resume();
    }
}
