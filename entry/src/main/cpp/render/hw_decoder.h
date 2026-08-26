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

#include "decoder_callback_gate.h"
#include "callback_admission_context.h"
#include "extensions/protocol_adapter.h"
#include "native_image_context_policy.h"
#include "video_perf_counters.h"
#include "video_backpressure_controller.h"
#include <GLES3/gl3.h>
#include <napi/native_api.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_DECODER_INTERNAL __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_DECODER_INTERNAL
#endif

// OH_AVCodec / NativeImage 前向声明
struct OH_AVCodec;
struct OH_AVFormat;
struct OH_AVBuffer;
struct OH_NativeImage;
// OHNativeWindow: 使用 void* 存储避免与 SDK typedef 冲突

using DecoderSessionIdentity = Render::DecoderSessionIdentity;

struct DecoderTelemetrySnapshot {
    bool valid = false;
    bool ready = false;
    bool software = false;
    int codec = 0;
    int width = 0;
    int height = 0;
    size_t queueDepth = 0;
    size_t queueMax = 0;
    DecoderSessionIdentity owner;
    uint64_t decoderGeneration = 0;
    uint64_t displayGeneration = 0;
    int display = -1;
    uint64_t inputDroppedFrames = 0;
    uint64_t droppedFrames = 0;
    uint64_t waitKeyframeDrops = 0;
    uint64_t dropCounterGeneration = 0;
    int64_t codecLatencyMs = 0;
    int64_t codecLatencyMaxMs = 0;
    bool lowLatencyEnabled = false;
};

// Private native presentation proof kept separate from the established
// diagnostics DTO so existing RDP/RustDesk/VNC NAPI output and ABI remain
// byte-for-byte stable.
struct REMOTEDESK_DECODER_INTERNAL DecoderPresentationTelemetrySnapshot {
    bool valid = false;
    bool ready = false;
    bool hardware = false;
    int codec = 0;
    int width = 0;
    int height = 0;
    DecoderSessionIdentity owner {};
    int64_t decoderHandle = 0;
    int64_t rendererHandle = 0;
    uint64_t decoderGeneration = 0;
    uint64_t displayGeneration = 0;
    int display = -1;
    uint64_t rendererGeneration = 0;
    uint64_t renderedOutputBuffers = 0;
    uint64_t nativeImageFrames = 0;
    uint64_t rendererPresentedFrames = 0;
    size_t queueDepth = 0;
    uint64_t inputDroppedFrames = 0;
    uint64_t waitKeyframeDrops = 0;
    uint64_t inputTruncated = 0;
    uint64_t renderOutputFailures = 0;
    uint64_t updateSurfaceFailures = 0;
    uint64_t coalescedSurfaceNotifications = 0;
    int64_t codecLatencyMs = 0;
    int64_t codecLatencyMaxMs = 0;
    bool lowLatencyEnabled = false;
};

struct REMOTEDESK_DECODER_INTERNAL OwnedDecoderCreationResult {
    bool ok = false;
    int64_t decoderHandle = 0;
    uint64_t decoderGeneration = 0;
    uint64_t displayGeneration = 0;
    int display = -1;
    uint64_t rendererGeneration = 0;
};

struct HardwareTelemetrySnapshot {
    size_t queueDepth = 0;
    uint64_t inputDroppedFrames = 0;
    uint64_t waitKeyframeDrops = 0;
    uint64_t inputTruncated = 0;
    uint64_t renderOutputFailures = 0;
    uint64_t updateSurfaceFailures = 0;
    uint64_t coalescedSurfaceNotifications = 0;
    uint64_t renderedOutputBuffers = 0;
    uint64_t outputFrames = 0;
    int64_t codecLatencyMs = 0;
    int64_t codecLatencyMaxMs = 0;
    CodecType codec = CodecType::H264;
    bool initialized = false;
    bool lowLatencyEnabled = false;
};

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

enum class REMOTEDESK_DECODER_INTERNAL HardwareDecodeAdmission : uint8_t {
    Queued,
    Backpressure,
    NeedKeyframe,
    Failed,
};

/** 解码帧就绪回调 */
using DecoderFrameCallback = std::function<void(GLuint textureId, int width, int height,
    const Render::NativeImageTransform& textureTransform)>;
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

struct SubmittedFrameTiming {
    int64_t timestamp;
    std::chrono::steady_clock::time_point submittedAt;
};

/**
 * HardwareDecoder — 硬件视频解码器 (OH_AVCodec Surface 模式)
 *
 * 每个远程桌面连接创建一个实例。
 * 解码 H.264/H.265 编码帧，输出 GL 纹理 ID 供渲染器直接采样。
 * 回调在解码器内部线程执行, 所有状态访问通过 mutex_ 保护。
 */
class HardwareDecoder : public std::enable_shared_from_this<HardwareDecoder> {
public:
    // Internal result consumed by DecodeNativeLocked and translated to the
    // public DecoderNapi admission result. It must never escape directly
    // because DecoderNapi reserves other positive values for owner/display
    // admission decisions.
    static constexpr int kDecodeKeyframeRequired = 1;

    HardwareDecoder();
    ~HardwareDecoder();

    /**
     * 初始化解码器
     * @param width   视频宽度
     * @param height  视频高度
     * @param codec   编码类型 (H264 或 H265)
     * @return 0=成功, 负数=错误码
     */
    int Init(int width, int height, CodecType codec, int64_t rendererHandle = -1,
             bool desktopSurfaceCompatibility = false,
             Render::NativeImagePresentationMode presentationMode =
                 Render::NativeImagePresentationMode::Identity);

    /** Update the protocol-owned OES orientation without rebuilding AVCodec. */
    void SetNativeImagePresentationMode(
        Render::NativeImagePresentationMode presentationMode);

    /**
     * 送入编码帧数据 (线程安全, 入队等待解码器回调取走)
     * @param data       编码帧数据 (调用方保证生命周期)
     * @param size       数据大小 (bytes)
     * @param timestamp  时间戳 (微秒)
     * @return 0=成功
     */
    int Decode(const uint8_t* data, size_t size, uint64_t timestamp, bool isKeyFrame = false);
    REMOTEDESK_DECODER_INTERNAL int DecodeOwned(
        const uint8_t* data, size_t size, uint64_t timestamp, bool isKeyFrame,
        HardwareDecodeAdmission& admission);

    /** Bind the opaque DecoderContext token before OH_AVCodec is started. */
    bool SetCallbackIdentity(int64_t token, const DecoderSessionIdentity& owner,
                             uint64_t generation);
    /** Stop platform callback admission before codec/image teardown. */
    void BeginCallbackTeardown();

    /**
     * 获取 NativeImage 的 GL 纹理 ID
     * 用于零拷贝绑定到 GLRenderer
     */
    GLuint GetTextureId() const;

    /** Wake the render owner to redraw the retained NativeImage texture. */
    void RequestRedraw();

    /** 刷新解码器缓冲区 */
    void Flush();

    /** 销毁解码器 */
    void Destroy();

    /** 是否已初始化 */
    bool IsInitialized() const { return initialized_; }

    /** 当前解码器编码类型 */
    CodecType GetCodecType() const { return codecType_; }
    size_t QueuedFrameCount() const;
    uint64_t InputDroppedFrameCount() const;
    uint64_t DroppedFrameCount() const;
    HardwareTelemetrySnapshot GetTelemetrySnapshot() const;
    uint64_t WaitKeyframeDroppedFrameCount() const;

    /** 检测解码器是否过载 (基于丢帧/截断/输出失败) */
    bool IsOverloaded() const;

    /** 获取过载原因字符串 */
    std::string OverloadReason() const;

    /** 设置帧就绪回调 */
    void SetFrameCallback(DecoderFrameCallback callback);
    void SetMakeCurrentCallback(DecoderMakeCurrentCallback callback);
    void SetReleaseCurrentCallback(DecoderReleaseCurrentCallback callback);
    void StartRenderThread();
    /** Clear presentation failure state when a new Surface bind is published. */
    void ResetSurfaceRecoveryForBind();
    bool StopRenderThreadForDetach();
    /** Deferred owners wait on the render done fence outside the caller. */
    void WaitForRenderThreadForDeferredDestroy();

    /** 设置错误回调 */
    void SetErrorCallback(DecoderErrorCallback callback);

    /** Reset cumulative telemetry at a decoder/stream generation boundary. */
    void ResetTelemetryCounters();

    // Bounded render teardown. A platform output call that is still
    // unwinding keeps the decoder in the explicit shared retire owner until
    // the render done fence is published; it is never detached or destroyed
    // underneath the worker.
    bool FinishDeferredDestroy();

#if defined(RDP_NATIVE_CALLBACK_TESTING)
    // Keep these test-only accessors out-of-line. The callback test addon and
    // its production host are separate DSOs; an inline accessor would read
    // HardwareDecoder layout from the caller DSO instead of the defining DSO.
    void* CallbackUserDataForTesting() const;
    std::shared_ptr<Render::CallbackAdmissionContext> CallbackContextForTesting() const;
    bool HoldCallbackAdmissionForTesting();
    void ReleaseCallbackAdmissionForTesting();
    void MarkPlatformResourceLiveForTesting();
    int PlatformResourceDestroyCountForTesting() const;
    int PlatformResourceStopCountForTesting() const;
    int PlatformResourceUnsetCountForTesting() const;
    size_t PendingInputBufferCountForTesting() const;
    uint64_t FrameAvailableCountForTesting() const;
    // Inject a failure after the selected Init stage so the real Init failure
    // path can be exercised with the same deferred retire owner as Destroy.
    void SetInitFailureStageForTesting(int stage);
    static void InvokeErrorCallbackForTesting(OH_AVCodec* codec, int32_t errorCode,
                                              void* userData) {
        OnError(codec, errorCode, userData);
    }
    static void InvokeStreamChangedCallbackForTesting(OH_AVCodec* codec,
                                                      OH_AVFormat* format,
                                                      void* userData) {
        OnStreamChanged(codec, format, userData);
    }
    static void InvokeNeedInputCallbackForTesting(OH_AVCodec* codec, uint32_t index,
                                                  OH_AVBuffer* buffer, void* userData) {
        OnNeedInputBuffer(codec, index, buffer, userData);
    }
    static void InvokeNewOutputCallbackForTesting(OH_AVCodec* codec, uint32_t index,
                                                  OH_AVBuffer* buffer, void* userData) {
        OnNewOutputBuffer(codec, index, buffer, userData);
    }
    static void InvokeFrameAvailableCallbackForTesting(void* userData) {
        OnFrameAvailable(userData);
    }
#endif

    // R2: 测试用 — 获取解码器原始指针用于 testDecoderH264
    OH_AVCodec* GetDecoder() const { return decoder_; }

private:
    OH_AVCodec*     decoder_ = nullptr;        // OH_VideoDecoder 实例
    OH_NativeImage* nativeImage_ = nullptr;    // NativeImage (零拷贝纹理)
    void*          nativeWindow_ = nullptr;     // OHNativeWindow* (从 NativeImage 获取, 存为 void* 避免头文件冲突)
    GLuint          textureId_ = 0;            // NativeImage 关联的 GL 纹理 ID
    Render::NativeImageTransform textureTransform_ =
        Render::IdentityNativeImageTransform();
    bool            desktopSurfaceCompatibility_ = false;
    std::atomic<Render::NativeImagePresentationMode> presentationMode_ {
        Render::NativeImagePresentationMode::Identity};
    std::atomic<bool> textureTransformLogged_ {false};
    int             width_ = 0;
    int             height_ = 0;
    CodecType       codecType_ = CodecType::H264;
    bool            initialized_ = false;

    DecoderCallbackGate<DecoderFrameCallback> frameCallbackGate_;
    DecoderCallbackGate<DecoderMakeCurrentCallback> makeCurrentCallbackGate_;
    DecoderCallbackGate<DecoderReleaseCurrentCallback> releaseCurrentCallbackGate_;
    DecoderCallbackGate<DecoderErrorCallback> errorCallbackGate_;

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
    std::atomic<uint64_t> renderedOutputBufferCount_ {0};
    std::atomic<uint64_t> updateSurfaceFailureCount_ {0};
    std::atomic<uint64_t> coalescedSurfaceNotificationCount_ {0};
    std::atomic<uint64_t> inputPushFailureCount_ {0};
    std::atomic<uint64_t> outputFrameCount_ {0};
    mutable std::mutex telemetryMutex_;
    std::deque<SubmittedFrameTiming> submittedFrameTimings_;
    uint64_t codecLatencySampleCount_ = 0;
    int64_t codecLatencyMs_ = 0;
    int64_t codecLatencyMaxMs_ = 0;
    bool lowLatencyEnabled_ = false;
    std::condition_variable frameAvailableCv_;
    uint64_t frameAvailableCount_ = 0;
    uint64_t frameConsumeCount_ = 0;
    bool surfaceUpdatePending_ = false;
    std::chrono::steady_clock::time_point surfaceRetryAt_ =
        std::chrono::steady_clock::time_point::min();
    int consecutiveSurfaceUpdateFailures_ = 0;
    // Once the NativeImage surface is known to be invalid, stop retrying on
    // every output notification. DecoderContext owns the bounded recreation
    // decision; this flag only prevents a render-thread recovery storm.
    std::atomic<bool> surfaceRecoveryBlocked_ {false};
    std::condition_variable inputCv_;
    std::thread inputThread_;
    std::atomic<bool> inputThreadStop_ {true};
    mutable std::mutex inputThreadMutex_;
    std::condition_variable inputThreadDoneCv_;
    bool inputThreadDone_ = true;
    // A transform wake is a latest-value hint, not one render obligation per
    // pinch event. Keep at most one retained redraw pending behind the render
    // owner so a fast UI gesture cannot build a decoder-side backlog.
    bool redrawRequested_ = false;
    Render::VideoBackpressureController backpressure_;
    bool nativeImageContextAttached_ = false;
    std::thread renderThread_;
    std::atomic<bool> renderThreadStop_ {false};
    mutable std::mutex renderThreadMutex_;
    std::condition_variable renderThreadCv_;
    bool renderThreadDone_ = true;
    std::atomic<bool> renderDestroyDeferred_ {false};

    // Stable callback context. Platform userData never points at this object.
    std::shared_ptr<Render::CallbackAdmissionContext> callbackContext_;
    DecoderSessionIdentity callbackOwner_;
    std::shared_ptr<std::atomic<int>> callbackResourceDestroyCount_ =
        std::make_shared<std::atomic<int>>(0);
    std::shared_ptr<std::atomic<int>> callbackResourceStopCount_ =
        std::make_shared<std::atomic<int>>(0);
    std::shared_ptr<std::atomic<int>> callbackResourceUnsetCount_ =
        std::make_shared<std::atomic<int>>(0);
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    bool testPlatformResourceLive_ = false;
    std::atomic<int> testInitFailureStage_ {-1};
#endif
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    // Test-only lease storage stays inside the production host DSO. The
    // addon observes only the bool/void boundary and never moves a callback
    // lease or reads CallbackAdmissionContext layout across DSOs.
    std::unique_ptr<Render::CallbackAdmissionContext::Lease> callbackTestLease_;
#endif

    /** 获取 OH_AVCodec MIME 类型字符串 */
    static const char* GetMimeType(CodecType codec);

    // OH_AVCodec 回调 (static, 通过 userData → this 转发)
    static void OnError(OH_AVCodec* codec, int32_t errorCode, void* userData);
    static void OnStreamChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData);
    static void OnNeedInputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);
    static void OnNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);
    static void OnFrameAvailable(void* context);

    size_t clearInputQueueLocked();
    size_t dropOldestNonKeyFramesLocked(size_t count);
    void handleInputBuffer(uint32_t index, OH_AVBuffer* buffer);
    void recordInputSubmission(int64_t timestamp,
                               std::chrono::steady_clock::time_point submittedAt);
    void discardInputSubmission(int64_t timestamp,
                                std::chrono::steady_clock::time_point submittedAt);
    void recordOutputLatency(int64_t timestamp);
    void drainInputBuffers();
    void inputLoop();
    void startInputThread();
    bool stopInputThread();
    void waitForInputThreadForDeferredDestroy();
    bool waitForRenderRequest(bool& hasNewFrame, bool& hasPendingSurfaceUpdate,
                              uint64_t& frameSequence);
    void handleOutputBuffer(uint32_t index);
    void noteFrameAvailable();
    bool stopRenderThread();
    void renderLoop();
};

// ============================================================
// NAPI 包装 (定义在 hw_decoder.cpp)
// ============================================================

namespace DecoderNapi {
    constexpr int kDecodeInactiveDisplay = 1;
    constexpr int kDecodeInactiveSession = 2;
    // Software decode admission results. These are intentionally positive:
    // the frame was dropped by latency recovery rather than rejected by the
    // decoder, so callers must not classify it as a decode error.
    constexpr int kDecodeSoftwareFrameDropped = 3;
    constexpr int kDecodeSoftwareKeyframeRequired = 4;
    constexpr int kDecodeHardwareKeyframeRequired = 5;
    enum class OwnedSubmitStatus : uint8_t {
        Accepted,
        // The current frame was queued, but an older dependent frame was
        // evicted to preserve latency. Keep admitting later frames while the
        // caller requests an IDR out of band.
        AcceptedNeedsKeyframe,
        Backpressure,
        NeedKeyframe,
        Stale,
        Failed,
    };
    napi_value Init(napi_env env, napi_value exports);
    int DecodeNative(int64_t handle, const VideoFrame& frame);
    int DecodeActiveNative(const DecoderSessionIdentity& owner, const VideoFrame& frame);
    /** Exact-owner typed boundary for non-NAPI protocol sinks. */
    REMOTEDESK_DECODER_INTERNAL OwnedSubmitStatus DecodeOwnedNative(
        int64_t decoderHandle, uint64_t decoderGeneration,
        uint64_t displayGeneration, const DecoderSessionIdentity& owner,
        const VideoFrame& frame);
    bool IsActiveSessionOwner(const DecoderSessionIdentity& owner);
    bool IsActiveDisplayFrame(const DecoderSessionIdentity& owner, const VideoFrame& frame);
    DecoderTelemetrySnapshot GetActiveTelemetry(const DecoderSessionIdentity& expectedOwner);
    REMOTEDESK_DECODER_INTERNAL DecoderPresentationTelemetrySnapshot
    GetActivePresentationTelemetry(const DecoderSessionIdentity& expectedOwner);
    /** Create and bind the existing hardware decoder for one exact native owner. */
    REMOTEDESK_DECODER_INTERNAL OwnedDecoderCreationResult
    CreateOwnedHardwareDecoder(int width, int height, int codec,
                               int64_t rendererHandle,
                               const DecoderSessionIdentity& owner,
                               bool desktopSurfaceCompatibility = false);
    void SetActiveSessionId(const DecoderSessionIdentity& owner);
    void ClearActiveSessionId(const DecoderSessionIdentity& owner);
    bool SetActiveNativeImagePresentationMode(
        const DecoderSessionIdentity& owner,
        Render::NativeImagePresentationMode presentationMode);
    bool SetActiveDisplay(const DecoderSessionIdentity& owner, int display);
    bool RequestActiveDecoderRecovery(const DecoderSessionIdentity& owner);
    /** Rebind a surviving decoder to the current renderer after transport continuity. */
    bool RebindActiveVideoPipeline(const DecoderSessionIdentity& owner);
    /** Exact hidden rebind seam for a protocol-owned detached decoder. */
    REMOTEDESK_DECODER_INTERNAL bool RebindOwnedVideoPipeline(
        int64_t decoderHandle, uint64_t decoderGeneration,
        int64_t rendererHandle, uint64_t rendererGeneration,
        const DecoderSessionIdentity& owner);
    bool BindVideoPipeline(int64_t decoderHandle, int64_t rendererHandle);
    bool BindVideoPipeline(int64_t decoderHandle, int64_t rendererHandle,
                           const DecoderSessionIdentity& owner);
    bool DetachVideoPipeline(int64_t decoderHandle);
    bool DetachVideoPipeline(int64_t decoderHandle, const DecoderSessionIdentity& owner);
    bool RequestDecoderRecovery(int64_t decoderHandle);
    bool RequestDecoderRecovery(int64_t decoderHandle, const DecoderSessionIdentity& owner);
    void DeactivateDecoder(int64_t decoderHandle);
    void DeactivateDecoder(int64_t decoderHandle, const DecoderSessionIdentity& owner);
    void DestroyDecoderHandle(int64_t decoderHandle);
    void DestroyDecoderHandle(int64_t decoderHandle, const DecoderSessionIdentity& owner);
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    std::shared_ptr<HardwareDecoder> RegisterCallbackTestDecoder(
        const DecoderSessionIdentity& owner, int64_t& handle);
    bool SetCallbackTestPipelineState(int64_t handle,
                                      const DecoderSessionIdentity& owner,
                                      bool attached, bool transitioning);
    bool PublishCallbackTestDecoder(
        int64_t handle, const DecoderSessionIdentity& owner);
    OwnedSubmitStatus DecodeOwnedNativeForTesting(
        int64_t decoderHandle, uint64_t decoderGeneration,
        uint64_t displayGeneration, const DecoderSessionIdentity& owner,
        const VideoFrame& frame);
    DecoderPresentationTelemetrySnapshot GetActivePresentationTelemetryForTesting(
        const DecoderSessionIdentity& expectedOwner);
    void DestroyCallbackTestDecoder(int64_t handle, const DecoderSessionIdentity& owner);
#endif
}

#undef REMOTEDESK_DECODER_INTERNAL

#endif // HW_DECODER_H
