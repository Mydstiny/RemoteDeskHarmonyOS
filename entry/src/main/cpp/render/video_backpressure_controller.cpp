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
    if (waitingForKeyframe_) {
        if (isKeyFrame) {
            waitingForKeyframe_ = false;
            keyframeRequestPending_ = false;
            return VideoFrameAdmission::AcceptRecoveryKeyframe;
        }
        ++droppedFrames_;
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
    waitingForKeyframe_ = true;
    if (!keyframeRequestPending_) {
        keyframeRequestPending_ = true;
        ++keyframeRequests_;
    }
}

void VideoBackpressureController::onKeyframeRequested() {
    keyframeRequestPending_ = false;
}

void VideoBackpressureController::reset() {
    waitingForKeyframe_ = false;
    keyframeRequestPending_ = false;
    droppedFrames_ = 0;
    waitKeyframeDrops_ = 0;
    keyframeRequests_ = 0;
}

} // namespace Render
