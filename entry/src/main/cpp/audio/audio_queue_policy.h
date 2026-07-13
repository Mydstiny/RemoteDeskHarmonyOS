#ifndef AUDIO_QUEUE_POLICY_H
#define AUDIO_QUEUE_POLICY_H

#include <cstddef>
#include <cstdint>

struct AudioQueuePolicyConfig {
    int sampleRate {48000};
    int channels {2};
    uint32_t prebufferMs {120};
    uint32_t maxBufferMs {500};
};

size_t AudioBytesForDurationMs(int sampleRate, int channels, uint32_t durationMs);
uint32_t AudioDurationMsForBytes(int sampleRate, int channels, size_t bytes);
uint32_t RecommendedPrebufferMsForIncomingChunk(int sampleRate, int channels, size_t incomingBytes);
uint32_t RecommendedMaxBufferMsForPrebuffer(uint32_t prebufferMs);
AudioQueuePolicyConfig AudioQueuePolicyForIncomingPcm(int sampleRate, int channels,
                                                      size_t incomingBytes);
size_t MaxAudioQueueBytes(const AudioQueuePolicyConfig& config);
bool ShouldReleaseAudioFromPrebuffer(const AudioQueuePolicyConfig& config, size_t queuedBytes);
size_t AudioDropBytesForOverflow(const AudioQueuePolicyConfig& config, size_t queuedBytes,
                                 size_t incomingBytes);

#endif // AUDIO_QUEUE_POLICY_H
