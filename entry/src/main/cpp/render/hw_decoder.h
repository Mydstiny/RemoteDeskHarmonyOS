/**
 * hw_decoder.h — 硬件视频解码器
 *
 * 基于 OH_AVCodec (OH_VideoDecoder) 的 H.264/H.265 硬件解码器。
 * Surface 模式: 解码帧直接写入 NativeImage Surface → GL OES 纹理 → GLRenderer 零拷贝采样。
 *
 * 管线：
 *   编码帧 → OH_VideoDecoder → NativeImage Surface → GL OES 纹理 → GLRenderer
 */

#ifndef HW_DECODER_H
#define HW_DECODER_H

#include "extensions/protocol_adapter.h"
#include "video_backpressure_controller.h"
#include <GLES3/gl3.h>
#include <napi/native_api.h>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

// OH_AVCodec / NativeImage 前向声明
struct OH_AVCodec;
struct OH_AVFormat;
struct OH_AVBuffer;
struct OH_NativeImage;
// OHNativeWindow: 使用 void* 存储避免与 SDK typedef 冲突

/**
 * 解码器错误码
 */
enum class DecoderError {
    NONE = 0,
    CREATE_FAILED = -1,
    CONFIGURE_FAILED = -2,
    START_FAILED = -3,
    INPUT_FAILED = -4,
    OUTPUT_FAILED = -5,
    FLUSH_FAILED = -6
};

/** 解码帧就绪回调 */
using DecoderFrameCallback = std::function<void(GLuint textureId, int width, int height)>;
using DecoderMakeCurrentCallback = std::function<void()>;
using DecoderReleaseCurrentCallback = std::function<void()>;

/** 解码器错误回调 */
using DecoderErrorCallback = std::function<void(DecoderError error, const std::string& message)>;

/** 编码帧队列项 */
struct EncodedFrame {
    uint8_t* data;
    size_t   size;
    int64_t  timestamp;
    bool     isKeyFrame;
};

struct PendingInputBuffer {
    uint32_t     index;
    OH_AVBuffer* buffer;
};

/**
 * HardwareDecoder — 硬件视频解码器 (OH_AVCodec Surface 模式)
 *
 * 每个远程桌面连接创建一个实例。
 * 解码 H.264/H.265 编码帧，输出 GL 纹理 ID 供渲染器直接采样。
 * 回调在解码器内部线程执行, 所有状态访问通过 mutex_ 保护。
 */
class HardwareDecoder {
public:
    HardwareDecoder();
    ~HardwareDecoder();

    /**
     * 初始化解码器
     * @param width   视频宽度
     * @param height  视频高度
     * @param codec   编码类型 (H264 或 H265)
     * @return 0=成功, 负数=错误码
     */
    int Init(int width, int height, CodecType codec);

    /**
     * 送入编码帧数据 (线程安全, 入队等待解码器回调取走)
     * @param data       编码帧数据 (调用方保证生命周期)
     * @param size       数据大小 (bytes)
     * @param timestamp  时间戳 (微秒)
     * @return 0=成功
     */
    int Decode(const uint8_t* data, size_t size, uint64_t timestamp, bool isKeyFrame = false);

    /**
     * 获取 NativeImage 的 GL 纹理 ID
     * 用于零拷贝绑定到 GLRenderer
     */
    GLuint GetTextureId() const;

    /** 刷新解码器缓冲区 */
    void Flush();

    /** 销毁解码器 */
    void Destroy();

    /** 是否已初始化 */
    bool IsInitialized() const { return initialized_; }

    /** 当前解码器编码类型 */
    CodecType GetCodecType() const { return codecType_; }
    size_t QueuedFrameCount() const;
    uint64_t DroppedFrameCount() const;

    /** 检测解码器是否过载 (基于丢帧/截断/输出失败) */
    bool IsOverloaded() const {
        uint64_t drops = inputDropCount_.load();
        uint64_t waitDrops = waitKeyframeDropCount_.load();
        uint64_t truncs = inputTruncatedCount_.load();
        uint64_t renderFails = renderOutputFailureCount_.load();
        return (drops > 0) || (waitDrops > 20) || (truncs > 0) || (renderFails > 0);
    }

    /** 获取过载原因字符串 */
    std::string OverloadReason() const {
        std::string reason;
        if (inputDropCount_.load() > 0) reason += "drops=" + std::to_string(inputDropCount_.load()) + " ";
        if (waitKeyframeDropCount_.load() > 0) reason += "waitDrops=" + std::to_string(waitKeyframeDropCount_.load()) + " ";
        if (inputTruncatedCount_.load() > 0) reason += "truncs=" + std::to_string(inputTruncatedCount_.load()) + " ";
        if (renderOutputFailureCount_.load() > 0) reason += "renderFails=" + std::to_string(renderOutputFailureCount_.load()) + " ";
        if (updateSurfaceFailureCount_.load() > 0) reason += "updateFails=" + std::to_string(updateSurfaceFailureCount_.load()) + " ";
        return reason.empty() ? "none" : reason;
    }

    /** 设置帧就绪回调 */
    void SetFrameCallback(DecoderFrameCallback callback);
    void SetMakeCurrentCallback(DecoderMakeCurrentCallback callback);
    void SetReleaseCurrentCallback(DecoderReleaseCurrentCallback callback);
    void StartRenderThread();
    void StopRenderThreadForDetach();

    /** 设置错误回调 */
    void SetErrorCallback(DecoderErrorCallback callback);

    // R2: 测试用 — 获取解码器原始指针用于 testDecoderH264
    OH_AVCodec* GetDecoder() const { return decoder_; }

private:
    OH_AVCodec*     decoder_ = nullptr;        // OH_VideoDecoder 实例
    OH_NativeImage* nativeImage_ = nullptr;    // NativeImage (零拷贝纹理)
    void*          nativeWindow_ = nullptr;     // OHNativeWindow* (从 NativeImage 获取, 存为 void* 避免头文件冲突)
    GLuint          textureId_ = 0;            // NativeImage 关联的 GL 纹理 ID
    int             width_ = 0;
    int             height_ = 0;
    CodecType       codecType_ = CodecType::H264;
    bool            initialized_ = false;

    DecoderFrameCallback  frameCallback_;
    DecoderMakeCurrentCallback makeCurrentCallback_;
    DecoderReleaseCurrentCallback releaseCurrentCallback_;
    DecoderErrorCallback  errorCallback_;

    // 输入队列 + 线程安全
    mutable std::mutex      mutex_;
    std::deque<EncodedFrame> inputQueue_;
    std::deque<PendingInputBuffer> pendingInputBuffers_;
    std::atomic<uint64_t> inputPushCount_ {0};
    std::atomic<uint64_t> inputDropCount_ {0};
    std::atomic<uint64_t> waitKeyframeDropCount_ {0};
    std::atomic<uint64_t> keyframeRecoveryCount_ {0};
    std::atomic<uint64_t> inputTruncatedCount_ {0};
    std::atomic<uint64_t> renderOutputFailureCount_ {0};
    std::atomic<uint64_t> updateSurfaceFailureCount_ {0};
    std::atomic<uint64_t> outputFrameCount_ {0};
    std::condition_variable frameAvailableCv_;
    uint64_t frameAvailableCount_ = 0;
    uint64_t frameConsumeCount_ = 0;
    Render::VideoBackpressureController backpressure_;
    bool nativeImageContextAttached_ = false;
    std::thread renderThread_;
    std::atomic<bool> renderThreadStop_ {false};

    // 回调上下文 (静态函数 + userData)
    struct CallbackUserData {
        HardwareDecoder* self;
    };
    CallbackUserData cbUserData_;

    /** 获取 OH_AVCodec MIME 类型字符串 */
    static const char* GetMimeType(CodecType codec);

    // OH_AVCodec 回调 (static, 通过 userData → this 转发)
    static void OnError(OH_AVCodec* codec, int32_t errorCode, void* userData);
    static void OnStreamChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData);
    static void OnNeedInputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);
    static void OnNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);
    static void OnFrameAvailable(void* context);

    size_t clearInputQueueLocked();
    size_t dropOldestInputFramesLocked(size_t count);
    void handleInputBuffer(uint32_t index, OH_AVBuffer* buffer);
    void drainInputBuffers();
    bool waitForFrameAvailable();
    void handleOutputBuffer(uint32_t index);
    void noteFrameAvailable();
    void stopRenderThread();
    void renderLoop();
};

// ============================================================
// NAPI 包装 (定义在 hw_decoder.cpp)
// ============================================================

namespace DecoderNapi {
    napi_value Init(napi_env env, napi_value exports);
    int DecodeNative(int64_t handle, const VideoFrame& frame);
    int DecodeActiveNative(const VideoFrame& frame);
    int ActiveVideoPressureLevel();
    bool BindVideoPipeline(int64_t decoderHandle, int64_t rendererHandle);
    bool DetachVideoPipeline(int64_t decoderHandle);
    bool RequestDecoderRecovery(int64_t decoderHandle);
    void DeactivateDecoder(int64_t decoderHandle);
    void DestroyDecoderHandle(int64_t decoderHandle);
}

#endif // HW_DECODER_H
