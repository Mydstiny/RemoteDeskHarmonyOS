#ifndef VIDEO_ACTIVITY_STATE_H
#define VIDEO_ACTIVITY_STATE_H

#include <atomic>
#include <cstddef>
#include <cstdint>

class VideoActivityState {
public:
    void recordFrame(size_t bytes, int width, int height);
    bool hasReceivedFrame() const;
    uint64_t frameCount() const;
    void reset();

private:
    std::atomic<bool> receivedFrame_ {false};
    std::atomic<uint64_t> frameCount_ {0};
};

void recordRemoteVideoFrame(size_t bytes, int width, int height);
bool isRemoteVideoPlaybackActive();
void resetRemoteVideoActivity();

#endif // VIDEO_ACTIVITY_STATE_H
