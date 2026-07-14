/**
 * audio_player.h — 低延迟音频播放器
 *
 * 基于 OHAudio (OH_AudioRenderer) 的 PCM 音频播放器。
 * 使用 FAST 延迟模式，适合远程桌面实时音频场景。
 *
 * 参数: 48kHz, 双声道, 16-bit PCM, 低延迟模式
 */

#include <napi/native_api.h>
#ifndef AUDIO_PLAYER_H
#define AUDIO_PLAYER_H

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <memory>
#include <string>
#include <vector>
#include <ohaudio/native_audiostream_base.h>

#include "audio_queue_policy.h"

/** 音频播放器状态 */
enum class AudioPlayerState {
    IDLE = 0,
    INITIALIZED = 1,
    RUNNING = 2,
    PAUSED = 3,
    STOPPED = 4,
    RELEASED = 5,
    ERROR = 6
};

/** 音频播放器错误码 */
enum class AudioPlayerError {
    NONE = 0,
    CREATE_FAILED = -1,
    START_FAILED = -2,
    WRITE_FAILED = -3,
    INVALID_STATE = -4
};

/**
 * AudioPlayer — OHAudio 音频播放器
 *
 * 每个远程桌面连接创建一个实例。
 * 通过 AudioDataCallback 从协议后端接收 PCM 数据。
 */
class AudioPlayer {
public:
    AudioPlayer();
    ~AudioPlayer();

    /**
     * 初始化音频播放器
     * @param sampleRate  采样率 (默认 48000)
     * @param channels    声道数 (默认 2)
     * @return 0=成功, 负数=错误码
     */
    int Init(int sampleRate = 48000, int channels = 2);

    /**
     * 写入 PCM 音频数据
     * @param data  PCM 数据 (16-bit signed, interleaved)
     * @param size  数据大小 (bytes)
     * @return 实际写入字节数
     */
    int Write(const uint8_t* data, size_t size);

    /** 暂停播放 */
    void Pause();

    /** 恢复播放 */
    void Resume();

    /** 停止播放 */
    void Stop();

    /** 销毁播放器，释放资源 */
    void Destroy();

    /** 获取当前状态 */
    AudioPlayerState GetState() const { return state_; }

    /** 是否正在运行 */
    bool IsRunning() const { return state_ == AudioPlayerState::RUNNING; }

    int SampleRate() const { return sampleRate_; }
    int Channels() const { return channels_; }

private:
    OH_AudioRenderer*     renderer_;      // OH_AudioRenderer 实例
    OH_AudioStreamBuilder* builder_;      // 流构建器
    int                   sampleRate_;
    int                   channels_;
    AudioPlayerState      state_;
    std::mutex            bufferMutex_;
    std::vector<uint8_t>  pcmBuffer_;
    size_t                pcmReadOffset_ = 0;
    AudioQueuePolicyConfig queueConfig_;
    bool                  prebuffering_ = true;
    std::atomic<uint64_t> writeCount_ {0};
    std::atomic<uint64_t> fillCount_ {0};
    std::atomic<uint64_t> underrunCount_ {0};
    std::atomic<uint64_t> prebufferSilenceCount_ {0};
    std::atomic<uint64_t> dropCount_ {0};
    std::atomic<uint64_t> writtenBytes_ {0};
    std::atomic<uint64_t> callbackBytes_ {0};
    std::atomic<uint64_t> silenceBytes_ {0};
    std::atomic<uint64_t> droppedBytes_ {0};
    std::atomic<uint64_t> lastDiagMs_ {0};

    bool CreateStream();
    int FillAudioBuffer(void* audioData, int32_t audioDataSize);
    size_t FrameBytes() const;
    size_t QueuedBytesLocked() const;
    void LogQueueStatsIfDue(uint64_t nowMs, const char* reason, size_t queuedBytes,
                             bool prebuffering);
    static OH_AudioData_Callback_Result OnWriteData(
        OH_AudioRenderer* renderer, void* userData, void* audioData, int32_t audioDataSize);
};

// ============================================================
// NAPI 包装
// ============================================================

namespace AudioPlayerNapi {
    napi_value Init(napi_env env, napi_value exports);
    int DispatchActiveNative(const uint8_t* data, size_t size, int sampleRate, int channels);
    void DestroyActiveNative();
    std::shared_ptr<AudioPlayer> TakeActiveNative();
    void DestroyDetachedNative(int64_t handle, std::shared_ptr<AudioPlayer> activePlayer);
    bool IsActivePlaybackReceiving();
    bool IsActiveAudioMuted();
    void SetActiveAudioMuted(bool muted);
}

#endif // AUDIO_PLAYER_H
