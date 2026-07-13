#ifndef RDP_AUDIO_POLICY_H
#define RDP_AUDIO_POLICY_H

#include <cstddef>
#include <cstdint>

struct RdpAudioPcmDecision {
    bool accepted;
    size_t bytesToSubmit;
    const char* reason;
};

RdpAudioPcmDecision evaluateRdpAudioPcm(uint32_t sampleRate, uint16_t channels,
                                        uint16_t bitsPerSample, size_t byteCount);

#endif // RDP_AUDIO_POLICY_H
