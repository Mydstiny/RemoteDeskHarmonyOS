#include "test_runner.h"
#include "audio/audio_activity_state.h"

RDP_TEST_CASE(audio_activity_starts_inactive_until_pcm_arrives) {
    AudioActivityState state;
    RDP_ASSERT(!state.hasReceivedPcm());
    state.recordPcmFrame(480);
    RDP_ASSERT(state.hasReceivedPcm());
}

RDP_TEST_CASE(audio_activity_mute_drops_incoming_pcm_without_clearing_activity) {
    AudioActivityState state;
    state.recordPcmFrame(480);
    state.setMuted(true);
    RDP_ASSERT(state.hasReceivedPcm());
    RDP_ASSERT(state.isMuted());
    RDP_ASSERT(state.shouldDropIncomingPcm());
    state.setMuted(false);
    RDP_ASSERT(!state.isMuted());
    RDP_ASSERT(!state.shouldDropIncomingPcm());
}

RDP_TEST_CASE(audio_activity_reset_clears_activity_and_mute) {
    AudioActivityState state;
    state.recordPcmFrame(480);
    state.setMuted(true);
    state.reset();
    RDP_ASSERT(!state.hasReceivedPcm());
    RDP_ASSERT(!state.isMuted());
    RDP_ASSERT(!state.shouldDropIncomingPcm());
}
