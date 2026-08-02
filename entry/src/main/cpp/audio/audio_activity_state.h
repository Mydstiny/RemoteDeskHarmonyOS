#ifndef AUDIO_ACTIVITY_STATE_H
#define AUDIO_ACTIVITY_STATE_H

#include <atomic>
#include <cstddef>
#include <cstdint>

class AudioActivityState {
public:
    void recordPcmFrame(size_t bytes);
    void recordPcmFrame(size_t bytes, uint64_t nowMs);
    void setMuted(bool muted);
    bool isMuted() const;
    bool hasReceivedPcm() const;
    bool shouldDropIncomingPcm() const;
    uint64_t pcmFrameCount() const;
    bool pollInactivity(uint64_t nowMs);
    bool inactivitySuspended() const;
    uint64_t lastPcmAtMs() const;
    void markResumed();
    void reset();

private:
    std::atomic<bool> muted_ {false};
    std::atomic<bool> receivedPcm_ {false};
    std::atomic<uint64_t> pcmFrames_ {0};
    std::atomic<uint64_t> lastPcmAtMs_ {0};
    std::atomic<bool> inactivitySuspended_ {false};
};

#endif // AUDIO_ACTIVITY_STATE_H
