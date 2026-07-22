/**
 * decoder_pipeline_lifecycle_policy.h — software pipeline admission policy.
 *
 * A frame may only enter the software queue while the video pipeline is
 * attached and its worker is not in the stop/join phase.  Keeping this rule
 * as a pure policy makes the detach contract testable without OHOS/NAPI.
 */

#ifndef DECODER_PIPELINE_LIFECYCLE_POLICY_H
#define DECODER_PIPELINE_LIFECYCLE_POLICY_H

namespace Render {

inline bool ShouldAcceptSoftwareDecoderFrame(bool pipelineAttached, bool workerStopping) {
    return pipelineAttached && !workerStopping;
}

} // namespace Render

#endif // DECODER_PIPELINE_LIFECYCLE_POLICY_H
