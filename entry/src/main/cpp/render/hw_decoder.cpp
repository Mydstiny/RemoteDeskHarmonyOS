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
#include "decoder_pipeline_lifecycle_policy.h"
#include "decoder_callback_lifecycle_policy.h"
#include "gl_renderer.h"
#include "opaque_handle_registry.h"
#include "native_image_context_policy.h"
#include <napi/native_api.h>
#include <hilog/log.h>
#include <algorithm>
#include <cstring>
#include <atomic>
#include <chrono>
#include <deque>
#include <limits>
#include <memory>
#include <mutex>
#include <vector>
#include <native_image/native_image.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcapability.h>
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

uint64_t SaturatingAdd(std::atomic<uint64_t>& counter, uint64_t delta) {
    if (delta == 0) {
        return counter.load(std::memory_order_acquire);
    }
    uint64_t current = counter.load(std::memory_order_relaxed);
    while (true) {
        const uint64_t next = (current > std::numeric_limits<uint64_t>::max() - delta) ?
            std::numeric_limits<uint64_t>::max() : current + delta;
        if (counter.compare_exchange_weak(current, next,
                                           std::memory_order_acq_rel,
                                           std::memory_order_relaxed)) {
            return next;
        }
    }
}

struct DecoderContext;

using DecoderHandleLease = OpaqueHandleRegistry<DecoderContext>::Lease;

// An input index reported by the asynchronous codec callback remains owned by
// the application until it is pushed back to OH_AVCodec. Even when the frame
// is malformed or does not fit, return an empty/discarded buffer so one bad
// packet cannot permanently reduce the codec's input-buffer pool.
OH_AVErrCode ReturnEmptyInputBuffer(OH_AVCodec* decoder, uint32_t index,
                                    OH_AVBuffer* buffer, int64_t pts) {
    if (decoder == nullptr) {
        return AV_ERR_INVALID_VAL;
    }
    if (buffer != nullptr) {
        OH_AVCodecBufferAttr attr {};
        attr.pts = pts;
        attr.size = 0;
        attr.offset = 0;
        attr.flags = AVCODEC_BUFFER_FLAGS_DISCARD;
        const OH_AVErrCode attrRet = OH_AVBuffer_SetBufferAttr(buffer, &attr);
        if (attrRet != AV_ERR_OK) {
            OH_LOG_WARN(LOG_APP,
                        "[Decoder] empty input attr failed: %{public}d index=%{public}u",
                        attrRet, index);
        }
    }
    const OH_AVErrCode ret = OH_VideoDecoder_PushInputBuffer(decoder, index);
    if (ret != AV_ERR_OK) {
        OH_LOG_WARN(LOG_APP,
                    "[Decoder] empty input recycle failed: %{public}d index=%{public}u",
                    ret, index);
    }
    return ret;
}

struct DecoderCallbackTarget {
    // This is the complete callback-body bundle.  The admission lease is
    // deliberately moved into the bundle instead of being left as a helper
    // argument, so every platform callback keeps all identity/lifetime
    // protections until its final sink/platform call returns.
    Render::CallbackAdmissionContext::Lease callbackLease;
    Render::SessionSinkOwnerLease::Lease ownerLease;
    DecoderHandleLease decoderLease;
    std::shared_ptr<HardwareDecoder> decoder;
    OH_AVCodec* codec = nullptr;
    uint64_t generation = 0;

    explicit operator bool() const {
        return static_cast<bool>(callbackLease) && static_cast<bool>(ownerLease) &&
            static_cast<bool>(decoderLease) && decoder != nullptr;
    }
};

DecoderCallbackTarget AcquireDecoderCallbackTarget(
    Render::CallbackAdmissionContext::Lease callbackLease,
    OH_AVCodec* expectedCodec,
    Render::DecoderCallbackKind callbackKind);

void RetireDecoderCallbackContext(
    std::shared_ptr<Render::CallbackAdmissionContext> context,
    OH_AVCodec* decoder,
    OH_NativeImage* nativeImage,
    bool testResourceLive,
    std::shared_ptr<std::atomic<int>> testDestroyCount,
    std::shared_ptr<std::atomic<int>> testStopCount,
    std::shared_ptr<std::atomic<int>> testUnsetCount) {
    auto cleanup = [decoder, nativeImage, testResourceLive,
                    testDestroyCount = std::move(testDestroyCount),
                    testStopCount = std::move(testStopCount),
                    testUnsetCount = std::move(testUnsetCount)]() mutable {
        if (nativeImage) {
            OH_NativeImage_UnsetOnFrameAvailableListener(nativeImage);
        }
        if (testResourceLive && testUnsetCount) {
            testUnsetCount->fetch_add(1, std::memory_order_release);
        }
        if (decoder) {
            OH_VideoDecoder_Stop(decoder);
        }
        if (testResourceLive && testStopCount) {
            testStopCount->fetch_add(1, std::memory_order_release);
        }
        if (decoder) {
            OH_VideoDecoder_Destroy(decoder);
        }
        if (nativeImage) {
            OH_NativeImage_Destroy(&nativeImage);
        }
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
                    "[Decoder] callback admission timed out but cleanup completed after drain");
    }
}

struct DecoderRetireJob {
    std::shared_ptr<void> keepAlive;
    std::function<bool()> step;
};

class DecoderRetireOwner {
public:
    DecoderRetireOwner() : worker_([this]() { run(); }) {}

    ~DecoderRetireOwner() {
        if (worker_.joinable() && worker_.get_id() != std::this_thread::get_id()) {
            worker_.join();
        }
    }

    bool done() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return workerDone_;
    }

    void enqueue(std::shared_ptr<void> keepAlive, std::function<bool()> step) {
        if (!keepAlive || !step) {
            return;
        }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            pending_.push_back(DecoderRetireJob {
                std::move(keepAlive), std::move(step)});
        }
        cv_.notify_one();
    }

private:
    void run() {
        for (;;) {
            DecoderRetireJob job;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                if (pending_.empty() &&
                    !cv_.wait_for(lock, std::chrono::milliseconds(250), [this]() {
                        return !pending_.empty();
                    })) {
                    workerDone_ = true;
                    return;
                }
                if (pending_.empty()) {
                    continue;
                }
                job = std::move(pending_.front());
                pending_.pop_front();
            }
            // Deferred DestroyDecoderContext runs with deferredOwner=true and
            // waits on pipeline/software/render done fences itself.  It must
            // therefore complete in one owner invocation; requeueing a live
            // decoder every 50 ms would make retirement depend on polling.
            // A false result is an invariant violation: every deferred
            // DestroyDecoderContext path either completes or explicitly
            // transfers ownership to a second queued phase before returning.
            // Consume the result here so a dropped keepAlive can never be
            // mistaken for successful retirement.
            const bool completed = job.step();
            if (!completed) {
                OH_LOG_ERROR(LOG_APP,
                             "[Decoder] retire job returned without terminal or transferred ownership");
            }
            {
                std::lock_guard<std::mutex> lock(mutex_);
                cv_.notify_all();
            }
        }
    }

    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::deque<DecoderRetireJob> pending_;
    std::thread worker_;
    bool workerDone_ = false;
};

DecoderRetireOwner& decoderRetireOwner() {
    static std::mutex ownerMutex;
    static DecoderRetireOwner* owner = nullptr;
    std::lock_guard<std::mutex> lock(ownerMutex);
    if (owner != nullptr && owner->done()) {
        delete owner;
        owner = nullptr;
    }
    if (owner == nullptr) {
        owner = new DecoderRetireOwner();
    }
    return *owner;
}

// A detach/rebind caller owns the decoder object and cannot hand it to the
// retire owner while it is about to reuse the same codec.  Wait only after the
// bounded stop attempt fails; the normal streaming path never waits on codec
// IPC here.
bool StopHardwarePipeline(const std::shared_ptr<HardwareDecoder>& decoder,
                          bool waitForCompletion) {
    if (!decoder || decoder->StopRenderThreadForDetach()) {
        return true;
    }
    if (!waitForCompletion) {
        return false;
    }
    decoder->WaitForRenderThreadForDeferredDestroy();
    return decoder->StopRenderThreadForDetach();
}
}

// ============================================================
// HardwareDecoder: 静态回调转发
// ============================================================

void HardwareDecoder::OnError(OH_AVCodec* codec, int32_t errorCode, void* userData) {
    auto* context = static_cast<Render::CallbackAdmissionContext*>(userData);
    if (!context) {
        return;
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    context->invokeBeforeAcquireHookForTesting();
#endif
    auto callbackLease = context->tryAcquire();
    if (!callbackLease) {
        return;
    }
    auto target = AcquireDecoderCallbackTarget(
        std::move(callbackLease), codec, Render::DecoderCallbackKind::Error);
    if (!target) {
        return;
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    context->invokeAfterAcquireHookForTesting();
#endif
    OH_LOG_ERROR(LOG_APP, "[Decoder] 解码器错误: code=%{public}d", errorCode);
    target.decoder->errorCallbackGate_.Invoke(DecoderError::OUTPUT_FAILED,
        "OH_AVCodec error " + std::to_string(errorCode));
}

void HardwareDecoder::OnStreamChanged(OH_AVCodec* codec, OH_AVFormat* /*format*/, void* userData) {
    auto* context = static_cast<Render::CallbackAdmissionContext*>(userData);
    if (!context) {
        return;
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    context->invokeBeforeAcquireHookForTesting();
#endif
    auto callbackLease = context->tryAcquire();
    auto target = AcquireDecoderCallbackTarget(
        std::move(callbackLease), codec, Render::DecoderCallbackKind::StreamChanged);
    if (!target) {
        return;
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    context->invokeAfterAcquireHookForTesting();
#endif
    OH_LOG_INFO(LOG_APP, "[Decoder] 码流格式变更");
}

void HardwareDecoder::OnNeedInputBuffer(OH_AVCodec* codec, uint32_t index,
                                         OH_AVBuffer* buffer, void* userData) {
    auto* context = static_cast<Render::CallbackAdmissionContext*>(userData);
    if (!context) {
        return;
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    context->invokeBeforeAcquireHookForTesting();
#endif
    auto callbackLease = context->tryAcquire();
    if (!callbackLease) {
        return;
    }
    auto target = AcquireDecoderCallbackTarget(
        std::move(callbackLease), codec, Render::DecoderCallbackKind::InputBuffer);
    if (target) {
#if defined(RDP_NATIVE_CALLBACK_TESTING)
        context->invokeAfterAcquireHookForTesting();
#endif
        target.decoder->handleInputBuffer(index, buffer);
    }
}

void HardwareDecoder::OnNewOutputBuffer(OH_AVCodec* codec, uint32_t index,
                                         OH_AVBuffer* buffer, void* userData) {
    auto* context = static_cast<Render::CallbackAdmissionContext*>(userData);
    if (!context) {
        return;
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    context->invokeBeforeAcquireHookForTesting();
#endif
    auto callbackLease = context->tryAcquire();
    if (!callbackLease) {
        return;
    }
    auto target = AcquireDecoderCallbackTarget(
        std::move(callbackLease), codec, Render::DecoderCallbackKind::OutputBuffer);
    if (!target) {
        return;
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    context->invokeAfterAcquireHookForTesting();
#endif
    if (codec == nullptr) {
        return;
    }
    OH_AVCodecBufferAttr attr {};
    if (buffer != nullptr && OH_AVBuffer_GetBufferAttr(buffer, &attr) == AV_ERR_OK) {
        target.decoder->recordOutputLatency(attr.pts);
    }
    OH_AVErrCode ret = AV_ERR_OK;
    if (Render::ShouldRenderNativeImageImmediately(
            target.decoder->desktopSurfaceCompatibility_)) {
        // The PC Surface implementation rejects the native-fence sync used by
        // RenderOutputBufferAtTime and can retain the newest quiet-desktop
        // frame until the next packet (typically ~500 ms). Remote desktop has
        // no media timeline, so publish PC output as soon as it is decoded.
        ret = OH_VideoDecoder_RenderOutputBuffer(codec, index);
    } else {
        // Preserve the already accepted Phone/Pad path. Frames completed before
        // the same VSYNC may collapse to the newest image without changing the
        // mobile hardware-decoder presentation contract.
        const int64_t renderTimestampNs =
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count();
        ret = OH_VideoDecoder_RenderOutputBufferAtTime(
            codec, index, renderTimestampNs);
    }
    if (ret != AV_ERR_OK) {
        std::lock_guard<std::mutex> telemetryLock(target.decoder->telemetryMutex_);
        SaturatingAdd(target.decoder->renderOutputFailureCount_, 1);
        OH_LOG_WARN(LOG_APP, "[Decoder] RenderOutputBuffer failed: %{public}d index=%{public}u",
                    ret, index);
        return;
    }
    SaturatingAdd(target.decoder->renderedOutputBufferCount_, 1);
    // NativeImage/GL is consumed by the dedicated render thread after OnFrameAvailable.
}

void HardwareDecoder::OnFrameAvailable(void* context) {
    auto* callbackContext = static_cast<Render::CallbackAdmissionContext*>(context);
    if (!callbackContext) {
        return;
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    callbackContext->invokeBeforeAcquireHookForTesting();
#endif
    auto callbackLease = callbackContext->tryAcquire();
    if (!callbackLease) {
        return;
    }
    auto target = AcquireDecoderCallbackTarget(
        std::move(callbackLease), nullptr, Render::DecoderCallbackKind::FrameAvailable);
    if (target) {
#if defined(RDP_NATIVE_CALLBACK_TESTING)
        callbackContext->invokeAfterAcquireHookForTesting();
#endif
        target.decoder->noteFrameAvailable();
    }
}

// ============================================================
// HardwareDecoder 实现
// ============================================================

HardwareDecoder::HardwareDecoder()
    : callbackContext_(std::make_shared<Render::CallbackAdmissionContext>()) {}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
void* HardwareDecoder::CallbackUserDataForTesting() const {
    return callbackContext_.get();
}

std::shared_ptr<Render::CallbackAdmissionContext>
HardwareDecoder::CallbackContextForTesting() const {
    return callbackContext_;
}

bool HardwareDecoder::HoldCallbackAdmissionForTesting() {
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

void HardwareDecoder::ReleaseCallbackAdmissionForTesting() {
    callbackTestLease_.reset();
}

void HardwareDecoder::MarkPlatformResourceLiveForTesting() {
    std::lock_guard<std::mutex> lock(mutex_);
    testPlatformResourceLive_ = true;
}

int HardwareDecoder::PlatformResourceDestroyCountForTesting() const {
    return callbackResourceDestroyCount_
        ? callbackResourceDestroyCount_->load(std::memory_order_acquire) : 0;
}

int HardwareDecoder::PlatformResourceStopCountForTesting() const {
    return callbackResourceStopCount_
        ? callbackResourceStopCount_->load(std::memory_order_acquire) : 0;
}

int HardwareDecoder::PlatformResourceUnsetCountForTesting() const {
    return callbackResourceUnsetCount_
        ? callbackResourceUnsetCount_->load(std::memory_order_acquire) : 0;
}

size_t HardwareDecoder::PendingInputBufferCountForTesting() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return pendingInputBuffers_.size();
}

uint64_t HardwareDecoder::FrameAvailableCountForTesting() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return frameAvailableCount_;
}

void HardwareDecoder::SetInitFailureStageForTesting(int stage) {
    testInitFailureStage_.store(stage, std::memory_order_release);
}
#endif

HardwareDecoder::~HardwareDecoder() {
    Destroy();
}

bool HardwareDecoder::SetCallbackIdentity(
    int64_t token, const DecoderSessionIdentity& owner, uint64_t generation) {
    if (!callbackContext_) {
        callbackContext_ = std::make_shared<Render::CallbackAdmissionContext>();
    }
    const bool bound = callbackContext_->bind(token, owner, generation);
    if (bound) {
        callbackOwner_ = owner;
    }
    return bound;
}

void HardwareDecoder::BeginCallbackTeardown() {
    if (callbackContext_) {
        const bool drained = callbackContext_->closeAndWait();
        if (!drained) {
            OH_LOG_WARN(LOG_APP,
                        "[Decoder] callback admission remains leased; codec cleanup deferred");
        }
    }
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

int HardwareDecoder::Init(int width, int height, CodecType codec, int64_t rendererHandle,
                          bool desktopSurfaceCompatibility,
                          Render::NativeImagePresentationMode presentationMode) {
    OH_LOG_INFO(LOG_APP,
                "[Decoder] Init: %{public}dx%{public}d codec=%{public}s desktopSurface=%{public}s presentation=%{public}s",
                width, height, GetMimeType(codec),
                desktopSurfaceCompatibility ? "yes" : "no",
                Render::NativeImagePresentationModeName(presentationMode));

    // A failed init retires the callback context together with any platform
    // objects that had already registered a callback.  A later reconnect must
    // bind a fresh admission context; reusing the closed context would make
    // every new codec callback fail closed and would also blur generations.
    if (!callbackContext_) {
        callbackContext_ = std::make_shared<Render::CallbackAdmissionContext>();
    }

    width_ = width;
    height_ = height;
    codecType_ = codec;
    desktopSurfaceCompatibility_ = desktopSurfaceCompatibility;
    presentationMode_.store(presentationMode, std::memory_order_release);
    textureTransform_ = Render::IdentityNativeImageTransform();
    textureTransformLogged_.store(false, std::memory_order_release);
    {
        std::lock_guard<std::mutex> lk(mutex_);
        frameAvailableCount_ = 0;
        frameConsumeCount_ = 0;
        redrawRequested_ = false;
        surfaceUpdatePending_ = false;
        surfaceRetryAt_ = std::chrono::steady_clock::time_point::min();
        consecutiveSurfaceUpdateFailures_ = 0;
    }
    auto releaseTexture = [this]() {
        if (textureId_ != 0) {
            glDeleteTextures(1, &textureId_);
            textureId_ = 0;
        }
    };

    bool initContextCurrent = false;
    auto releaseInitContext = [this, rendererHandle, &initContextCurrent]() {
        if (!initContextCurrent || rendererHandle <= 0) {
            return;
        }
        RendererNapi::ReleaseCurrent(rendererHandle, callbackOwner_);
        initContextCurrent = false;
    };

    // Init failures are teardown boundaries too.  Once the codec callback has
    // been registered, every platform object is owned by the same admission
    // context as the normal Destroy path.  In particular, do not call
    // OH_*Destroy directly while a late callback can still hold a lease.
    auto retireInitResources = [this, &releaseTexture, &releaseInitContext](int result) {
        OH_AVCodec* decoder = decoder_;
        OH_NativeImage* nativeImage = nativeImage_;
        decoder_ = nullptr;
        nativeImage_ = nullptr;
        nativeWindow_ = nullptr;
        initialized_ = false;
        releaseTexture();
        releaseInitContext();
        bool testResourceLive = false;
#if defined(RDP_NATIVE_CALLBACK_TESTING)
        {
            std::lock_guard<std::mutex> lock(mutex_);
            testResourceLive = testPlatformResourceLive_;
            testPlatformResourceLive_ = false;
        }
#endif
        RetireDecoderCallbackContext(
            std::move(callbackContext_), decoder, nativeImage, testResourceLive,
            callbackResourceDestroyCount_, callbackResourceStopCount_,
            callbackResourceUnsetCount_);
        return result;
    };
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    const auto failAtStage = [this, &retireInitResources](int stage, int result) {
        int expected = stage;
        if (testInitFailureStage_.compare_exchange_strong(
                expected, -1, std::memory_order_acq_rel,
                std::memory_order_acquire)) {
            return retireInitResources(result);
        }
        return 0;
    };
#endif

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
    OH_AVErrCode ret = OH_VideoDecoder_RegisterCallback(decoder_, cb, callbackContext_.get());
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Decoder] RegisterCallback 失败: %{public}d", ret);
        return retireInitResources(-2);
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    if (const int injected = failAtStage(1, -101); injected != 0) return injected;
#endif

    // 3. 创建 NativeImage 并获取 surface (零拷贝纹理)
    //    textureTarget = GL_TEXTURE_EXTERNAL_OES, 由 GLRenderer 采样
    if (rendererHandle > 0) {
        auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(callbackOwner_);
        if (!ownerLease || !RendererNapi::IsActiveRendererForOwnerUnderLease(
                rendererHandle, callbackOwner_)) {
            OH_LOG_ERROR(LOG_APP, "[Decoder] renderer owner is not active before GL init");
            return retireInitResources(-9);
        }
        RendererNapi::MakeCurrent(rendererHandle, callbackOwner_);
        initContextCurrent = true;
    }
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
        return retireInitResources(-3);
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    if (const int injected = failAtStage(2, -102); injected != 0) return injected;
#endif

    nativeImage_ = OH_NativeImage_Create(textureId_, GL_TEXTURE_EXTERNAL_OES);
    if (!nativeImage_) {
        OH_LOG_ERROR(LOG_APP, "[Decoder] OH_NativeImage_Create 失败");
        return retireInitResources(-3);
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    if (const int injected = failAtStage(3, -103); injected != 0) return injected;
#endif
    OH_OnFrameAvailableListener listener;
    listener.context = callbackContext_.get();
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
        return retireInitResources(-4);
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    if (const int injected = failAtStage(4, -104); injected != 0) return injected;
#endif

    // 4. 配置解码器参数
    OH_AVFormat* format = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height);
    lowLatencyEnabled_ = false;
    if (codec == CodecType::H264 || codec == CodecType::H265) {
        OH_AVCapability* capability = OH_AVCodec_GetCapability(GetMimeType(codec), false);
        const bool supported = capability != nullptr &&
            OH_AVCapability_IsFeatureSupported(capability, VIDEO_LOW_LATENCY);
        if (supported) {
            lowLatencyEnabled_ = OH_AVFormat_SetIntValue(
                format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
        }
        OH_LOG_INFO(LOG_APP,
                    "[Decoder] low-latency capability=%{public}s configured=%{public}s codec=%{public}s",
                    supported ? "yes" : "no",
                    lowLatencyEnabled_ ? "yes" : "no",
                    GetMimeType(codec));
    }
    // Surface 模式不需要 OH_MD_KEY_PIXEL_FORMAT

    ret = OH_VideoDecoder_Configure(decoder_, format);
    OH_AVFormat_Destroy(format);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Decoder] Configure 失败: %{public}d", ret);
        return retireInitResources(-6);
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    if (const int injected = failAtStage(5, -105); injected != 0) return injected;
#endif

    // 5. 设置解码输出 surface。必须在 Prepare 前，且部分设备要求 Configure 后调用。
    ret = OH_VideoDecoder_SetSurface(decoder_, static_cast<OHNativeWindow*>(nativeWindow_));
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Decoder] SetSurface 失败: %{public}d", ret);
        return retireInitResources(-5);
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    if (const int injected = failAtStage(6, -106); injected != 0) return injected;
#endif

    // 6. Prepare
    ret = OH_VideoDecoder_Prepare(decoder_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Decoder] Prepare 失败: %{public}d", ret);
        return retireInitResources(-7);
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    if (const int injected = failAtStage(7, -107); injected != 0) return injected;
#endif

    // 7. Start
    ret = OH_VideoDecoder_Start(decoder_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Decoder] Start 失败: %{public}d", ret);
        return retireInitResources(-8);
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    if (const int injected = failAtStage(8, -108); injected != 0) return injected;
#endif

    initialized_ = true;
    releaseInitContext();
    OH_LOG_INFO(LOG_APP, "[Decoder] ✓ 解码器启动成功 (Surface模式, %{public}dx%{public}d texture=%{public}u)",
                width, height, textureId_);
    return 0;
}

void HardwareDecoder::SetNativeImagePresentationMode(
    Render::NativeImagePresentationMode presentationMode) {
    const Render::NativeImagePresentationMode previous =
        presentationMode_.exchange(presentationMode, std::memory_order_acq_rel);
    if (previous == presentationMode) {
        return;
    }
    textureTransformLogged_.store(false, std::memory_order_release);
    OH_LOG_INFO(LOG_APP,
                "[Decoder] NativeImage presentation changed %{public}s -> %{public}s",
                Render::NativeImagePresentationModeName(previous),
                Render::NativeImagePresentationModeName(presentationMode));
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

size_t HardwareDecoder::dropOldestNonKeyFramesLocked(size_t count) {
    size_t dropped = 0;
    for (auto it = inputQueue_.begin(); it != inputQueue_.end() && dropped < count;) {
        if (!it->isKeyFrame) {
            delete[] it->data;
            it = inputQueue_.erase(it);
            ++dropped;
        } else {
            ++it;
        }
    }
    return dropped;
}

int HardwareDecoder::Decode(const uint8_t* data, size_t size, uint64_t timestamp, bool isKeyFrame) {
    HardwareDecodeAdmission admission = HardwareDecodeAdmission::Failed;
    return DecodeOwned(data, size, timestamp, isKeyFrame, admission);
}

int HardwareDecoder::DecodeOwned(
    const uint8_t* data, size_t size, uint64_t timestamp, bool isKeyFrame,
    HardwareDecodeAdmission& ownedAdmission) {
    ownedAdmission = HardwareDecodeAdmission::Failed;
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
    bool droppedIncomingForCapacity = false;
    bool recoveredWithKeyframe = false;
    bool softDroppedOldFrames = false;
    bool requestKeyframe = false;
    Render::VideoFrameAdmission admission = Render::VideoFrameAdmission::Accept;
    {
        std::lock_guard<std::mutex> lk(mutex_);
        const bool wasWaitingForKeyframe = backpressure_.isWaitingForKeyframe();
        const bool requestAlreadyPending = backpressure_.shouldRequestKeyframe();
        admission = backpressure_.admitFrame(inputQueue_.size(), isKeyFrame);
        requestKeyframe = !requestAlreadyPending &&
            admission == Render::VideoFrameAdmission::AcceptAfterSoftDrop &&
            backpressure_.shouldRequestKeyframe();
        if (admission == Render::VideoFrameAdmission::DropWaitingKeyframe) {
            droppedIncomingForKeyframe = true;
            std::lock_guard<std::mutex> telemetryLock(telemetryMutex_);
            waitDroppedTotal = SaturatingAdd(waitKeyframeDropCount_, 1);
        } else {
            if (inputQueue_.size() >= kMaxQueuedFrames) {
                if (isKeyFrame) {
                    // A new keyframe is a complete decoder restart point. Do
                    // not leave stale deltas ahead of it, and never evict the
                    // keyframe itself when recovering from queue pressure.
                    droppedQueued = clearInputQueueLocked();
                } else {
                    const size_t removeCount = inputQueue_.size() - kMaxQueuedFrames + 1;
                    droppedQueued = dropOldestNonKeyFramesLocked(removeCount);
                    if (inputQueue_.size() >= kMaxQueuedFrames) {
                        // All retained frames are keyframes. Keep the restart
                        // points and discard this dependent frame instead of
                        // allowing the queue to grow or corrupt decode state.
                        droppedIncomingForCapacity = true;
                    }
                }
                if (droppedQueued > 0) {
                    softDroppedOldFrames = true;
                    std::lock_guard<std::mutex> telemetryLock(telemetryMutex_);
                    droppedTotal = SaturatingAdd(inputDropCount_, droppedQueued);
                }
            }
            if (droppedIncomingForCapacity) {
                std::lock_guard<std::mutex> telemetryLock(telemetryMutex_);
                droppedTotal = SaturatingAdd(inputDropCount_, 1);
            }
            if (admission == Render::VideoFrameAdmission::AcceptRecoveryKeyframe && wasWaitingForKeyframe) {
                recoveredWithKeyframe = true;
                std::lock_guard<std::mutex> telemetryLock(telemetryMutex_);
                recoveryTotal = SaturatingAdd(keyframeRecoveryCount_, 1);
            }
            if (!droppedIncomingForCapacity) {
                inputQueue_.push_back({copy, size, static_cast<int64_t>(timestamp), isKeyFrame});
                copy = nullptr;
                queued = inputQueue_.size();
            }
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
        ownedAdmission = HardwareDecodeAdmission::Backpressure;
        return 0;
    }
    if (droppedIncomingForCapacity) {
        if (droppedTotal <= 16 || droppedTotal % 60 == 0) {
            OH_LOG_WARN(LOG_APP,
                        "[Decoder] queue kept keyframes; drop dependent input total=%{public}llu size=%{public}zu pts=%{public}llu",
                        static_cast<unsigned long long>(droppedTotal),
                        size,
                        static_cast<unsigned long long>(timestamp));
        }
        ownedAdmission = HardwareDecodeAdmission::Backpressure;
        return 0;
    }
    if (recoveredWithKeyframe) {
        OH_LOG_INFO(LOG_APP,
                    "[Decoder] wait-keyframe recovered with keyframe pts=%{public}llu queue=%{public}zu recoveries=%{public}llu",
                    static_cast<unsigned long long>(timestamp),
                    queued,
                    static_cast<unsigned long long>(recoveryTotal));
    }

    // Never enter OH_VideoDecoder_PushInputBuffer from the transport/callback
    // path. The Harmony codec service can block that IPC for seconds.
    inputCv_.notify_one();
    ownedAdmission = requestKeyframe ? HardwareDecodeAdmission::NeedKeyframe
                                     : HardwareDecodeAdmission::Queued;
    return requestKeyframe ? kDecodeKeyframeRequired : 0;
}

void HardwareDecoder::handleInputBuffer(uint32_t index, OH_AVBuffer* buffer) {
    {
        std::lock_guard<std::mutex> lk(mutex_);
        pendingInputBuffers_.push_back({index, buffer});
    }
    inputCv_.notify_one();
}

void HardwareDecoder::recordInputSubmission(
    int64_t timestamp, std::chrono::steady_clock::time_point submittedAt) {
    std::lock_guard<std::mutex> telemetryLock(telemetryMutex_);
    constexpr size_t kMaxSubmittedFrameTimings = 256;
    while (submittedFrameTimings_.size() >= kMaxSubmittedFrameTimings) {
        submittedFrameTimings_.pop_front();
    }
    submittedFrameTimings_.push_back({timestamp, submittedAt});
}

void HardwareDecoder::discardInputSubmission(
    int64_t timestamp, std::chrono::steady_clock::time_point submittedAt) {
    std::lock_guard<std::mutex> telemetryLock(telemetryMutex_);
    const auto it = std::find_if(submittedFrameTimings_.begin(), submittedFrameTimings_.end(),
        [timestamp, submittedAt](const SubmittedFrameTiming& timing) {
            return timing.timestamp == timestamp && timing.submittedAt == submittedAt;
        });
    if (it != submittedFrameTimings_.end()) {
        submittedFrameTimings_.erase(it);
    }
}

void HardwareDecoder::recordOutputLatency(int64_t timestamp) {
    int64_t latencyMs = -1;
    int64_t maxLatencyMs = 0;
    uint64_t sampleCount = 0;
    bool lowLatencyEnabled = false;
    {
        std::lock_guard<std::mutex> telemetryLock(telemetryMutex_);
        const auto it = std::find_if(submittedFrameTimings_.begin(), submittedFrameTimings_.end(),
            [timestamp](const SubmittedFrameTiming& timing) {
                return timing.timestamp == timestamp;
            });
        if (it == submittedFrameTimings_.end()) {
            return;
        }
        latencyMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - it->submittedAt).count();
        submittedFrameTimings_.erase(it);
        codecLatencyMs_ = latencyMs;
        codecLatencyMaxMs_ = std::max(codecLatencyMaxMs_, latencyMs);
        maxLatencyMs = codecLatencyMaxMs_;
        sampleCount = ++codecLatencySampleCount_;
        lowLatencyEnabled = lowLatencyEnabled_;
    }
    if (sampleCount <= 5 || sampleCount % 120 == 0 ||
        (latencyMs >= 250 && sampleCount % 30 == 0)) {
        OH_LOG_INFO(LOG_APP,
                    "[Decoder] codec latency sample=%{public}llu current=%{public}lldms max=%{public}lldms lowLatency=%{public}s pts=%{public}lld",
                    static_cast<unsigned long long>(sampleCount),
                    static_cast<long long>(latencyMs),
                    static_cast<long long>(maxLatencyMs),
                    lowLatencyEnabled ? "yes" : "no",
                    static_cast<long long>(timestamp));
    }
}

void HardwareDecoder::drainInputBuffers() {
    // This function is owned by inputLoop(). In particular, no codec IPC is
    // allowed to run on the Harmony codec callback thread or the GL thread.
    auto enterRecovery = [this](const char* operation, uint32_t index, int32_t error) {
        const uint64_t failures = inputPushFailureCount_.fetch_add(
            1, std::memory_order_acq_rel) + 1;
        size_t droppedQueued = 0;
        {
            std::lock_guard<std::mutex> lk(mutex_);
            droppedQueued = clearInputQueueLocked();
            backpressure_.enterHardWaitForKeyframe();
        }
        OH_LOG_WARN(LOG_APP,
                    "[Decoder] input submission failed op=%{public}s error=%{public}d index=%{public}u failures=%{public}llu dropped=%{public}zu; waiting for keyframe",
                    operation,
                    error,
                    index,
                    static_cast<unsigned long long>(failures),
                    droppedQueued);
        if (codecType_ == CodecType::H264 || codecType_ == CodecType::H265) {
            // The failed index has unknown platform ownership. Do not submit it
            // a second time. Recreate the codec at the next keyframe instead.
            errorCallbackGate_.Invoke(
                DecoderError::INPUT_FAILED,
                std::string("OH_VideoDecoder_PushInputBuffer failed: ") + operation);
        }
    };
    while (true) {
        if (inputThreadStop_.load(std::memory_order_acquire)) {
            return;
        }
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
            const OH_AVErrCode recycleRet = ReturnEmptyInputBuffer(
                decoder, input.index, nullptr, frame.timestamp);
            if (recycleRet != AV_ERR_OK) {
                enterRecovery("null-buffer-recycle", input.index, recycleRet);
            }
            delete[] frame.data;
            continue;
        }

        uint8_t* bufAddr = OH_AVBuffer_GetAddr(input.buffer);
        int32_t bufCap = OH_AVBuffer_GetCapacity(input.buffer);
        if (!bufAddr || bufCap <= 0) {
            OH_LOG_WARN(LOG_APP, "[Decoder] invalid input buffer index=%{public}u cap=%{public}d",
                        input.index, bufCap);
            const OH_AVErrCode recycleRet = ReturnEmptyInputBuffer(
                decoder, input.index, input.buffer, frame.timestamp);
            if (recycleRet != AV_ERR_OK) {
                enterRecovery("invalid-buffer-recycle", input.index, recycleRet);
            }
            delete[] frame.data;
            continue;
        }

        size_t copyLen = (static_cast<size_t>(bufCap) < frame.size) ? static_cast<size_t>(bufCap) : frame.size;
        if (copyLen < frame.size) {
            // T-130: Hard recovery on truncated input — never push truncated encoded data.
            // Enter wait-keyframe mode; decoder will self-recover at next keyframe.
            // Do NOT call OH_VideoDecoder_Flush here — it's too heavy and causes
            // visual freeze by discarding all already-decoded frames.
            size_t droppedQueued = 0;
            {
                std::lock_guard<std::mutex> lk(mutex_);
                droppedQueued = clearInputQueueLocked();
                backpressure_.enterHardWaitForKeyframe();
            }
            uint64_t truncated = 0;
            uint64_t recoveryCount = 0;
            {
                std::lock_guard<std::mutex> telemetryLock(telemetryMutex_);
                truncated = SaturatingAdd(inputTruncatedCount_, 1);
                recoveryCount = SaturatingAdd(keyframeRecoveryCount_, 1);
            }
            OH_LOG_WARN(LOG_APP,
                        "[Decoder] TRUNCATED INPUT: size=%{public}zu cap=%{public}d truncated_total=%{public}llu dropped_queued=%{public}zu recoveries=%{public}llu waiting_for_keyframe",
                        frame.size, bufCap,
                        static_cast<unsigned long long>(truncated),
                        droppedQueued,
                        static_cast<unsigned long long>(recoveryCount));
            const OH_AVErrCode recycleRet = ReturnEmptyInputBuffer(
                decoder, input.index, input.buffer, frame.timestamp);
            if (recycleRet != AV_ERR_OK) {
                enterRecovery("truncated-input-recycle", input.index, recycleRet);
            }
            delete[] frame.data;
            continue;
        }
        std::memcpy(bufAddr, frame.data, copyLen);

        OH_AVCodecBufferAttr attr {};
        attr.pts = frame.timestamp;
        attr.size = static_cast<int32_t>(copyLen);
        attr.offset = 0;
        // Keep the 1.0.7 compatibility behavior. The remote frame's keyframe
        // bit is used by our recovery policy, but marking the AVBuffer as a
        // sync frame makes this Harmony codec reject otherwise valid streams.
        attr.flags = AVCODEC_BUFFER_FLAGS_NONE;
        const OH_AVErrCode attrRet = OH_AVBuffer_SetBufferAttr(input.buffer, &attr);
        if (attrRet != AV_ERR_OK) {
            OH_LOG_WARN(LOG_APP,
                        "[Decoder] input attr failed: %{public}d index=%{public}u",
                        attrRet, input.index);
            const OH_AVErrCode recycleRet = ReturnEmptyInputBuffer(
                decoder, input.index, input.buffer, frame.timestamp);
            enterRecovery("set-attr", input.index,
                          recycleRet == AV_ERR_OK ? attrRet : recycleRet);
            delete[] frame.data;
            continue;
        }

        const auto pushStartedAt = std::chrono::steady_clock::now();
        recordInputSubmission(frame.timestamp, pushStartedAt);
        OH_AVErrCode ret = OH_VideoDecoder_PushInputBuffer(decoder, input.index);
        const auto pushCostMs = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - pushStartedAt).count();
        if (pushCostMs >= 100) {
            OH_LOG_WARN(LOG_APP,
                        "[Decoder] PushInputBuffer worker blocked cost=%{public}lldms index=%{public}u ret=%{public}d",
                        static_cast<long long>(pushCostMs), input.index, ret);
        }
        if (ret != AV_ERR_OK) {
            discardInputSubmission(frame.timestamp, pushStartedAt);
            OH_LOG_WARN(LOG_APP, "[Decoder] PushInputBuffer failed: %{public}d index=%{public}u",
                        ret, input.index);
            // The platform documentation only guarantees buffer reuse after a
            // successful submission and a later callback. On an unknown error
            // the index may already have crossed that boundary, so retrying it
            // can double-submit the same slot and permanently poison the
            // decoder. Drop this frame and recover from a fresh keyframe.
            enterRecovery("push-input", input.index, ret);
            delete[] frame.data;
            return;
        } else {
            inputPushFailureCount_.store(0, std::memory_order_release);
            uint64_t count = 0;
            {
                std::lock_guard<std::mutex> telemetryLock(telemetryMutex_);
                count = SaturatingAdd(inputPushCount_, 1);
            }
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

void HardwareDecoder::inputLoop() {
    OH_LOG_INFO(LOG_APP, "[Decoder] input thread started");
    while (!inputThreadStop_.load(std::memory_order_acquire)) {
        std::unique_lock<std::mutex> lk(mutex_);
        inputCv_.wait_for(lk, std::chrono::milliseconds(50), [this]() {
            return inputThreadStop_.load(std::memory_order_acquire) ||
                (!pendingInputBuffers_.empty() && !inputQueue_.empty());
        });
        if (inputThreadStop_.load(std::memory_order_acquire)) {
            break;
        }
        lk.unlock();
        drainInputBuffers();
    }
    {
        std::lock_guard<std::mutex> lk(inputThreadMutex_);
        inputThreadDone_ = true;
    }
    inputThreadDoneCv_.notify_all();
    OH_LOG_INFO(LOG_APP, "[Decoder] input thread stopped");
}

void HardwareDecoder::noteFrameAvailable() {
    {
        std::lock_guard<std::mutex> lk(mutex_);
        ++frameAvailableCount_;
    }
    frameAvailableCv_.notify_one();
}

bool HardwareDecoder::waitForRenderRequest(bool& hasNewFrame,
                                           bool& hasPendingSurfaceUpdate,
                                           uint64_t& frameSequence) {
    std::unique_lock<std::mutex> lk(mutex_);
    for (;;) {
        if (renderThreadStop_.load() || !initialized_) {
            return false;
        }
        const auto now = std::chrono::steady_clock::now();
        const bool hasFrame = Render::HasUnconsumedNativeImageFrame(
            frameAvailableCount_, frameConsumeCount_);
        const bool retryScheduled =
            surfaceRetryAt_ != std::chrono::steady_clock::time_point::min();
        const bool retryDue = surfaceUpdatePending_ &&
            (!retryScheduled || now >= surfaceRetryAt_);
        if (Render::ShouldDeferNativeImageRetry(
                surfaceUpdatePending_, retryScheduled, retryDue)) {
            frameAvailableCv_.wait_until(lk, surfaceRetryAt_);
            continue;
        }
        if (hasFrame || redrawRequested_ || retryDue) {
            break;
        }
        if (surfaceUpdatePending_ &&
            surfaceRetryAt_ != std::chrono::steady_clock::time_point::min()) {
            frameAvailableCv_.wait_until(lk, surfaceRetryAt_);
        } else {
            // Keep a bounded wake-up for a retained surface update even when
            // the codec has not produced another output callback.
            frameAvailableCv_.wait_for(lk, std::chrono::milliseconds(50));
        }
    }
    hasNewFrame = Render::HasUnconsumedNativeImageFrame(
        frameAvailableCount_, frameConsumeCount_);
    hasPendingSurfaceUpdate = surfaceUpdatePending_;
    frameSequence = Render::LatestNativeImageFrameSequence(frameAvailableCount_);
    if (hasNewFrame) {
        // A decoded frame is presented through the same callback and consumes
        // the newest transform, so an older retained redraw hint is redundant.
        // The notification sequence is committed only after UpdateSurfaceImage
        // succeeds; a failed acquire must remain retryable.
        redrawRequested_ = false;
    } else if (redrawRequested_) {
        redrawRequested_ = false;
    }
    return true;
}

void HardwareDecoder::handleOutputBuffer(uint32_t /*index*/) {
    if (!nativeImage_) { return; }
    if (surfaceRecoveryBlocked_.load(std::memory_order_acquire)) {
        return;
    }

    bool hasNewFrame = false;
    bool hasPendingSurfaceUpdate = false;
    uint64_t frameSequence = 0;
    if (!waitForRenderRequest(hasNewFrame, hasPendingSurfaceUpdate, frameSequence)) {
        return;
    }

    // A transform wake may arrive before the first decoded frame. There is no
    // retained image to present yet, so wait for the first NativeImage update.
    if (!hasNewFrame && !hasPendingSurfaceUpdate &&
        outputFrameCount_.load(std::memory_order_acquire) == 0) {
        return;
    }

    makeCurrentCallbackGate_.Invoke();

    if (!nativeImageContextAttached_) {
        int32_t attachRet = OH_NativeImage_AttachContext(nativeImage_, textureId_);
        int32_t detachRet = 0;
        bool retriedAfterDetach = false;
        if (Render::ShouldRetryNativeImageAttach(attachRet, false)) {
            retriedAfterDetach = true;
            detachRet = OH_NativeImage_DetachContext(nativeImage_);
            attachRet = OH_NativeImage_AttachContext(nativeImage_, textureId_);
        }
        if (attachRet == 0) {
            nativeImageContextAttached_ = true;
            OH_LOG_INFO(LOG_APP, "[Decoder] NativeImage attached to current GL context texture=%{public}u",
                        textureId_);
        } else {
            // Do not call UpdateSurfaceImage without a valid GL attachment.
            // Retain the newest request but honor a bounded retry deadline even
            // though its producer notification remains unconsumed. Repeated
            // failures arm the existing keyframe-driven decoder recreation.
            bool requestRecovery = false;
            int consecutiveFailures = 0;
            {
                std::lock_guard<std::mutex> lk(mutex_);
                consecutiveFailures = ++consecutiveSurfaceUpdateFailures_;
                requestRecovery = Render::ShouldRequestNativeImageRecovery(
                    consecutiveFailures) &&
                    !surfaceRecoveryBlocked_.exchange(true,
                                                       std::memory_order_acq_rel);
                surfaceUpdatePending_ = !requestRecovery;
                surfaceRetryAt_ = requestRecovery ?
                    std::chrono::steady_clock::time_point::min() :
                    std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(Render::NativeImageUpdateRetryDelayMs(
                            consecutiveFailures));
            }
            if (consecutiveFailures <= 3 || requestRecovery ||
                consecutiveFailures % 60 == 0) {
                OH_LOG_WARN(LOG_APP,
                            "[Decoder] AttachContext failed ret=%{public}d texture=%{public}u retryDetach=%{public}s detachRet=%{public}d consecutive=%{public}d recovery=%{public}s",
                            attachRet,
                            textureId_,
                            retriedAfterDetach ? "yes" : "no",
                            detachRet,
                            consecutiveFailures,
                            requestRecovery ? "yes" : "no");
            }
            if (requestRecovery) {
                errorCallbackGate_.Invoke(
                    DecoderError::OUTPUT_FAILED,
                    "repeated OH_NativeImage_AttachContext failure");
            }
            return;
        }
    }

    if (hasNewFrame || hasPendingSurfaceUpdate) {
        // 更新 NativeImage — 解码帧已写入 surface, 刷新 GL 纹理
        int32_t ret = 0;
        int retryCount = 0;
        bool updated = false;
        for (;;) {
            ret = OH_NativeImage_UpdateSurfaceImage(nativeImage_);
            if (ret == 0) {
                updated = true;
                break;
            }

            uint64_t failureCount = 0;
            {
                std::lock_guard<std::mutex> telemetryLock(telemetryMutex_);
                failureCount = SaturatingAdd(updateSurfaceFailureCount_, 1);
            }
            if (!Render::ShouldRetryNativeImageUpdate(ret, retryCount)) {
                if (Render::IsCoalescedNativeImageNotification(ret, retryCount)) {
                    // SetDropBufferMode keeps the latest buffer but deliberately
                    // preserves all listener callbacks. Once the short producer
                    // handoff window has elapsed, consume this callback sequence
                    // without treating the missing (already dropped) buffer as a
                    // decoder failure. A newer callback remains pending.
                    {
                        std::lock_guard<std::mutex> lk(mutex_);
                        frameConsumeCount_ = std::max(frameConsumeCount_, frameSequence);
                        surfaceUpdatePending_ = frameAvailableCount_ > frameConsumeCount_;
                        surfaceRetryAt_ = surfaceUpdatePending_ ?
                            std::chrono::steady_clock::now() :
                            std::chrono::steady_clock::time_point::min();
                    }
                    const uint64_t coalesced = coalescedSurfaceNotificationCount_.fetch_add(
                        1, std::memory_order_acq_rel) + 1;
                    if (coalesced <= 3 || coalesced % 300 == 0) {
                        OH_LOG_INFO(LOG_APP,
                                    "[Decoder] drop-mode coalesced stale NativeImage notification total=%{public}llu sequence=%{public}llu",
                                    static_cast<unsigned long long>(coalesced),
                                    static_cast<unsigned long long>(frameSequence));
                    }
                    return;
                }
                bool requestRecovery = false;
                OH_LOG_WARN(LOG_APP,
                            "[Decoder] UpdateSurfaceImage failed: %{public}d retries=%{public}d total=%{public}llu",
                            ret,
                            retryCount,
                            static_cast<unsigned long long>(failureCount));
                {
                    std::lock_guard<std::mutex> lk(mutex_);
                    surfaceUpdatePending_ = true;
                    surfaceRetryAt_ = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(20);
                    ++consecutiveSurfaceUpdateFailures_;
                    requestRecovery = Render::ShouldRequestNativeImageRecovery(
                        consecutiveSurfaceUpdateFailures_) &&
                        !surfaceRecoveryBlocked_.exchange(true,
                                                           std::memory_order_acq_rel);
                    if (requestRecovery) {
                        // A new keyframe must drive decoder recreation. Do not
                        // keep waking this thread at 50-60 Hz while the old
                        // NativeImage has no producer buffer.
                        surfaceUpdatePending_ = false;
                        surfaceRetryAt_ = std::chrono::steady_clock::time_point::min();
                    }
                }
                if (requestRecovery) {
                    OH_LOG_WARN(LOG_APP,
                                "[Decoder] repeated UpdateSurfaceImage failure, requesting keyframe recovery failures=%{public}d",
                                consecutiveSurfaceUpdateFailures_);
                    errorCallbackGate_.Invoke(
                        DecoderError::OUTPUT_FAILED,
                        "repeated OH_NativeImage_UpdateSurfaceImage failure");
                }
                return;
            }

            ++retryCount;
            if (failureCount <= 3 || failureCount % 60 == 0) {
                OH_LOG_WARN(LOG_APP,
                            "[Decoder] UpdateSurfaceImage no buffer; retry=%{public}d/%{public}d total=%{public}llu",
                            retryCount,
                            Render::kNativeImageUpdateRetryBudget,
                            static_cast<unsigned long long>(failureCount));
            }
            // The callback can race the producer's buffer handoff. Keep these
            // bounded retries on the dedicated render thread and yield briefly
            // instead of spinning or blocking codec/input callbacks.
            std::this_thread::sleep_for(std::chrono::milliseconds(
                Render::NativeImageUpdateRetryDelayMs(retryCount)));
        }
        if (updated) {
            std::lock_guard<std::mutex> lk(mutex_);
            // Consume all notifications observed before this update as one
            // latest-frame hint. A callback racing after the snapshot remains
            // visible as an unconsumed sequence and wakes the next iteration.
            frameConsumeCount_ = std::max(frameConsumeCount_, frameSequence);
            surfaceUpdatePending_ =
                frameAvailableCount_ > frameConsumeCount_;
            surfaceRetryAt_ = surfaceUpdatePending_ ?
                std::chrono::steady_clock::now() :
                std::chrono::steady_clock::time_point::min();
            consecutiveSurfaceUpdateFailures_ = 0;
        }
        if (updated && desktopSurfaceCompatibility_) {
            const Render::NativeImagePresentationMode presentationMode =
                presentationMode_.load(std::memory_order_acquire);
            float producerTransform[16] = {};
            const int32_t transformRet = OH_NativeImage_GetTransformMatrixV2(
                nativeImage_, producerTransform);
            textureTransform_ =
                Render::ResolveNativeImagePresentationTransform(
                    presentationMode, transformRet, producerTransform,
                    textureTransform_);
            if (!textureTransformLogged_.exchange(true, std::memory_order_acq_rel)) {
                OH_LOG_INFO(LOG_APP,
                            "[Decoder] desktop NativeImage producer transform ret=%{public}d row0=[%{public}f,%{public}f,%{public}f,%{public}f] row1=[%{public}f,%{public}f,%{public}f,%{public}f] row3=[%{public}f,%{public}f,%{public}f,%{public}f] presentation=%{public}s",
                            transformRet,
                            producerTransform[0], producerTransform[4],
                            producerTransform[8], producerTransform[12],
                            producerTransform[1], producerTransform[5],
                            producerTransform[9], producerTransform[13],
                            producerTransform[3], producerTransform[7],
                            producerTransform[11], producerTransform[15],
                            Render::NativeImagePresentationModeName(presentationMode));
            }
        }
    }

    // 通知渲染器: 纹理就绪
    frameCallbackGate_.Invoke(textureId_, width_, height_, textureTransform_);
    uint64_t count = 0;
    {
        std::lock_guard<std::mutex> telemetryLock(telemetryMutex_);
        count = SaturatingAdd(outputFrameCount_, 1);
    }
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
    if (renderThread_.joinable() || inputThread_.joinable()) {
        return;
    }
    startInputThread();
    ResetSurfaceRecoveryForBind();
    renderThreadStop_.store(false);
    {
        std::lock_guard<std::mutex> lock(renderThreadMutex_);
        renderThreadDone_ = false;
    }
    renderThread_ = std::thread(&HardwareDecoder::renderLoop, this);
}

void HardwareDecoder::ResetSurfaceRecoveryForBind() {
    surfaceRecoveryBlocked_.store(false, std::memory_order_release);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        surfaceUpdatePending_ = false;
        surfaceRetryAt_ = std::chrono::steady_clock::time_point::min();
        consecutiveSurfaceUpdateFailures_ = 0;
    }
    frameAvailableCv_.notify_all();
}

void HardwareDecoder::startInputThread() {
    if (inputThread_.joinable()) {
        if (inputThread_.get_id() == std::this_thread::get_id()) {
            return;
        }
        {
            std::lock_guard<std::mutex> lock(inputThreadMutex_);
            if (!inputThreadDone_) {
                return;
            }
        }
        // A completed thread must be joined before its std::thread slot can be
        // reused.  The done fence makes this join non-blocking in the normal
        // rebind path.
        inputThread_.join();
    }
    inputThreadStop_.store(false, std::memory_order_release);
    {
        std::lock_guard<std::mutex> lock(inputThreadMutex_);
        inputThreadDone_ = false;
    }
    inputThread_ = std::thread(&HardwareDecoder::inputLoop, this);
}

bool HardwareDecoder::stopInputThread() {
    inputThreadStop_.store(true, std::memory_order_release);
    inputCv_.notify_all();
    if (!inputThread_.joinable()) {
        std::lock_guard<std::mutex> lock(inputThreadMutex_);
        inputThreadDone_ = true;
        return true;
    }
    if (inputThread_.get_id() == std::this_thread::get_id()) {
        return false;
    }
    std::unique_lock<std::mutex> lock(inputThreadMutex_);
    if (!inputThreadDone_ && !inputThreadDoneCv_.wait_for(
            lock, std::chrono::milliseconds(500), [this]() {
                return inputThreadDone_;
            })) {
        return false;
    }
    lock.unlock();
    inputThread_.join();
    return true;
}

void HardwareDecoder::waitForInputThreadForDeferredDestroy() {
    if (!inputThread_.joinable() ||
        inputThread_.get_id() == std::this_thread::get_id()) {
        return;
    }
    std::unique_lock<std::mutex> lock(inputThreadMutex_);
    inputThreadDoneCv_.wait(lock, [this]() {
        return inputThreadDone_;
    });
    lock.unlock();
    if (inputThread_.joinable()) {
        inputThread_.join();
    }
}

bool HardwareDecoder::stopRenderThread() {
    renderThreadStop_.store(true);
    frameAvailableCv_.notify_all();
    if (!renderThread_.joinable()) {
        return true;
    }
    if (renderThread_.get_id() == std::this_thread::get_id()) {
        return false;
    }
    std::unique_lock<std::mutex> lock(renderThreadMutex_);
    if (!renderThreadCv_.wait_for(lock, std::chrono::milliseconds(500), [this]() {
            return renderThreadDone_;
        })) {
        return false;
    }
    lock.unlock();
    renderThread_.join();
    return true;
}

void HardwareDecoder::renderLoop() {
    OH_LOG_INFO(LOG_APP, "[Decoder] render thread started");
    while (!renderThreadStop_.load()) {
        if (surfaceRecoveryBlocked_.load(std::memory_order_acquire)) {
            std::unique_lock<std::mutex> lock(mutex_);
            frameAvailableCv_.wait(lock, [this]() {
                return renderThreadStop_.load(std::memory_order_acquire) ||
                    !surfaceRecoveryBlocked_.load(std::memory_order_acquire);
            });
            continue;
        }
        handleOutputBuffer(0);
    }
    if (Render::ShouldDetachNativeImageOnRenderThreadStop(nativeImageContextAttached_, nativeImage_ != nullptr)) {
        int32_t detachRet = OH_NativeImage_DetachContext(nativeImage_);
        OH_LOG_INFO(LOG_APP, "[Decoder] NativeImage detached from GL context ret=%{public}d texture=%{public}u",
                    detachRet,
                    textureId_);
    }
    releaseCurrentCallbackGate_.Invoke();
    nativeImageContextAttached_ = false;
    {
        std::lock_guard<std::mutex> lock(renderThreadMutex_);
        renderThreadDone_ = true;
    }
    renderThreadCv_.notify_all();
    OH_LOG_INFO(LOG_APP, "[Decoder] render thread stopped");
}

bool HardwareDecoder::StopRenderThreadForDetach() {
    const bool renderStopped = stopRenderThread();
    const bool inputStopped = stopInputThread();
    if (!renderStopped || !inputStopped) {
        OH_LOG_WARN(LOG_APP,
                    "[Decoder] detach stop deferred render=%{public}s input=%{public}s",
                    renderStopped ? "stopped" : "running",
                    inputStopped ? "stopped" : "running");
        return false;
    }
    SetFrameCallback(nullptr);
    SetMakeCurrentCallback(nullptr);
    SetReleaseCurrentCallback(nullptr);
    errorCallbackGate_.ClearAndWait();
    nativeImageContextAttached_ = false;
    return true;
}

void HardwareDecoder::WaitForRenderThreadForDeferredDestroy() {
    std::unique_lock<std::mutex> lock(renderThreadMutex_);
    renderThreadCv_.wait(lock, [this]() {
        return renderThreadDone_ || !renderThread_.joinable();
    });
    lock.unlock();
    if (renderThread_.joinable() &&
        renderThread_.get_id() != std::this_thread::get_id()) {
        renderThread_.join();
    }
    waitForInputThreadForDeferredDestroy();
}

GLuint HardwareDecoder::GetTextureId() const {
    return textureId_;
}

void HardwareDecoder::RequestRedraw() {
    {
        std::lock_guard<std::mutex> lk(mutex_);
        if (!initialized_ || renderThreadStop_.load(std::memory_order_acquire)) {
            return;
        }
        redrawRequested_ = true;
    }
    frameAvailableCv_.notify_one();
}

void HardwareDecoder::Flush() {
    const bool restartInput = inputThread_.joinable() &&
        !inputThreadStop_.load(std::memory_order_acquire);
    if (restartInput && !stopInputThread()) {
        waitForInputThreadForDeferredDestroy();
    }
    if (initialized_ && decoder_) {
        OH_LOG_INFO(LOG_APP, "[Decoder] Flush");
        OH_VideoDecoder_Flush(decoder_);
        std::lock_guard<std::mutex> lk(mutex_);
        clearInputQueueLocked();
        pendingInputBuffers_.clear();
        backpressure_.reset();
        redrawRequested_ = false;
        surfaceUpdatePending_ = false;
        frameConsumeCount_ = frameAvailableCount_;
        surfaceRetryAt_ = std::chrono::steady_clock::time_point::min();
        consecutiveSurfaceUpdateFailures_ = 0;
    }
    ResetTelemetryCounters();
    if (restartInput && initialized_ && !renderThreadStop_.load(std::memory_order_acquire)) {
        startInputThread();
    }
}

size_t HardwareDecoder::QueuedFrameCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return inputQueue_.size();
}

uint64_t HardwareDecoder::DroppedFrameCount() const {
    // Waiting-for-keyframe drops are a separate metric. Callers that need the
    // complete drop count must explicitly add this value to
    // WaitKeyframeDroppedFrameCount() once, not rely on an ambiguous total.
    return GetTelemetrySnapshot().inputDroppedFrames;
}

uint64_t HardwareDecoder::InputDroppedFrameCount() const {
    return GetTelemetrySnapshot().inputDroppedFrames;
}

uint64_t HardwareDecoder::WaitKeyframeDroppedFrameCount() const {
    return GetTelemetrySnapshot().waitKeyframeDrops;
}

bool HardwareDecoder::IsOverloaded() const {
    const HardwareTelemetrySnapshot snapshot = GetTelemetrySnapshot();
    return snapshot.inputDroppedFrames > 0 || snapshot.waitKeyframeDrops > 20 ||
        snapshot.inputTruncated > 0 || snapshot.renderOutputFailures > 0;
}

std::string HardwareDecoder::OverloadReason() const {
    const HardwareTelemetrySnapshot snapshot = GetTelemetrySnapshot();
    std::string reason;
    if (snapshot.inputDroppedFrames > 0) {
        reason += "drops=" + std::to_string(snapshot.inputDroppedFrames) + " ";
    }
    if (snapshot.waitKeyframeDrops > 0) {
        reason += "waitDrops=" + std::to_string(snapshot.waitKeyframeDrops) + " ";
    }
    if (snapshot.inputTruncated > 0) {
        reason += "truncs=" + std::to_string(snapshot.inputTruncated) + " ";
    }
    if (snapshot.renderOutputFailures > 0) {
        reason += "renderFails=" + std::to_string(snapshot.renderOutputFailures) + " ";
    }
    if (snapshot.updateSurfaceFailures > 0) {
        reason += "updateFails=" + std::to_string(snapshot.updateSurfaceFailures) + " ";
    }
    return reason.empty() ? "none" : reason;
}

HardwareTelemetrySnapshot HardwareDecoder::GetTelemetrySnapshot() const {
    HardwareTelemetrySnapshot snapshot;
    // Decode and reset update counters while holding mutex_ before taking the
    // telemetry mutex, so queue depth and all cumulative counters belong to
    // one coherent decoder observation.
    std::lock_guard<std::mutex> pipelineLock(mutex_);
    std::lock_guard<std::mutex> telemetryLock(telemetryMutex_);
    snapshot.queueDepth = inputQueue_.size();
    snapshot.inputDroppedFrames = inputDropCount_.load(std::memory_order_relaxed);
    snapshot.waitKeyframeDrops = waitKeyframeDropCount_.load(std::memory_order_relaxed);
    snapshot.inputTruncated = inputTruncatedCount_.load(std::memory_order_relaxed);
    snapshot.renderOutputFailures = renderOutputFailureCount_.load(std::memory_order_relaxed);
    snapshot.updateSurfaceFailures = updateSurfaceFailureCount_.load(std::memory_order_relaxed);
    snapshot.coalescedSurfaceNotifications =
        coalescedSurfaceNotificationCount_.load(std::memory_order_relaxed);
    snapshot.renderedOutputBuffers =
        renderedOutputBufferCount_.load(std::memory_order_relaxed);
    snapshot.outputFrames = outputFrameCount_.load(std::memory_order_relaxed);
    snapshot.codecLatencyMs = codecLatencyMs_;
    snapshot.codecLatencyMaxMs = codecLatencyMaxMs_;
    snapshot.codec = codecType_;
    snapshot.initialized = initialized_;
    snapshot.lowLatencyEnabled = lowLatencyEnabled_;
    return snapshot;
}

void HardwareDecoder::ResetTelemetryCounters() {
    std::lock_guard<std::mutex> pipelineLock(mutex_);
    std::lock_guard<std::mutex> telemetryLock(telemetryMutex_);
    inputPushCount_.store(0, std::memory_order_release);
    inputDropCount_.store(0, std::memory_order_release);
    waitKeyframeDropCount_.store(0, std::memory_order_release);
    keyframeRecoveryCount_.store(0, std::memory_order_release);
    inputTruncatedCount_.store(0, std::memory_order_release);
    renderOutputFailureCount_.store(0, std::memory_order_release);
    renderedOutputBufferCount_.store(0, std::memory_order_release);
    updateSurfaceFailureCount_.store(0, std::memory_order_release);
    coalescedSurfaceNotificationCount_.store(0, std::memory_order_release);
    inputPushFailureCount_.store(0, std::memory_order_release);
    outputFrameCount_.store(0, std::memory_order_release);
    submittedFrameTimings_.clear();
    codecLatencySampleCount_ = 0;
    codecLatencyMs_ = 0;
    codecLatencyMaxMs_ = 0;
}

void HardwareDecoder::Destroy() {
    // Stop admission before stopping/destroying OH_AVCodec or NativeImage.
    // The platform may still invoke a raw userData callback after its source
    // is stopped; the stable context remains valid until the source has
    // quiesced and rejects any late callback.
    BeginCallbackTeardown();
    const bool renderStopped = stopRenderThread();
    const bool inputStopped = stopInputThread();
    if (!renderStopped || !inputStopped) {
        if (!renderDestroyDeferred_.exchange(true, std::memory_order_acq_rel)) {
            try {
                auto retained = shared_from_this();
                decoderRetireOwner().enqueue(retained, [retained]() {
                    return retained->FinishDeferredDestroy();
                });
            } catch (const std::bad_weak_ptr&) {
                // Stack-owned test decoders stay alive until the caller
                // releases the barrier and retries Destroy. Never free a
                // platform resource underneath a live render worker.
                OH_LOG_WARN(LOG_APP,
                            "[Decoder] render teardown deferred without shared owner");
            }
        }
        return;
    }
    renderDestroyDeferred_.store(false, std::memory_order_release);
    OH_AVCodec* decoder = nullptr;
    OH_NativeImage* nativeImage = nullptr;
    bool testResourceLive = false;
    if (initialized_) {
        OH_LOG_INFO(LOG_APP, "[Decoder] Destroy");
        decoder = decoder_;
        nativeImage = nativeImage_;
        decoder_ = nullptr;
        nativeImage_ = nullptr;
        if (textureId_ != 0) {
            makeCurrentCallbackGate_.Invoke();
            glDeleteTextures(1, &textureId_);
            textureId_ = 0;
            releaseCurrentCallbackGate_.Invoke();
        }
        nativeWindow_ = nullptr;
        initialized_ = false;

        // 清空未处理的输入队列
        std::lock_guard<std::mutex> lk(mutex_);
        clearInputQueueLocked();
        pendingInputBuffers_.clear();
        backpressure_.reset();
    }
#if defined(RDP_NATIVE_CALLBACK_TESTING)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        testResourceLive = testPlatformResourceLive_;
        testPlatformResourceLive_ = false;
    }
#endif
    ResetTelemetryCounters();

    // The render thread is joined above. Keep make/release callbacks alive
    // long enough to delete the decoder-owned GL texture, then make every
    // callback inert before this decoder can be reused or destroyed.
    frameCallbackGate_.ClearAndWait();
    makeCurrentCallbackGate_.ClearAndWait();
    releaseCurrentCallbackGate_.ClearAndWait();
    errorCallbackGate_.ClearAndWait();
    RetireDecoderCallbackContext(std::move(callbackContext_), decoder, nativeImage,
                                 testResourceLive, callbackResourceDestroyCount_,
                                 callbackResourceStopCount_, callbackResourceUnsetCount_);
}

bool HardwareDecoder::FinishDeferredDestroy() {
    if (!renderDestroyDeferred_.load(std::memory_order_acquire)) {
        return true;
    }
    // The first Destroy() already requested render-thread cancellation and
    // transferred this decoder to the deferred owner.  Do not call Destroy()
    // again while that thread is still live: the exchange guard would suppress
    // a second transfer and the owner could then drop its last shared_ptr.
    // Waiting here is outside the bounded caller path; the deferred owner is
    // the resource owner until the render done fence is published.
    WaitForRenderThreadForDeferredDestroy();
    Destroy();
    return !renderDestroyDeferred_.load(std::memory_order_acquire) &&
        !renderThread_.joinable() && !inputThread_.joinable();
}

void HardwareDecoder::SetFrameCallback(DecoderFrameCallback callback) {
    frameCallbackGate_.Set(std::move(callback));
}

void HardwareDecoder::SetMakeCurrentCallback(DecoderMakeCurrentCallback callback) {
    makeCurrentCallbackGate_.Set(std::move(callback));
}

void HardwareDecoder::SetReleaseCurrentCallback(DecoderReleaseCurrentCallback callback) {
    releaseCurrentCallbackGate_.Set(std::move(callback));
}

void HardwareDecoder::SetErrorCallback(DecoderErrorCallback callback) {
    errorCallbackGate_.Set(std::move(callback));
}

// ============================================================
// H.264 最小 IDR 帧 — 64×64 蓝色测试画面
// 编码: SPS + PPS + IDR slice (YUV all-blue)
// ============================================================

#if defined(RDP_NATIVE_CALLBACK_TESTING)
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
#endif

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
    // Explicitly set only for RustDesk sessions running in the PC layout.
    // Phone/Pad keep their released output scheduling and texture orientation.
    bool desktopSurfaceCompatibility = false;
    std::atomic<Render::NativeImagePresentationMode> presentationMode {
        Render::NativeImagePresentationMode::Identity};
    // Serializes decode/rebind/detach/destroy and keeps a context alive while
    // a caller is using it through the registry below.
    std::mutex pipelineMutex;
    std::atomic<bool> videoPipelineAttached {false};
    // Set while decoder/renderer callbacks are being detached or rebound
    // outside pipelineMutex. Public operations reject this state after taking
    // their registry lease, so no object call races the two-phase transition.
    std::atomic<bool> pipelineTransitioning {false};
    std::condition_variable pipelineTransitionCv;
    int64_t rendererHandle = 0;
    DecoderSessionIdentity owner;
    // A decoder handle is permanently bound to the session generation that
    // created it. Keep this value after detach so a stale public handle cannot
    // be rebound to a later session merely because its numeric value survived.
    DecoderSessionIdentity boundOwner;
    // The registry token is also captured by the platform callback context.
    // It is immutable for the lifetime of this decoder context and therefore
    // cannot be confused with an adapter or object address after reconnect.
    int64_t registryHandle = 0;
    uint64_t decoderGeneration = 0;
    uint64_t dropCounterGeneration = 0;
    uint64_t displayGeneration = 0;
    int display = -1;
    std::atomic<uint64_t> rendererGeneration {0};
    std::atomic<uint64_t> presentationDecoderGeneration {0};
    std::atomic<uint64_t> rendererPresentedFrames {0};
    int width = 0;
    int height = 0;
    // The requested decoder size may be an adaptive page size. Once a real
    // frame arrives, retain its dimensions for PIP and foreground rebinds.
    bool observedFrameSize = false;

    std::mutex softMutex;
    std::condition_variable softCv;
    std::condition_variable softDoneCv;
    std::thread softThread;
    std::atomic<bool> softDone {true};
    std::deque<SoftQueuedFrame> softQueue;
    bool softStop = false;
    bool softRedrawRequested = false;
    std::atomic<int64_t> softRendererHandle {0};
    Render::SoftwareDecodeQueueRecoveryPolicy softRecovery;
    std::atomic<uint64_t> softQueued {0};
    std::atomic<uint64_t> softDecoded {0};
    std::atomic<uint64_t> softDropped {0};
    std::atomic<uint64_t> softSkippedPresent {0};
    std::atomic<bool> recoveryRequested {false};
    std::atomic<uint32_t> recoveryAttempts {0};
    std::atomic<bool> recoveryTerminal {false};
    // 0 = no deferred destroy, 1 = waiting for a prior pipeline transition,
    // 2 = transition owned but a decoder/software worker is still draining.
    std::atomic<int> deferredDestroyPhase {0};
    int64_t retiringRendererHandle = 0;
};

static std::atomic<int64_t> g_activeDecoderHandle {0};
static std::mutex g_activeDecoderOwnerMutex;
static DecoderSessionIdentity g_activeDecoderOwner;
static std::atomic<Render::NativeImagePresentationMode>
    g_activeNativeImagePresentationMode {
        Render::NativeImagePresentationMode::Identity};
static std::atomic<uint64_t> g_activeDisplayGeneration {0};
static std::atomic<uint64_t> g_nextDecoderGeneration {1};
// -1 means that the first frame establishes the legacy/current display. Once
// a RustDesk display is selected, frames from every other display are dropped
// before entering either decoder implementation.
static std::atomic<int> g_activeDisplay {-1};
static OpaqueHandleRegistry<DecoderContext> g_decoderRegistry;
constexpr size_t kMaxSoftwareDecodeQueue = 30;

DecoderCallbackTarget AcquireDecoderCallbackTarget(
    Render::CallbackAdmissionContext::Lease callbackLease,
    OH_AVCodec* expectedCodec,
    Render::DecoderCallbackKind callbackKind) {
    DecoderCallbackTarget target;
    const auto snapshot = callbackLease.snapshot();
    auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(snapshot.owner);
    if (!ownerLease) {
        return target;
    }
    auto decoderLease = g_decoderRegistry.acquire(snapshot.token, snapshot.owner);
    if (!decoderLease) {
        return target;
    }
    std::shared_ptr<HardwareDecoder> decoder;
    {
        std::lock_guard<std::mutex> pipelineLock(decoderLease->pipelineMutex);
        if (decoderLease->decoderGeneration != snapshot.generation ||
            decoderLease->boundOwner != snapshot.owner || !decoderLease->decoder) {
            return target;
        }
        // The callback admission lease and registry operation lease already
        // establish that this is the live decoder source for the exact owner
        // and generation. Do not also require an attached renderer here:
        // during bind/rebind/recovery, input buffers must be retained and
        // output buffers must be returned to OH_AVCodec while the render
        // thread is being replaced. Frame notifications are retained by the
        // decoder until its new render thread starts.
        if (!Render::ShouldAdmitDecoderCallback(
                callbackKind,
                static_cast<bool>(callbackLease),
                Render::SessionOwnerMatches(decoderLease->owner, snapshot.owner),
                static_cast<bool>(decoderLease))) {
            return target;
        }
        decoder = decoderLease->decoder;
        if (expectedCodec != nullptr && decoder->GetDecoder() != expectedCodec) {
            return target;
        }
    }
    target.callbackLease = std::move(callbackLease);
    target.ownerLease = std::move(ownerLease);
    target.decoderLease = std::move(decoderLease);
    target.decoder = std::move(decoder);
    target.codec = expectedCodec;
    target.generation = snapshot.generation;
    return target;
}

int64_t RegisterDecoderContext(const std::shared_ptr<DecoderContext>& ctx) {
    if (!ctx) {
        return 0;
    }
    const DecoderSessionIdentity owner =
        Render::SharedSessionSinkOwnerLease().snapshot();
    const auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!ownerLease) {
        return 0;
    }
    const int64_t handle = g_decoderRegistry.registerObject(ctx, owner);
    if (handle > 0) {
        ctx->owner = owner;
        ctx->boundOwner = owner;
        ctx->registryHandle = handle;
        if (ctx->decoderGeneration == 0) {
            ctx->decoderGeneration = g_nextDecoderGeneration.fetch_add(
                1, std::memory_order_acq_rel);
        }
        ctx->dropCounterGeneration = ctx->decoderGeneration;
    }
    return handle;
}

bool StopSoftwareWorker(DecoderContext* ctx, bool waitForCompletion = false) {
    if (!ctx) {
        return true;
    }
    bool shouldJoin = false;
    {
        std::lock_guard<std::mutex> lk(ctx->softMutex);
        ctx->softStop = true;
        ctx->softQueue.clear();
        ctx->softRedrawRequested = false;
        ctx->softRecovery.reset();
        shouldJoin = ctx->softThread.joinable();
    }
    ctx->softCv.notify_all();
    if (shouldJoin) {
        std::unique_lock<std::mutex> lock(ctx->softMutex);
        if (waitForCompletion) {
            ctx->softDoneCv.wait(lock, [ctx]() {
                return ctx->softDone.load(std::memory_order_acquire);
            });
        } else if (!ctx->softDoneCv.wait_for(lock, std::chrono::milliseconds(500), [ctx]() {
                    return ctx->softDone.load(std::memory_order_acquire);
                })) {
            return false;
        }
        lock.unlock();
        ctx->softThread.join();
    }
    {
        std::lock_guard<std::mutex> lk(ctx->softMutex);
        ctx->softStop = false;
        ctx->softRedrawRequested = false;
    }
    return true;
}

void ResetSoftwareTelemetry(DecoderContext* ctx) {
    if (!ctx) {
        return;
    }
    std::lock_guard<std::mutex> lk(ctx->softMutex);
    ctx->softQueue.clear();
    ctx->softRecovery.reset();
    ctx->softQueued.store(0, std::memory_order_release);
    ctx->softDecoded.store(0, std::memory_order_release);
    ctx->softDropped.store(0, std::memory_order_release);
    ctx->softSkippedPresent.store(0, std::memory_order_release);
}

void ResetDecoderTelemetry(DecoderContext* ctx) {
    if (!ctx) {
        return;
    }
    if (ctx->decoder) {
        ctx->decoder->ResetTelemetryCounters();
    }
    ctx->rendererPresentedFrames.store(0, std::memory_order_release);
    ctx->presentationDecoderGeneration.store(
        ctx->decoderGeneration, std::memory_order_release);
    ResetSoftwareTelemetry(ctx);
}

void RequestSoftwareRedraw(DecoderContext* ctx) {
    if (!ctx) {
        return;
    }
    {
        std::lock_guard<std::mutex> lk(ctx->softMutex);
        if (ctx->softStop) {
            return;
        }
        ctx->softRedrawRequested = true;
    }
    ctx->softCv.notify_one();
}

void StartSoftwareWorkerIfNeeded(DecoderContext* ctx) {
    if (!ctx) {
        return;
    }
    std::lock_guard<std::mutex> lk(ctx->softMutex);
    if (ctx->softThread.joinable() || !ctx->videoPipelineAttached) {
        return;
    }
    ctx->softStop = false;
    ctx->softDone.store(false, std::memory_order_release);
    const DecoderSessionIdentity owner = ctx->owner;
    ctx->softThread = std::thread([ctx, owner]() {
        OH_LOG_INFO(LOG_APP, "[Decoder] software decode worker started");
        while (true) {
            SoftQueuedFrame item;
            size_t queueLeft = 0;
            bool redrawOnly = false;
            {
                std::unique_lock<std::mutex> lk(ctx->softMutex);
                ctx->softCv.wait(lk, [ctx]() {
                    return ctx->softStop || ctx->softRedrawRequested || !ctx->softQueue.empty();
                });
                if (ctx->softStop) {
                    break;
                }
                if (ctx->softRedrawRequested) {
                    ctx->softRedrawRequested = false;
                    redrawOnly = true;
                } else {
                    item = std::move(ctx->softQueue.front());
                    ctx->softQueue.pop_front();
                    queueLeft = ctx->softQueue.size();
                }
            }

            if (redrawOnly) {
                const int64_t rendererHandle =
                    ctx->softRendererHandle.load(std::memory_order_acquire);
                if (rendererHandle > 0) {
                    if (owner.valid()) {
                        RendererNapi::RenderRetained(rendererHandle, owner);
                    } else {
                        RendererNapi::RenderRetained(rendererHandle);
                    }
                }
                continue;
            }

            if (!ctx->softwareDecoder || !ctx->softwareDecoder->IsInitialized() || item.data.empty()) {
                continue;
            }
            item.frame.data = item.data.data();
            item.frame.size = item.data.size();
            const bool presentOutput = Render::shouldPresentSoftwareDecodedFrame(queueLeft);
            uint64_t skippedPresent = ctx->softSkippedPresent.load(std::memory_order_acquire);
            if (!presentOutput) {
                skippedPresent = ctx->softSkippedPresent.fetch_add(1, std::memory_order_acq_rel) + 1;
            }
            const int ret = ctx->softwareDecoder->Decode(item.frame.data, item.frame.size,
                                                         item.frame.timestamp, item.frame.isKeyFrame,
                                                         presentOutput);
            const uint64_t decoded = ctx->softDecoded.fetch_add(1) + 1;
            const bool skippedLogDue = !presentOutput &&
                (skippedPresent <= 8 || skippedPresent % 120 == 0);
            const bool backlogLogDue = queueLeft > 8 && decoded % 30 == 0;
            if (decoded <= 5 || decoded % 120 == 0 || ret != 0 ||
                backlogLogDue || skippedLogDue) {
                OH_LOG_INFO(LOG_APP,
                            "[Decoder] software worker frame=%{public}llu ret=%{public}d codec=%{public}d size=%{public}zu queue=%{public}zu dropped=%{public}llu present=%{public}s skippedPresent=%{public}llu key=%{public}s",
                            static_cast<unsigned long long>(decoded),
                            ret,
                            static_cast<int>(item.frame.codec),
                            item.frame.size,
                            queueLeft,
                            static_cast<unsigned long long>(ctx->softDropped.load()),
                            presentOutput ? "yes" : "no",
                            static_cast<unsigned long long>(skippedPresent),
                            item.frame.isKeyFrame ? "yes" : "no");
            }
        }
        ctx->softDone.store(true, std::memory_order_release);
        ctx->softDoneCv.notify_all();
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
        if (!Render::ShouldAcceptSoftwareDecoderFrame(ctx->videoPipelineAttached, ctx->softStop)) {
            return -1;
        }
        const bool wasWaitingForKeyframe = ctx->softRecovery.waitingForKeyframe();
        const Render::SoftwareDecodeQueueAction action = ctx->softRecovery.classify(
            ctx->softQueue.size() >= kMaxSoftwareDecodeQueue, frame.isKeyFrame);
        if (action == Render::SoftwareDecodeQueueAction::DropWaitingKeyframe) {
            dropped = ctx->softDropped.fetch_add(1) + 1;
            if (dropped <= 8 || dropped % 60 == 0) {
                OH_LOG_WARN(LOG_APP,
                            "[Decoder] software queue waiting keyframe drop total=%{public}llu size=%{public}zu",
                            static_cast<unsigned long long>(dropped), frame.size);
            }
            return DecoderNapi::kDecodeSoftwareFrameDropped;
        }
        if (action == Render::SoftwareDecodeQueueAction::DropAndRequestKeyframe) {
            const size_t removed = ctx->softQueue.size();
            ctx->softQueue.clear();
            dropped = ctx->softDropped.fetch_add(removed + 1) + removed + 1;
            OH_LOG_WARN(LOG_APP,
                        "[Decoder] software queue overflow removed=%{public}zu totalDropped=%{public}llu incomingKey=no requestKeyframe=yes",
                        removed,
                        static_cast<unsigned long long>(dropped));
            return DecoderNapi::kDecodeSoftwareKeyframeRequired;
        }
        if (action == Render::SoftwareDecodeQueueAction::QueueAfterReset) {
            const size_t removed = ctx->softQueue.size();
            ctx->softQueue.clear();
            if (removed > 0) {
                dropped = ctx->softDropped.fetch_add(removed) + removed;
            }
            OH_LOG_INFO(LOG_APP,
                        "[Decoder] software queue accepted recovery keyframe removed=%{public}zu totalDropped=%{public}llu waited=%{public}s",
                        removed,
                        static_cast<unsigned long long>(ctx->softDropped.load()),
                        wasWaitingForKeyframe ? "yes" : "no");
        }
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

bool ConfigurePipeline(const std::shared_ptr<DecoderContext>& ctx,
                       bool ownerLeaseAlreadyHeld = false) {
    if (!ctx || ctx->rendererHandle <= 0 || !ctx->owner.valid()) {
        return false;
    }

    const int64_t rendererHandle = ctx->rendererHandle;
    const DecoderSessionIdentity owner = ctx->owner;
    if (ctx->useSoftware) {
        if (!ctx->softwareDecoder || !ctx->softwareDecoder->IsInitialized()) {
            return false;
        }
        const bool rendererBound = ownerLeaseAlreadyHeld ?
            (RendererNapi::SetActiveRenderer(rendererHandle),
             RendererNapi::IsActiveRendererForOwnerUnderLease(rendererHandle, owner)) :
            RendererNapi::SetActiveRenderer(rendererHandle, owner);
        if (!rendererBound) {
            return false;
        }
        if (ctx->width > 0 && ctx->height > 0) {
            if (ownerLeaseAlreadyHeld) {
                RendererNapi::SetActiveSourceSize(ctx->width, ctx->height);
            } else {
                RendererNapi::SetActiveSourceSize(owner, ctx->width, ctx->height);
            }
        }
        ctx->softRendererHandle.store(rendererHandle, std::memory_order_release);
        ctx->softwareDecoder->SetFrameCallback([owner](const uint8_t* data, size_t size,
                                                         int width, int height, int stride) {
            return RendererNapi::RenderRawBgraActive(owner, data, size, width, height, stride);
        });
        const std::weak_ptr<DecoderContext> weakContext = ctx;
        if (ownerLeaseAlreadyHeld) {
            RendererNapi::SetRendererRedrawCallback(rendererHandle, [weakContext]() {
                if (const auto context = weakContext.lock()) {
                    RequestSoftwareRedraw(context.get());
                }
            });
        } else {
            RendererNapi::SetRendererRedrawCallback(rendererHandle, owner, [weakContext]() {
                if (const auto context = weakContext.lock()) {
                    RequestSoftwareRedraw(context.get());
                }
            });
        }
        return true;
    }

    if (!ctx->decoder || !ctx->decoder->IsInitialized()) {
        return false;
    }
    ctx->softRendererHandle.store(0, std::memory_order_release);
    // Hardware output uses the same renderer viewport path as software output.
    // Publish the remote frame dimensions explicitly so a rotated page surface
    // cannot become the PIP content ratio before the first frame is presented.
    const bool rendererBound = ownerLeaseAlreadyHeld ?
        (RendererNapi::SetActiveRenderer(rendererHandle),
         RendererNapi::IsActiveRendererForOwnerUnderLease(rendererHandle, owner)) :
        RendererNapi::SetActiveRenderer(rendererHandle, owner);
    if (!rendererBound) {
        return false;
    }
    const uint64_t rendererGeneration = ownerLeaseAlreadyHeld
        ? RendererNapi::GetActiveRendererGenerationUnderOwnerLease(
              rendererHandle, owner)
        : RendererNapi::GetActiveRendererGeneration(rendererHandle, owner);
    if (rendererGeneration == 0U) {
        return false;
    }
    const uint64_t presentationDecoderGeneration = ctx->decoderGeneration;
    ctx->rendererGeneration.store(rendererGeneration, std::memory_order_release);
    ctx->presentationDecoderGeneration.store(
        presentationDecoderGeneration, std::memory_order_release);
    if (ctx->width > 0 && ctx->height > 0) {
        if (ownerLeaseAlreadyHeld) {
            RendererNapi::SetActiveSourceSize(ctx->width, ctx->height);
            RendererNapi::SetRendererSourceSize(
                rendererHandle, ctx->width, ctx->height);
        } else {
            RendererNapi::SetActiveSourceSize(owner, ctx->width, ctx->height);
            RendererNapi::SetRendererSourceSize(
                rendererHandle, owner, ctx->width, ctx->height);
        }
    }
    const std::weak_ptr<DecoderContext> weakContext = ctx;
    ctx->decoder->SetErrorCallback([weakContext](DecoderError error,
                                                   const std::string& message) {
        if (const auto context = weakContext.lock()) {
            const bool terminal = context->recoveryTerminal.load(
                std::memory_order_acquire);
            const bool alreadyRequested = context->recoveryRequested.exchange(
                true, std::memory_order_acq_rel);
            if (Render::ShouldArmDecoderRecovery(alreadyRequested, terminal)) {
                OH_LOG_WARN(LOG_APP,
                            "[Decoder] hardware recovery armed error=%{public}d reason=%{public}s",
                            static_cast<int>(error), message.c_str());
            } else if (terminal) {
                context->recoveryRequested.store(false, std::memory_order_release);
                OH_LOG_ERROR(LOG_APP,
                             "[Decoder] hardware recovery blocked after per-bind budget error=%{public}d reason=%{public}s",
                             static_cast<int>(error), message.c_str());
            }
        }
    });
    ctx->decoder->SetMakeCurrentCallback([rendererHandle, owner]() {
        RendererNapi::MakeCurrent(rendererHandle, owner);
    });
    ctx->decoder->SetReleaseCurrentCallback([rendererHandle, owner]() {
        RendererNapi::ReleaseCurrent(rendererHandle, owner);
    });
    ctx->decoder->SetFrameCallback(
        [rendererHandle, owner, weakContext, rendererGeneration,
         presentationDecoderGeneration](
            GLuint textureId, int, int,
            const Render::NativeImageTransform& textureTransform) {
            const RdpPresentMetrics present = RendererNapi::PresentNative(
                rendererHandle, owner, textureId, textureTransform);
            if (!present.presented() || present.generation != rendererGeneration) {
                return;
            }
            if (const auto context = weakContext.lock()) {
                if (context->presentationDecoderGeneration.load(
                        std::memory_order_acquire) !=
                        presentationDecoderGeneration ||
                    context->rendererGeneration.load(std::memory_order_acquire) !=
                        rendererGeneration ||
                    !context->videoPipelineAttached.load(
                        std::memory_order_acquire)) {
                    return;
                }
                SaturatingAdd(context->rendererPresentedFrames, 1);
            }
        });
    const std::weak_ptr<HardwareDecoder> weakDecoder = ctx->decoder;
    if (ownerLeaseAlreadyHeld) {
        RendererNapi::SetRendererRedrawCallback(rendererHandle, [weakDecoder]() {
            if (const auto decoder = weakDecoder.lock()) {
                decoder->RequestRedraw();
            }
        });
    } else {
        RendererNapi::SetRendererRedrawCallback(rendererHandle, owner, [weakDecoder]() {
            if (const auto decoder = weakDecoder.lock()) {
                decoder->RequestRedraw();
            }
        });
    }
    if (ownerLeaseAlreadyHeld) {
        RendererNapi::ReleaseCurrent(rendererHandle);
    } else {
        RendererNapi::ReleaseCurrent(rendererHandle, owner);
    }
    ctx->decoder->ResetSurfaceRecoveryForBind();
    ctx->decoder->StartRenderThread();
    return true;
}

bool RecreateDecoderForFrame(const std::shared_ptr<DecoderContext>& ctx, const VideoFrame& frame) {
    if (!ctx || frame.width <= 0 || frame.height <= 0) {
        return false;
    }

    const DecoderSessionIdentity owner = ctx->owner;
    if (ctx->rendererHandle > 0) {
        if (owner.valid()) {
            RendererNapi::SetRendererRedrawCallback(ctx->rendererHandle, owner, nullptr);
        } else {
            RendererNapi::SetRendererRedrawCallback(ctx->rendererHandle, nullptr);
        }
    }
    ctx->softRendererHandle.store(0, std::memory_order_release);
    StopSoftwareWorker(ctx.get());
    ctx->decoderGeneration = g_nextDecoderGeneration.fetch_add(
        1, std::memory_order_acq_rel);
    ctx->dropCounterGeneration = ctx->decoderGeneration;
    ResetDecoderTelemetry(ctx.get());
    if (ctx->decoder) {
        if (!StopHardwarePipeline(ctx->decoder, true)) {
            OH_LOG_ERROR(LOG_APP,
                         "[Decoder] recovery cannot stop previous hardware pipeline");
            return false;
        }
        ctx->decoder->Destroy();
        ctx->decoder.reset();
    }
    if (ctx->softwareDecoder) {
        ctx->softwareDecoder->Destroy();
        ctx->softwareDecoder.reset();
    }
    ctx->useSoftware = false;

    auto decoder = std::shared_ptr<HardwareDecoder>(new HardwareDecoder());
    if (!decoder->SetCallbackIdentity(ctx->registryHandle, owner,
                                      ctx->decoderGeneration)) {
        return false;
    }
    // Publish the strong decoder reference before Init registers platform
    // callbacks. The callback admission helper accepts the current decoder
    // during this transition, so early input/output notifications are retained
    // instead of leaving OH_AVCodec buffers in user ownership.
    ctx->decoder = decoder;
    if (ctx->rendererHandle > 0) {
        if (owner.valid()) {
            RendererNapi::MakeCurrent(ctx->rendererHandle, owner);
        } else {
            RendererNapi::MakeCurrent(ctx->rendererHandle);
        }
    }
    int result = decoder->Init(frame.width, frame.height, frame.codec, -1,
                               ctx->desktopSurfaceCompatibility,
                               ctx->presentationMode.load(std::memory_order_acquire));
    if (ctx->rendererHandle > 0) {
        if (owner.valid()) {
            RendererNapi::ReleaseCurrent(ctx->rendererHandle, owner);
        } else {
            RendererNapi::ReleaseCurrent(ctx->rendererHandle);
        }
    }
    if (result == 0) {
        ctx->width = frame.width;
        ctx->height = frame.height;
        ctx->observedFrameSize = true;
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

    // Init registered a platform callback context even when codec creation or
    // configuration failed.  Close it before dropping the decoder; the
    // context itself is retained by HardwareDecoder::Destroy for late raw
    // callbacks that the platform may still deliver.
    ctx->decoder->Destroy();
    ctx->decoder.reset();

    if (SoftwareDecoder::Supports(frame.codec)) {
        auto softwareDecoder = std::shared_ptr<SoftwareDecoder>(new SoftwareDecoder());
        int softResult = softwareDecoder->Init(frame.width, frame.height, frame.codec);
        if (softResult == 0) {
            ctx->softwareDecoder = softwareDecoder;
            ctx->useSoftware = true;
            ctx->width = frame.width;
            ctx->height = frame.height;
            ctx->observedFrameSize = true;
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

int DecodeNativeLocked(const std::shared_ptr<DecoderContext>& ctx, const VideoFrame& frame,
                       std::unique_lock<std::mutex>& pipelineLock,
                       HardwareDecodeAdmission* ownedHardwareAdmission = nullptr) {
    if (!ctx || !ctx->videoPipelineAttached ||
        ctx->pipelineTransitioning.load(std::memory_order_acquire)) {
        OH_LOG_WARN(LOG_APP, "[Decoder] native decode skipped: video pipeline detached");
        return -1;
    }
    if (frame.codec != CodecType::H264 && frame.codec != CodecType::H265 &&
        frame.codec != CodecType::VP8 && frame.codec != CodecType::VP9 &&
        frame.codec != CodecType::AV1) {
        OH_LOG_WARN(LOG_APP, "[Decoder] native decode skipped: unsupported codec=%{public}d size=%{public}zu",
                    static_cast<int>(frame.codec), frame.size);
        return -2;
    }
    if (frame.width > 0 && frame.height > 0) {
        ctx->width = frame.width;
        ctx->height = frame.height;
        ctx->observedFrameSize = true;
    }
    if (Render::ShouldDropFrameWhileWaitingRecoveryKeyframe(
        ctx->recoveryRequested.load(std::memory_order_acquire), frame.isKeyFrame)) {
        if (ctx->useSoftware) {
            const uint64_t dropped = ctx->softDropped.fetch_add(1,
                std::memory_order_acq_rel) + 1;
            if (dropped <= 8 || dropped % 60 == 0) {
                OH_LOG_WARN(LOG_APP,
                            "[Decoder] recovery waiting keyframe software drop total=%{public}llu",
                            static_cast<unsigned long long>(dropped));
            }
        }
        return 0;
    }
    if (Render::ShouldDecodeFrameTriggerRecovery(
        ctx->recoveryRequested.load(std::memory_order_acquire), frame.isKeyFrame)) {
        const uint32_t attemptsBefore = ctx->recoveryAttempts.load(
            std::memory_order_acquire);
        const bool terminal = ctx->recoveryTerminal.load(std::memory_order_acquire);
        if (!Render::CanStartDecoderRecovery(attemptsBefore, terminal)) {
            ctx->recoveryRequested.store(false, std::memory_order_release);
            ctx->recoveryTerminal.store(true, std::memory_order_release);
            ctx->videoPipelineAttached.store(false, std::memory_order_release);
            OH_LOG_ERROR(LOG_APP,
                         "[Decoder] recovery terminal: per-bind budget exhausted attempts=%{public}u",
                         attemptsBefore);
            return -4;
        }
        const uint32_t attempt = ctx->recoveryAttempts.fetch_add(
            1, std::memory_order_acq_rel) + 1;
        OH_LOG_INFO(LOG_APP,
                    "[Decoder] recovery recreating decoder attempt=%{public}u/%{public}u from keyframe codec=%{public}d size=%{public}dx%{public}d bytes=%{public}zu",
                    attempt,
                    Render::kMaxDecoderRecoveryAttemptsPerBinding,
                    static_cast<int>(frame.codec), frame.width, frame.height, frame.size);
        // Consume this recovery request before the old codec is stopped. A
        // callback from the newly created codec may arm the next request while
        // the recreation is in progress.
        ctx->recoveryRequested.store(false, std::memory_order_release);
        ctx->videoPipelineAttached.store(false, std::memory_order_release);
        ctx->pipelineTransitioning.store(true, std::memory_order_release);
        pipelineLock.unlock();
        const bool recreated = RecreateDecoderForFrame(ctx, frame);
        pipelineLock.lock();
        if (recreated && ctx->decoder) {
            // A platform update may arrive while recreation owns the decoder
            // outside pipelineMutex. Reapply the latest atomic value before
            // reopening frame admission so the new NativeImage cannot retain
            // the transform captured at the start of recovery.
            ctx->decoder->SetNativeImagePresentationMode(
                ctx->presentationMode.load(std::memory_order_acquire));
        }
        ctx->pipelineTransitioning.store(false, std::memory_order_release);
        ctx->pipelineTransitionCv.notify_all();
        if (!recreated) {
            ctx->recoveryRequested.store(false, std::memory_order_release);
            ctx->recoveryTerminal.store(true, std::memory_order_release);
            ctx->videoPipelineAttached.store(false, std::memory_order_release);
            OH_LOG_ERROR(LOG_APP,
                         "[Decoder] recovery terminal: decoder recreation failed attempt=%{public}u",
                         attempt);
            return -3;
        }
        ctx->videoPipelineAttached.store(true, std::memory_order_release);
        if (Render::ShouldEnterTerminalDecoderRecovery(true, attempt)) {
            ctx->recoveryTerminal.store(true, std::memory_order_release);
            ctx->recoveryRequested.store(false, std::memory_order_release);
            OH_LOG_WARN(LOG_APP,
                        "[Decoder] recovery budget exhausted after successful attempt=%{public}u; waiting for new bind",
                        attempt);
        }
    }

    const CodecType currentCodec = CurrentCodec(ctx.get());
    if (frame.codec != currentCodec) {
        OH_LOG_WARN(LOG_APP,
                    "[Decoder] native codec changed: decoder=%{public}d frame=%{public}d size=%{public}zu key=%{public}s frameSize=%{public}dx%{public}d",
                    static_cast<int>(currentCodec), static_cast<int>(frame.codec), frame.size,
                    frame.isKeyFrame ? "yes" : "no", frame.width, frame.height);
        if (!frame.isKeyFrame) {
            return -3;
        }
        ctx->videoPipelineAttached.store(false, std::memory_order_release);
        ctx->pipelineTransitioning.store(true, std::memory_order_release);
        pipelineLock.unlock();
        const bool recreated = RecreateDecoderForFrame(ctx, frame);
        pipelineLock.lock();
        if (recreated && ctx->decoder) {
            ctx->decoder->SetNativeImagePresentationMode(
                ctx->presentationMode.load(std::memory_order_acquire));
        }
        ctx->pipelineTransitioning.store(false, std::memory_order_release);
        ctx->pipelineTransitionCv.notify_all();
        if (!recreated) {
            return -3;
        }
        ctx->videoPipelineAttached.store(true, std::memory_order_release);
    }

    if (ctx->useSoftware) {
        if (!ctx->softwareDecoder || !ctx->softwareDecoder->IsInitialized()) {
            OH_LOG_WARN(LOG_APP, "[Decoder] native software decode skipped: decoder not ready");
            return -1;
        }
        // Queueing is not a sink write. The software worker's renderer
        // callback validates and leases the exact owner before presentation;
        // no owner gate is acquired while pipelineMutex is held here.
        return QueueSoftwareFrame(ctx.get(), frame);
    }
    if (!ctx->decoder || !ctx->decoder->IsInitialized()) {
        OH_LOG_WARN(LOG_APP, "[Decoder] native decode skipped: decoder not ready");
        return -1;
    }
    const int decodeResult = ownedHardwareAdmission != nullptr
        ? ctx->decoder->DecodeOwned(
              frame.data, frame.size, frame.timestamp, frame.isKeyFrame,
              *ownedHardwareAdmission)
        : ctx->decoder->Decode(
              frame.data, frame.size, frame.timestamp, frame.isKeyFrame);
    return decodeResult == HardwareDecoder::kDecodeKeyframeRequired ?
        DecoderNapi::kDecodeHardwareKeyframeRequired : decodeResult;
}

// Public/native callbacks must not hold g_activeDecoderOwnerMutex while
// entering either decoder.  SoftwareDecoder invokes its frame callback
// synchronously, and that callback may take the shared sink owner lease or
// initiate teardown.  Keep identity validation and the registry lease as the
// boundary, then call the decoder only after the owner mutex is released.
struct OwnedDecodeOutcome final {
    int legacy = DecoderNapi::kDecodeInactiveSession;
    DecoderNapi::OwnedSubmitStatus status =
        DecoderNapi::OwnedSubmitStatus::Stale;
};

OwnedDecodeOutcome DecodeNativeForOwnerOutcome(
    int64_t handle, const DecoderSessionIdentity& owner,
    const VideoFrame& frame, uint64_t expectedDecoderGeneration = 0U) {
    if (!owner.valid()) {
        return {};
    }

    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return {};
    }
    DecoderHandleLease decoderLease;
    {
        // Lock order for public decoder operations is shared owner lease,
        // active-owner mutex, registry lease, then pipeline mutex. No
        // decoder operation takes the owner gate or active-owner mutex back
        // while holding the pipeline mutex.
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (!Render::SessionOwnerMatches(g_activeDecoderOwner, owner) ||
            g_activeDecoderHandle.load(std::memory_order_acquire) != handle) {
            return {};
        }
        decoderLease = g_decoderRegistry.acquire(handle, owner);
    }
    if (!decoderLease) {
        return {};
    }
    // Release the owner gate before taking pipelineMutex or joining/recreating
    // decoder workers. Sink writes validate and lease the exact owner at their
    // own callback boundary, so a pending S1->S2 writer cannot deadlock a
    // decoder transition that is waiting for a worker callback.
    sinkLease = {};

    // The RustDesk stream callback is a transport-facing path. A decoder
    // transition may take the same mutex while stopping/recreating workers;
    // waiting here would turn that transition into a network receive stall.
    // Drop this frame and let the retained-keyframe/refresh path recover once
    // the new pipeline is published.
    std::unique_lock<std::mutex> pipelineLock(
        decoderLease->pipelineMutex, std::try_to_lock);
    if (!pipelineLock.owns_lock()) {
        OH_LOG_DEBUG(LOG_APP,
                     "[Decoder] native decode skipped: pipeline busy, retry via next frame");
        return {-1, DecoderNapi::OwnedSubmitStatus::Backpressure};
    }
    if (g_activeDecoderHandle.load(std::memory_order_acquire) != handle) {
        return {};
    }
    if (decoderLease->pipelineTransitioning.load(std::memory_order_acquire)) {
        return {DecoderNapi::kDecodeInactiveSession,
                DecoderNapi::OwnedSubmitStatus::Backpressure};
    }
    if (expectedDecoderGeneration != 0U &&
        decoderLease->decoderGeneration != expectedDecoderGeneration) {
        return {};
    }
    if (!decoderLease->videoPipelineAttached ||
        !Render::SessionOwnerMatches(decoderLease.owner(), owner)) {
        return {};
    }
    if (expectedDecoderGeneration != 0U &&
        decoderLease->recoveryRequested.load(std::memory_order_acquire) &&
        !frame.isKeyFrame) {
        return {0, DecoderNapi::OwnedSubmitStatus::NeedKeyframe};
    }
    HardwareDecodeAdmission hardwareAdmission = HardwareDecodeAdmission::Failed;
    const int result = DecodeNativeLocked(
        decoderLease.shared(), frame, pipelineLock,
        expectedDecoderGeneration != 0U ? &hardwareAdmission : nullptr);
    if (expectedDecoderGeneration != 0U && !decoderLease->useSoftware) {
        switch (hardwareAdmission) {
            case HardwareDecodeAdmission::Queued:
                return {result, DecoderNapi::OwnedSubmitStatus::Accepted};
            case HardwareDecodeAdmission::Backpressure:
                return {result, DecoderNapi::OwnedSubmitStatus::Backpressure};
            case HardwareDecodeAdmission::NeedKeyframe:
                // DecodeNativeLocked() queued the current frame after a soft
                // drop. This is a refresh request, not a hard decoder gate.
                // Returning NeedKeyframe here used to make common-c discard
                // every following P-frame until an IDR arrived, producing a
                // 10-20 second freeze during high-motion 4K content.
                return {result,
                        DecoderNapi::OwnedSubmitStatus::AcceptedNeedsKeyframe};
            case HardwareDecodeAdmission::Failed:
                return {result, DecoderNapi::OwnedSubmitStatus::Failed};
        }
    }
    if (expectedDecoderGeneration != 0U && decoderLease->useSoftware) {
        return {result, DecoderNapi::OwnedSubmitStatus::Failed};
    }
    if (result == 0) {
        return {result, DecoderNapi::OwnedSubmitStatus::Accepted};
    }
    if (result == DecoderNapi::kDecodeSoftwareFrameDropped) {
        return {result, DecoderNapi::OwnedSubmitStatus::Backpressure};
    }
    if (result == DecoderNapi::kDecodeSoftwareKeyframeRequired ||
        result == DecoderNapi::kDecodeHardwareKeyframeRequired) {
        return {result, DecoderNapi::OwnedSubmitStatus::NeedKeyframe};
    }
    return {result, DecoderNapi::OwnedSubmitStatus::Failed};
}

int DecodeNativeForOwner(int64_t handle, const DecoderSessionIdentity& owner,
                         const VideoFrame& frame) {
    return DecodeNativeForOwnerOutcome(handle, owner, frame).legacy;
}

int DecodePublicNative(int64_t handle, const DecoderSessionIdentity& owner,
                       const uint8_t* data, size_t size, uint64_t timestamp) {
    if (!owner.valid()) {
        return DecoderNapi::kDecodeInactiveSession;
    }
    VideoFrame frame;
    frame.data = data;
    frame.size = size;
    frame.timestamp = timestamp;
    frame.isKeyFrame = false;
    frame.display = 0;
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return DecoderNapi::kDecodeInactiveSession;
    }
    DecoderHandleLease decoderLease;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (!Render::SessionOwnerMatches(g_activeDecoderOwner, owner) ||
            g_activeDecoderHandle.load(std::memory_order_acquire) != handle) {
            return DecoderNapi::kDecodeInactiveSession;
        }
        decoderLease = g_decoderRegistry.acquire(handle, owner);
    }
    if (!decoderLease) {
        return DecoderNapi::kDecodeInactiveSession;
    }
    {
        std::lock_guard<std::mutex> pipelineLock(decoderLease->pipelineMutex);
        if (decoderLease->pipelineTransitioning.load(std::memory_order_acquire) ||
            !decoderLease->videoPipelineAttached) {
            return DecoderNapi::kDecodeInactiveSession;
        }
        frame.width = decoderLease->width;
        frame.height = decoderLease->height;
        frame.codec = CurrentCodec(decoderLease.operator->());
    }
    // The helper reacquires the owner lease for the actual decode boundary.
    // Do not rely on recursive shared_mutex behavior here.
    sinkLease = {};
    // The helper also obtains its own registry operation lease. Release this
    // snapshot-only lease before crossing that boundary for the same reason.
    decoderLease = {};
    return DecodeNativeForOwner(handle, owner, frame);
}

void DestroyDecoderContext(const std::shared_ptr<DecoderContext>& ctx,
                           const DecoderSessionIdentity& owner,
                           bool deferredOwner = false) {
    if (!ctx) {
        return;
    }
    int64_t rendererHandle = 0;
    bool software = false;
    std::shared_ptr<HardwareDecoder> decoder;
    std::shared_ptr<SoftwareDecoder> softwareDecoder;
    // phase 1 means the caller timed out waiting for another pipeline
    // transition; phase 2 means this destroy already owns the transition and
    // only a decoder/software worker remains. Keeping those phases distinct
    // prevents a retry after a transition-wait timeout from skipping the
    // admission boundary and touching a concurrently rebinding decoder.
    const int deferredPhase = ctx->deferredDestroyPhase.exchange(
        0, std::memory_order_acq_rel);
    const bool resumeDeferred = deferredPhase == 2;
    {
        std::unique_lock<std::mutex> pipelineLock(ctx->pipelineMutex);
        if (!resumeDeferred) {
            const bool transitionReady = deferredOwner ?
                (ctx->pipelineTransitionCv.wait(
                    pipelineLock, [&ctx]() {
                        return !ctx->pipelineTransitioning.load(
                            std::memory_order_acquire);
                    }), true) :
                ctx->pipelineTransitionCv.wait_for(
                    pipelineLock, std::chrono::milliseconds(500), [&ctx]() {
                        return !ctx->pipelineTransitioning.load(
                            std::memory_order_acquire);
                    });
            if (!transitionReady) {
                ctx->deferredDestroyPhase.store(1, std::memory_order_release);
                auto retained = ctx;
                decoderRetireOwner().enqueue(retained, [retained, owner]() {
                    DestroyDecoderContext(retained, owner, true);
                    // DestroyDecoderContext either reaches phase 0 or queues
                    // the next owned phase before returning. The current job
                    // therefore has a terminal ownership outcome here.
                    return true;
                });
                return;
            }
            ctx->pipelineTransitioning.store(true, std::memory_order_release);
            ctx->videoPipelineAttached.store(false, std::memory_order_release);
            ctx->owner = DecoderSessionIdentity {};
            ctx->softRendererHandle.store(0, std::memory_order_release);
            rendererHandle = ctx->rendererHandle;
            ctx->retiringRendererHandle = rendererHandle;
            ctx->rendererHandle = 0;
        } else {
            rendererHandle = ctx->retiringRendererHandle;
        }
        software = ctx->useSoftware;
        decoder = ctx->decoder;
        softwareDecoder = ctx->softwareDecoder;
    }

    // Clear callback gates before waiting for worker/render threads. No
    // decoder mutex is held while those threads may synchronously enter a
    // renderer/audio owner lease.
    if (software) {
        if (!StopSoftwareWorker(ctx.get(), deferredOwner)) {
            ctx->deferredDestroyPhase.store(2, std::memory_order_release);
            auto retained = ctx;
            decoderRetireOwner().enqueue(retained, [retained, owner]() {
                DestroyDecoderContext(retained, owner, true);
                return true;
            });
            return;
        }
        if (softwareDecoder) {
            softwareDecoder->SetFrameCallback(nullptr);
        }
    } else if (decoder) {
        decoder->SetFrameCallback(nullptr);
        decoder->SetMakeCurrentCallback(nullptr);
        decoder->SetReleaseCurrentCallback(nullptr);
        if (!StopHardwarePipeline(decoder, deferredOwner)) {
            ctx->deferredDestroyPhase.store(2, std::memory_order_release);
            auto retained = ctx;
            decoderRetireOwner().enqueue(retained, [retained, owner]() {
                DestroyDecoderContext(retained, owner, true);
                return true;
            });
            return;
        }
    }
    ResetDecoderTelemetry(ctx.get());
    if (decoder) {
        decoder->Destroy();
    }
    if (softwareDecoder) {
        softwareDecoder->Destroy();
    }
    if (rendererHandle > 0) {
        if (owner.valid()) {
            RendererNapi::SetRendererRedrawCallback(rendererHandle, owner, nullptr);
        } else {
            RendererNapi::SetRendererRedrawCallback(rendererHandle, nullptr);
        }
    }
    {
        std::lock_guard<std::mutex> pipelineLock(ctx->pipelineMutex);
        ctx->decoder.reset();
        ctx->softwareDecoder.reset();
        ctx->retiringRendererHandle = 0;
        ctx->pipelineTransitioning.store(false, std::memory_order_release);
        ctx->pipelineTransitionCv.notify_all();
    }
}

} // namespace

#if defined(RDP_NATIVE_CALLBACK_TESTING)
namespace DecoderNapi {

std::shared_ptr<HardwareDecoder> RegisterCallbackTestDecoder(
    const DecoderSessionIdentity& owner, int64_t& handle) {
    handle = 0;
    const auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!owner.valid() || !ownerLease) {
        return nullptr;
    }
    auto ctx = std::make_shared<DecoderContext>();
    ctx->owner = owner;
    ctx->boundOwner = owner;
    ctx->decoderGeneration = g_nextDecoderGeneration.fetch_add(
        1, std::memory_order_acq_rel);
    ctx->dropCounterGeneration = ctx->decoderGeneration;
    auto decoder = std::make_shared<HardwareDecoder>();
    handle = g_decoderRegistry.registerObject(ctx, owner);
    if (handle <= 0 || !decoder->SetCallbackIdentity(handle, owner, ctx->decoderGeneration)) {
        if (handle > 0) {
            g_decoderRegistry.destroy(handle, owner);
        }
        handle = 0;
        decoder->Destroy();
        return nullptr;
    }
    ctx->registryHandle = handle;
    ctx->decoder = decoder;
    ctx->videoPipelineAttached.store(true, std::memory_order_release);
    return decoder;
}

bool SetCallbackTestPipelineState(int64_t handle,
                                  const DecoderSessionIdentity& owner,
                                  bool attached, bool transitioning) {
    auto lease = g_decoderRegistry.acquire(handle, owner);
    if (!lease) {
        return false;
    }
    std::lock_guard<std::mutex> pipelineLock(lease->pipelineMutex);
    lease->videoPipelineAttached.store(attached, std::memory_order_release);
    lease->pipelineTransitioning.store(transitioning, std::memory_order_release);
    return true;
}

bool PublishCallbackTestDecoder(
    int64_t handle, const DecoderSessionIdentity& owner) {
    auto lease = g_decoderRegistry.acquire(handle, owner);
    if (!lease || !owner.valid() ||
        !Render::SharedSessionSinkOwnerLease().accepts(owner)) {
        return false;
    }
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (!Render::SessionOwnerMatches(g_activeDecoderOwner, owner)) {
            return false;
        }
        g_activeDecoderHandle.store(handle, std::memory_order_release);
    }
    return true;
}

OwnedSubmitStatus DecodeOwnedNativeForTesting(
    int64_t decoderHandle, uint64_t decoderGeneration,
    uint64_t displayGeneration, const DecoderSessionIdentity& owner,
    const VideoFrame& frame) {
    return DecodeOwnedNative(decoderHandle, decoderGeneration,
                             displayGeneration, owner, frame);
}

DecoderPresentationTelemetrySnapshot GetActivePresentationTelemetryForTesting(
    const DecoderSessionIdentity& expectedOwner) {
    return GetActivePresentationTelemetry(expectedOwner);
}

void DestroyCallbackTestDecoder(
    int64_t handle, const DecoderSessionIdentity& owner) {
    const auto ctx = g_decoderRegistry.destroy(handle, owner);
    if (ctx) {
        DestroyDecoderContext(ctx, owner);
    }
}

} // namespace DecoderNapi
#endif

/**
 * NAPI: initDecoder(width: number, height: number, codec: number,
 *                   rendererHandle?: number,
 *                   desktopSurfaceCompatibility?: boolean): number
 */
napi_value NapiInitDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t width, height, codecInt;
    napi_get_value_int32(env, args[0], &width);
    napi_get_value_int32(env, args[1], &height);
    napi_get_value_int32(env, args[2], &codecInt);
    int64_t rendererHandle = -1;
    if (argc >= 4 && args[3] != nullptr) {
        napi_get_value_int64(env, args[3], &rendererHandle);
    }
    bool desktopSurfaceCompatibility = false;
    if (argc >= 5 && args[4] != nullptr) {
        napi_get_value_bool(env, args[4], &desktopSurfaceCompatibility);
    }

    CodecType codec = static_cast<CodecType>(codecInt);

    // Register the opaque context before starting OH_AVCodec so every
    // callback can resolve token -> owner/generation -> strong decoder lease.
    auto ctx = std::make_shared<DecoderContext>();
    ctx->useSoftware = false;
    ctx->desktopSurfaceCompatibility = desktopSurfaceCompatibility;
    ctx->width = width;
    ctx->height = height;
    const int64_t handleValue = RegisterDecoderContext(ctx);
    if (handleValue > 0) {
        {
            std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
            if (Render::SessionOwnerMatches(g_activeDecoderOwner, ctx->owner)) {
                ctx->presentationMode.store(
                    g_activeNativeImagePresentationMode.load(std::memory_order_acquire),
                    std::memory_order_release);
            }
        }
        auto decoder = std::shared_ptr<HardwareDecoder>(new HardwareDecoder());
        if (decoder->SetCallbackIdentity(handleValue, ctx->owner,
                                          ctx->decoderGeneration)) {
            ctx->decoder = decoder;
            const int result = decoder->Init(
                width, height, codec, rendererHandle,
                desktopSurfaceCompatibility,
                ctx->presentationMode.load(std::memory_order_acquire));
            if (result == 0) {
                napi_value handle;
                napi_create_int64(env, handleValue, &handle);
                return handle;
            }
            // The callback context is closed before the registry entry is
            // removed, so an old codec callback cannot race fallback setup.
            decoder->Destroy();
            ctx->decoder.reset();
        }
        g_decoderRegistry.destroy(handleValue, ctx->boundOwner);
    }

    int result = -1;

    if (SoftwareDecoder::Supports(codec)) {
        auto softwareDecoder = std::shared_ptr<SoftwareDecoder>(new SoftwareDecoder());
        int softResult = softwareDecoder->Init(width, height, codec);
        if (softResult == 0) {
            auto softwareCtx = std::make_shared<DecoderContext>();
            softwareCtx->softwareDecoder = softwareDecoder;
            softwareCtx->useSoftware = true;
            softwareCtx->desktopSurfaceCompatibility =
                desktopSurfaceCompatibility;
            softwareCtx->presentationMode.store(
                ctx->presentationMode.load(std::memory_order_acquire),
                std::memory_order_release);
            softwareCtx->width = width;
            softwareCtx->height = height;
            const int64_t softwareHandle = RegisterDecoderContext(softwareCtx);
            if (softwareHandle <= 0) {
                softwareDecoder->Destroy();
                napi_value errVal;
                napi_create_int32(env, -1, &errVal);
                return errVal;
            }
            napi_value handle;
            napi_create_int64(env, softwareHandle, &handle);
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

    void* data = nullptr;
    size_t size = 0;
    napi_get_arraybuffer_info(env, args[1], &data, &size);

    int64_t timestamp = 0;
    napi_get_value_int64(env, args[3], &timestamp);

    DecoderSessionIdentity owner;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        owner = g_activeDecoderOwner;
    }
    const int result = DecodePublicNative(handleVal, owner,
                                          static_cast<const uint8_t*>(data), size,
                                          static_cast<uint64_t>(timestamp));

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
    DecoderSessionIdentity owner;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        owner = g_activeDecoderOwner;
    }
    const auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    DecoderHandleLease decoderLease;
    bool isActive = false;
    if (sinkLease) {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        isActive = Render::SessionOwnerMatches(g_activeDecoderOwner, owner) &&
            g_activeDecoderHandle.load(std::memory_order_acquire) == handleVal;
        if (isActive) {
            decoderLease = g_decoderRegistry.acquire(handleVal, owner);
        }
    }

    int32_t texId = 0;
    if (isActive && decoderLease) {
        std::lock_guard<std::mutex> lock(decoderLease->pipelineMutex);
        if (!decoderLease->useSoftware && decoderLease->decoder) {
            texId = static_cast<int32_t>(decoderLease->decoder->GetTextureId());
        }
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
    const DecoderSessionIdentity owner = Render::SharedSessionSinkOwnerLease().snapshot();
    if (owner.valid()) {
        DecoderNapi::DeactivateDecoder(handleVal, owner);
        DecoderNapi::DestroyDecoderHandle(handleVal, owner);
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
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
    DecoderSessionIdentity owner;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        owner = g_activeDecoderOwner;
    }
    bool decoderReady = false;
    {
        const auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
        DecoderHandleLease decoderLease;
        if (sinkLease) {
            std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
            if (Render::SessionOwnerMatches(g_activeDecoderOwner, owner) &&
                g_activeDecoderHandle.load(std::memory_order_acquire) == handleVal) {
                decoderLease = g_decoderRegistry.acquire(handleVal, owner);
            }
        }
        if (decoderLease) {
            std::lock_guard<std::mutex> pipelineLock(decoderLease->pipelineMutex);
            decoderReady = !decoderLease->pipelineTransitioning.load(std::memory_order_acquire) &&
                decoderLease->videoPipelineAttached && !decoderLease->useSoftware &&
                decoderLease->decoder &&
                decoderLease->decoder->IsInitialized();
        }
    }
    if (!decoderReady) {
        OH_LOG_WARN(LOG_APP, "[Decoder] testDecoderH264: 解码器未就绪");
        napi_value r; napi_create_int32(env, -1, &r); return r;
    }
    VideoFrame testFrame;
    testFrame.data = H264_BLUE_IDR_64x64;
    testFrame.size = H264_BLUE_IDR_SIZE;
    testFrame.width = 64;
    testFrame.height = 64;
    testFrame.codec = CodecType::H264;
    testFrame.timestamp = 0;
    testFrame.isKeyFrame = true;
    testFrame.display = 0;
    const int ret = DecodeNativeForOwner(handleVal, owner, testFrame);
    OH_LOG_INFO(LOG_APP, "[Decoder] testDecoderH264: 已送入 %{public}zu bytes, ret=%{public}d",
                H264_BLUE_IDR_SIZE, ret);
    napi_value r; napi_create_int32(env, ret, &r); return r;
}
#endif

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

/**
 * NAPI: rebindActiveVideoPipeline(): boolean
 *
 * Background/PIP transfer deliberately deactivates the surviving decoder
 * token. A normal bind cannot acquire that token until it is activated again;
 * keep that lifecycle transaction in native code so every foreground/PIP
 * restore path uses the same owner and renderer validation.
 */
napi_value NapiRebindActiveVideoPipeline(napi_env env, napi_callback_info info) {
    (void)info;
    DecoderSessionIdentity owner;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        owner = g_activeDecoderOwner;
    }
    const bool rebound = DecoderNapi::RebindActiveVideoPipeline(owner);
    napi_value ret;
    napi_get_boolean(env, rebound, &ret);
    return ret;
}

void SetDecoderCapabilityBoolean(napi_env env, napi_value object,
                                 const char* name, bool value) {
    napi_value item = nullptr;
    if (napi_get_boolean(env, value, &item) == napi_ok) {
        (void)napi_set_named_property(env, object, name, item);
    }
}

void SetDecoderCapabilityInt32(napi_env env, napi_value object,
                               const char* name, int32_t value) {
    napi_value item = nullptr;
    if (napi_create_int32(env, value, &item) == napi_ok) {
        (void)napi_set_named_property(env, object, name, item);
    }
}

void SetDecoderCapabilityString(napi_env env, napi_value object,
                                const char* name, const char* value) {
    napi_value item = nullptr;
    const char* safe = value == nullptr ? "" : value;
    if (napi_create_string_utf8(env, safe, NAPI_AUTO_LENGTH, &item) == napi_ok) {
        (void)napi_set_named_property(env, object, name, item);
    }
}

napi_value HardwareDecoderCapabilityValue(napi_env env, const char* mime) {
    napi_value value = nullptr;
    (void)napi_create_object(env, &value);
    OH_AVCapability* capability =
        OH_AVCodec_GetCapabilityByCategory(mime, false, HARDWARE);
    const bool available = capability != nullptr &&
        OH_AVCapability_IsHardware(capability);
    OH_AVRange width {0, 0};
    OH_AVRange height {0, 0};
    OH_AVRange frameRate {0, 0};
    int32_t widthAlignment = 0;
    int32_t heightAlignment = 0;
    if (available) {
        if (OH_AVCapability_GetVideoWidthRange(capability, &width) != AV_ERR_OK) {
            width = {0, 0};
        }
        if (OH_AVCapability_GetVideoHeightRange(capability, &height) != AV_ERR_OK) {
            height = {0, 0};
        }
        if (OH_AVCapability_GetVideoFrameRateRange(capability, &frameRate) != AV_ERR_OK) {
            frameRate = {0, 0};
        }
        if (OH_AVCapability_GetVideoWidthAlignment(
                capability, &widthAlignment) != AV_ERR_OK) {
            widthAlignment = 0;
        }
        if (OH_AVCapability_GetVideoHeightAlignment(
                capability, &heightAlignment) != AV_ERR_OK) {
            heightAlignment = 0;
        }
    }
    SetDecoderCapabilityBoolean(env, value, "available", available);
    SetDecoderCapabilityString(env, value, "name",
        available ? OH_AVCapability_GetName(capability) : "");
    SetDecoderCapabilityInt32(env, value, "minWidth", width.minVal);
    SetDecoderCapabilityInt32(env, value, "maxWidth", width.maxVal);
    SetDecoderCapabilityInt32(env, value, "minHeight", height.minVal);
    SetDecoderCapabilityInt32(env, value, "maxHeight", height.maxVal);
    SetDecoderCapabilityInt32(env, value, "minFps", frameRate.minVal);
    SetDecoderCapabilityInt32(env, value, "maxFps", frameRate.maxVal);
    SetDecoderCapabilityInt32(env, value, "widthAlignment", widthAlignment);
    SetDecoderCapabilityInt32(env, value, "heightAlignment", heightAlignment);
    SetDecoderCapabilityBoolean(env, value, "lowLatency",
        available && OH_AVCapability_IsFeatureSupported(
            capability, VIDEO_LOW_LATENCY));
    return value;
}

/** Runtime truth for Moonlight's hardware-only video choices. */
napi_value NapiGetHardwareVideoDecoderCapabilities(
    napi_env env, napi_callback_info info) {
    (void)info;
    napi_value result = nullptr;
    (void)napi_create_object(env, &result);
    (void)napi_set_named_property(env, result, "h264",
        HardwareDecoderCapabilityValue(env, OH_AVCODEC_MIMETYPE_VIDEO_AVC));
    (void)napi_set_named_property(env, result, "hevc",
        HardwareDecoderCapabilityValue(env, OH_AVCODEC_MIMETYPE_VIDEO_HEVC));
    (void)napi_set_named_property(env, result, "av1",
        HardwareDecoderCapabilityValue(env, OH_AVCODEC_MIMETYPE_VIDEO_AV1));
    return result;
}

int DecoderNapi::DecodeNative(int64_t handle, const VideoFrame& frame) {
    DecoderSessionIdentity owner;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        owner = g_activeDecoderOwner;
    }
    return DecodeNativeForOwner(handle, owner, frame);
}

bool DecoderNapi::IsActiveSessionOwner(const DecoderSessionIdentity& owner) {
    std::lock_guard<std::mutex> lock(g_activeDecoderOwnerMutex);
    return Render::SessionOwnerMatches(g_activeDecoderOwner, owner);
}

bool DecoderNapi::IsActiveDisplayFrame(const DecoderSessionIdentity& owner,
                                       const VideoFrame& frame) {
    std::lock_guard<std::mutex> lock(g_activeDecoderOwnerMutex);
    if (!Render::SessionOwnerMatches(g_activeDecoderOwner, owner)) {
        return false;
    }
    int activeDisplay = g_activeDisplay.load(std::memory_order_acquire);
    if (activeDisplay < 0) {
        activeDisplay = frame.display;
        g_activeDisplay.store(activeDisplay, std::memory_order_release);
        g_activeDisplayGeneration.fetch_add(1, std::memory_order_acq_rel);
    }
    return activeDisplay >= 0 && frame.display == activeDisplay;
}

int DecoderNapi::DecodeActiveNative(const DecoderSessionIdentity& owner,
                                    const VideoFrame& frame) {
    int activeDisplay = -1;
    int64_t handle = 0;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (!Render::SessionOwnerMatches(g_activeDecoderOwner, owner)) {
            return kDecodeInactiveSession;
        }
        activeDisplay = g_activeDisplay.load(std::memory_order_acquire);
        handle = g_activeDecoderHandle.load(std::memory_order_acquire);
    }
    if (activeDisplay < 0 || frame.display != activeDisplay) {
        return kDecodeInactiveDisplay;
    }
    if (handle <= 0) {
        OH_LOG_WARN(LOG_APP, "[Decoder] native decode skipped: no active video pipeline");
        return -1;
    }
    return DecodeNativeForOwner(handle, owner, frame);
}

DecoderNapi::OwnedSubmitStatus DecoderNapi::DecodeOwnedNative(
    int64_t decoderHandle, uint64_t decoderGeneration,
    uint64_t displayGeneration, const DecoderSessionIdentity& owner,
    const VideoFrame& frame) {
    if (decoderHandle <= 0 || decoderGeneration == 0U ||
        displayGeneration == 0U) {
        return OwnedSubmitStatus::Stale;
    }
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (!Render::SessionOwnerMatches(g_activeDecoderOwner, owner)) {
            return OwnedSubmitStatus::Stale;
        }
        const int activeDisplay = g_activeDisplay.load(std::memory_order_acquire);
        // Phone/Pad Surface sessions deliberately use display=-1: they bind
        // the codec directly to the native window and do not select a
        // RustDesk display. Keep that sentinel valid while retaining exact
        // display matching whenever a RustDesk display is active.
        const bool displayMatches = activeDisplay < 0
            ? frame.display < 0
            : frame.display == activeDisplay;
        if (!displayMatches ||
            g_activeDisplayGeneration.load(std::memory_order_acquire) !=
                displayGeneration ||
            g_activeDecoderHandle.load(std::memory_order_acquire) !=
                decoderHandle) {
            return OwnedSubmitStatus::Stale;
        }
    }
    return DecodeNativeForOwnerOutcome(
        decoderHandle, owner, frame, decoderGeneration).status;
}

void DecoderNapi::DeactivateDecoder(int64_t handle) {
    if (handle <= 0) {
        return;
    }
    DecoderSessionIdentity owner;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        owner = g_activeDecoderOwner;
    }
    if (owner.valid()) {
        DeactivateDecoder(handle, owner);
    }
}

void DecoderNapi::DeactivateDecoder(
    int64_t handle, const DecoderSessionIdentity& owner) {
    if (handle <= 0 || !owner.valid()) {
        return;
    }
    const auto metadata = g_decoderRegistry.snapshot(handle);
    if (!metadata.found || metadata.boundOwner != owner) {
        return;
    }
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (!Render::SessionOwnerMatches(g_activeDecoderOwner, owner) ||
            g_activeDecoderHandle.load(std::memory_order_acquire) != handle) {
            return;
        }
        g_activeDecoderHandle.store(0, std::memory_order_release);
    }
    g_decoderRegistry.deactivate(handle, owner);
}

void DecoderNapi::DestroyDecoderHandle(int64_t handle) {
    if (handle <= 0) {
        return;
    }
    const auto metadata = g_decoderRegistry.snapshot(handle);
    if (!metadata.found) {
        return;
    }
    auto ctx = g_decoderRegistry.destroy(handle);
    if (!ctx) {
        return;
    }
    const DecoderSessionIdentity owner = ctx->boundOwner;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (g_activeDecoderHandle.load(std::memory_order_acquire) == handle) {
            g_activeDecoderHandle.store(0, std::memory_order_release);
        }
    }
    DestroyDecoderContext(ctx, owner);
}

void DecoderNapi::DestroyDecoderHandle(
    int64_t handle, const DecoderSessionIdentity& owner) {
    if (handle <= 0 || !owner.valid()) {
        return;
    }
    const auto metadata = g_decoderRegistry.snapshot(handle);
    if (!metadata.found || metadata.boundOwner != owner) {
        return;
    }
    const bool wasActive = [&]() {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        return g_activeDecoderHandle.load(std::memory_order_acquire) == handle &&
            Render::SessionOwnerMatches(g_activeDecoderOwner, owner);
    }();
    auto ctx = g_decoderRegistry.destroy(handle, owner);
    if (!ctx) {
        return;
    }
    if (wasActive) {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (g_activeDecoderHandle.load(std::memory_order_acquire) == handle &&
            Render::SessionOwnerMatches(g_activeDecoderOwner, owner)) {
            g_activeDecoderHandle.store(0, std::memory_order_release);
        }
    }
    DestroyDecoderContext(ctx, owner);
}

DecoderTelemetrySnapshot DecoderNapi::GetActiveTelemetry(
    const DecoderSessionIdentity& expectedOwner) {
    DecoderTelemetrySnapshot snapshot;
    int64_t handle = 0;
    const auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(expectedOwner);
    if (!sinkLease) {
        return snapshot;
    }
    DecoderHandleLease decoderLease;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (!Render::SessionOwnerMatches(g_activeDecoderOwner, expectedOwner)) {
            return snapshot;
        }
        handle = g_activeDecoderHandle.load(std::memory_order_acquire);
        decoderLease = g_decoderRegistry.acquire(handle, expectedOwner);
    }
    if (!decoderLease) {
        return snapshot;
    }
    std::lock_guard<std::mutex> pipelineLock(decoderLease->pipelineMutex);
    if (decoderLease->pipelineTransitioning.load(std::memory_order_acquire) ||
        !decoderLease->videoPipelineAttached ||
        !Render::SessionOwnerMatches(decoderLease.owner(), expectedOwner)) {
        return DecoderTelemetrySnapshot {};
    }
    if (g_activeDecoderHandle.load(std::memory_order_acquire) != handle) {
        return DecoderTelemetrySnapshot {};
    }
    snapshot.valid = true;
    snapshot.owner = decoderLease.owner();
    snapshot.decoderGeneration = decoderLease->decoderGeneration;
    snapshot.dropCounterGeneration = decoderLease->dropCounterGeneration;
    snapshot.displayGeneration = g_activeDisplayGeneration.load(std::memory_order_acquire);
    snapshot.display = g_activeDisplay.load(std::memory_order_acquire);
    snapshot.software = decoderLease->useSoftware;
    snapshot.width = decoderLease->width;
    snapshot.height = decoderLease->height;
    if (decoderLease->useSoftware) {
        std::lock_guard<std::mutex> lk(decoderLease->softMutex);
        snapshot.queueDepth = decoderLease->softQueue.size();
        snapshot.queueMax = kMaxSoftwareDecodeQueue;
        snapshot.inputDroppedFrames = decoderLease->softDropped.load(std::memory_order_acquire);
        snapshot.droppedFrames = snapshot.inputDroppedFrames;
        if (decoderLease->softwareDecoder) {
            snapshot.codec = static_cast<int>(decoderLease->softwareDecoder->GetCodecType());
            snapshot.ready = decoderLease->softwareDecoder->IsInitialized();
        }
    } else if (decoderLease->decoder) {
        const HardwareTelemetrySnapshot hardware = decoderLease->decoder->GetTelemetrySnapshot();
        snapshot.queueDepth = hardware.queueDepth;
        snapshot.inputDroppedFrames = hardware.inputDroppedFrames;
        snapshot.droppedFrames = hardware.inputDroppedFrames;
        snapshot.waitKeyframeDrops = hardware.waitKeyframeDrops;
        snapshot.codecLatencyMs = hardware.codecLatencyMs;
        snapshot.codecLatencyMaxMs = hardware.codecLatencyMaxMs;
        snapshot.lowLatencyEnabled = hardware.lowLatencyEnabled;
        snapshot.codec = static_cast<int>(hardware.codec);
        snapshot.ready = hardware.initialized;
    }
    return snapshot;
}

DecoderPresentationTelemetrySnapshot DecoderNapi::GetActivePresentationTelemetry(
    const DecoderSessionIdentity& expectedOwner) {
    DecoderPresentationTelemetrySnapshot snapshot;
    int64_t handle = 0;
    const auto sinkLease =
        Render::SharedSessionSinkOwnerLease().acquire(expectedOwner);
    if (!sinkLease) {
        return snapshot;
    }
    DecoderHandleLease decoderLease;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (!Render::SessionOwnerMatches(g_activeDecoderOwner, expectedOwner)) {
            return snapshot;
        }
        handle = g_activeDecoderHandle.load(std::memory_order_acquire);
        decoderLease = g_decoderRegistry.acquire(handle, expectedOwner);
    }
    if (!decoderLease) {
        return snapshot;
    }
    std::lock_guard<std::mutex> pipelineLock(decoderLease->pipelineMutex);
    if (decoderLease->pipelineTransitioning.load(std::memory_order_acquire) ||
        !decoderLease->videoPipelineAttached ||
        !Render::SessionOwnerMatches(decoderLease.owner(), expectedOwner) ||
        g_activeDecoderHandle.load(std::memory_order_acquire) != handle) {
        return {};
    }
    const uint64_t presentationDecoderGeneration =
        decoderLease->presentationDecoderGeneration.load(
            std::memory_order_acquire);
    const uint64_t rendererGeneration =
        decoderLease->rendererGeneration.load(std::memory_order_acquire);
    if (presentationDecoderGeneration != decoderLease->decoderGeneration) {
        return {};
    }
    if (decoderLease->rendererHandle > 0) {
        const uint64_t activeRendererGeneration =
            RendererNapi::GetActiveRendererGenerationUnderOwnerLease(
                decoderLease->rendererHandle, expectedOwner);
        if (rendererGeneration == 0U ||
            activeRendererGeneration != rendererGeneration) {
            return {};
        }
    }
    snapshot.valid = true;
    snapshot.owner = decoderLease.owner();
    snapshot.decoderHandle = handle;
    snapshot.rendererHandle = decoderLease->rendererHandle;
    snapshot.decoderGeneration = decoderLease->decoderGeneration;
    snapshot.displayGeneration =
        g_activeDisplayGeneration.load(std::memory_order_acquire);
    snapshot.display = g_activeDisplay.load(std::memory_order_acquire);
    snapshot.rendererGeneration = rendererGeneration;
    snapshot.rendererPresentedFrames =
        decoderLease->rendererPresentedFrames.load(std::memory_order_acquire);
    snapshot.width = decoderLease->width;
    snapshot.height = decoderLease->height;
    snapshot.hardware = !decoderLease->useSoftware;
    if (decoderLease->useSoftware) {
        if (decoderLease->softwareDecoder) {
            snapshot.codec =
                static_cast<int>(decoderLease->softwareDecoder->GetCodecType());
            snapshot.ready = decoderLease->softwareDecoder->IsInitialized();
        }
    } else if (decoderLease->decoder) {
        const HardwareTelemetrySnapshot hardware =
            decoderLease->decoder->GetTelemetrySnapshot();
        snapshot.codec = static_cast<int>(hardware.codec);
        snapshot.ready = hardware.initialized;
        snapshot.renderedOutputBuffers = hardware.renderedOutputBuffers;
        snapshot.nativeImageFrames = hardware.outputFrames;
        snapshot.queueDepth = hardware.queueDepth;
        snapshot.inputDroppedFrames = hardware.inputDroppedFrames;
        snapshot.waitKeyframeDrops = hardware.waitKeyframeDrops;
        snapshot.inputTruncated = hardware.inputTruncated;
        snapshot.renderOutputFailures = hardware.renderOutputFailures;
        snapshot.updateSurfaceFailures = hardware.updateSurfaceFailures;
        snapshot.coalescedSurfaceNotifications =
            hardware.coalescedSurfaceNotifications;
        snapshot.codecLatencyMs = hardware.codecLatencyMs;
        snapshot.codecLatencyMaxMs = hardware.codecLatencyMaxMs;
        snapshot.lowLatencyEnabled = hardware.lowLatencyEnabled;
    }
    return snapshot;
}

OwnedDecoderCreationResult DecoderNapi::CreateOwnedHardwareDecoder(
    int width, int height, int codec, int64_t rendererHandle,
    const DecoderSessionIdentity& owner) {
    OwnedDecoderCreationResult result;
    if (width <= 0 || height <= 0 || rendererHandle <= 0 || !owner.valid() ||
        !Render::SharedSessionSinkOwnerLease().accepts(owner)) {
        return result;
    }
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (!Render::SessionOwnerMatches(g_activeDecoderOwner, owner)) {
            return result;
        }
    }

    auto ctx = std::make_shared<DecoderContext>();
    ctx->useSoftware = false;
    ctx->desktopSurfaceCompatibility = false;
    ctx->width = width;
    ctx->height = height;
    const int64_t handle = RegisterDecoderContext(ctx);
    if (handle <= 0) {
        return result;
    }
    auto decoder = std::shared_ptr<HardwareDecoder>(new HardwareDecoder());
    ctx->decoder = decoder;
    const CodecType exactCodec = static_cast<CodecType>(codec);
    if (!decoder->SetCallbackIdentity(handle, ctx->owner,
                                      ctx->decoderGeneration) ||
        decoder->Init(width, height, exactCodec, rendererHandle, false) != 0 ||
        !BindVideoPipeline(handle, rendererHandle, owner)) {
        DestroyDecoderHandle(handle, owner);
        return result;
    }
    const auto proof = GetActivePresentationTelemetry(owner);
    if (!proof.valid || !proof.ready || !proof.hardware ||
        proof.owner != owner || proof.decoderHandle != handle ||
        proof.rendererHandle != rendererHandle || proof.decoderGeneration == 0U ||
        proof.rendererGeneration == 0U) {
        DestroyDecoderHandle(handle, owner);
        return result;
    }
    result.ok = true;
    result.decoderHandle = handle;
    result.decoderGeneration = proof.decoderGeneration;
    result.displayGeneration = proof.displayGeneration;
    result.display = proof.display;
    result.rendererGeneration = proof.rendererGeneration;
    return result;
}

void DecoderNapi::SetActiveSessionId(const DecoderSessionIdentity& owner) {
    std::lock_guard<std::mutex> lock(g_activeDecoderOwnerMutex);
    if (Render::SessionOwnerMatches(g_activeDecoderOwner, owner)) {
        // A RustDesk transport reconnect keeps the native sink owner stable;
        // changing only its FFI admission epoch must not discard the active
        // decoder handle or selected display.
        return;
    }
    g_activeDecoderOwner = owner;
    g_activeNativeImagePresentationMode.store(
        Render::NativeImagePresentationMode::Identity,
        std::memory_order_release);
    g_activeDecoderHandle.store(0, std::memory_order_release);
    g_activeDisplay.store(-1, std::memory_order_release);
    g_activeDisplayGeneration.fetch_add(1, std::memory_order_acq_rel);
}

void DecoderNapi::ClearActiveSessionId(const DecoderSessionIdentity& owner) {
    std::lock_guard<std::mutex> lock(g_activeDecoderOwnerMutex);
    if (!Render::SessionOwnerMatches(g_activeDecoderOwner, owner)) {
        return;
    }
    g_activeDecoderOwner = DecoderSessionIdentity {};
    g_activeNativeImagePresentationMode.store(
        Render::NativeImagePresentationMode::Identity,
        std::memory_order_release);
    g_activeDecoderHandle.store(0, std::memory_order_release);
    g_activeDisplay.store(-1, std::memory_order_release);
    g_activeDisplayGeneration.fetch_add(1, std::memory_order_acq_rel);
}

bool DecoderNapi::SetActiveNativeImagePresentationMode(
    const DecoderSessionIdentity& owner,
    Render::NativeImagePresentationMode presentationMode) {
    DecoderHandleLease decoderLease;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (!Render::SessionOwnerMatches(g_activeDecoderOwner, owner)) {
            return false;
        }
        g_activeNativeImagePresentationMode.store(
            presentationMode, std::memory_order_release);
        const int64_t decoderHandle =
            g_activeDecoderHandle.load(std::memory_order_acquire);
        if (decoderHandle > 0) {
            decoderLease = g_decoderRegistry.acquire(decoderHandle, owner);
        }
    }
    if (!decoderLease) {
        // The protocol can finish its handshake before ArkTS publishes the
        // decoder handle. The owner-scoped value above is consumed by init/bind.
        return true;
    }
    std::lock_guard<std::mutex> pipelineLock(decoderLease->pipelineMutex);
    if (!Render::SessionOwnerMatches(decoderLease.owner(), owner)) {
        return false;
    }
    decoderLease->presentationMode.store(
        presentationMode, std::memory_order_release);
    if (decoderLease->pipelineTransitioning.load(std::memory_order_acquire)) {
        // Bind/recovery owns ctx->decoder outside the mutex while this flag is
        // set. The transition's final publication point reapplies this atomic
        // value to whichever decoder survived; touching the shared_ptr here
        // would race replacement/destruction.
        return true;
    }
    if (decoderLease->decoder) {
        decoderLease->decoder->SetNativeImagePresentationMode(presentationMode);
    }
    return true;
}

bool DecoderNapi::SetActiveDisplay(const DecoderSessionIdentity& owner, int display) {
    std::lock_guard<std::mutex> lock(g_activeDecoderOwnerMutex);
    if (!Render::SessionOwnerMatches(g_activeDecoderOwner, owner)) {
        return false;
    }
    if (display < 0) {
        const int previous = g_activeDisplay.exchange(-1, std::memory_order_acq_rel);
        if (previous != -1) {
            g_activeDisplayGeneration.fetch_add(1, std::memory_order_acq_rel);
        }
        return previous != -1;
    }
    const int previous = g_activeDisplay.exchange(display, std::memory_order_acq_rel);
    if (previous != display) {
        g_activeDisplayGeneration.fetch_add(1, std::memory_order_acq_rel);
    }
    OH_LOG_INFO(LOG_APP, "[Decoder] active RustDesk display=%{public}d", display);
    return previous != display;
}

bool DecoderNapi::BindVideoPipeline(int64_t decoderHandle, int64_t rendererHandle) {
    DecoderSessionIdentity owner;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        owner = g_activeDecoderOwner;
    }
    return BindVideoPipeline(decoderHandle, rendererHandle, owner);
}

bool DecoderNapi::BindVideoPipeline(
    int64_t decoderHandle, int64_t rendererHandle, const DecoderSessionIdentity& owner) {
    if (!owner.valid() || !Render::SharedSessionSinkOwnerLease().accepts(owner)) {
        OH_LOG_WARN(LOG_APP, "[Decoder] bindVideoPipeline rejected stale session owner");
        return false;
    }
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (!Render::SessionOwnerMatches(g_activeDecoderOwner, owner)) {
            OH_LOG_WARN(LOG_APP, "[Decoder] bindVideoPipeline rejected: no active session owner");
            return false;
        }
    }
    const auto metadata = g_decoderRegistry.snapshot(decoderHandle);
    if (metadata.found && metadata.boundOwner.valid() && metadata.boundOwner != owner) {
        OH_LOG_WARN(LOG_APP, "[Decoder] bindVideoPipeline rejected stale decoder handle=%{public}lld",
                    static_cast<long long>(decoderHandle));
        return false;
    }
    if (!metadata.found || rendererHandle <= 0) {
        OH_LOG_WARN(LOG_APP, "[Decoder] bindVideoPipeline failed: decoder=%{public}lld renderer=%{public}lld",
                    static_cast<long long>(decoderHandle), static_cast<long long>(rendererHandle));
        return false;
    }
    if (!metadata.boundOwner.valid() && !g_decoderRegistry.bind(decoderHandle, owner)) {
        return false;
    }
    DecoderHandleLease decoderLease;
    Render::NativeImagePresentationMode presentationMode =
        Render::NativeImagePresentationMode::Identity;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (!Render::SessionOwnerMatches(g_activeDecoderOwner, owner)) {
            return false;
        }
        presentationMode = g_activeNativeImagePresentationMode.load(
            std::memory_order_acquire);
        decoderLease = g_decoderRegistry.acquire(decoderHandle, owner);
    }
    const std::shared_ptr<DecoderContext> ctx = decoderLease.shared();
    if (!decoderLease || !ctx || rendererHandle <= 0) {
        OH_LOG_WARN(LOG_APP, "[Decoder] bindVideoPipeline failed: decoder=%{public}lld renderer=%{public}lld",
                    static_cast<long long>(decoderHandle), static_cast<long long>(rendererHandle));
        return false;
    }
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (!Render::SessionOwnerMatches(g_activeDecoderOwner, owner)) {
            return false;
        }
        g_activeDecoderHandle.store(0, std::memory_order_release);
    }
    int64_t oldRendererHandle = 0;
    DecoderSessionIdentity oldOwner;
    bool oldAttached = false;
    bool oldSoftware = false;
    std::shared_ptr<HardwareDecoder> oldDecoder;
    std::shared_ptr<SoftwareDecoder> oldSoftwareDecoder;
    {
        std::lock_guard<std::mutex> pipelineLock(ctx->pipelineMutex);
        if (ctx->pipelineTransitioning.load(std::memory_order_acquire)) {
            return false;
        }
        ctx->pipelineTransitioning.store(true, std::memory_order_release);
        oldAttached = ctx->videoPipelineAttached.load(std::memory_order_acquire);
        oldRendererHandle = ctx->rendererHandle;
        oldOwner = ctx->owner;
        oldSoftware = ctx->useSoftware;
        oldDecoder = ctx->decoder;
        oldSoftwareDecoder = ctx->softwareDecoder;
        ctx->videoPipelineAttached.store(false, std::memory_order_release);
        ctx->softRendererHandle.store(0, std::memory_order_release);
        ctx->owner = owner;
        ctx->boundOwner = owner;
        // RegisterDecoderContext allocated the decoder generation before
        // OH_AVCodec callbacks were registered.  Keep it across the first
        // renderer bind: changing it here would strand the already-registered
        // callback context.  Recovery/codec recreation allocates a new
        // generation before constructing a new HardwareDecoder instead.
        if (ctx->decoderGeneration == 0) {
            ctx->decoderGeneration = g_nextDecoderGeneration.fetch_add(
                1, std::memory_order_acq_rel);
        }
        ctx->dropCounterGeneration = ctx->decoderGeneration;
        ctx->displayGeneration = g_activeDisplayGeneration.load(std::memory_order_acquire);
        ctx->display = g_activeDisplay.load(std::memory_order_acquire);
        ctx->presentationMode.store(presentationMode, std::memory_order_release);
        if (ctx->decoder) {
            ctx->decoder->SetNativeImagePresentationMode(presentationMode);
        }
        ctx->recoveryRequested.store(false, std::memory_order_release);
        ctx->recoveryAttempts.store(0, std::memory_order_release);
        ctx->recoveryTerminal.store(false, std::memory_order_release);
        ctx->rendererHandle = rendererHandle;
    }

    // The transition flag blocks new decode/bind/detach leases, while the
    // actual callback gates are stopped with no pipeline mutex held. This is
    // the ordered half of bind: component/object callbacks cannot acquire the
    // owner gate while a decoder mutex is held.
    if (oldAttached) {
        if (oldRendererHandle > 0) {
            if (oldOwner.valid()) {
                RendererNapi::SetRendererRedrawCallback(oldRendererHandle, oldOwner, nullptr);
            } else {
                RendererNapi::SetRendererRedrawCallback(oldRendererHandle, nullptr);
            }
        }
        StopSoftwareWorker(ctx.get());
        if (oldSoftware && oldSoftwareDecoder) {
            oldSoftwareDecoder->SetFrameCallback(nullptr);
        }
        if (!oldSoftware && oldDecoder) {
            if (!StopHardwarePipeline(oldDecoder, true)) {
                OH_LOG_ERROR(LOG_APP,
                             "[Decoder] bindVideoPipeline could not stop old hardware pipeline");
                return false;
            }
        }
    } else {
        StopSoftwareWorker(ctx.get());
    }
    ResetDecoderTelemetry(ctx.get());

    auto clearTransitionState = [&]() {
        std::lock_guard<std::mutex> pipelineLock(ctx->pipelineMutex);
        ctx->videoPipelineAttached.store(false, std::memory_order_release);
        ctx->pipelineTransitioning.store(false, std::memory_order_release);
        ctx->pipelineTransitionCv.notify_all();
        ctx->owner = DecoderSessionIdentity {};
        ctx->rendererHandle = 0;
        ctx->softRendererHandle.store(0, std::memory_order_release);
    };
    auto stopConfiguredPipeline = [&]() {
        RendererNapi::SetRendererRedrawCallback(rendererHandle, nullptr);
        if (ctx->useSoftware) {
            if (ctx->softwareDecoder) {
                ctx->softwareDecoder->SetFrameCallback(nullptr);
            }
            StopSoftwareWorker(ctx.get());
        } else if (ctx->decoder) {
            // StopHardwarePipeline owns callback shutdown. In particular the
            // release-current callback must remain live until the render
            // thread has detached NativeImage from its EGL context.
            StopHardwarePipeline(ctx->decoder, true);
        }
    };

    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        clearTransitionState();
        decoderLease = {};
        g_decoderRegistry.deactivate(decoderHandle, owner);
        return false;
    }
    bool ownerStillActive = false;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        ownerStillActive = Render::SessionOwnerMatches(g_activeDecoderOwner, owner);
    }
    const bool configured = ownerStillActive && ConfigurePipeline(ctx, true);
    if (!configured) {
        sinkLease = {};
        stopConfiguredPipeline();
        clearTransitionState();
        decoderLease = {};
        g_decoderRegistry.deactivate(decoderHandle, owner);
        OH_LOG_WARN(LOG_APP,
                    "[Decoder] bindVideoPipeline failed: decoder=%{public}lld renderer=%{public}lld soft=%{public}s",
                    static_cast<long long>(decoderHandle),
                    static_cast<long long>(rendererHandle),
                    ctx->useSoftware ? "yes" : "no");
        return false;
    }

    bool published = false;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (Render::SessionOwnerMatches(g_activeDecoderOwner, owner) &&
            g_activeDecoderHandle.load(std::memory_order_acquire) == 0) {
            g_activeDecoderHandle.store(decoderHandle, std::memory_order_release);
            published = true;
        }
    }
    if (!published) {
        sinkLease = {};
        stopConfiguredPipeline();
        clearTransitionState();
        decoderLease = {};
        g_decoderRegistry.deactivate(decoderHandle, owner);
        return false;
    }
    {
        std::lock_guard<std::mutex> pipelineLock(ctx->pipelineMutex);
        // The peer-platform callback can update the owner-scoped mode before
        // the decoder handle is published, or after publication while this
        // transition still blocks direct decoder access. Consume the latest
        // global value at this single finalization point. A later setter will
        // see the published handle and serialize behind pipelineMutex.
        const Render::NativeImagePresentationMode finalPresentationMode =
            g_activeNativeImagePresentationMode.load(std::memory_order_acquire);
        ctx->presentationMode.store(
            finalPresentationMode, std::memory_order_release);
        if (ctx->decoder) {
            ctx->decoder->SetNativeImagePresentationMode(finalPresentationMode);
        }
        ctx->videoPipelineAttached.store(true, std::memory_order_release);
        ctx->pipelineTransitioning.store(false, std::memory_order_release);
        ctx->pipelineTransitionCv.notify_all();
    }
    const bool software = ctx->useSoftware;
    OH_LOG_INFO(LOG_APP, "[Decoder] bindVideoPipeline %{public}s ok decoder=%{public}lld renderer=%{public}lld",
                software ? "software" : "hardware",
                static_cast<long long>(decoderHandle),
                static_cast<long long>(rendererHandle));
    return true;
}

bool DecoderNapi::DetachVideoPipeline(int64_t decoderHandle) {
    DecoderSessionIdentity owner;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        owner = g_activeDecoderOwner;
    }
    return DetachVideoPipeline(decoderHandle, owner);
}

bool DecoderNapi::DetachVideoPipeline(
    int64_t decoderHandle, const DecoderSessionIdentity& owner) {
    if (!owner.valid() || !Render::SharedSessionSinkOwnerLease().accepts(owner)) {
        return false;
    }
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (!Render::SessionOwnerMatches(g_activeDecoderOwner, owner)) {
            return false;
        }
    }
    DecoderHandleLease decoderLease;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        decoderLease = g_decoderRegistry.acquire(decoderHandle, owner);
        if (!decoderLease) {
            OH_LOG_WARN(LOG_APP, "[Decoder] detachVideoPipeline failed: decoder=%{public}lld",
                        static_cast<long long>(decoderHandle));
            return false;
        }
    }
    if (!decoderLease) {
        OH_LOG_WARN(LOG_APP, "[Decoder] detachVideoPipeline failed: decoder=%{public}lld",
                    static_cast<long long>(decoderHandle));
        return false;
    }
    auto ctx = decoderLease.shared();
    if (!ctx) {
        OH_LOG_WARN(LOG_APP, "[Decoder] detachVideoPipeline failed: decoder=%{public}lld",
                    static_cast<long long>(decoderHandle));
        return false;
    }

    int64_t rendererHandle = 0;
    bool software = false;
    std::shared_ptr<HardwareDecoder> decoder;
    std::shared_ptr<SoftwareDecoder> softwareDecoder;
    {
        std::lock_guard<std::mutex> pipelineLock(ctx->pipelineMutex);
        if (!Render::SessionOwnerMatches(ctx->owner, owner)) {
            return false;
        }
        if (ctx->pipelineTransitioning.load(std::memory_order_acquire)) {
            return false;
        }
        ctx->pipelineTransitioning.store(true, std::memory_order_release);
        ctx->videoPipelineAttached.store(false, std::memory_order_release);
        ctx->owner = DecoderSessionIdentity {};
        ctx->softRendererHandle.store(0, std::memory_order_release);
        rendererHandle = ctx->rendererHandle;
        software = ctx->useSoftware;
        decoder = ctx->decoder;
        softwareDecoder = ctx->softwareDecoder;
        ctx->rendererHandle = 0;
    }
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (g_activeDecoderHandle.load(std::memory_order_acquire) == decoderHandle) {
            g_activeDecoderHandle.store(0, std::memory_order_release);
        }
    }
    // Stop callback gates only after the pipeline mutex is released. A render
    // callback may take the shared owner lease; holding pipelineMutex here
    // would recreate the decoder->owner edge during S1 teardown.
    if (software) {
        StopSoftwareWorker(ctx.get());
        if (softwareDecoder) {
            softwareDecoder->SetFrameCallback(nullptr);
        }
    } else if (decoder) {
        // Keep the GL callbacks installed until StopRenderThreadForDetach has
        // detached NativeImage and released the renderer context. Clearing
        // them first strands the context on the old page/PIP surface and the
        // next hardware bind presents black.
        if (!StopHardwarePipeline(decoder, true)) {
            OH_LOG_ERROR(LOG_APP,
                         "[Decoder] detachVideoPipeline could not stop hardware pipeline");
            return false;
        }
    }
    ResetDecoderTelemetry(ctx.get());
    if (rendererHandle > 0) {
        RendererNapi::SetRendererRedrawCallback(rendererHandle, owner, nullptr);
    }
    {
        std::lock_guard<std::mutex> pipelineLock(ctx->pipelineMutex);
        ctx->pipelineTransitioning.store(false, std::memory_order_release);
        ctx->pipelineTransitionCv.notify_all();
    }
    decoderLease = {};
    g_decoderRegistry.deactivate(decoderHandle, owner);
    OH_LOG_INFO(LOG_APP, "[Decoder] detachVideoPipeline ok decoder=%{public}lld mode=%{public}s",
                static_cast<long long>(decoderHandle),
                software ? "software" : "hardware");
    return true;
}

bool DecoderNapi::RequestDecoderRecovery(int64_t decoderHandle) {
    DecoderSessionIdentity owner;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        owner = g_activeDecoderOwner;
    }
    return RequestDecoderRecovery(decoderHandle, owner);
}

bool DecoderNapi::RequestDecoderRecovery(
    int64_t decoderHandle, const DecoderSessionIdentity& owner) {
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return false;
    }
    DecoderHandleLease decoderLease;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (!Render::SessionOwnerMatches(g_activeDecoderOwner, owner) ||
            g_activeDecoderHandle.load(std::memory_order_acquire) != decoderHandle) {
            return false;
        }
        decoderLease = g_decoderRegistry.acquire(decoderHandle, owner);
    }
    if (!decoderLease) {
        OH_LOG_WARN(LOG_APP, "[Decoder] requestDecoderRecovery failed: decoder=%{public}lld",
                    static_cast<long long>(decoderHandle));
        return false;
    }
    std::lock_guard<std::mutex> pipelineLock(decoderLease->pipelineMutex);
    if (decoderLease->pipelineTransitioning.load(std::memory_order_acquire) ||
        !decoderLease->videoPipelineAttached ||
        !Render::SessionOwnerMatches(decoderLease.owner(), owner) ||
        !Render::ShouldRequestDecoderRecoveryAfterForegroundRestore(
        true, decoderHandle, decoderLease->rendererHandle)) {
        OH_LOG_WARN(LOG_APP,
                    "[Decoder] requestDecoderRecovery skipped: decoder=%{public}lld renderer=%{public}lld",
                    static_cast<long long>(decoderHandle),
                    static_cast<long long>(decoderLease->rendererHandle));
        return false;
    }
    if (decoderLease->recoveryTerminal.load(std::memory_order_acquire) ||
        decoderLease->recoveryAttempts.load(std::memory_order_acquire) >=
            Render::kMaxDecoderRecoveryAttemptsPerBinding) {
        decoderLease->recoveryTerminal.store(true, std::memory_order_release);
        OH_LOG_WARN(LOG_APP,
                    "[Decoder] requestDecoderRecovery blocked: per-bind budget exhausted decoder=%{public}lld",
                    static_cast<long long>(decoderHandle));
        return false;
    }
    const bool alreadyRequested = decoderLease->recoveryRequested.exchange(
        true, std::memory_order_acq_rel);
    OH_LOG_INFO(LOG_APP,
                "[Decoder] requestDecoderRecovery %{public}s decoder=%{public}lld renderer=%{public}lld",
                alreadyRequested ? "coalesced" : "armed",
                static_cast<long long>(decoderHandle),
                static_cast<long long>(decoderLease->rendererHandle));
    return true;
}

bool DecoderNapi::RequestActiveDecoderRecovery(const DecoderSessionIdentity& owner) {
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return false;
    }
    int64_t handle = 0;
    DecoderHandleLease decoderLease;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (!Render::SessionOwnerMatches(g_activeDecoderOwner, owner)) {
            return false;
        }
        handle = g_activeDecoderHandle.load(std::memory_order_acquire);
        decoderLease = g_decoderRegistry.acquire(handle, owner);
    }
    if (!decoderLease) {
        return false;
    }
    std::lock_guard<std::mutex> pipelineLock(decoderLease->pipelineMutex);
    if (decoderLease->pipelineTransitioning.load(std::memory_order_acquire) ||
        !decoderLease->videoPipelineAttached ||
        !Render::SessionOwnerMatches(decoderLease.owner(), owner) ||
        !Render::ShouldRequestDecoderRecoveryAfterForegroundRestore(
            true, handle, decoderLease->rendererHandle)) {
        return false;
    }
    if (decoderLease->recoveryTerminal.load(std::memory_order_acquire) ||
        decoderLease->recoveryAttempts.load(std::memory_order_acquire) >=
            Render::kMaxDecoderRecoveryAttemptsPerBinding) {
        decoderLease->recoveryTerminal.store(true, std::memory_order_release);
        return false;
    }
    decoderLease->recoveryRequested.exchange(true, std::memory_order_acq_rel);
    return true;
}

bool DecoderNapi::RebindOwnedVideoPipeline(
    int64_t decoderHandle, uint64_t decoderGeneration,
    int64_t rendererHandle, uint64_t rendererGeneration,
    const DecoderSessionIdentity& owner) {
    if (decoderHandle <= 0 || decoderGeneration == 0 || rendererHandle <= 0 ||
        rendererGeneration == 0 || !owner.valid() ||
        !Render::SharedSessionSinkOwnerLease().accepts(owner)) {
        return false;
    }
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (!Render::SessionOwnerMatches(g_activeDecoderOwner, owner)) {
            return false;
        }
    }
    if (RendererNapi::GetActiveRendererHandle(owner) != rendererHandle ||
        RendererNapi::GetActiveRendererGeneration(rendererHandle, owner) !=
            rendererGeneration) {
        return false;
    }

    const auto metadata = g_decoderRegistry.snapshot(decoderHandle);
    if (!metadata.found || metadata.destroying || metadata.boundOwner != owner ||
        metadata.active || !metadata.detached ||
        !g_decoderRegistry.activate(decoderHandle, owner)) {
        return false;
    }

    bool exactDetachedDecoder = false;
    {
        auto lease = g_decoderRegistry.acquire(decoderHandle, owner);
        if (lease) {
            std::lock_guard<std::mutex> pipelineLock(lease->pipelineMutex);
            exactDetachedDecoder =
                lease->boundOwner == owner &&
                lease->decoderGeneration == decoderGeneration &&
                !lease->pipelineTransitioning.load(std::memory_order_acquire) &&
                !lease->videoPipelineAttached.load(std::memory_order_acquire) &&
                !lease->owner.valid() && lease->rendererHandle == 0;
        }
    }
    if (!exactDetachedDecoder ||
        RendererNapi::GetActiveRendererHandle(owner) != rendererHandle ||
        RendererNapi::GetActiveRendererGeneration(rendererHandle, owner) !=
            rendererGeneration) {
        g_decoderRegistry.deactivate(decoderHandle, owner);
        return false;
    }

    if (!BindVideoPipeline(decoderHandle, rendererHandle, owner)) {
        g_decoderRegistry.deactivate(decoderHandle, owner);
        return false;
    }
    const auto telemetry = GetActivePresentationTelemetry(owner);
    const bool exactRebind = telemetry.valid && telemetry.ready &&
        telemetry.owner == owner && telemetry.decoderHandle == decoderHandle &&
        telemetry.decoderGeneration == decoderGeneration &&
        telemetry.rendererHandle == rendererHandle &&
        telemetry.rendererGeneration == rendererGeneration;
    if (!exactRebind) {
        (void)DetachVideoPipeline(decoderHandle, owner);
        return false;
    }
    return true;
}

bool DecoderNapi::RebindActiveVideoPipeline(const DecoderSessionIdentity& owner) {
    if (!owner.valid() || !Render::SharedSessionSinkOwnerLease().accepts(owner)) {
        return false;
    }

    int64_t decoderHandle = 0;
    {
        std::lock_guard<std::mutex> ownerLock(g_activeDecoderOwnerMutex);
        if (!Render::SessionOwnerMatches(g_activeDecoderOwner, owner)) {
            return false;
        }
        decoderHandle = g_activeDecoderHandle.load(std::memory_order_acquire);
    }

    const int64_t rendererHandle = RendererNapi::GetActiveRendererHandle(owner);
    if (rendererHandle <= 0) {
        OH_LOG_INFO(LOG_APP,
                    "[Decoder] continuity video rebind skipped: no live renderer owner");
        return false;
    }

    auto pipelineMatchesRenderer = [&](int64_t candidate) {
        if (candidate <= 0) {
            return false;
        }
        auto lease = g_decoderRegistry.acquire(candidate, owner);
        if (!lease) {
            return false;
        }
        std::lock_guard<std::mutex> pipelineLock(lease->pipelineMutex);
        return !lease->pipelineTransitioning.load(std::memory_order_acquire) &&
            lease->videoPipelineAttached.load(std::memory_order_acquire) &&
            lease->rendererHandle == rendererHandle &&
            Render::SessionOwnerMatches(lease->owner, owner);
    };

    if (pipelineMatchesRenderer(decoderHandle)) {
        return true;
    }

    const auto metadata = g_decoderRegistry.snapshot(decoderHandle);
    if (!metadata.found || metadata.boundOwner != owner) {
        decoderHandle = g_decoderRegistry.findTokenByOwner(owner);
    }
    if (decoderHandle <= 0) {
        OH_LOG_INFO(LOG_APP,
                    "[Decoder] continuity video rebind skipped: no surviving decoder owner");
        return false;
    }

    const auto candidateMetadata = g_decoderRegistry.snapshot(decoderHandle);
    if (!candidateMetadata.found || candidateMetadata.boundOwner != owner) {
        OH_LOG_WARN(LOG_APP,
                    "[Decoder] continuity video rebind rejected stale decoder=%{public}lld",
                    static_cast<long long>(decoderHandle));
        return false;
    }

    const bool wasDetached = !candidateMetadata.active || candidateMetadata.detached;
    if (wasDetached && !g_decoderRegistry.activate(decoderHandle, owner)) {
        OH_LOG_WARN(LOG_APP,
                    "[Decoder] continuity video rebind could not reactivate decoder=%{public}lld",
                    static_cast<long long>(decoderHandle));
        return false;
    }

    const bool rebound = BindVideoPipeline(decoderHandle, rendererHandle, owner);
    if (!rebound && wasDetached) {
        g_decoderRegistry.deactivate(decoderHandle, owner);
    }
    if (rebound) {
        OH_LOG_INFO(LOG_APP,
                    "[Decoder] continuity video pipeline rebound decoder=%{public}lld renderer=%{public}lld",
                    static_cast<long long>(decoderHandle),
                    static_cast<long long>(rendererHandle));
    }
    return rebound;
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

#if defined(RDP_NATIVE_CALLBACK_TESTING)
    napi_create_function(env, "testDecoderH264", NAPI_AUTO_LENGTH,
                         NapiTestDecoderH264, nullptr, &fn);
    napi_set_named_property(env, exports, "testDecoderH264", fn);
#endif

    napi_create_function(env, "bindVideoPipeline", NAPI_AUTO_LENGTH,
                         NapiBindVideoPipeline, nullptr, &fn);
    napi_set_named_property(env, exports, "bindVideoPipeline", fn);

    napi_create_function(env, "detachVideoPipeline", NAPI_AUTO_LENGTH,
                         NapiDetachVideoPipeline, nullptr, &fn);
    napi_set_named_property(env, exports, "detachVideoPipeline", fn);

    napi_create_function(env, "requestDecoderRecovery", NAPI_AUTO_LENGTH,
                         NapiRequestDecoderRecovery, nullptr, &fn);
    napi_set_named_property(env, exports, "requestDecoderRecovery", fn);

    napi_create_function(env, "rebindActiveVideoPipeline", NAPI_AUTO_LENGTH,
                         NapiRebindActiveVideoPipeline, nullptr, &fn);
    napi_set_named_property(env, exports, "rebindActiveVideoPipeline", fn);

    napi_create_function(env, "getHardwareVideoDecoderCapabilities",
                         NAPI_AUTO_LENGTH,
                         NapiGetHardwareVideoDecoderCapabilities, nullptr, &fn);
    napi_set_named_property(env, exports,
                            "getHardwareVideoDecoderCapabilities", fn);

    return exports;
}
