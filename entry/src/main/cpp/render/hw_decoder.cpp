#include <cstdint>
#include <cstring>
#include <string>

#include <securec.h>

#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avformat.h>
#include <native_image/native_image.h>
#include <native_window/native_window.h>
#include <hilog/log.h>

#include "extensions/protocol_adapter.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "HwDecoder"

// HardwareDecoder — 基于 OH_AVCodec 的硬件视频解码器
// 支持 H.264 / H.265 硬解，通过 NativeImage 实现零拷贝 GL 纹理输出
class HardwareDecoder {
public:
    HardwareDecoder() = default;
    ~HardwareDecoder() { Release(); }

    // 初始化解码器：指定宽高和编码格式
    // w/h: 视频分辨率宽度和高度
    // codec: H264 或 H265
    bool Init(int w, int h, CodecType codec) {
        if (w <= 0 || h <= 0) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "Invalid resolution: %dx%d", w, h);
            return false;
        }

        width_ = w;
        height_ = h;
        codecType_ = codec;
        isRunning_ = false;

        // 根据编码类型选择 MIME
        const char* mime = (codec == CodecType::H265)
                               ? OH_AVCODEC_MIMETYPE_VIDEO_HEVC
                               : OH_AVCODEC_MIMETYPE_VIDEO_AVC;
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "Creating decoder: %s, %dx%d", mime, w, h);

        // 创建视频解码器
        decoder_ = OH_VideoDecoder_CreateByMime(mime);
        if (!decoder_) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "Failed to create OH_VideoDecoder");
            return false;
        }

        // 创建 NativeImage 用于零拷贝纹理输出
        OH_NativeImage_Create(&nativeImage_, 0);
        if (!nativeImage_) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "Failed to create OH_NativeImage");
            Release();
            return false;
        }

        // 获取 NativeImage 的 Surface 并设置到解码器
        OHNativeWindow* nativeWindow = OH_NativeImage_AcquireNativeWindow(nativeImage_);
        if (!nativeWindow) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "Failed to acquire native window from NativeImage");
            Release();
            return false;
        }

        OHNativeWindow* surface = OH_NativeImage_GetSurface(nativeImage_);
        if (surface) {
            OH_VideoDecoder_SetSurface(decoder_, surface);
        } else {
            OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG,
                         "OH_NativeImage_GetSurface returned null, trying AcquireNativeWindow");
            OH_VideoDecoder_SetSurface(decoder_, nativeWindow);
        }
        OH_NativeWindow_DestroyNativeWindow(nativeWindow);

        // 配置解码参数
        if (!ConfigureDecoder()) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "Failed to configure decoder");
            Release();
            return false;
        }

        // 启动解码器
        OH_AVErrCode ret = OH_VideoDecoder_Start(decoder_);
        if (ret != AV_ERR_OK) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "OH_VideoDecoder_Start failed: %d", ret);
            Release();
            return false;
        }

        isRunning_ = true;
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "Decoder initialized successfully, texId=%u", GetTextureId());
        return true;
    }

    // 向解码器推送一帧 H.264/H.265 数据
    // data: 编码帧数据指针
    // len: 数据长度
    // pts: 显示时间戳（微秒）
    bool PushFrame(const uint8_t* data, size_t len, int64_t pts) {
        if (!decoder_ || !isRunning_) {
            OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG,
                         "PushFrame: decoder not running");
            return false;
        }
        if (!data || len == 0) {
            return false;
        }

        // 创建输入缓冲区
        OH_AVCodecBufferAttr attr = {};
        attr.pts = pts;
        attr.size = len;
        attr.offset = 0;
        attr.flags = AVCODEC_BUFFER_FLAG_SYNC_FRAME;

        int32_t inputIndex = OH_VideoDecoder_GetInputIndex(decoder_, 3000);
        if (inputIndex < 0) {
            OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG,
                         "GetInputIndex timeout: %d", inputIndex);
            return false;
        }

        OH_AVMemory* inputMem = OH_VideoDecoder_GetInputMemory(decoder_, inputIndex);
        if (!inputMem) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "Failed to get input memory buffer");
            return false;
        }

        // 拷贝数据到输入缓冲区
        uint8_t* buf = OH_AVMemory_GetAddr(inputMem);
        uint32_t bufSize = OH_AVMemory_GetSize(inputMem);
        if (!buf || len > bufSize) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "Input buffer too small: need %zu, have %u", len, bufSize);
            return false;
        }
        if (memcpy_s(buf, bufSize, data, len) != EOK) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "memcpy_s failed in PushFrame");
            return false;
        }

        // 将填充好的缓冲区交还解码器
        OH_AVErrCode ret = OH_VideoDecoder_PushInputData(decoder_, inputIndex, attr);
        if (ret != AV_ERR_OK) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "PushInputData failed: %d", ret);
            return false;
        }

        return true;
    }

    // 获取关联的 GL 纹理 ID（用于渲染管线）
    // 返回 NativeImage 背面的 GL 纹理句柄
    GLuint GetTextureId() const {
        if (nativeImage_) {
            return OH_NativeImage_GetTextureId(nativeImage_);
        }
        return 0;
    }

    // 获取解码后的实际分辨率
    int GetWidth() const { return width_; }
    int GetHeight() const { return height_; }

    // 解码器是否正在运行
    bool IsRunning() const { return isRunning_; }

private:
    // 配置解码器参数
    bool ConfigureDecoder() {
        OH_AVFormat* format = OH_AVFormat_Create();
        if (!format) return false;

        OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width_);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height_);

        // H.264 基本配置
        if (codecType_ == CodecType::H264) {
            OH_AVFormat_SetIntValue(format, OH_MD_KEY_PROFILE,
                                    OH_AVCODEC_PROFILE_AVC_MAIN);
        } else {
            OH_AVFormat_SetIntValue(format, OH_MD_KEY_PROFILE,
                                    OH_AVCODEC_PROFILE_HEVC_MAIN);
        }

        // 设置 PixelFormat 为 NV12（硬件解码器通常输出 NV12）
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT,
                                OH_AVCODEC_PIXEL_FORMAT_NV12);

        // 设置帧率
        OH_AVFormat_SetFloatValue(format, OH_MD_KEY_FRAME_RATE, 30.0f);

        OH_AVErrCode ret = OH_VideoDecoder_Configure(decoder_, format);
        OH_AVFormat_Destroy(format);

        if (ret != AV_ERR_OK) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "OH_VideoDecoder_Configure failed: %d", ret);
            return false;
        }

        // 注册回调
        OH_AVCodecCallback cb;
        cb.onError = OnDecoderError;
        cb.onOutputAvailable = OnOutputAvailable;
        cb.onInputAvailable = OnInputAvailable;
        cb.onOutputFormatChanged = OnOutputFormatChanged;
        ret = OH_VideoDecoder_RegisterCallback(decoder_, cb, this);
        if (ret != AV_ERR_OK) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "RegisterCallback failed: %d", ret);
            return false;
        }

        return true;
    }

    // 释放所有资源
    void Release() {
        if (decoder_ && isRunning_) {
            OH_VideoDecoder_Stop(decoder_);
            isRunning_ = false;
        }
        if (decoder_) {
            OH_VideoDecoder_Destroy(decoder_);
            decoder_ = nullptr;
        }
        if (nativeImage_) {
            OH_NativeImage_Destroy(&nativeImage_);
            nativeImage_ = nullptr;
        }
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "Decoder released");
    }

    // ---- 静态回调函数 ----

    static void OnDecoderError(OH_AVCodec* codec, int32_t errorCode,
                               void* userData) {
        auto* self = static_cast<HardwareDecoder*>(userData);
        OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                     "Decoder error: %d", errorCode);
        if (self) {
            self->isRunning_ = false;
        }
    }

    static void OnOutputAvailable(OH_AVCodec* codec, uint32_t index,
                                  OH_AVCodecBufferAttr* attr, void* userData) {
        auto* self = static_cast<HardwareDecoder*>(userData);
        if (self && self->decoder_) {
            // 释放输出缓冲区（由 Surface 消费，只需 ReleaseOutputBuffer）
            OH_VideoDecoder_FreeOutputData(self->decoder_, index);
        }
    }

    static void OnInputAvailable(OH_AVCodec* codec, uint32_t index,
                                 void* userData) {
        // 有可用输入缓冲区—由 PushFrame 管理，无需额外处理
    }

    static void OnOutputFormatChanged(OH_AVCodec* codec,
                                      OH_AVFormat* format, void* userData) {
        auto* self = static_cast<HardwareDecoder*>(userData);
        if (self && format) {
            int32_t newW = 0, newH = 0;
            OH_AVFormat_GetIntValue(format, OH_MD_KEY_WIDTH, &newW);
            OH_AVFormat_GetIntValue(format, OH_MD_KEY_HEIGHT, &newH);
            if (newW > 0 && newH > 0) {
                self->width_ = newW;
                self->height_ = newH;
                OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                             "Output format changed: %dx%d", newW, newH);
            }
        }
    }

private:
    OH_AVCodec* decoder_ = nullptr;         // OH_AVCodec 解码器实例
    OH_NativeImage* nativeImage_ = nullptr; // NativeImage：零拷贝输出到 GL 纹理
    int width_ = 0;                          // 视频宽度
    int height_ = 0;                         // 视频高度
    CodecType codecType_ = CodecType::H264;  // 编码类型
    bool isRunning_ = false;                 // 解码器是否已启动
};
