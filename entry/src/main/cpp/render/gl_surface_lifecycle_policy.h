#ifndef GL_SURFACE_LIFECYCLE_POLICY_H
#define GL_SURFACE_LIFECYCLE_POLICY_H

#include <cstdint>

namespace Render {

inline bool ShouldReplaceSurfaceWindow(bool hasNativeWindow,
                                       uint64_t currentSurfaceId,
                                       uint64_t requestedSurfaceId,
                                       bool surfaceDetached) {
    if (!hasNativeWindow) {
        return true;
    }
    return surfaceDetached || currentSurfaceId != requestedSurfaceId;
}

/**
 * A renderer generation fences ownership transfers, not repeated publication
 * of the same live token. Re-publishing an already-active exact handle/owner
 * must therefore be idempotent. Otherwise initRenderer() followed by decoder
 * bind advances the generation twice and the decoder immediately rejects the
 * renderer generation it sampled between those two calls.
 */
inline bool ShouldAdvanceRendererGeneration(int64_t activeHandle,
                                            int64_t requestedHandle,
                                            bool contextActive,
                                            bool contextDetached,
                                            bool ownerMatches,
                                            uint64_t contextGeneration) {
    return activeHandle != requestedHandle || !contextActive ||
        contextDetached || !ownerMatches || contextGeneration == 0U;
}

} // namespace Render

#endif // GL_SURFACE_LIFECYCLE_POLICY_H
