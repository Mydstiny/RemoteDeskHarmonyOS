#include "test_runner.h"
#include "audio/audio_queue_policy.h"

RDP_TEST_CASE(audio_queue_policy_converts_ms_to_frame_aligned_bytes) {
    RDP_ASSERT(AudioBytesForDurationMs(48000, 2, 120) == 23040);
    RDP_ASSERT(AudioBytesForDurationMs(44100, 2, 120) == 21168);
    RDP_ASSERT(AudioBytesForDurationMs(48000, 1, 5) == 480);
}

RDP_TEST_CASE(audio_queue_policy_requires_prebuffer_before_playback) {
    AudioQueuePolicyConfig cfg;
    cfg.sampleRate = 48000;
    cfg.channels = 2;
    cfg.prebufferMs = 120;

    RDP_ASSERT(!ShouldReleaseAudioFromPrebuffer(cfg, 0));
    RDP_ASSERT(!ShouldReleaseAudioFromPrebuffer(cfg, 23039));
    RDP_ASSERT(ShouldReleaseAudioFromPrebuffer(cfg, 23040));
}

RDP_TEST_CASE(audio_queue_policy_limits_buffer_by_latency_budget) {
    AudioQueuePolicyConfig cfg;
    cfg.sampleRate = 48000;
    cfg.channels = 2;
    cfg.maxBufferMs = 500;

    RDP_ASSERT(MaxAudioQueueBytes(cfg) == 96000);
    RDP_ASSERT(AudioDropBytesForOverflow(cfg, 90000, 1920) == 0);
    RDP_ASSERT(AudioDropBytesForOverflow(cfg, 96000, 1920) == 1920);
    RDP_ASSERT(AudioDropBytesForOverflow(cfg, 95000, 4000) == 3000);
}

RDP_TEST_CASE(audio_queue_policy_keeps_small_packets_low_latency) {
    RDP_ASSERT(AudioDurationMsForBytes(48000, 2, 3840) == 20);
    RDP_ASSERT(RecommendedPrebufferMsForIncomingChunk(48000, 2, 3840) == 120);
    RDP_ASSERT(RecommendedMaxBufferMsForPrebuffer(120) == 500);
}

RDP_TEST_CASE(audio_queue_policy_expands_prebuffer_for_rdp_sized_packets) {
    RDP_ASSERT(AudioDurationMsForBytes(44100, 2, 32768) == 185);
    RDP_ASSERT(RecommendedPrebufferMsForIncomingChunk(44100, 2, 32768) == 300);

    const AudioQueuePolicyConfig cfg = AudioQueuePolicyForIncomingPcm(44100, 2, 32768);
    RDP_ASSERT(cfg.sampleRate == 44100);
    RDP_ASSERT(cfg.channels == 2);
    RDP_ASSERT(cfg.prebufferMs == 300);
    RDP_ASSERT(cfg.maxBufferMs == 800);
}
