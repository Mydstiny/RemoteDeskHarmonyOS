/**
 * software_decoder.h — VP8/VP9/AV1 软件解码器
 *
 * FFmpeg 后端输出 BGRA 像素帧, 交给 GLRenderer 的原始像素路径渲染。
 */

#ifndef SOFTWARE_DECODER_H
#define SOFTWARE_DECODER_H

#include "extensions/protocol_adapter.h"
#include <cstddef>
#include <cstdint>
#include <functional>
#include <vector>

using SoftwareDecoderFrameCallback = std::function<int(const uint8_t* data, size_t size, int width, int height, int stride)>;

struct SoftwareDecoderImpl;

class SoftwareDecoder {
public:
    SoftwareDecoder() = default;
    ~SoftwareDecoder();

    int Init(int width, int height, CodecType codec);
    int Decode(const uint8_t* data, size_t size, uint64_t timestamp, bool isKeyFrame = false);
    void Destroy();

    bool IsInitialized() const { return initialized_; }
    CodecType GetCodecType() const { return codecType_; }
    int GetWidth() const { return width_; }
    int GetHeight() const { return height_; }

    void SetFrameCallback(SoftwareDecoderFrameCallback callback);

    static bool Supports(CodecType codec);
    static bool BackendAvailable();
    static const char* CodecName(CodecType codec);

private:
    int renderFrame();

    int width_ = 0;
    int height_ = 0;
    int outputWidth_ = 0;
    int outputHeight_ = 0;
    uint64_t renderedFrames_ = 0;
    CodecType codecType_ = CodecType::VP9;
    bool initialized_ = false;
    SoftwareDecoderFrameCallback frameCallback_;
    SoftwareDecoderImpl* impl_ = nullptr;
    std::vector<uint8_t> bgraBuffer_;
};

#endif // SOFTWARE_DECODER_H
