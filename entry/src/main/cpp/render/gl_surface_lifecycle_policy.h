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

} // namespace Render

#endif // GL_SURFACE_LIFECYCLE_POLICY_H
