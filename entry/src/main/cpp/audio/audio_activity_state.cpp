#include "audio_activity_state.h"

#include <chrono>

namespace {
uint64_t AudioActivityNowMs() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}
}

void AudioActivityState::recordPcmFrame(size_t bytes) {
    recordPcmFrame(bytes, AudioActivityNowMs());
}

void AudioActivityState::recordPcmFrame(size_t bytes, uint64_t nowMs) {
    if (bytes == 0) {
        return;
    }
    receivedPcm_.store(true);
    pcmFrames_.fetch_add(1);
    lastPcmAtMs_.store(nowMs, std::memory_order_release);
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

bool AudioActivityState::pollInactivity(uint64_t nowMs) {
    const uint64_t lastPcmAtMs = lastPcmAtMs_.load(std::memory_order_acquire);
    if (!receivedPcm_.load(std::memory_order_acquire) ||
        muted_.load(std::memory_order_acquire) || lastPcmAtMs == 0 ||
        nowMs < lastPcmAtMs || nowMs - lastPcmAtMs < 1500) {
        return false;
    }
    bool expected = false;
    return inactivitySuspended_.compare_exchange_strong(
        expected, true, std::memory_order_acq_rel);
}

bool AudioActivityState::inactivitySuspended() const {
    return inactivitySuspended_.load(std::memory_order_acquire);
}

uint64_t AudioActivityState::lastPcmAtMs() const {
    return lastPcmAtMs_.load(std::memory_order_acquire);
}

void AudioActivityState::markResumed() {
    inactivitySuspended_.store(false, std::memory_order_release);
}

void AudioActivityState::reset() {
    muted_.store(false);
    receivedPcm_.store(false);
    pcmFrames_.store(0);
    lastPcmAtMs_.store(0, std::memory_order_release);
    inactivitySuspended_.store(false, std::memory_order_release);
}
