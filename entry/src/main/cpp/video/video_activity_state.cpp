#include "video_activity_state.h"

void VideoActivityState::recordFrame(size_t bytes, int width, int height) {
    if (bytes == 0 || width <= 0 || height <= 0) {
        return;
    }
    receivedFrame_.store(true);
    frameCount_.fetch_add(1);
}

bool VideoActivityState::hasReceivedFrame() const {
    return receivedFrame_.load();
}

uint64_t VideoActivityState::frameCount() const {
    return frameCount_.load();
}

void VideoActivityState::reset() {
    receivedFrame_.store(false);
    frameCount_.store(0);
}

static VideoActivityState g_remoteVideoActivityState;

void recordRemoteVideoFrame(size_t bytes, int width, int height) {
    g_remoteVideoActivityState.recordFrame(bytes, width, height);
}

bool isRemoteVideoPlaybackActive() {
    return g_remoteVideoActivityState.hasReceivedFrame();
}

void resetRemoteVideoActivity() {
    g_remoteVideoActivityState.reset();
}
