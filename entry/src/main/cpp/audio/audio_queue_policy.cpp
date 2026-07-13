#include "audio_queue_policy.h"

namespace {
constexpr size_t kBytesPerSample = 2;
constexpr uint32_t kMinPrebufferMs = 120;
constexpr uint32_t kMaxPrebufferMs = 300;
constexpr uint32_t kBaseMaxBufferMs = 500;
constexpr uint32_t kOverflowBudgetAfterPrebufferMs = 500;

size_t FrameBytes(int channels) {
    const int safeChannels = channels > 0 ? channels : 2;
    return static_cast<size_t>(safeChannels) * kBytesPerSample;
}
}

size_t AudioBytesForDurationMs(int sampleRate, int channels, uint32_t durationMs) {
    const int safeRate = sampleRate > 0 ? sampleRate : 48000;
    const size_t frameBytes = FrameBytes(channels);
    const uint64_t frames = (static_cast<uint64_t>(safeRate) * durationMs) / 1000;
    return static_cast<size_t>(frames) * frameBytes;
}

uint32_t AudioDurationMsForBytes(int sampleRate, int channels, size_t bytes) {
    const int safeRate = sampleRate > 0 ? sampleRate : 48000;
    const size_t frameBytes = FrameBytes(channels);
    if (frameBytes == 0 || bytes < frameBytes) {
        return 0;
    }
    const uint64_t frames = static_cast<uint64_t>(bytes / frameBytes);
    return static_cast<uint32_t>((frames * 1000) / static_cast<uint64_t>(safeRate));
}

uint32_t RecommendedPrebufferMsForIncomingChunk(int sampleRate, int channels,
                                                size_t incomingBytes) {
    const uint32_t chunkMs = AudioDurationMsForBytes(sampleRate, channels, incomingBytes);
    uint32_t targetMs = chunkMs * 2;
    if (targetMs < kMinPrebufferMs) {
        targetMs = kMinPrebufferMs;
    }
    if (targetMs > kMaxPrebufferMs) {
        targetMs = kMaxPrebufferMs;
    }
    return targetMs;
}

uint32_t RecommendedMaxBufferMsForPrebuffer(uint32_t prebufferMs) {
    if (prebufferMs <= kMinPrebufferMs) {
        return kBaseMaxBufferMs;
    }
    const uint32_t targetMs = prebufferMs + kOverflowBudgetAfterPrebufferMs;
    return targetMs > kBaseMaxBufferMs ? targetMs : kBaseMaxBufferMs;
}

AudioQueuePolicyConfig AudioQueuePolicyForIncomingPcm(int sampleRate, int channels,
                                                      size_t incomingBytes) {
    AudioQueuePolicyConfig config;
    config.sampleRate = sampleRate > 0 ? sampleRate : 48000;
    config.channels = channels > 0 ? channels : 2;
    config.prebufferMs = RecommendedPrebufferMsForIncomingChunk(config.sampleRate,
                                                                config.channels,
                                                                incomingBytes);
    config.maxBufferMs = RecommendedMaxBufferMsForPrebuffer(config.prebufferMs);
    return config;
}

size_t MaxAudioQueueBytes(const AudioQueuePolicyConfig& config) {
    return AudioBytesForDurationMs(config.sampleRate, config.channels, config.maxBufferMs);
}

bool ShouldReleaseAudioFromPrebuffer(const AudioQueuePolicyConfig& config, size_t queuedBytes) {
    return queuedBytes >= AudioBytesForDurationMs(config.sampleRate, config.channels,
                                                 config.prebufferMs);
}

size_t AudioDropBytesForOverflow(const AudioQueuePolicyConfig& config, size_t queuedBytes,
                                 size_t incomingBytes) {
    const size_t maxBytes = MaxAudioQueueBytes(config);
    if (maxBytes == 0 || queuedBytes + incomingBytes <= maxBytes) {
        return 0;
    }
    return (queuedBytes + incomingBytes) - maxBytes;
}
