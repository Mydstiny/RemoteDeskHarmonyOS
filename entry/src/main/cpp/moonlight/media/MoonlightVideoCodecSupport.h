#ifndef REMOTEDESK_MOONLIGHT_VIDEO_CODEC_SUPPORT_H
#define REMOTEDESK_MOONLIGHT_VIDEO_CODEC_SUPPORT_H

#include "extensions/protocol_adapter.h"
#include "moonlight/media/MoonlightStreamConfig.h"

#include <cstdint>

namespace remotedesk::moonlight {

// The production Surface pipeline is intentionally limited to the three
// hardware-decodable 8-bit 4:2:0 formats that moonlight-common-c can negotiate.
// HDR/10-bit and 4:4:4 remain separate product capabilities.
constexpr bool moonlightHardwareVideoProfileSupported(
    const MoonlightStreamCodecProfile& profile) noexcept {
    return (profile.codec == MoonlightStreamCodec::H264 ||
            profile.codec == MoonlightStreamCodec::Hevc ||
            profile.codec == MoonlightStreamCodec::Av1) &&
        profile.bitDepth == MoonlightStreamBitDepth::Bit8 &&
        profile.chroma == MoonlightStreamChroma::Yuv420;
}

constexpr CodecType moonlightHardwareCodecType(
    MoonlightStreamCodec codec) noexcept {
    switch (codec) {
        case MoonlightStreamCodec::Hevc: return CodecType::H265;
        case MoonlightStreamCodec::Av1: return CodecType::AV1;
        case MoonlightStreamCodec::H264: return CodecType::H264;
    }
    return CodecType::H264;
}

constexpr std::uint64_t moonlightServerCodecBit(
    MoonlightStreamCodec codec) noexcept {
    switch (codec) {
        case MoonlightStreamCodec::H264: return 0x00000001U;
        case MoonlightStreamCodec::Hevc: return 0x00000100U;
        case MoonlightStreamCodec::Av1: return 0x00010000U;
    }
    return 0U;
}

constexpr MoonlightStreamCodecProfile moonlightHardwareVideoProfile(
    MoonlightStreamCodec codec) noexcept {
    return {codec, MoonlightStreamBitDepth::Bit8,
            MoonlightStreamChroma::Yuv420};
}

} // namespace remotedesk::moonlight

#endif // REMOTEDESK_MOONLIGHT_VIDEO_CODEC_SUPPORT_H
