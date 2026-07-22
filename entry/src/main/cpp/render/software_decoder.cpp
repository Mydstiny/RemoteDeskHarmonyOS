/**
 * software_decoder.cpp — VP8/VP9/AV1 软件解码器
 */

#include "software_decoder.h"
#include <hilog/log.h>
#include <algorithm>
#include <cstring>
#include <string>
#include <chrono>
#include <thread>

#ifdef USE_FFMPEG_SOFTWARE_DECODER
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/pixfmt.h>
#include <libswscale/swscale.h>
}
#endif

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0004
#define LOG_TAG "SOFT_DECODER"

namespace {
constexpr int kErrUnsupportedCodec = -100;
constexpr int kErrBackendMissing = -101;
constexpr int kErrDecoderNotFound = -102;
constexpr int kErrAllocFailed = -103;
constexpr int kErrOpenFailed = -104;
constexpr int kErrPacketAllocFailed = -105;
constexpr int kErrSendPacketFailed = -106;
constexpr int kErrReceiveFrameFailed = -107;
constexpr int kErrConvertFailed = -108;
constexpr int kErrRenderFailed = -109;
constexpr int kSoftwareDecodeMaxOutputEdge = 1600;
constexpr int kSoftwareDecodeMinThreads = 4;
constexpr int kSoftwareDecodeMaxThreads = 8;

int softwareDecodeThreadCount() {
    const unsigned int detected = std::thread::hardware_concurrency();
    const int available = detected == 0 ? kSoftwareDecodeMinThreads : static_cast<int>(detected);
    return std::clamp(available, kSoftwareDecodeMinThreads, kSoftwareDecodeMaxThreads);
}

void computeOutputSize(int srcWidth, int srcHeight, int& outWidth, int& outHeight) {
    outWidth = srcWidth;
    outHeight = srcHeight;
    if (srcWidth <= 0 || srcHeight <= 0) {
        return;
    }
    const int maxEdge = srcWidth > srcHeight ? srcWidth : srcHeight;
    if (maxEdge <= kSoftwareDecodeMaxOutputEdge) {
        return;
    }
    outWidth = static_cast<int>((static_cast<int64_t>(srcWidth) * kSoftwareDecodeMaxOutputEdge) / maxEdge);
    outHeight = static_cast<int>((static_cast<int64_t>(srcHeight) * kSoftwareDecodeMaxOutputEdge) / maxEdge);
    outWidth = outWidth < 2 ? 2 : (outWidth & ~1);
    outHeight = outHeight < 2 ? 2 : (outHeight & ~1);
}

#ifdef USE_FFMPEG_SOFTWARE_DECODER
AVCodecID toAvCodecId(CodecType codec) {
    switch (codec) {
        case CodecType::VP8: return AV_CODEC_ID_VP8;
        case CodecType::VP9: return AV_CODEC_ID_VP9;
        case CodecType::AV1: return AV_CODEC_ID_AV1;
        default: return AV_CODEC_ID_NONE;
    }
}

std::string avError(int code) {
    char buf[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(code, buf, sizeof(buf));
    return std::string(buf);
}
#endif
}

struct SoftwareDecoderImpl {
#ifdef USE_FFMPEG_SOFTWARE_DECODER
    AVCodecContext* codecCtx = nullptr;
    AVFrame* frame = nullptr;
    AVPacket* packet = nullptr;
    SwsContext* sws = nullptr;
#endif
};

SoftwareDecoder::~SoftwareDecoder() {
    Destroy();
}

bool SoftwareDecoder::Supports(CodecType codec) {
    return codec == CodecType::VP8 || codec == CodecType::VP9 || codec == CodecType::AV1;
}

bool SoftwareDecoder::BackendAvailable() {
#ifdef USE_FFMPEG_SOFTWARE_DECODER
    return true;
#else
    return false;
#endif
}

const char* SoftwareDecoder::CodecName(CodecType codec) {
    switch (codec) {
        case CodecType::VP8: return "VP8";
        case CodecType::VP9: return "VP9";
        case CodecType::AV1: return "AV1";
        case CodecType::H265: return "H265";
        case CodecType::H264:
        default: return "H264";
    }
}

int SoftwareDecoder::Init(int width, int height, CodecType codec) {
    Destroy();
    width_ = width;
    height_ = height;
    codecType_ = codec;
    initialized_ = false;

    if (!Supports(codec)) {
        OH_LOG_WARN(LOG_APP, "[SoftDecoder] unsupported codec=%{public}s", CodecName(codec));
        return kErrUnsupportedCodec;
    }

#ifndef USE_FFMPEG_SOFTWARE_DECODER
    OH_LOG_ERROR(LOG_APP,
        "[SoftDecoder] %{public}s software backend missing. Run scripts/build_ffmpeg_softdec_ohos.sh and rebuild.",
        CodecName(codec));
    return kErrBackendMissing;
#else
    const AVCodecID codecId = toAvCodecId(codec);
    const AVCodec* decoder = avcodec_find_decoder(codecId);
    if (!decoder) {
        OH_LOG_ERROR(LOG_APP, "[SoftDecoder] FFmpeg decoder not found: %{public}s", CodecName(codec));
        return kErrDecoderNotFound;
    }

    impl_ = new SoftwareDecoderImpl();
    impl_->codecCtx = avcodec_alloc_context3(decoder);
    impl_->frame = av_frame_alloc();
    impl_->packet = av_packet_alloc();
    if (!impl_->codecCtx || !impl_->frame || !impl_->packet) {
        OH_LOG_ERROR(LOG_APP, "[SoftDecoder] FFmpeg alloc failed codec=%{public}s", CodecName(codec));
        Destroy();
        return kErrAllocFailed;
    }

    impl_->codecCtx->width = width;
    impl_->codecCtx->height = height;
    impl_->codecCtx->thread_count = softwareDecodeThreadCount();
    // VP9 tile/slice parallelism keeps latency low, while frame parallelism
    // provides enough throughput for a 60 FPS stream when the peer emits
    // frames that cannot be split into enough tiles.
    impl_->codecCtx->thread_type = FF_THREAD_SLICE | FF_THREAD_FRAME;
    impl_->codecCtx->flags |= AV_CODEC_FLAG_LOW_DELAY;

    const int openRet = avcodec_open2(impl_->codecCtx, decoder, nullptr);
    if (openRet < 0) {
        const std::string err = avError(openRet);
        OH_LOG_ERROR(LOG_APP, "[SoftDecoder] avcodec_open2 failed codec=%{public}s err=%{public}s",
                     CodecName(codec), err.c_str());
        Destroy();
        return kErrOpenFailed;
    }

    initialized_ = true;
    OH_LOG_INFO(LOG_APP,
                "[SoftDecoder] FFmpeg %{public}s ready initSize=%{public}dx%{public}d decoder=%{public}s threads=%{public}d lowDelay=1 maxOut=%{public}d",
                CodecName(codec), width, height, decoder->name ? decoder->name : "unknown",
                impl_->codecCtx->thread_count, kSoftwareDecodeMaxOutputEdge);
    return 0;
#endif
}

int SoftwareDecoder::Decode(const uint8_t* data, size_t size, uint64_t timestamp,
                            bool isKeyFrame, bool presentOutput) {
    (void)isKeyFrame;
    if (!initialized_ || !data || size == 0) {
        return -1;
    }

#ifndef USE_FFMPEG_SOFTWARE_DECODER
    (void)data;
    (void)size;
    (void)timestamp;
    return kErrBackendMissing;
#else
    if (!impl_ || !impl_->codecCtx || !impl_->frame || !impl_->packet) {
        return -1;
    }

    av_packet_unref(impl_->packet);
    int ret = av_new_packet(impl_->packet, static_cast<int>(size));
    if (ret < 0) {
        const std::string err = avError(ret);
        OH_LOG_ERROR(LOG_APP, "[SoftDecoder] av_new_packet failed size=%{public}zu err=%{public}s", size, err.c_str());
        return kErrPacketAllocFailed;
    }
    std::memcpy(impl_->packet->data, data, size);
    impl_->packet->pts = static_cast<int64_t>(timestamp);
    impl_->packet->dts = static_cast<int64_t>(timestamp);

    ret = avcodec_send_packet(impl_->codecCtx, impl_->packet);
    av_packet_unref(impl_->packet);
    if (ret < 0) {
        const std::string err = avError(ret);
        OH_LOG_WARN(LOG_APP, "[SoftDecoder] avcodec_send_packet failed codec=%{public}s size=%{public}zu err=%{public}s",
                    CodecName(codecType_), size, err.c_str());
        return kErrSendPacketFailed;
    }

    int rendered = 0;
    while (true) {
        ret = avcodec_receive_frame(impl_->codecCtx, impl_->frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            break;
        }
        if (ret < 0) {
            const std::string err = avError(ret);
            OH_LOG_WARN(LOG_APP, "[SoftDecoder] avcodec_receive_frame failed codec=%{public}s err=%{public}s",
                        CodecName(codecType_), err.c_str());
            av_frame_unref(impl_->frame);
            return kErrReceiveFrameFailed;
        }

        const int renderRet = presentOutput ? renderFrame() : 0;
        av_frame_unref(impl_->frame);
        if (renderRet != 0) {
            return renderRet;
        }
        rendered++;
    }

    return rendered >= 0 ? 0 : -1;
#endif
}

int SoftwareDecoder::renderFrame() {
#ifndef USE_FFMPEG_SOFTWARE_DECODER
    return kErrBackendMissing;
#else
    if (!impl_ || !impl_->frame) {
        return 0;
    }
    AVFrame* frame = impl_->frame;
    if (frame->width <= 0 || frame->height <= 0 || frame->format == AV_PIX_FMT_NONE) {
        return -1;
    }

    using clock = std::chrono::steady_clock;
    const auto beginAt = clock::now();

    int outWidth = 0;
    int outHeight = 0;
    computeOutputSize(frame->width, frame->height, outWidth, outHeight);

    const auto srcFormat = static_cast<AVPixelFormat>(frame->format);
    impl_->sws = sws_getCachedContext(impl_->sws,
                                      frame->width, frame->height, srcFormat,
                                      outWidth, outHeight, AV_PIX_FMT_BGRA,
                                      SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);
    if (!impl_->sws) {
        OH_LOG_ERROR(LOG_APP, "[SoftDecoder] sws_getCachedContext failed codec=%{public}s fmt=%{public}d src=%{public}dx%{public}d out=%{public}dx%{public}d",
                     CodecName(codecType_), frame->format, frame->width, frame->height, outWidth, outHeight);
        return kErrConvertFailed;
    }

    if (outWidth != outputWidth_ || outHeight != outputHeight_) {
        outputWidth_ = outWidth;
        outputHeight_ = outHeight;
        OH_LOG_INFO(LOG_APP, "[SoftDecoder] output scaled codec=%{public}s src=%{public}dx%{public}d out=%{public}dx%{public}d",
                    CodecName(codecType_), frame->width, frame->height, outputWidth_, outputHeight_);
    }

    const int stride = outWidth * 4;
    const size_t outSize = static_cast<size_t>(stride) * static_cast<size_t>(outHeight);
    bgraBuffer_.resize(outSize);
    uint8_t* dstData[4] = { bgraBuffer_.data(), nullptr, nullptr, nullptr };
    int dstStride[4] = { stride, 0, 0, 0 };
    const auto convertBeginAt = clock::now();
    const int scaled = sws_scale(impl_->sws, frame->data, frame->linesize, 0, frame->height, dstData, dstStride);
    if (scaled <= 0) {
        OH_LOG_ERROR(LOG_APP, "[SoftDecoder] sws_scale failed codec=%{public}s scaled=%{public}d", CodecName(codecType_), scaled);
        return kErrConvertFailed;
    }
    const auto convertEndAt = clock::now();

    width_ = frame->width;
    height_ = frame->height;
    const int renderRet = frameCallbackGate_.Invoke(
        bgraBuffer_.data(), bgraBuffer_.size(), outWidth, outHeight, stride);
    const auto renderEndAt = clock::now();
    if (renderRet != 0) {
        OH_LOG_WARN(LOG_APP, "[SoftDecoder] render callback failed codec=%{public}s ret=%{public}d", CodecName(codecType_), renderRet);
        return kErrRenderFailed;
    }
    renderedFrames_++;
    const auto convertUs = std::chrono::duration_cast<std::chrono::microseconds>(convertEndAt - convertBeginAt).count();
    const auto renderUs = std::chrono::duration_cast<std::chrono::microseconds>(renderEndAt - convertEndAt).count();
    const auto totalUs = std::chrono::duration_cast<std::chrono::microseconds>(renderEndAt - beginAt).count();
    if (renderedFrames_ <= 5 || renderedFrames_ % 120 == 0 || totalUs > 20000) {
        OH_LOG_INFO(LOG_APP,
                    "[SoftDecoder] frame=%{public}llu codec=%{public}s src=%{public}dx%{public}d out=%{public}dx%{public}d convert=%{public}lldus render=%{public}lldus total=%{public}lldus",
                    static_cast<unsigned long long>(renderedFrames_), CodecName(codecType_),
                    frame->width, frame->height, outWidth, outHeight,
                    static_cast<long long>(convertUs), static_cast<long long>(renderUs),
                    static_cast<long long>(totalUs));
    }
    return 0;
#endif
}

void SoftwareDecoder::Destroy() {
    frameCallbackGate_.ClearAndWait();
#ifdef USE_FFMPEG_SOFTWARE_DECODER
    if (impl_) {
        if (impl_->sws) {
            sws_freeContext(impl_->sws);
            impl_->sws = nullptr;
        }
        if (impl_->packet) {
            av_packet_free(&impl_->packet);
        }
        if (impl_->frame) {
            av_frame_free(&impl_->frame);
        }
        if (impl_->codecCtx) {
            avcodec_free_context(&impl_->codecCtx);
        }
    }
#endif
    delete impl_;
    impl_ = nullptr;
    bgraBuffer_.clear();
    outputWidth_ = 0;
    outputHeight_ = 0;
    renderedFrames_ = 0;
    initialized_ = false;
}

void SoftwareDecoder::SetFrameCallback(SoftwareDecoderFrameCallback callback) {
    frameCallbackGate_.Set(std::move(callback));
}




