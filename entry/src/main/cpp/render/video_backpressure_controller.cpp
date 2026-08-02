/**
 * video_backpressure_controller.cpp — 视频过载/关键帧恢复策略
 */

#include "video_backpressure_controller.h"

namespace Render {

VideoBackpressureController::VideoBackpressureController(size_t maxQueuedFrames)
    : maxQueuedFrames_(maxQueuedFrames == 0 ? 1 : maxQueuedFrames),
      waitingForKeyframe_(false),
      keyframeRequestPending_(false),
      droppedFrames_(0),
      waitKeyframeDrops_(0),
      keyframeRequests_(0) {}

VideoFrameAdmission VideoBackpressureController::admitFrame(size_t queuedFrames, bool isKeyFrame) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (waitingForKeyframe_) {
        if (isKeyFrame) {
            waitingForKeyframe_ = false;
            keyframeRequestPending_ = false;
            return VideoFrameAdmission::AcceptRecoveryKeyframe;
        }
        // Waiting-for-keyframe is a mutually exclusive drop class. Keep it
        // out of droppedFrames_ so telemetry cannot add input+wait a second
        // time when it combines the two explicit counters.
        ++waitKeyframeDrops_;
        if (!keyframeRequestPending_) {
            keyframeRequestPending_ = true;
            ++keyframeRequests_;
        }
        return VideoFrameAdmission::DropWaitingKeyframe;
    }

    if (queuedFrames >= maxQueuedFrames_) {
        ++droppedFrames_;
        if (!isKeyFrame && !keyframeRequestPending_) {
            keyframeRequestPending_ = true;
            ++keyframeRequests_;
        }
        return isKeyFrame ? VideoFrameAdmission::AcceptRecoveryKeyframe :
            VideoFrameAdmission::AcceptAfterSoftDrop;
    }

    return VideoFrameAdmission::Accept;
}

void VideoBackpressureController::enterHardWaitForKeyframe() {
    std::lock_guard<std::mutex> lock(mutex_);
    waitingForKeyframe_ = true;
    if (!keyframeRequestPending_) {
        keyframeRequestPending_ = true;
        ++keyframeRequests_;
    }
}

void VideoBackpressureController::onKeyframeRequested() {
    std::lock_guard<std::mutex> lock(mutex_);
    keyframeRequestPending_ = false;
}

void VideoBackpressureController::reset() {
    std::lock_guard<std::mutex> lock(mutex_);
    waitingForKeyframe_ = false;
    keyframeRequestPending_ = false;
    droppedFrames_ = 0;
    waitKeyframeDrops_ = 0;
    keyframeRequests_ = 0;
}

bool VideoBackpressureController::isWaitingForKeyframe() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return waitingForKeyframe_;
}

bool VideoBackpressureController::shouldRequestKeyframe() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return keyframeRequestPending_;
}

uint64_t VideoBackpressureController::droppedFrames() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return droppedFrames_;
}

uint64_t VideoBackpressureController::waitKeyframeDrops() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return waitKeyframeDrops_;
}

uint64_t VideoBackpressureController::keyframeRequests() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return keyframeRequests_;
}

} // namespace Render
