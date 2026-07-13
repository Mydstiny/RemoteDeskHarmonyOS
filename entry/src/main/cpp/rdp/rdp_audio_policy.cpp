#include "rdp_audio_policy.h"

namespace {
constexpr uint16_t kSupportedBitsPerSample = 16;
constexpr uint16_t kMaxChannels = 8;
constexpr size_t kBytesPerSample = 2;

RdpAudioPcmDecision reject(const char* reason) {
    return {false, 0, reason};
}
}

RdpAudioPcmDecision evaluateRdpAudioPcm(uint32_t sampleRate, uint16_t channels,
                                        uint16_t bitsPerSample, size_t byteCount) {
    if (sampleRate == 0) {
        return reject("invalid_sample_rate");
    }
    if (channels == 0 || channels > kMaxChannels) {
        return reject("invalid_channels");
    }
    if (bitsPerSample != kSupportedBitsPerSample) {
        return reject("unsupported_bits_per_sample");
    }

    const size_t frameBytes = static_cast<size_t>(channels) * kBytesPerSample;
    const size_t alignedBytes = byteCount - (byteCount % frameBytes);
    if (alignedBytes == 0) {
        return reject("empty_or_incomplete_frame");
    }
    return {true, alignedBytes, "accepted"};
}
