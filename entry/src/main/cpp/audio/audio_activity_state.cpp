#include "audio_activity_state.h"

void AudioActivityState::recordPcmFrame(size_t bytes) {
    if (bytes == 0) {
        return;
    }
    receivedPcm_.store(true);
    pcmFrames_.fetch_add(1);
}

void AudioActivityState::setMuted(bool muted) {
    muted_.store(muted);
}

bool AudioActivityState::isMuted() const {
    return muted_.load();
}

bool AudioActivityState::hasReceivedPcm() const {
    return receivedPcm_.load();
}

bool AudioActivityState::shouldDropIncomingPcm() const {
    return muted_.load();
}

uint64_t AudioActivityState::pcmFrameCount() const {
    return pcmFrames_.load();
}

void AudioActivityState::reset() {
    muted_.store(false);
    receivedPcm_.store(false);
    pcmFrames_.store(0);
}
