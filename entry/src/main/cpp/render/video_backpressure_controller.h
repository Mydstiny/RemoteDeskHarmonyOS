/**
 * video_backpressure_controller.h — 视频过载/关键帧恢复策略
 *
 * 纯 C++ 策略类, 不依赖 OH_AVCodec/GL, 便于单元测试。
 */

#ifndef VIDEO_BACKPRESSURE_CONTROLLER_H
#define VIDEO_BACKPRESSURE_CONTROLLER_H

#include <cstdint>
#include <cstddef>

namespace Render {

enum class VideoFrameAdmission {
    Accept,
    AcceptAfterSoftDrop,
    DropWaitingKeyframe,
    AcceptRecoveryKeyframe,
};

class VideoBackpressureController {
public:
    explicit VideoBackpressureController(size_t maxQueuedFrames = 12);

    VideoFrameAdmission admitFrame(size_t queuedFrames, bool isKeyFrame);
    void enterHardWaitForKeyframe();
    void onKeyframeRequested();
    void reset();

    bool isWaitingForKeyframe() const { return waitingForKeyframe_; }
    bool shouldRequestKeyframe() const { return keyframeRequestPending_; }
    uint64_t droppedFrames() const { return droppedFrames_; }
    uint64_t waitKeyframeDrops() const { return waitKeyframeDrops_; }
    uint64_t keyframeRequests() const { return keyframeRequests_; }

private:
    size_t maxQueuedFrames_;
    bool waitingForKeyframe_;
    bool keyframeRequestPending_;
    uint64_t droppedFrames_;
    uint64_t waitKeyframeDrops_;
    uint64_t keyframeRequests_;
};

} // namespace Render

#endif // VIDEO_BACKPRESSURE_CONTROLLER_H
