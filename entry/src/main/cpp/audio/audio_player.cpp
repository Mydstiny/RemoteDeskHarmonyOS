#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

#include <securec.h>

#include <OHAudio/OHAudio.h>
#include <hilog/log.h>

#include "extensions/protocol_adapter.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3202
#define LOG_TAG "AudioPlayer"

// AudioPlayer — 基于 OHAudio 的低延迟音频播放器
// 48kHz 立体声 PCM 播放，通过 AudioDataCallback 接收数据
class AudioPlayer {
public:
    AudioPlayer() = default;
    ~AudioPlayer() { Stop(); }

    // 初始化音频渲染器
    // 默认配置：48kHz 采样率，双声道，低延迟模式
    bool Init() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (renderer_) {
            OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG,
                         "AudioPlayer already initialized");
            return true;
        }

        OH_AudioStreamBuilder* builder = nullptr;
        OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_RENDERER);
        if (!builder) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "Failed to create AudioStreamBuilder");
            return false;
        }

        // 配置音频参数
        OH_AudioStreamBuilder_SetSamplingRate(builder, 48000);
        OH_AudioStreamBuilder_SetChannelCount(builder, 2);
        OH_AudioStreamBuilder_SetSampleFormat(builder,
                                               AUDIOSTREAM_SAMPLE_S16LE);
        OH_AudioStreamBuilder_SetEncodingType(builder,
                                               AUDIOSTREAM_ENCODING_PCM);
        OH_AudioStreamBuilder_SetLatencyMode(builder,
                                              AUDIOSTREAM_LATENCY_MODE_FAST);

        // 设置写入回调
        OH_AudioRenderer_Callbacks callbacks;
        callbacks.OH_AudioRenderer_OnWriteData = OnWriteData;
        callbacks.OH_AudioRenderer_OnStreamEvent = nullptr;
        callbacks.OH_AudioRenderer_OnInterruptEvent = nullptr;
        callbacks.OH_AudioRenderer_OnException = nullptr;

        OH_AudioStreamBuilder_SetRendererCallback(builder, callbacks, this);

        // 生成渲染器
        OH_AudioStreamBuilder_GenerateRenderer(builder, &renderer_);
        OH_AudioStreamBuilder_Destroy(builder);

        if (!renderer_) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "Failed to generate audio renderer");
            return false;
        }

        // 获取帧大小（每次回调期望写入的采样数）
        OH_AudioRenderer_GetFramesPerWrite(renderer_, &framesPerWrite_);
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "AudioPlayer initialized, framesPerWrite=%u",
                     framesPerWrite_);

        isInitialized_ = true;
        return true;
    }

    // 开始播放
    bool Start() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!renderer_) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "Start: renderer not initialized");
            return false;
        }
        if (isPlaying_) return true;

        OH_AudioStream_Result ret = OH_AudioRenderer_Start(renderer_);
        if (ret != AUDIOSTREAM_SUCCESS) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "OH_AudioRenderer_Start failed: %d", ret);
            return false;
        }

        isPlaying_ = true;
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "Audio playback started");
        return true;
    }

    // 停止播放
    void Stop() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (renderer_ && isPlaying_) {
            OH_AudioRenderer_Flush(renderer_);
            OH_AudioRenderer_Stop(renderer_);
            isPlaying_ = false;
        }
        if (renderer_) {
            OH_AudioRenderer_Release(renderer_);
            renderer_ = nullptr;
        }
        isInitialized_ = false;
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "AudioPlayer stopped");
    }

    // 接收 PCM 音频数据（由协议适配器调用）
    // pcm: 16-bit signed integer PCM 数据
    // len: 数据长度（字节）
    void OnData(const uint8_t* pcm, size_t len) {
        if (!pcm || len == 0 || !isInitialized_) return;

        std::lock_guard<std::mutex> lock(mutex_);
        // 将数据追加到环形缓冲区
        pcmBuffer_.insert(pcmBuffer_.end(), pcm, pcm + len);

        // 防止缓冲区无限增长，上限 500ms 的音频数据
        // 48kHz 立体声 16bit = 192000 bytes/sec → 上限 96000 bytes
        const size_t maxBuffer = 96000;
        if (pcmBuffer_.size() > maxBuffer) {
            OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG,
                         "Audio buffer overflow, dropping %zu bytes",
                         pcmBuffer_.size() - maxBuffer);
            pcmBuffer_.erase(pcmBuffer_.begin(),
                             pcmBuffer_.begin() + (pcmBuffer_.size() - maxBuffer));
        }
    }

    // 暂停/恢复播放
    void Pause() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (renderer_ && isPlaying_) {
            OH_AudioRenderer_Pause(renderer_);
            isPlaying_ = false;
        }
    }

    void Resume() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (renderer_ && !isPlaying_) {
            OH_AudioRenderer_Start(renderer_);
            isPlaying_ = true;
        }
    }

    // 获取播放状态
    bool IsPlaying() const { return isPlaying_; }
    bool IsInitialized() const { return isInitialized_; }

private:
    // OHAudio 写入回调（音频渲染器从 PCM 数据源拉取数据）
    static int32_t OnWriteData(OH_AudioRenderer* renderer,
                               void* userData,
                               void* buffer,
                               int32_t bufferLen) {
        auto* self = static_cast<AudioPlayer*>(userData);
        if (!self || !buffer || bufferLen <= 0) return 0;

        std::lock_guard<std::mutex> lock(self->mutex_);

        if (self->pcmBuffer_.empty()) {
            // 无数据：输出静音
            memset(buffer, 0, bufferLen);
            return bufferLen;
        }

        int32_t copySize = static_cast<int32_t>(self->pcmBuffer_.size());
        if (copySize > bufferLen) copySize = bufferLen;

        if (memcpy_s(buffer, bufferLen, self->pcmBuffer_.data(), copySize) != EOK) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "memcpy_s failed in OnWriteData");
            memset(buffer, 0, bufferLen);
            return bufferLen;
        }

        self->pcmBuffer_.erase(self->pcmBuffer_.begin(),
                               self->pcmBuffer_.begin() + copySize);

        // 如果未填满 buffer，剩余部分填静音
        if (copySize < bufferLen) {
            memset(static_cast<uint8_t*>(buffer) + copySize, 0,
                   bufferLen - copySize);
        }

        return bufferLen;
    }

private:
    OH_AudioRenderer* renderer_ = nullptr;  // OHAudio 渲染器实例
    uint32_t framesPerWrite_ = 0;            // 每次回调写入的帧数

    std::vector<uint8_t> pcmBuffer_;         // PCM 数据环形缓冲区
    std::mutex mutex_;                       // 线程安全锁

    bool isInitialized_ = false;             // 是否已初始化
    bool isPlaying_ = false;                 // 是否正在播放
};
