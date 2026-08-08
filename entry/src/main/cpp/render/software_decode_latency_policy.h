/**
 * software_decode_latency_policy.h — 软件视频解码低延迟展示策略
 */

#ifndef SOFTWARE_DECODE_LATENCY_POLICY_H
#define SOFTWARE_DECODE_LATENCY_POLICY_H

#include <cstddef>

namespace Render {

// 压缩帧仍须全部解码以维护 VP8/VP9/AV1 参考链；积压时仅跳过昂贵的
// 色彩转换和纹理提交，追到队尾后立即恢复展示。
inline bool shouldPresentSoftwareDecodedFrame(size_t newerQueuedFrames) {
    return newerQueuedFrames <= 1;
}

enum class SoftwareDecodeQueueAction {
    Queue,
    QueueAfterReset,
    DropWaitingKeyframe,
    DropAndRequestKeyframe,
};

// Dropping any dependent VPx frame breaks the decoder reference chain. Keep
// the recovery state beside the queue and request exactly one keyframe until
// that keyframe arrives; repeated refresh requests can make the remote host
// recreate its encoder continuously and worsen latency.
class SoftwareDecodeQueueRecoveryPolicy {
public:
    SoftwareDecodeQueueAction classify(bool queueAtCapacity, bool isKeyframe) {
        if (waitingForKeyframe_) {
            if (!isKeyframe) {
                return SoftwareDecodeQueueAction::DropWaitingKeyframe;
            }
            waitingForKeyframe_ = false;
            return SoftwareDecodeQueueAction::QueueAfterReset;
        }
        if (!queueAtCapacity) {
            return SoftwareDecodeQueueAction::Queue;
        }
        if (isKeyframe) {
            return SoftwareDecodeQueueAction::QueueAfterReset;
        }
        waitingForKeyframe_ = true;
        return SoftwareDecodeQueueAction::DropAndRequestKeyframe;
    }

    bool waitingForKeyframe() const {
        return waitingForKeyframe_;
    }

    void reset() {
        waitingForKeyframe_ = false;
    }

private:
    bool waitingForKeyframe_ = false;
};

} // namespace Render

#endif // SOFTWARE_DECODE_LATENCY_POLICY_H
