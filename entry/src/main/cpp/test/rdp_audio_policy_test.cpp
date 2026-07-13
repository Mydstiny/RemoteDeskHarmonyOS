#include "test_runner.h"
#include "rdp/rdp_audio_policy.h"

RDP_TEST_CASE(rdp_audio_policy_accepts_only_s16_pcm) {
    RdpAudioPcmDecision ok = evaluateRdpAudioPcm(48000, 2, 16, 4096);
    RDP_ASSERT(ok.accepted);
    RDP_ASSERT(ok.bytesToSubmit == 4096);

    RdpAudioPcmDecision rejected = evaluateRdpAudioPcm(48000, 2, 8, 4096);
    RDP_ASSERT(!rejected.accepted);
    RDP_ASSERT(rejected.bytesToSubmit == 0);
}

RDP_TEST_CASE(rdp_audio_policy_rejects_invalid_rate_or_channels) {
    RDP_ASSERT(!evaluateRdpAudioPcm(0, 2, 16, 4096).accepted);
    RDP_ASSERT(!evaluateRdpAudioPcm(48000, 0, 16, 4096).accepted);
    RDP_ASSERT(!evaluateRdpAudioPcm(48000, 9, 16, 4096).accepted);
}

RDP_TEST_CASE(rdp_audio_policy_trims_to_complete_s16_frames) {
    RdpAudioPcmDecision decision = evaluateRdpAudioPcm(44100, 2, 16, 4097);
    RDP_ASSERT(decision.accepted);
    RDP_ASSERT(decision.bytesToSubmit == 4096);
}

RDP_TEST_CASE(rdp_audio_policy_rejects_zero_or_too_small_pcm) {
    RDP_ASSERT(!evaluateRdpAudioPcm(44100, 2, 16, 0).accepted);
    RDP_ASSERT(!evaluateRdpAudioPcm(44100, 2, 16, 3).accepted);
}
