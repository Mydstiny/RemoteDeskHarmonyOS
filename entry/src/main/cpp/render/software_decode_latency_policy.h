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

} // namespace Render

#endif // SOFTWARE_DECODE_LATENCY_POLICY_H
