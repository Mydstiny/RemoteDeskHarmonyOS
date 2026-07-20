/**
 * hw_decoder.cpp — 硬件视频解码器 + NAPI 包装
 *
 * OH_AVCodec Surface 模式: 解码帧 → NativeImage GL纹理 → GLRenderer 零拷贝渲染
 * R2: 从 Mock 迁移到真实 OH_AVCodec API (OH_VideoDecoder_*)
 */

#include "hw_decoder.h"
#include "decoder_recovery_policy.h"
#include "software_decoder.h"
#include "software_decode_latency_policy.h"
#include "gl_renderer.h"
#include "native_image_context_policy.h"
#include <napi/native_api.h>
#include <hilog/log.h>
#include <cstring>
#include <atomic>
#include <chrono>
#include <deque>
#include <vector>
#include <native_image/native_image.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avbuffer_info.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>  // GL_TEXTURE_EXTERNAL_OES

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0004
#define LOG_TAG "HW_DECODER"

namespace {
constexpr size_t kMaxQueuedFrames = 12;  // was 4 — too small for 45+fps w/ safe drop policy
}

// ============================================================
// HardwareDecoder: 静态回调转发
// ============================================================

void HardwareDecoder::OnError(OH_AVCodec* /*codec*/, int32_t errorCode, void* userData) {
    auto* cb = static_cast<CallbackUserData*>(userData);
    OH_LOG_ERROR(LOG_APP, "[Decoder] 解码器错误: code=%{public}d", errorCode);
    if (cb && cb->self && cb->self->errorCallback_) {
        cb->self->errorCallback_(DecoderError::OUTPUT_FAILED,
            "OH_AVCodec error " + std::to_string(errorCode));
    }
}

void HardwareDecoder::OnStreamChanged(OH_AVCodec* /*codec*/, OH_AVFormat* /*format*/, void* userData) {
    (void)userData;
    OH_LOG_INFO(LOG_APP, "[Decoder] 码流格式变更");
}

void HardwareDecoder::OnNeedInputBuffer(OH_AVCodec* /*codec*/, uint32_t index,
                                         OH_AVBuffer* buffer, void* userData) {
    auto* self = static_cast<CallbackUserData*>(userData)->self;
    self->handleInputBuffer(index, buffer);
}

void HardwareDecoder::OnNewOutputBuffer(OH_AVCodec* codec, uint32_t index,
                                         OH_AVBuffer* /*buffer*/, void* userData) {
    auto* self = static_cast<CallbackUserData*>(userData)->self;
    OH_AVErrCode ret = OH_VideoDecoder_RenderOutputBuffer(codec, index);
    if (ret != AV_ERR_OK) {
        if (self) {
            ++self->renderOutputFailureCount_;
        }
        OH_LOG_WARN(LOG_APP, "[Decoder] RenderOutputBuffer failed: %{public}d index=%{public}u",
                    ret, index);
        return;
    }
    // NativeImage/GL is consumed by the dedicated render thread after OnFrameAvailable.
}

void HardwareDecoder::OnFrameAvailable(void* context) {
    auto* cb = static_cast<CallbackUserData*>(context);
    if (cb && cb->self) {
        cb->self->noteFrameAvailable();
    }
}

// ============================================================
// HardwareDecoder 实现
// ============================================================

HardwareDecoder::HardwareDecoder() {
    cbUserData_.self = this;
}

HardwareDecoder::~HardwareDecoder() {
    Destroy();
}

const char* HardwareDecoder::GetMimeType(CodecType codec) {
    switch (codec) {
        case CodecType::AV1:
            return OH_AVCODEC_MIMETYPE_VIDEO_AV1;
        case CodecType::VP9:
            return OH_AVCODEC_MIMETYPE_VIDEO_VP9;
        case CodecType::VP8:
            return OH_AVCODEC_MIMETYPE_VIDEO_VP8;
        case CodecType::H265:
            return OH_AVCODEC_MIMETYPE_VIDEO_HEVC;
        case CodecType::H264:
        default:
            return OH_AVCODEC_MIMETYPE_VIDEO_AVC;
    }
}

int HardwareDecoder::Init(int width, int height, CodecType codec) {
    OH_LOG_INFO(LOG_APP, "[Decoder] Init: %{public}dx%{public}d codec=%{public}s",
                width, height, GetMimeType(codec));

    width_ = width;
    height_ = height;
    codecType_ = codec;
    auto releaseTexture = [this]() {
        if (textureId_ != 0) {
            glDeleteTextures(1, &textureId_);
            textureId_ = 0;
        }
    };

    // 1. 创建解码器
    decoder_ = OH_VideoDecoder_CreateByMime(GetMimeType(codec));
    if (!decoder_) {
        OH_LOG_ERROR(LOG_APP, "[Decoder] OH_VideoDecoder_CreateByMime 失败");
        return -1;
    }

    // 2. 注册回调 (必须在 Configure 之前)
    OH_AVCodecCallback cb;
    cb.onError = OnError;
    cb.onStreamChanged = OnStreamChanged;
    cb.onNeedInputBuffer = OnNeedInputBuffer;
    cb.onNewOutputBuffer = OnNewOutputBuffer;
    OH_AVErrCode ret = OH_VideoDecoder_RegisterCallback(decoder_, cb, &cbUserData_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Decoder] RegisterCallback 失败: %{public}d", ret);
        OH_VideoDecoder_Destroy(decoder_);
        decoder_ = nullptr;
        return -2;
    }

    // 3. 创建 NativeImage 并获取 surface (零拷贝纹理)
    //    textureTarget = GL_TEXTURE_EXTERNAL_OES, 由 GLRenderer 采样
    glGenTextures(1, &textureId_);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, textureId_);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    GLenum glErr = glGetError();
    if (textureId_ == 0 || glErr != GL_NO_ERROR) {
        OH_LOG_ERROR(LOG_APP, "[Decoder] 创建 GL 外部纹理失败: texture=%{public}u err=%{public}x",
                     textureId_, glErr);
        releaseTexture();
        OH_VideoDecoder_Destroy(decoder_);
        decoder_ = nullptr;
        return -3;
    }

    nativeImage_ = OH_NativeImage_Create(textureId_, GL_TEXTURE_EXTERNAL_OES);
    if (!nativeImage_) {
        OH_LOG_ERROR(LOG_APP, "[Decoder] OH_NativeImage_Create 失败");
        releaseTexture();
        OH_VideoDecoder_Destroy(decoder_);
        decoder_ = nullptr;
        return -3;
    }
    OH_OnFrameAvailableListener listener;
    listener.context = &cbUserData_;
    listener.onFrameAvailable = OnFrameAvailable;
    int32_t imageRet = OH_NativeImage_SetOnFrameAvailableListener(nativeImage_, listener);
    if (imageRet != 0) {
        OH_LOG_WARN(LOG_APP, "[Decoder] SetOnFrameAvailableListener failed: %{public}d", imageRet);
    }
    imageRet = OH_NativeImage_SetDropBufferMode(nativeImage_, true);
    if (imageRet != 0) {
        OH_LOG_WARN(LOG_APP, "[Decoder] SetDropBufferMode failed: %{public}d", imageRet);
    }
    nativeWindow_ = OH_NativeImage_AcquireNativeWindow(nativeImage_);
    if (!nativeWindow_) {
        OH_LOG_ERROR(LOG_APP, "[Decoder] AcquireNativeWindow 失败");
        OH_NativeImage_Destroy(&nativeImage_);
        releaseTexture();
        OH_VideoDecoder_Destroy(decoder_);
        decoder_ = nullptr;
        return -4;
    }

    // 4. 配置解码器参数
    OH_AVFormat* format = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height);
    // Surface 模式不需要 OH_MD_KEY_PIXEL_FORMAT

    ret = OH_VideoDecoder_Configure(decoder_, format);
    OH_AVFormat_Destroy(format);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Decoder] Configure 失败: %{public}d", ret);
        OH_NativeImage_Destroy(&nativeImage_);
        releaseTexture();
        OH_VideoDecoder_Destroy(decoder_);
        decoder_ = nullptr;
        return -6;
    }

    // 5. 设置解码输出 surface。必须在 Prepare 前，且部分设备要求 Configure 后调用。
    ret = OH_VideoDecoder_SetSurface(decoder_, static_cast<OHNativeWindow*>(nativeWindow_));
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Decoder] SetSurface 失败: %{public}d", ret);
        OH_NativeImage_Destroy(&nativeImage_);
        releaseTexture();
        OH_VideoDecoder_Destroy(decoder_);
        decoder_ = nullptr;
        return -5;
    }

    // 6. Prepare
    ret = OH_VideoDecoder_Prepare(decoder_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Decoder] Prepare 失败: %{public}d", ret);
        OH_NativeImage_Destroy(&nativeImage_);
        releaseTexture();
        OH_VideoDecoder_Destroy(decoder_);
        decoder_ = nullptr;
        return -7;
    }

    // 7. Start
    ret = OH_VideoDecoder_Start(decoder_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Decoder] Start 失败: %{public}d", ret);
        OH_NativeImage_Destroy(&nativeImage_);
        releaseTexture();
        OH_VideoDecoder_Destroy(decoder_);
        decoder_ = nullptr;
        return -8;
    }

    initialized_ = true;
    OH_LOG_INFO(LOG_APP, "[Decoder] ✓ 解码器启动成功 (Surface模式, %{public}dx%{public}d texture=%{public}u)",
                width, height, textureId_);
    return 0;
}

size_t HardwareDecoder::clearInputQueueLocked() {
    size_t dropped = 0;
    while (!inputQueue_.empty()) {
        delete[] inputQueue_.front().data;
        inputQueue_.pop_front();
        ++dropped;
    }
    return dropped;
}

size_t HardwareDecoder::dropOldestInputFramesLocked(size_t count) {
    size_t dropped = 0;
    while (dropped < count && !inputQueue_.empty()) {
        delete[] inputQueue_.front().data;
        inputQueue_.pop_front();
        ++dropped;
    }
    return dropped;
}

int HardwareDecoder::Decode(const uint8_t* data, size_t size, uint64_t timestamp, bool isKeyFrame) {
    if (!initialized_) {
        OH_LOG_WARN(LOG_APP, "[Decoder] 解码器未初始化");
        return -1;
    }
    if (!data || size == 0) {
        return 0;
    }

    // 拷贝编码数据到堆, 入队等待 onNeedInputBuffer 回调取走
    auto* copy = new uint8_t[size];
    std::memcpy(copy, data, size);

    size_t queued = 0;
    size_t droppedQueued = 0;
    uint64_t droppedTotal = inputDropCount_.load();
    uint64_t waitDroppedTotal = waitKeyframeDropCount_.load();
    uint64_t recoveryTotal = keyframeRecoveryCount_.load();
    bool droppedIncomingForKeyframe = false;
    bool recoveredWithKeyframe = false;
    bool softDroppedOldFrames = false;
    Render::VideoFrameAdmission admission = Render::VideoFrameAdmission::Accept;
    {
        std::lock_guard<std::mutex> lk(mutex_);
        const bool wasWaitingForKeyframe = backpressure_.isWaitingForKeyframe();
        admission = backpressure_.admitFrame(inputQueue_.size(), isKeyFrame);
        if (admission == Render::VideoFrameAdmission::DropWaitingKeyframe) {
            droppedIncomingForKeyframe = true;
            droppedTotal = inputDropCount_.fetch_add(1) + 1;
            waitDroppedTotal = ++waitKeyframeDropCount_;
        } else {
            if (inputQueue_.size() >= kMaxQueuedFrames) {
                const size_t removeCount = inputQueue_.size() - kMaxQueuedFrames + 1;
                droppedQueued = dropOldestInputFramesLocked(removeCount);
                if (droppedQueued > 0) {
                    softDroppedOldFrames = true;
                    droppedTotal = inputDropCount_.fetch_add(droppedQueued) + droppedQueued;
                }
            }
            if (admission == Render::VideoFrameAdmission::AcceptRecoveryKeyframe && wasWaitingForKeyframe) {
                recoveredWithKeyframe = true;
                recoveryTotal = ++keyframeRecoveryCount_;
            }
            inputQueue_.push_back({copy, size, static_cast<int64_t>(timestamp), isKeyFrame});
            copy = nullptr;
            queued = inputQueue_.size();
        }
    }

    if (copy != nullptr) {
        delete[] copy;
    }

    if (droppedQueued > 0 && (droppedTotal <= 16 || droppedTotal % 60 == 0)) {
        OH_LOG_WARN(LOG_APP,
                    "[Decoder] queue overflow: dropped_old=%{public}zu total=%{public}llu soft=%{public}s need_keyframe=%{public}s recoveries=%{public}llu",
                    droppedQueued,
                    static_cast<unsigned long long>(droppedTotal),
                    softDroppedOldFrames ? "yes" : "no",
                    backpressure_.shouldRequestKeyframe() ? "yes" : "no",
                    static_cast<unsigned long long>(recoveryTotal));
    }
    if (droppedIncomingForKeyframe) {
        if (waitDroppedTotal <= 16 || waitDroppedTotal % 60 == 0) {
            OH_LOG_WARN(LOG_APP,
                        "[Decoder] wait-keyframe drop non-key input total=%{public}llu size=%{public}zu pts=%{public}llu",
                        static_cast<unsigned long long>(waitDroppedTotal),
                        size,
                        static_cast<unsigned long long>(timestamp));
        }
        return 0;
    }
    if (recoveredWithKeyframe) {
        OH_LOG_INFO(LOG_APP,
                    "[Decoder] wait-keyframe recovered with keyframe pts=%{public}llu queue=%{public}zu recoveries=%{public}llu",
                    static_cast<unsigned long long>(timestamp),
                    queued,
                    static_cast<unsigned long long>(recoveryTotal));
    }

    OH_LOG_DEBUG(LOG_APP, "[Decoder] 编码帧入队: %{public}zu bytes ts=%{public}lu queue=%{public}zu",
                 size, (unsigned long)timestamp, queued);
    drainInputBuffers();
    return 0;
}

void HardwareDecoder::handleInputBuffer(uint32_t index, OH_AVBuffer* buffer) {
    {
        std::lock_guard<std::mutex> lk(mutex_);
        pendingInputBuffers_.push_back({index, buffer});
    }
    drainInputBuffers();
}

void HardwareDecoder::drainInputBuffers() {
    while (true) {
        PendingInputBuffer input {};
        EncodedFrame frame {};
        OH_AVCodec* decoder = nullptr;
        size_t queuedFrames = 0;
        size_t pendingBuffers = 0;

        {
            std::lock_guard<std::mutex> lk(mutex_);
            if (!initialized_ || !decoder_ || pendingInputBuffers_.empty() || inputQueue_.empty()) {
                return;
            }
            input = pendingInputBuffers_.front();
            pendingInputBuffers_.pop_front();
            frame = inputQueue_.front();
            inputQueue_.pop_front();
            decoder = decoder_;
            queuedFrames = inputQueue_.size();
            pendingBuffers = pendingInputBuffers_.size();
        }

        if (!input.buffer) {
            OH_LOG_WARN(LOG_APP, "[Decoder] input buffer null index=%{public}u", input.index);
            delete[] frame.data;
            continue;
        }

        uint8_t* bufAddr = OH_AVBuffer_GetAddr(input.buffer);
        int32_t bufCap = OH_AVBuffer_GetCapacity(input.buffer);
        if (!bufAddr || bufCap <= 0) {
            OH_LOG_WARN(LOG_APP, "[Decoder] invalid input buffer index=%{public}u cap=%{public}d",
                        input.index, bufCap);
            delete[] frame.data;
            continue;
        }

        size_t copyLen = (static_cast<size_t>(bufCap) < frame.size) ? static_cast<size_t>(bufCap) : frame.size;
        if (copyLen < frame.size) {
            // T-130: Hard recovery on truncated input — never push truncated encoded data.
            // Enter wait-keyframe mode; decoder will self-recover at next keyframe.
            // Do NOT call OH_VideoDecoder_Flush here — it's too heavy and causes
            // visual freeze by discarding all already-decoded frames.
            uint64_t truncated = ++inputTruncatedCount_;
            size_t droppedQueued = 0;
            {
                std::lock_guard<std::mutex> lk(mutex_);
                droppedQueued = clearInputQueueLocked();
                pendingInputBuffers_.clear();
                backpressure_.enterHardWaitForKeyframe();
            }
            uint64_t recoveryCount = ++keyframeRecoveryCount_;
            OH_LOG_WARN(LOG_APP,
                        "[Decoder] TRUNCATED INPUT: size=%{public}zu cap=%{public}d truncated_total=%{public}llu dropped_queued=%{public}zu recoveries=%{public}llu waiting_for_keyframe",
                        frame.size, bufCap,
                        static_cast<unsigned long long>(truncated),
                        droppedQueued,
                        static_cast<unsigned long long>(recoveryCount));
            delete[] frame.data;
            continue;
        }
        std::memcpy(bufAddr, frame.data, copyLen);

        OH_AVCodecBufferAttr attr;
        attr.pts = frame.timestamp;
        attr.size = static_cast<int32_t>(copyLen);
        attr.offset = 0;
        attr.flags = 0;
        OH_AVBuffer_SetBufferAttr(input.buffer, &attr);

        OH_AVErrCode ret = OH_VideoDecoder_PushInputBuffer(decoder, input.index);
        if (ret != AV_ERR_OK) {
            OH_LOG_WARN(LOG_APP, "[Decoder] PushInputBuffer failed: %{public}d index=%{public}u",
                        ret, input.index);
        } else {
            uint64_t count = ++inputPushCount_;
            if (count <= 5 || count % 60 == 0) {
                OH_LOG_INFO(LOG_APP,
                            "[Decoder] PushInputBuffer #%{public}llu size=%{public}zu pts=%{public}lld queued=%{public}zu pending=%{public}zu",
                            static_cast<unsigned long long>(count),
                            copyLen,
                            static_cast<long long>(frame.timestamp),
                            queuedFrames,
                            pendingBuffers);
            }
        }

        delete[] frame.data;
    }
}

void HardwareDecoder::noteFrameAvailable() {
    {
        std::lock_guard<std::mutex> lk(mutex_);
        ++frameAvailableCount_;
    }
    frameAvailableCv_.notify_one();
}

bool HardwareDecoder::waitForFrameAvailable() {
    std::unique_lock<std::mutex> lk(mutex_);
    bool ok = frameAvailableCv_.wait_for(lk, std::chrono::milliseconds(50), [this]() {
        return renderThreadStop_.load() || !initialized_ || frameAvailableCount_ > frameConsumeCount_;
    });
    if (ok && !renderThreadStop_.load() && initialized_ && frameAvailableCount_ > frameConsumeCount_) {
        ++frameConsumeCount_;
        return true;
    }
    return false;
}

void HardwareDecoder::handleOutputBuffer(uint32_t /*index*/) {
    if (!nativeImage_) { return; }

    if (!waitForFrameAvailable()) {
        return;
    }

    if (makeCurrentCallback_) {
        makeCurrentCallback_();
    }

    if (!nativeImageContextAttached_) {
        int32_t attachRet = OH_NativeImage_AttachContext(nativeImage_, textureId_);
        if (Render::ShouldRetryNativeImageAttach(attachRet, false)) {
            int32_t detachRet = OH_NativeImage_DetachContext(nativeImage_);
            OH_LOG_WARN(LOG_APP,
                        "[Decoder] AttachContext failed: %{public}d texture=%{public}u, detach stale context ret=%{public}d",
                        attachRet,
                        textureId_,
                        detachRet);
            attachRet = OH_NativeImage_AttachContext(nativeImage_, textureId_);
        }
        if (attachRet == 0) {
            nativeImageContextAttached_ = true;
            OH_LOG_INFO(LOG_APP, "[Decoder] NativeImage attached to current GL context texture=%{public}u",
                        textureId_);
        } else {
            OH_LOG_WARN(LOG_APP, "[Decoder] AttachContext failed: %{public}d texture=%{public}u",
                        attachRet, textureId_);
        }
    }

    // 更新 NativeImage — 解码帧已写入 surface, 刷新 GL 纹理
    int32_t ret = OH_NativeImage_UpdateSurfaceImage(nativeImage_);
    if (ret != 0) {
        ++updateSurfaceFailureCount_;
        OH_LOG_WARN(LOG_APP, "[Decoder] UpdateSurfaceImage 失败: %{public}d", ret);
        return;
    }

    // 通知渲染器: 纹理就绪
    if (frameCallback_) {
        frameCallback_(textureId_, width_, height_);
    }
    uint64_t count = ++outputFrameCount_;
    if (count <= 3 || count % 300 == 0) {
        OH_LOG_INFO(LOG_APP,
                    "[Decoder] output frame #%{public}llu texture=%{public}u size=%{public}dx%{public}d drops=%{public}llu waitDrops=%{public}llu trunc=%{public}llu renderFail=%{public}llu updateFail=%{public}llu",
                    static_cast<unsigned long long>(count),
                    textureId_,
                    width_,
                    height_,
                    static_cast<unsigned long long>(inputDropCount_.load()),
                    static_cast<unsigned long long>(waitKeyframeDropCount_.load()),
                    static_cast<unsigned long long>(inputTruncatedCount_.load()),
                    static_cast<unsigned long long>(renderOutputFailureCount_.load()),
                    static_cast<unsigned long long>(updateSurfaceFailureCount_.load()));
    }
}

void HardwareDecoder::StartRenderThread() {
    if (renderThread_.joinable()) {
        return;
    }
    renderThreadStop_.store(false);
    renderThread_ = std::thread(&HardwareDecoder::renderLoop, this);
}

void HardwareDecoder::stopRenderThread() {
    renderThreadStop_.store(true);
    frameAvailableCv_.notify_all();
    if (renderThread_.joinable()) {
        renderThread_.join();
    }
}

void HardwareDecoder::renderLoop() {
    OH_LOG_INFO(LOG_APP, "[Decoder] render thread started");
    while (!renderThreadStop_.load()) {
        handleOutputBuffer(0);
    }
    if (Render::ShouldDetachNativeImageOnRenderThreadStop(nativeImageContextAttached_, nativeImage_ != nullptr)) {
        int32_t detachRet = OH_NativeImage_DetachContext(nativeImage_);
        OH_LOG_INFO(LOG_APP, "[Decoder] NativeImage detached from GL context ret=%{public}d texture=%{public}u",
                    detachRet,
                    textureId_);
    }
    if (releaseCurrentCallback_) {
        releaseCurrentCallback_();
    }
    nativeImageContextAttached_ = false;
    OH_LOG_INFO(LOG_APP, "[Decoder] render thread stopped");
}

void HardwareDecoder::StopRenderThreadForDetach() {
    stopRenderThread();
    SetFrameCallback(nullptr);
    SetMakeCurrentCallback(nullptr);
    SetReleaseCurrentCallback(nullptr);
    nativeImageContextAttached_ = false;
}

GLuint HardwareDecoder::GetTextureId() const {
    return textureId_;
}

void HardwareDecoder::Flush() {
    if (initialized_ && decoder_) {
        OH_LOG_INFO(LOG_APP, "[Decoder] Flush");
        OH_VideoDecoder_Flush(decoder_);
        std::lock_guard<std::mutex> lk(mutex_);
        clearInputQueueLocked();
        pendingInputBuffers_.clear();
        backpressure_.reset();
    }
}

size_t HardwareDecoder::QueuedFrameCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return inputQueue_.size();
}

uint64_t HardwareDecoder::DroppedFrameCount() const {
    return inputDropCount_.load() + waitKeyframeDropCount_.load();
}

void HardwareDecoder::Destroy() {
    stopRenderThread();
    if (initialized_) {
        OH_LOG_INFO(LOG_APP, "[Decoder] Destroy");
        if (decoder_) {
            OH_VideoDecoder_Stop(decoder_);
            OH_VideoDecoder_Destroy(decoder_);
            decoder_ = nullptr;
        }
        if (nativeImage_) {
            OH_NativeImage_Destroy(&nativeImage_);
            nativeImage_ = nullptr;
        }
        if (textureId_ != 0) {
            if (makeCurrentCallback_) {
                makeCurrentCallback_();
            }
            glDeleteTextures(1, &textureId_);
            textureId_ = 0;
            if (releaseCurrentCallback_) {
                releaseCurrentCallback_();
            }
        }
        nativeWindow_ = nullptr;
        initialized_ = false;

        // 清空未处理的输入队列
        std::lock_guard<std::mutex> lk(mutex_);
        clearInputQueueLocked();
        pendingInputBuffers_.clear();
        backpressure_.reset();
    }
}

void HardwareDecoder::SetFrameCallback(DecoderFrameCallback callback) {
    frameCallback_ = std::move(callback);
}

void HardwareDecoder::SetMakeCurrentCallback(DecoderMakeCurrentCallback callback) {
    makeCurrentCallback_ = std::move(callback);
}

void HardwareDecoder::SetReleaseCurrentCallback(DecoderReleaseCurrentCallback callback) {
    releaseCurrentCallback_ = std::move(callback);
}

void HardwareDecoder::SetErrorCallback(DecoderErrorCallback callback) {
    errorCallback_ = std::move(callback);
}

// ============================================================
// H.264 最小 IDR 帧 — 64×64 蓝色测试画面
// 编码: SPS + PPS + IDR slice (YUV all-blue)
// ============================================================

static const uint8_t H264_BLUE_IDR_64x64[] = {
    // SPS (baseline profile, level 1.0, 64x64)
    0x00, 0x00, 0x00, 0x01,  // start code
    0x67,                      // NALU header: SPS, baseline
    0x42, 0x00, 0x0A,         // profile_idc=66, constraint, level_idc=10
    0xE8,                      // seq_parameter_set_id, log2_max_frame_num
    0x01,                      // pic_order_cnt_type
    0x41,                      // num_ref_frames
    0xB2, 0x11, 0x20,         // pic_width=64, pic_height=64
    0x50, 0x00, 0x04, 0x68, 0xEA, 0x43, 0xBC,
    // PPS
    0x00, 0x00, 0x00, 0x01,  // start code
    0x68,                      // NALU header: PPS
    0xEB, 0xE3, 0x04, 0x20,
    // IDR slice — 64×64 all blue (Cb=128, Cr=255 in YCbCr → U=128, V=0 in NV21)
    0x00, 0x00, 0x00, 0x01,  // start code
    0x65,                      // NALU header: IDR
    0x88, 0x84, 0x00, 0x5F, 0xFE, 0xBC, 0x95, 0xAA,
    0x00, 0x00, 0x00, 0x01,  // End of stream
};

static const size_t H264_BLUE_IDR_SIZE = sizeof(H264_BLUE_IDR_64x64);

// ============================================================
// NAPI 包装
// ============================================================

namespace {

struct SoftQueuedFrame {
    std::vector<uint8_t> data;
    VideoFrame frame;
};

struct DecoderContext {
    std::shared_ptr<HardwareDecoder> decoder;
    std::shared_ptr<SoftwareDecoder> softwareDecoder;
    bool useSoftware = false;
    int64_t rendererHandle = 0;
    int width = 0;
    int height = 0;

    std::mutex softMutex;
    std::condition_variable softCv;
    std::thread softThread;
    std::deque<SoftQueuedFrame> softQueue;
    bool softStop = false;
    bool softWaitingKeyframe = false;
    std::atomic<uint64_t> softQueued {0};
    std::atomic<uint64_t> softDecoded {0};
    std::atomic<uint64_t> softDropped {0};
    std::atomic<uint64_t> softSkippedPresent {0};
    std::atomic<bool> recoveryRequested {false};
};

static std::atomic<int64_t> g_activeDecoderHandle {0};
constexpr size_t kMaxSoftwareDecodeQueue = 30;

void StopSoftwareWorker(DecoderContext* ctx) {
    if (!ctx) {
        return;
    }
    {
        std::lock_guard<std::mutex> lk(ctx->softMutex);
        ctx->softStop = true;
        ctx->softQueue.clear();
        ctx->softWaitingKeyframe = false;
    }
    ctx->softCv.notify_all();
    if (ctx->softThread.joinable()) {
        ctx->softThread.join();
    }
    ctx->softStop = false;
}

void StartSoftwareWorkerIfNeeded(DecoderContext* ctx) {
    if (!ctx || ctx->softThread.joinable()) {
        return;
    }
    ctx->softStop = false;
    ctx->softThread = std::thread([ctx]() {
        OH_LOG_INFO(LOG_APP, "[Decoder] software decode worker started");
        while (true) {
            SoftQueuedFrame item;
            size_t queueLeft = 0;
            {
                std::unique_lock<std::mutex> lk(ctx->softMutex);
                ctx->softCv.wait(lk, [ctx]() {
                    return ctx->softStop || !ctx->softQueue.empty();
                });
                if (ctx->softStop) {
                    break;
                }
                item = std::move(ctx->softQueue.front());
                ctx->softQueue.pop_front();
                queueLeft = ctx->softQueue.size();
            }

            if (!ctx->softwareDecoder || !ctx->softwareDecoder->IsInitialized() || item.data.empty()) {
                continue;
            }
            item.frame.data = item.data.data();
            item.frame.size = item.data.size();
            const bool presentOutput = Render::shouldPresentSoftwareDecodedFrame(queueLeft);
            if (!presentOutput) {
                ctx->softSkippedPresent.fetch_add(1);
            }
            const int ret = ctx->softwareDecoder->Decode(item.frame.data, item.frame.size,
                                                         item.frame.timestamp, item.frame.isKeyFrame,
                                                         presentOutput);
            const uint64_t decoded = ctx->softDecoded.fetch_add(1) + 1;
            if (decoded <= 5 || decoded % 120 == 0 || ret != 0 || queueLeft > 8 || !presentOutput) {
                OH_LOG_INFO(LOG_APP,
                            "[Decoder] software worker frame=%{public}llu ret=%{public}d codec=%{public}d size=%{public}zu queue=%{public}zu dropped=%{public}llu present=%{public}s skippedPresent=%{public}llu key=%{public}s",
                            static_cast<unsigned long long>(decoded),
                            ret,
                            static_cast<int>(item.frame.codec),
                            item.frame.size,
                            queueLeft,
                            static_cast<unsigned long long>(ctx->softDropped.load()),
                            presentOutput ? "yes" : "no",
                            static_cast<unsigned long long>(ctx->softSkippedPresent.load()),
                            item.frame.isKeyFrame ? "yes" : "no");
            }
        }
        OH_LOG_INFO(LOG_APP, "[Decoder] software decode worker stopped");
    });
}

int QueueSoftwareFrame(DecoderContext* ctx, const VideoFrame& frame) {
    if (!ctx || !ctx->softwareDecoder || !ctx->softwareDecoder->IsInitialized() || !frame.data || frame.size == 0) {
        return -1;
    }
    StartSoftwareWorkerIfNeeded(ctx);

    SoftQueuedFrame item;
    item.data.resize(frame.size);
    std::memcpy(item.data.data(), frame.data, frame.size);
    item.frame = frame;
    item.frame.data = nullptr;
    item.frame.size = item.data.size();

    size_t queueSize = 0;
    uint64_t dropped = 0;
    {
        std::lock_guard<std::mutex> lk(ctx->softMutex);
        if (ctx->softWaitingKeyframe && !frame.isKeyFrame) {
            dropped = ctx->softDropped.fetch_add(1) + 1;
            if (dropped <= 8 || dropped % 60 == 0) {
                OH_LOG_WARN(LOG_APP,
                            "[Decoder] software queue waiting keyframe drop total=%{public}llu size=%{public}zu",
                            static_cast<unsigned long long>(dropped), frame.size);
            }
            return 0;
        }
        if (ctx->softQueue.size() >= kMaxSoftwareDecodeQueue) {
            const size_t removed = ctx->softQueue.size();
            ctx->softQueue.clear();
            ctx->softWaitingKeyframe = !frame.isKeyFrame;
            dropped = ctx->softDropped.fetch_add(removed + (frame.isKeyFrame ? 0 : 1)) + removed + (frame.isKeyFrame ? 0 : 1);
            OH_LOG_WARN(LOG_APP,
                        "[Decoder] software queue overflow removed=%{public}zu totalDropped=%{public}llu incomingKey=%{public}s",
                        removed,
                        static_cast<unsigned long long>(dropped),
                        frame.isKeyFrame ? "yes" : "no");
            if (!frame.isKeyFrame) {
                return 0;
            }
        }
        ctx->softWaitingKeyframe = false;
        ctx->softQueue.push_back(std::move(item));
        queueSize = ctx->softQueue.size();
    }
    ctx->softCv.notify_one();
    const uint64_t queued = ctx->softQueued.fetch_add(1) + 1;
    if (queued <= 5 || queued % 300 == 0 || queueSize > 8) {
        OH_LOG_INFO(LOG_APP,
                    "[Decoder] software queued frame=%{public}llu codec=%{public}d size=%{public}zu queue=%{public}zu key=%{public}s",
                    static_cast<unsigned long long>(queued),
                    static_cast<int>(frame.codec),
                    frame.size,
                    queueSize,
                    frame.isKeyFrame ? "yes" : "no");
    }
    return 0;
}

CodecType CurrentCodec(const DecoderContext* ctx) {
    if (!ctx) {
        return CodecType::H264;
    }
    if (ctx->useSoftware && ctx->softwareDecoder) {
        return ctx->softwareDecoder->GetCodecType();
    }
    if (ctx->decoder) {
        return ctx->decoder->GetCodecType();
    }
    return CodecType::H264;
}

bool ConfigurePipeline(DecoderContext* ctx) {
    if (!ctx || ctx->rendererHandle <= 0) {
        return false;
    }

    const int64_t rendererHandle = ctx->rendererHandle;
    if (ctx->useSoftware) {
        if (!ctx->softwareDecoder || !ctx->softwareDecoder->IsInitialized()) {
            return false;
        }
        RendererNapi::SetActiveRenderer(rendererHandle);
        RendererNapi::SetActiveSourceSize(ctx->softwareDecoder->GetWidth(), ctx->softwareDecoder->GetHeight());
        ctx->softwareDecoder->SetFrameCallback([](const uint8_t* data, size_t size, int width, int height, int stride) {
            return RendererNapi::RenderRawBgraActive(data, size, width, height, stride);
        });
        return true;
    }

    if (!ctx->decoder || !ctx->decoder->IsInitialized()) {
        return false;
    }
    ctx->decoder->SetMakeCurrentCallback([rendererHandle]() {
        RendererNapi::MakeCurrent(rendererHandle);
    });
    ctx->decoder->SetReleaseCurrentCallback([rendererHandle]() {
        RendererNapi::ReleaseCurrent(rendererHandle);
    });
    ctx->decoder->SetFrameCallback([rendererHandle](GLuint textureId, int width, int height) {
        OH_LOG_DEBUG(LOG_APP, "[Decoder] output texture=%{public}u size=%{public}dx%{public}d",
                     textureId, width, height);
        RendererNapi::RenderNative(rendererHandle, textureId);
    });
    RendererNapi::ReleaseCurrent(rendererHandle);
    ctx->decoder->StartRenderThread();
    return true;
}

bool RecreateDecoderForFrame(DecoderContext* ctx, const VideoFrame& frame) {
    if (!ctx || frame.width <= 0 || frame.height <= 0) {
        return false;
    }

    StopSoftwareWorker(ctx);
    if (ctx->decoder) {
        ctx->decoder->Destroy();
        ctx->decoder.reset();
    }
    if (ctx->softwareDecoder) {
        ctx->softwareDecoder->Destroy();
        ctx->softwareDecoder.reset();
    }
    ctx->useSoftware = false;

    auto decoder = std::shared_ptr<HardwareDecoder>(new HardwareDecoder());
    if (ctx->rendererHandle > 0) {
        RendererNapi::MakeCurrent(ctx->rendererHandle);
    }
    int result = decoder->Init(frame.width, frame.height, frame.codec);
    if (ctx->rendererHandle > 0) {
        RendererNapi::ReleaseCurrent(ctx->rendererHandle);
    }
    if (result == 0) {
        ctx->decoder = decoder;
        ctx->width = frame.width;
        ctx->height = frame.height;
        if (!ConfigurePipeline(ctx)) {
            ctx->decoder->Destroy();
            ctx->decoder.reset();
            return false;
        }
        OH_LOG_INFO(LOG_APP,
                    "[Decoder] native pipeline recreated with hardware codec=%{public}s size=%{public}dx%{public}d",
                    SoftwareDecoder::CodecName(frame.codec), frame.width, frame.height);
        return true;
    }

    if (SoftwareDecoder::Supports(frame.codec)) {
        auto softwareDecoder = std::shared_ptr<SoftwareDecoder>(new SoftwareDecoder());
        int softResult = softwareDecoder->Init(frame.width, frame.height, frame.codec);
        if (softResult == 0) {
            ctx->softwareDecoder = softwareDecoder;
            ctx->useSoftware = true;
            ctx->width = frame.width;
            ctx->height = frame.height;
            if (!ConfigurePipeline(ctx)) {
                ctx->softwareDecoder->Destroy();
                ctx->softwareDecoder.reset();
                ctx->useSoftware = false;
                return false;
            }
            OH_LOG_INFO(LOG_APP,
                        "[Decoder] native pipeline recreated with software codec=%{public}s size=%{public}dx%{public}d hw=%{public}d",
                        SoftwareDecoder::CodecName(frame.codec), frame.width, frame.height, result);
            return true;
        }
        OH_LOG_ERROR(LOG_APP,
                     "[Decoder] native pipeline recreate failed codec=%{public}s hw=%{public}d soft=%{public}d",
                     SoftwareDecoder::CodecName(frame.codec), result, softResult);
        return false;
    }

    OH_LOG_ERROR(LOG_APP,
                 "[Decoder] native pipeline recreate failed codec=%{public}s hw=%{public}d soft=unsupported",
                 SoftwareDecoder::CodecName(frame.codec), result);
    return false;
}

/**
 * NAPI: initDecoder(width: number, height: number, codec: number): number
 */
napi_value NapiInitDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t width, height, codecInt;
    napi_get_value_int32(env, args[0], &width);
    napi_get_value_int32(env, args[1], &height);
    napi_get_value_int32(env, args[2], &codecInt);

    CodecType codec = static_cast<CodecType>(codecInt);

    auto decoder = std::shared_ptr<HardwareDecoder>(new HardwareDecoder());
    int result = decoder->Init(width, height, codec);
    if (result == 0) {
        auto* ctx = new DecoderContext();
        ctx->decoder = decoder;
        ctx->useSoftware = false;
        ctx->width = width;
        ctx->height = height;
        napi_value handle;
        napi_create_int64(env, reinterpret_cast<int64_t>(ctx), &handle);
        return handle;
    }

    if (SoftwareDecoder::Supports(codec)) {
        auto softwareDecoder = std::shared_ptr<SoftwareDecoder>(new SoftwareDecoder());
        int softResult = softwareDecoder->Init(width, height, codec);
        if (softResult == 0) {
            auto* ctx = new DecoderContext();
            ctx->softwareDecoder = softwareDecoder;
            ctx->useSoftware = true;
            ctx->width = width;
            ctx->height = height;
            napi_value handle;
            napi_create_int64(env, reinterpret_cast<int64_t>(ctx), &handle);
            OH_LOG_INFO(LOG_APP, "[Decoder] NAPI initDecoder 使用软件后备 codec=%{public}s",
                        SoftwareDecoder::CodecName(codec));
            return handle;
        }
        OH_LOG_ERROR(LOG_APP,
            "[Decoder] NAPI initDecoder 失败: hw=%{public}d soft=%{public}d codec=%{public}s",
            result, softResult, SoftwareDecoder::CodecName(codec));
        napi_value errVal;
        napi_create_int32(env, softResult, &errVal);
        return errVal;
    }

    OH_LOG_ERROR(LOG_APP, "[Decoder] NAPI initDecoder 失败: %{public}d", result);
    napi_value errVal;
    napi_create_int32(env, result, &errVal);
    return errVal;
}

/**
 * NAPI: decodeFrame(handle: number, data: ArrayBuffer, size: number, timestamp: number): number
 */
napi_value NapiDecodeFrame(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t handleVal;
    napi_get_value_int64(env, args[0], &handleVal);
    auto* ctx = reinterpret_cast<DecoderContext*>(handleVal);

    void* data;
    size_t size;
    napi_get_arraybuffer_info(env, args[1], &data, &size);

    int64_t timestamp;
    napi_get_value_int64(env, args[3], &timestamp);

    int result = -1;
    if (ctx && ctx->useSoftware && ctx->softwareDecoder) {
        result = ctx->softwareDecoder->Decode(static_cast<const uint8_t*>(data), size,
                                              static_cast<uint64_t>(timestamp));
    } else if (ctx && ctx->decoder) {
        result = ctx->decoder->Decode(static_cast<const uint8_t*>(data), size,
                                      static_cast<uint64_t>(timestamp));
    }

    napi_value retVal;
    napi_create_int32(env, result, &retVal);
    return retVal;
}

/**
 * NAPI: getTextureId(handle: number): number
 */
napi_value NapiGetTextureId(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t handleVal;
    napi_get_value_int64(env, args[0], &handleVal);
    auto* ctx = reinterpret_cast<DecoderContext*>(handleVal);

    int32_t texId = 0;
    if (ctx && !ctx->useSoftware && ctx->decoder) {
        texId = static_cast<int32_t>(ctx->decoder->GetTextureId());
    }

    napi_value retVal;
    napi_create_int32(env, texId, &retVal);
    return retVal;
}

/**
 * NAPI: destroyDecoder(handle: number): void
 */
napi_value NapiDestroyDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t handleVal;
    napi_get_value_int64(env, args[0], &handleVal);
    DecoderNapi::DeactivateDecoder(handleVal);
    DecoderNapi::DestroyDecoderHandle(handleVal);

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * R2: testDecoderH264(handle: number): number
 * 送入内嵌 H.264 蓝色 IDR 帧验证解码→上屏闭环
 */
napi_value NapiTestDecoderH264(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t handleVal;
    napi_get_value_int64(env, args[0], &handleVal);
    auto* ctx = reinterpret_cast<DecoderContext*>(handleVal);

    if (!ctx || ctx->useSoftware || !ctx->decoder || !ctx->decoder->IsInitialized()) {
        OH_LOG_WARN(LOG_APP, "[Decoder] testDecoderH264: 解码器未就绪");
        napi_value r; napi_create_int32(env, -1, &r); return r;
    }

    int ret = ctx->decoder->Decode(H264_BLUE_IDR_64x64, H264_BLUE_IDR_SIZE, 0);
    OH_LOG_INFO(LOG_APP, "[Decoder] testDecoderH264: 已送入 %{public}zu bytes, ret=%{public}d",
                H264_BLUE_IDR_SIZE, ret);
    napi_value r; napi_create_int32(env, ret, &r); return r;
}

/**
 * NAPI: bindVideoPipeline(decoderHandle: number, rendererHandle: number): boolean
 */
napi_value NapiBindVideoPipeline(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t decoderHandle = 0;
    int64_t rendererHandle = 0;
    napi_get_value_int64(env, args[0], &decoderHandle);
    napi_get_value_int64(env, args[1], &rendererHandle);

    bool ok = DecoderNapi::BindVideoPipeline(decoderHandle, rendererHandle);
    napi_value ret;
    napi_get_boolean(env, ok, &ret);
    return ret;
}

/**
 * NAPI: detachVideoPipeline(decoderHandle: number): boolean
 */
napi_value NapiDetachVideoPipeline(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t decoderHandle = 0;
    napi_get_value_int64(env, args[0], &decoderHandle);

    bool ok = DecoderNapi::DetachVideoPipeline(decoderHandle);
    napi_value ret;
    napi_get_boolean(env, ok, &ret);
    return ret;
}

/**
 * NAPI: requestDecoderRecovery(decoderHandle: number): boolean
 */
napi_value NapiRequestDecoderRecovery(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t decoderHandle = 0;
    napi_get_value_int64(env, args[0], &decoderHandle);

    bool ok = DecoderNapi::RequestDecoderRecovery(decoderHandle);
    napi_value ret;
    napi_get_boolean(env, ok, &ret);
    return ret;
}

} // anonymous namespace

int DecoderNapi::DecodeNative(int64_t handle, const VideoFrame& frame) {
    auto* ctx = reinterpret_cast<DecoderContext*>(handle);
    if (!ctx) {
        OH_LOG_WARN(LOG_APP, "[Decoder] native decode skipped: decoder not ready");
        return -1;
    }
    if (frame.codec != CodecType::H264 && frame.codec != CodecType::H265 &&
        frame.codec != CodecType::VP8 && frame.codec != CodecType::VP9 &&
        frame.codec != CodecType::AV1) {
        OH_LOG_WARN(LOG_APP, "[Decoder] native decode skipped: unsupported codec=%{public}d size=%{public}zu",
                    static_cast<int>(frame.codec), frame.size);
        return -2;
    }
    if (Render::ShouldDropFrameWhileWaitingRecoveryKeyframe(
        ctx->recoveryRequested.load(), frame.isKeyFrame)) {
        static std::atomic<uint64_t> recoveryWaitDrops {0};
        const uint64_t dropped = recoveryWaitDrops.fetch_add(1) + 1;
        if (dropped <= 8 || dropped % 60 == 0) {
            OH_LOG_WARN(LOG_APP,
                        "[Decoder] recovery waiting keyframe drop total=%{public}llu codec=%{public}d size=%{public}zu",
                        static_cast<unsigned long long>(dropped),
                        static_cast<int>(frame.codec),
                        frame.size);
        }
        return 0;
    }
    if (Render::ShouldDecodeFrameTriggerRecovery(ctx->recoveryRequested.load(), frame.isKeyFrame)) {
        OH_LOG_INFO(LOG_APP,
                    "[Decoder] recovery recreating decoder from keyframe codec=%{public}d size=%{public}dx%{public}d bytes=%{public}zu",
                    static_cast<int>(frame.codec),
                    frame.width,
                    frame.height,
                    frame.size);
        if (!RecreateDecoderForFrame(ctx, frame)) {
            return -3;
        }
        ctx->recoveryRequested.store(false);
    }

    const CodecType currentCodec = CurrentCodec(ctx);
    if (frame.codec != currentCodec) {
        OH_LOG_WARN(LOG_APP,
                    "[Decoder] native codec changed: decoder=%{public}d frame=%{public}d size=%{public}zu key=%{public}s frameSize=%{public}dx%{public}d",
                    static_cast<int>(currentCodec),
                    static_cast<int>(frame.codec),
                    frame.size,
                    frame.isKeyFrame ? "yes" : "no",
                    frame.width,
                    frame.height);
        if (!frame.isKeyFrame) {
            return -3;
        }
        if (!RecreateDecoderForFrame(ctx, frame)) {
            return -3;
        }
    }

    if (ctx->useSoftware) {
        if (!ctx->softwareDecoder || !ctx->softwareDecoder->IsInitialized()) {
            OH_LOG_WARN(LOG_APP, "[Decoder] native software decode skipped: decoder not ready");
            return -1;
        }
        return QueueSoftwareFrame(ctx, frame);
    }
    if (!ctx->decoder || !ctx->decoder->IsInitialized()) {
        OH_LOG_WARN(LOG_APP, "[Decoder] native decode skipped: decoder not ready");
        return -1;
    }
    return ctx->decoder->Decode(frame.data, frame.size, frame.timestamp, frame.isKeyFrame);
}

int DecoderNapi::DecodeActiveNative(const VideoFrame& frame) {
    int64_t handle = g_activeDecoderHandle.load();
    if (handle <= 0) {
        OH_LOG_WARN(LOG_APP, "[Decoder] native decode skipped: no active video pipeline");
        return -1;
    }
    return DecodeNative(handle, frame);
}

void DecoderNapi::DeactivateDecoder(int64_t handle) {
    if (handle <= 0) {
        return;
    }
    int64_t expected = handle;
    g_activeDecoderHandle.compare_exchange_strong(expected, 0);
}

void DecoderNapi::DestroyDecoderHandle(int64_t handle) {
    if (handle <= 0) {
        return;
    }
    auto* ctx = reinterpret_cast<DecoderContext*>(handle);
    if (!ctx) {
        return;
    }
    StopSoftwareWorker(ctx);
    if (ctx->decoder) {
        ctx->decoder->Destroy();
    }
    if (ctx->softwareDecoder) {
        ctx->softwareDecoder->Destroy();
    }
    delete ctx;
}

int DecoderNapi::ActiveVideoPressureLevel() {
    int64_t handle = g_activeDecoderHandle.load();
    auto* ctx = reinterpret_cast<DecoderContext*>(handle);
    if (!ctx) {
        return 0;
    }
    size_t queueDepth = 0;
    uint64_t dropped = 0;
    if (ctx->useSoftware) {
        std::lock_guard<std::mutex> lk(ctx->softMutex);
        queueDepth = ctx->softQueue.size();
        dropped = ctx->softDropped.load();
    } else if (ctx->decoder) {
        queueDepth = ctx->decoder->QueuedFrameCount();
        dropped = ctx->decoder->DroppedFrameCount();
    }
    if (queueDepth >= 12 || dropped >= 10) {
        return 3;
    }
    if (queueDepth >= 8 || dropped >= 4) {
        return 2;
    }
    if (queueDepth >= 4) {
        return 1;
    }
    return 0;
}

bool DecoderNapi::BindVideoPipeline(int64_t decoderHandle, int64_t rendererHandle) {
    auto* ctx = reinterpret_cast<DecoderContext*>(decoderHandle);
    if (!ctx || rendererHandle <= 0) {
        OH_LOG_WARN(LOG_APP, "[Decoder] bindVideoPipeline failed: decoder=%{public}lld renderer=%{public}lld",
                    static_cast<long long>(decoderHandle), static_cast<long long>(rendererHandle));
        return false;
    }

    ctx->rendererHandle = rendererHandle;
    if (!ConfigurePipeline(ctx)) {
        OH_LOG_WARN(LOG_APP, "[Decoder] bindVideoPipeline failed: decoder=%{public}lld renderer=%{public}lld soft=%{public}s",
                    static_cast<long long>(decoderHandle),
                    static_cast<long long>(rendererHandle),
                    ctx->useSoftware ? "yes" : "no");
        return false;
    }

    g_activeDecoderHandle.store(decoderHandle);
    OH_LOG_INFO(LOG_APP, "[Decoder] bindVideoPipeline %{public}s ok decoder=%{public}lld renderer=%{public}lld",
                ctx->useSoftware ? "software" : "hardware",
                static_cast<long long>(decoderHandle),
                static_cast<long long>(rendererHandle));
    return true;
}

bool DecoderNapi::DetachVideoPipeline(int64_t decoderHandle) {
    auto* ctx = reinterpret_cast<DecoderContext*>(decoderHandle);
    if (!ctx) {
        OH_LOG_WARN(LOG_APP, "[Decoder] detachVideoPipeline failed: decoder=%{public}lld",
                    static_cast<long long>(decoderHandle));
        return false;
    }

    if (ctx->useSoftware) {
        if (ctx->softwareDecoder) {
            ctx->softwareDecoder->SetFrameCallback(nullptr);
        }
    } else if (ctx->decoder) {
        ctx->decoder->StopRenderThreadForDetach();
    }
    ctx->rendererHandle = 0;
    if (g_activeDecoderHandle.load() == decoderHandle) {
        g_activeDecoderHandle.store(0);
    }
    OH_LOG_INFO(LOG_APP, "[Decoder] detachVideoPipeline ok decoder=%{public}lld mode=%{public}s",
                static_cast<long long>(decoderHandle),
                ctx->useSoftware ? "software" : "hardware");
    return true;
}

bool DecoderNapi::RequestDecoderRecovery(int64_t decoderHandle) {
    auto* ctx = reinterpret_cast<DecoderContext*>(decoderHandle);
    if (!ctx) {
        OH_LOG_WARN(LOG_APP, "[Decoder] requestDecoderRecovery failed: decoder=%{public}lld",
                    static_cast<long long>(decoderHandle));
        return false;
    }
    if (!Render::ShouldRequestDecoderRecoveryAfterForegroundRestore(
        true, decoderHandle, ctx->rendererHandle)) {
        OH_LOG_WARN(LOG_APP,
                    "[Decoder] requestDecoderRecovery skipped: decoder=%{public}lld renderer=%{public}lld",
                    static_cast<long long>(decoderHandle),
                    static_cast<long long>(ctx->rendererHandle));
        return false;
    }
    ctx->recoveryRequested.store(true);
    OH_LOG_INFO(LOG_APP,
                "[Decoder] requestDecoderRecovery armed decoder=%{public}lld renderer=%{public}lld",
                static_cast<long long>(decoderHandle),
                static_cast<long long>(ctx->rendererHandle));
    return true;
}

// ============================================================
// DecoderNapi::Init
// ============================================================

napi_value DecoderNapi::Init(napi_env env, napi_value exports) {
    napi_value fn;

    napi_create_function(env, "initDecoder", NAPI_AUTO_LENGTH,
                         NapiInitDecoder, nullptr, &fn);
    napi_set_named_property(env, exports, "initDecoder", fn);

    napi_create_function(env, "decodeFrame", NAPI_AUTO_LENGTH,
                         NapiDecodeFrame, nullptr, &fn);
    napi_set_named_property(env, exports, "decodeFrame", fn);

    napi_create_function(env, "getTextureId", NAPI_AUTO_LENGTH,
                         NapiGetTextureId, nullptr, &fn);
    napi_set_named_property(env, exports, "getTextureId", fn);

    napi_create_function(env, "destroyDecoder", NAPI_AUTO_LENGTH,
                         NapiDestroyDecoder, nullptr, &fn);
    napi_set_named_property(env, exports, "destroyDecoder", fn);

    napi_create_function(env, "testDecoderH264", NAPI_AUTO_LENGTH,
                         NapiTestDecoderH264, nullptr, &fn);
    napi_set_named_property(env, exports, "testDecoderH264", fn);

    napi_create_function(env, "bindVideoPipeline", NAPI_AUTO_LENGTH,
                         NapiBindVideoPipeline, nullptr, &fn);
    napi_set_named_property(env, exports, "bindVideoPipeline", fn);

    napi_create_function(env, "detachVideoPipeline", NAPI_AUTO_LENGTH,
                         NapiDetachVideoPipeline, nullptr, &fn);
    napi_set_named_property(env, exports, "detachVideoPipeline", fn);

    napi_create_function(env, "requestDecoderRecovery", NAPI_AUTO_LENGTH,
                         NapiRequestDecoderRecovery, nullptr, &fn);
    napi_set_named_property(env, exports, "requestDecoderRecovery", fn);

    return exports;
}
